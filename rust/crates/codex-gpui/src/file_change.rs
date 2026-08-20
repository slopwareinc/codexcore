//! Swift-shaped file-change projections and native diff rendering.
//!
//! The app-server presentation layer deliberately keeps file changes close to
//! the wire (`FileChangePresentation`).  This module turns that lossless value
//! into a bounded, renderer-friendly file list and unified-diff model.  The
//! projection is pure so hosts can inspect the selected file and hunk gutter
//! without constructing a GPUI window.

use codex_presentation::{
    FileChangeKind, FileChangePresentation,
    transcript_v2::{FileChangeRowV2, WorkItemStatusV2},
};
use gpui::{AnyElement, KeyDownEvent, Role, WeakEntity, div, prelude::*, px};

use crate::{
    CodexTheme, TranscriptLayoutMetrics, transcript::is_activation_key,
    transcript_v2::CodexTranscriptV2,
};

/// Maximum number of file entries shown in a single file-change row.
pub const MAX_VISIBLE_FILES: usize = 12;
/// Maximum number of diff lines retained for one file.
pub const MAX_VISIBLE_DIFF_LINES: usize = 240;
/// Maximum number of bytes inspected from one diff.
pub const MAX_DIFF_BYTES: usize = 64 * 1_024;
/// Maximum height of the selected-file diff viewport.
pub const MAX_DIFF_HEIGHT: f32 = 280.;
/// Width reserved for old/new line-number gutters.
pub const DIFF_GUTTER_WIDTH: f32 = 76.;

/// A unified-diff line with independent old/new gutters.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DiffLineProjection {
    pub kind: DiffLineKind,
    pub old_line: Option<usize>,
    pub new_line: Option<usize>,
    /// Text without the leading unified-diff marker for code lines.
    pub text: String,
}

/// Semantic line style used by the native diff renderer.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DiffLineKind {
    Context,
    Addition,
    Deletion,
    Metadata,
}

impl DiffLineKind {
    #[must_use]
    pub const fn marker(self) -> char {
        match self {
            Self::Context => ' ',
            Self::Addition => '+',
            Self::Deletion => '-',
            Self::Metadata => '·',
        }
    }
}

/// A bounded unified-diff hunk.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DiffHunkProjection {
    pub header: String,
    pub old_start: Option<usize>,
    pub old_count: Option<usize>,
    pub new_start: Option<usize>,
    pub new_count: Option<usize>,
    pub lines: Vec<DiffLineProjection>,
}

/// One file in the selected-file list.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FileDiffProjection {
    pub path: String,
    pub destination_path: Option<String>,
    pub kind: FileChangeKind,
    pub additions: usize,
    pub deletions: usize,
    pub hunks: Vec<DiffHunkProjection>,
    /// A user-safe fallback for malformed wire data.  Raw payloads are not
    /// copied into visible text, keeping malformed responses bounded.
    pub malformed_fallback: Option<String>,
    pub truncated: bool,
}

/// File list plus selected file, suitable for a Swift-style split diff card.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FileChangeProjection {
    pub files: Vec<FileDiffProjection>,
    pub selected_index: Option<usize>,
    pub hidden_file_count: usize,
}

impl FileChangeProjection {
    /// Project at most [`MAX_VISIBLE_FILES`] files and clamp selection safely.
    #[must_use]
    pub fn from_changes(changes: &[FileChangePresentation], selected_index: usize) -> Self {
        let files = changes
            .iter()
            .take(MAX_VISIBLE_FILES)
            .map(project_file)
            .collect::<Vec<_>>();
        let selected_index = (!files.is_empty()).then_some(selected_index.min(files.len() - 1));
        Self {
            files,
            selected_index,
            hidden_file_count: changes.len().saturating_sub(MAX_VISIBLE_FILES),
        }
    }

    #[must_use]
    pub fn selected_file(&self) -> Option<&FileDiffProjection> {
        self.selected_index.and_then(|index| self.files.get(index))
    }
}

/// Pure file-change card geometry, independent of a GPUI viewport.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FileChangeLayout {
    pub card_width: f32,
    pub file_list_width: f32,
    pub diff_width: f32,
    pub gutter_width: f32,
    pub diff_max_height: f32,
}

impl FileChangeLayout {
    #[must_use]
    pub fn for_viewport(viewport_width: f32) -> Self {
        let card_width = TranscriptLayoutMetrics::card_width(viewport_width);
        let file_list_width = (card_width * 0.30).clamp(140., 220.);
        Self {
            card_width,
            file_list_width,
            diff_width: (card_width - file_list_width).max(1.),
            gutter_width: DIFF_GUTTER_WIDTH,
            diff_max_height: MAX_DIFF_HEIGHT,
        }
    }
}

/// Parse a unified diff into bounded hunks and line gutters.
///
/// Invalid hunk headers never panic: the resulting hunk retains its raw
/// bounded header and lines simply omit gutters.  The caller can still render
/// a useful textual diff, or use `malformed_fallback` for a malformed payload.
#[must_use]
pub fn parse_unified_diff(diff: &str) -> (Vec<DiffHunkProjection>, usize, usize, bool) {
    let (bounded, truncated_bytes) = bounded_diff(diff);
    let mut hunks = Vec::new();
    let mut current: Option<DiffHunkProjection> = None;
    let mut old_cursor = None;
    let mut new_cursor = None;
    let mut additions: usize = 0;
    let mut deletions: usize = 0;
    let mut retained_lines = 0;
    let mut truncated = truncated_bytes;

    for raw in bounded.lines() {
        if raw.starts_with("@@") {
            if let Some(hunk) = current.take() {
                hunks.push(hunk);
            }
            let (old_start, old_count, new_start, new_count) = parse_hunk_header(raw);
            old_cursor = old_start;
            new_cursor = new_start;
            current = Some(DiffHunkProjection {
                header: bounded_text(raw, 512),
                old_start,
                old_count,
                new_start,
                new_count,
                lines: Vec::new(),
            });
            continue;
        }

        if retained_lines >= MAX_VISIBLE_DIFF_LINES {
            truncated = true;
            break;
        }
        let (kind, text) = classify_line(raw);
        let (old_line, new_line) = match kind {
            DiffLineKind::Context => {
                let old = old_cursor;
                let new = new_cursor;
                old_cursor = old_cursor.and_then(|line| line.checked_add(1));
                new_cursor = new_cursor.and_then(|line| line.checked_add(1));
                (old, new)
            }
            DiffLineKind::Addition => {
                additions = additions.saturating_add(1);
                let new = new_cursor;
                new_cursor = new_cursor.and_then(|line| line.checked_add(1));
                (None, new)
            }
            DiffLineKind::Deletion => {
                deletions = deletions.saturating_add(1);
                let old = old_cursor;
                old_cursor = old_cursor.and_then(|line| line.checked_add(1));
                (old, None)
            }
            DiffLineKind::Metadata => (None, None),
        };
        let line = DiffLineProjection {
            kind,
            old_line,
            new_line,
            text,
        };
        current.get_or_insert_with(|| DiffHunkProjection {
            header: "Changes".to_owned(),
            old_start: None,
            old_count: None,
            new_start: None,
            new_count: None,
            lines: Vec::new(),
        });
        if let Some(hunk) = current.as_mut() {
            hunk.lines.push(line);
        }
        retained_lines += 1;
    }
    if let Some(hunk) = current {
        hunks.push(hunk);
    }
    (hunks, additions, deletions, truncated)
}

fn project_file(change: &FileChangePresentation) -> FileDiffProjection {
    let (hunks, additions, deletions, truncated) = parse_unified_diff(&change.diff);
    let malformed_fallback = change
        .malformed_raw
        .as_ref()
        .map(|_| "Diff unavailable: malformed file-change data from the app server.".to_owned());
    FileDiffProjection {
        path: bounded_text(&change.path, 512),
        destination_path: change
            .destination_path
            .as_deref()
            .map(|path| bounded_text(path, 512)),
        kind: change.kind.clone(),
        additions,
        deletions,
        hunks,
        malformed_fallback,
        truncated,
    }
}

fn bounded_diff(diff: &str) -> (&str, bool) {
    if diff.len() <= MAX_DIFF_BYTES {
        return (diff, false);
    }
    let mut end = MAX_DIFF_BYTES;
    while !diff.is_char_boundary(end) {
        end = end.saturating_sub(1);
    }
    (&diff[..end], true)
}

fn bounded_text(text: &str, maximum_chars: usize) -> String {
    let mut value = text.chars().take(maximum_chars).collect::<String>();
    if text.chars().count() > maximum_chars {
        value.push('…');
    }
    value
}

fn classify_line(raw: &str) -> (DiffLineKind, String) {
    if raw.starts_with("+++") || raw.starts_with("---") || raw.starts_with('\\') {
        return (DiffLineKind::Metadata, bounded_text(raw, 4_096));
    }
    match raw.chars().next() {
        Some('+') => (DiffLineKind::Addition, bounded_text(&raw[1..], 4_096)),
        Some('-') => (DiffLineKind::Deletion, bounded_text(&raw[1..], 4_096)),
        Some(' ') => (DiffLineKind::Context, bounded_text(&raw[1..], 4_096)),
        _ => (DiffLineKind::Metadata, bounded_text(raw, 4_096)),
    }
}

fn parse_hunk_header(header: &str) -> (Option<usize>, Option<usize>, Option<usize>, Option<usize>) {
    let Some(rest) = header.strip_prefix("@@") else {
        return (None, None, None, None);
    };
    let Some(end) = rest.find("@@") else {
        return (None, None, None, None);
    };
    let ranges = rest[..end].split_whitespace().collect::<Vec<_>>();
    let (Some(old), Some(new)) = (ranges.first().copied(), ranges.get(1).copied()) else {
        return (None, None, None, None);
    };
    let (old_start, old_count) =
        parse_range(old, '-').map_or((None, None), |(start, count)| (Some(start), Some(count)));
    let (new_start, new_count) =
        parse_range(new, '+').map_or((None, None), |(start, count)| (Some(start), Some(count)));
    (old_start, old_count, new_start, new_count)
}

fn parse_range(value: &str, marker: char) -> Option<(usize, usize)> {
    let value = value.strip_prefix(marker)?;
    let (start, count) = value
        .split_once(',')
        .map_or((value, "1"), |(start, count)| (start, count));
    let start = start.parse().ok()?;
    let count = count.parse().ok()?;
    Some((start, count))
}

/// Render a file-change row with a selected-file list and bounded diff panel.
#[allow(clippy::too_many_arguments)]
pub(crate) fn render_file_change_row(
    id: &str,
    group_key: &str,
    row: &FileChangeRowV2,
    theme: CodexTheme,
    emitter: &WeakEntity<CodexTranscriptV2>,
    expanded: bool,
    selected_index: usize,
) -> AnyElement {
    let projection = FileChangeProjection::from_changes(&row.changes, selected_index);
    let label = file_change_label(&projection, &row.status);
    let row_key = id.to_owned();
    let header = render_row_header(
        id,
        &label,
        &row.status,
        expanded,
        emitter,
        row_key.clone(),
        group_key.to_owned(),
        theme,
    );
    div()
        .id(format!("work-row:{id}"))
        .role(Role::ListItem)
        .aria_label(format!("File changes: {label}"))
        .w_full()
        .flex()
        .flex_col()
        .child(header)
        .when(expanded, |view| {
            view.child(render_file_change_details(
                id,
                group_key,
                &projection,
                theme,
                emitter,
            ))
        })
        .into_any()
}

fn file_change_label(projection: &FileChangeProjection, status: &WorkItemStatusV2) -> String {
    let count = projection.files.len() + projection.hidden_file_count;
    let status = match status {
        WorkItemStatusV2::InProgress => "Editing",
        WorkItemStatusV2::Completed => "Edited",
        WorkItemStatusV2::Failed => "Edit failed",
        WorkItemStatusV2::Declined => "Edit stopped",
        WorkItemStatusV2::Unknown(_) => "Edit status unknown",
    };
    format!("{status} {count} file{}", if count == 1 { "" } else { "s" })
}

#[allow(clippy::too_many_arguments)]
fn render_row_header(
    id: &str,
    label: &str,
    status: &WorkItemStatusV2,
    expanded: bool,
    emitter: &WeakEntity<CodexTranscriptV2>,
    row_key: String,
    group_key: String,
    theme: CodexTheme,
) -> AnyElement {
    let click_emitter = emitter.clone();
    let keyboard_emitter = emitter.clone();
    let keyboard_row_key = row_key.clone();
    let keyboard_group_key = group_key.clone();
    div()
        .id(format!("{id}:disclosure"))
        .role(Role::Button)
        .aria_label(format!(
            "{label}, {}",
            if expanded { "expanded" } else { "collapsed" }
        ))
        .aria_expanded(expanded)
        .focusable()
        .tab_stop(true)
        .cursor_pointer()
        .h(px(TranscriptLayoutMetrics::WORK_ROW_HEIGHT))
        .w_full()
        .pr_2()
        .flex()
        .items_center()
        .gap_2()
        .text_size(px(TranscriptLayoutMetrics::CAPTION_TEXT_SIZE))
        .text_color(theme.tertiary_text)
        .child(div().w(px(14.)).text_color(theme.muted_text).child("✎"))
        .child(status_glyph(status, theme))
        .child(div().min_w_0().flex_1().truncate().child(label.to_owned()))
        .child(div().child(if expanded { "⌄" } else { "›" }))
        .on_click(move |_, _, cx| {
            click_emitter
                .update(cx, |transcript, cx| {
                    transcript.toggle_work_row(row_key.clone(), &group_key, cx);
                })
                .ok();
        })
        .on_key_down(move |event, window, cx| {
            if is_activation_key(&event.keystroke.key) {
                window.prevent_default();
                keyboard_emitter
                    .update(cx, |transcript, cx| {
                        transcript.toggle_work_row(
                            keyboard_row_key.clone(),
                            &keyboard_group_key,
                            cx,
                        );
                    })
                    .ok();
            }
        })
        .into_any()
}

#[allow(clippy::too_many_lines)]
fn render_file_change_details(
    id: &str,
    group_key: &str,
    projection: &FileChangeProjection,
    theme: CodexTheme,
    emitter: &WeakEntity<CodexTranscriptV2>,
) -> AnyElement {
    let selected = projection.selected_file();
    let selected_index = projection.selected_index;
    let file_buttons = projection.files.iter().enumerate().map(|(index, file)| {
        let selected = selected_index == Some(index);
        let row_key = id.to_owned();
        let keyboard_row_key = row_key.clone();
        let row_group_key = group_key.to_owned();
        let keyboard_group_key = row_group_key.clone();
        let emitter = emitter.clone();
        let keyboard_emitter = emitter.clone();
        let path = file.path.clone();
        div()
            .id(format!("{id}:file:{index}"))
            .role(Role::Button)
            .aria_label(format!(
                "{}{}",
                path,
                if selected { ", selected" } else { "" }
            ))
            .aria_selected(selected)
            .focusable()
            .tab_stop(true)
            .cursor_pointer()
            .w_full()
            .px_2()
            .py_1()
            .text_size(px(TranscriptLayoutMetrics::CAPTION_TEXT_SIZE))
            .text_color(if selected {
                theme.text
            } else {
                theme.muted_text
            })
            .bg(if selected {
                theme.elevated_surface
            } else {
                theme.surface
            })
            .child(
                div()
                    .min_w_0()
                    .truncate()
                    .font_family("monospace")
                    .child(path),
            )
            .child(file_counts(file, theme))
            .on_click(move |_, _, cx| {
                emitter
                    .update(cx, |transcript, cx| {
                        transcript.select_file_change(&row_key, index, &row_group_key, cx);
                    })
                    .ok();
            })
            .on_key_down(move |event: &KeyDownEvent, window, cx| {
                if is_activation_key(&event.keystroke.key) {
                    window.prevent_default();
                    keyboard_emitter
                        .update(cx, |transcript, cx| {
                            transcript.select_file_change(
                                &keyboard_row_key,
                                index,
                                &keyboard_group_key,
                                cx,
                            );
                        })
                        .ok();
                }
            })
            .into_any()
    });
    let layout = FileChangeLayout::for_viewport(TranscriptLayoutMetrics::CARD_MAX_WIDTH);
    div()
        .id(format!("{id}:details"))
        .role(Role::Region)
        .aria_label("File change details")
        .ml(px(38.))
        .mb_2()
        .w_full()
        .max_w(px(TranscriptLayoutMetrics::CARD_MAX_WIDTH))
        .flex()
        .border_1()
        .border_color(theme.border)
        .bg(theme.surface)
        .rounded_md()
        .overflow_hidden()
        .child(
            div()
                .id(format!("{id}:files"))
                .role(Role::List)
                .aria_label("Changed files")
                .w(px(layout.file_list_width))
                .flex_none()
                .overflow_y_scroll()
                .children(file_buttons)
                .when(projection.hidden_file_count > 0, |view| {
                    view.child(
                        div()
                            .px_2()
                            .py_1()
                            .text_size(px(TranscriptLayoutMetrics::CAPTION_TEXT_SIZE))
                            .text_color(theme.muted_text)
                            .child(format!("+{} more file(s)", projection.hidden_file_count)),
                    )
                }),
        )
        .child(
            div()
                .id(format!("{id}:diff"))
                .role(Role::Region)
                .aria_label(selected.map_or_else(
                    || "Selected file diff".to_owned(),
                    |file| format!("Diff for {}", file.path),
                ))
                .min_w_0()
                .flex_1()
                .max_h(px(layout.diff_max_height))
                .overflow_y_scroll()
                .overflow_x_scroll()
                .font_family("monospace")
                .text_size(px(TranscriptLayoutMetrics::CAPTION_TEXT_SIZE))
                .when_some(selected, |view, file| {
                    view.child(render_selected_file(file, theme))
                }),
        )
        .into_any()
}

fn render_selected_file(file: &FileDiffProjection, theme: CodexTheme) -> AnyElement {
    let fallback = file.malformed_fallback.clone();
    div()
        .id("selected-file-diff")
        .w_full()
        .when_some(fallback, |view, fallback| {
            view.child(
                div()
                    .p_2()
                    .text_color(theme.warning)
                    .whitespace_normal()
                    .child(fallback),
            )
        })
        .when(
            file.hunks.is_empty() && file.malformed_fallback.is_none(),
            |view| {
                view.child(
                    div()
                        .p_2()
                        .text_color(theme.muted_text)
                        .child("No textual diff available."),
                )
            },
        )
        .children(file.hunks.iter().enumerate().map(|(hunk_index, hunk)| {
            let header = div()
                .id(("file-hunk", hunk_index))
                .w_full()
                .px_2()
                .py_1()
                .text_color(theme.accent)
                .bg(theme.elevated_surface)
                .child(hunk.header.clone());
            let lines = hunk.lines.iter().enumerate().map(|(line_index, line)| {
                let color = match line.kind {
                    DiffLineKind::Addition => theme.success,
                    DiffLineKind::Deletion => theme.danger,
                    DiffLineKind::Context | DiffLineKind::Metadata => theme.muted_text,
                };
                div()
                    .id(("file-diff-line", hunk_index * 1_000 + line_index))
                    .w_full()
                    .flex()
                    .items_start()
                    .whitespace_nowrap()
                    .text_color(color)
                    .child(
                        div()
                            .w(px(DIFF_GUTTER_WIDTH))
                            .flex_none()
                            .text_color(theme.tertiary_text)
                            .child(gutter_label(line)),
                    )
                    .child(
                        div()
                            .w(px(12.))
                            .flex_none()
                            .child(line.kind.marker().to_string()),
                    )
                    .child(div().min_w_0().child(line.text.clone()))
            });
            div().w_full().children([header.into_any()]).children(lines)
        }))
        .into_any()
}

fn gutter_label(line: &DiffLineProjection) -> String {
    match (line.old_line, line.new_line) {
        (Some(old), Some(new)) => format!("{old:>4} {new:>4}"),
        (Some(old), None) => format!("{old:>4}     "),
        (None, Some(new)) => format!("     {new:>4}"),
        (None, None) => "         ".to_owned(),
    }
}

fn file_counts(file: &FileDiffProjection, theme: CodexTheme) -> gpui::Div {
    div()
        .text_size(px(10.))
        .child(
            div()
                .text_color(theme.success)
                .child(format!("+{}", file.additions)),
        )
        .child(
            div()
                .text_color(theme.danger)
                .child(format!(" -{}", file.deletions)),
        )
}

fn status_glyph(status: &WorkItemStatusV2, theme: CodexTheme) -> gpui::Div {
    let (glyph, color) = match status {
        WorkItemStatusV2::InProgress => ("◌", theme.running),
        WorkItemStatusV2::Completed => ("✓", theme.success),
        WorkItemStatusV2::Failed => ("×", theme.danger),
        WorkItemStatusV2::Declined => ("—", theme.warning),
        WorkItemStatusV2::Unknown(_) => ("?", theme.warning),
    };
    div().w(px(14.)).text_color(color).child(glyph)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use codex_presentation::transcript_v2::WorkItemStatusV2;
    use serde_json::json;

    fn change(path: &str, diff: &str) -> FileChangePresentation {
        FileChangePresentation {
            path: path.to_owned(),
            destination_path: None,
            kind: FileChangeKind::Modified,
            diff: Arc::from(diff),
            malformed_raw: None,
        }
    }

    #[test]
    fn projection_counts_additions_deletions_and_gutters() {
        let projection = FileChangeProjection::from_changes(
            &[change(
                "src/lib.rs",
                "@@ -2,2 +2,3 @@\n keep\n-old\n+new\n+more",
            )],
            0,
        );
        let file = projection.selected_file().expect("selected file");
        assert_eq!(file.additions, 2);
        assert_eq!(file.deletions, 1);
        let lines = &file.hunks[0].lines;
        assert_eq!((lines[0].old_line, lines[0].new_line), (Some(2), Some(2)));
        assert_eq!((lines[1].old_line, lines[1].new_line), (Some(3), None));
        assert_eq!((lines[2].old_line, lines[2].new_line), (None, Some(3)));
    }

    #[test]
    fn selected_file_is_clamped_and_file_list_is_bounded() {
        let changes = (0..(MAX_VISIBLE_FILES + 3))
            .map(|index| change(&format!("file-{index}.rs"), ""))
            .collect::<Vec<_>>();
        let projection = FileChangeProjection::from_changes(&changes, usize::MAX);
        assert_eq!(projection.files.len(), MAX_VISIBLE_FILES);
        assert_eq!(projection.hidden_file_count, 3);
        assert_eq!(projection.selected_index, Some(MAX_VISIBLE_FILES - 1));
    }

    #[test]
    fn malformed_payload_uses_safe_fallback_without_rendering_raw_json() {
        let mut malformed = change("bad.rs", "@@ not a range @@\n+line");
        malformed.malformed_raw = Some(json!({"diff": ["not text"]}));
        let projection = FileChangeProjection::from_changes(&[malformed], 0);
        let file = projection.selected_file().expect("selected file");
        assert!(file.malformed_fallback.is_some());
        assert!(
            file.malformed_fallback.as_deref().is_some_and(|value| {
                value.contains("malformed") && !value.contains("not text")
            })
        );
    }

    #[test]
    fn diff_and_path_bounds_are_utf8_safe() {
        let path = "界".repeat(1_000);
        let diff = format!("@@ -1 +1 @@\n+{}", "λ".repeat(MAX_DIFF_BYTES));
        let projection = FileChangeProjection::from_changes(&[change(&path, &diff)], 0);
        let file = projection.selected_file().expect("selected file");
        assert!(file.path.chars().count() <= 513);
        assert!(file.truncated);
    }

    #[test]
    fn layout_keeps_diff_bounded_on_small_and_wide_viewports() {
        let narrow = FileChangeLayout::for_viewport(120.);
        let wide = FileChangeLayout::for_viewport(1_600.);
        assert!(narrow.file_list_width >= 140.);
        assert!(narrow.diff_width > 0.);
        assert!(wide.card_width <= TranscriptLayoutMetrics::OUTER_MAX_WIDTH);
        assert_eq!(wide.diff_max_height, MAX_DIFF_HEIGHT);
        assert_eq!(wide.gutter_width, DIFF_GUTTER_WIDTH);
    }

    #[test]
    fn status_label_fallback_handles_every_known_status() {
        let projection = FileChangeProjection::from_changes(&[change("a", "")], 0);
        for status in [
            WorkItemStatusV2::InProgress,
            WorkItemStatusV2::Completed,
            WorkItemStatusV2::Failed,
            WorkItemStatusV2::Declined,
            WorkItemStatusV2::Unknown("future".to_owned()),
        ] {
            assert!(!file_change_label(&projection, &status).is_empty());
        }
    }
}
