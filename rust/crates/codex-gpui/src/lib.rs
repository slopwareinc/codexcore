//! Embeddable native GPUI views for Codex.
//!
//! The views consume disposable [`codex_presentation`] projections. They do
//! not own an App Server session, Tokio runtime, window, or application
//! lifecycle, so hosts can compose them into an existing GPUI product.

use std::sync::Arc;

use codex_app_server_state::{LifecycleStatus, StateRevision};
use codex_presentation::{
    ActivityKind, ActivityPresentation, PresentedEntry, TranscriptEntry, TranscriptPresentation,
};
use gpui::{
    AnyElement, Context, FollowMode, ListAlignment, ListState, Render, Rgba, Role, Window, div,
    list, prelude::*, px, rgb,
};

mod composer;
mod prompt;
mod thread_list;

pub use composer::{CodexComposer, ComposerEvent, init as init_composer};
pub use prompt::{CodexPrompt, PromptIntent};
pub use thread_list::{CodexThreadList, ThreadSelectionEvent};

/// Exact Zed revision supplying GPUI for this crate.
pub const GPUI_REVISION: &str = "8bbbeb3d15a7b08c852d6c941cefdbbbaeab82fe";

/// Semantic colors for the native transcript surface.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CodexTheme {
    pub background: Rgba,
    pub surface: Rgba,
    pub elevated_surface: Rgba,
    pub border: Rgba,
    pub text: Rgba,
    pub muted_text: Rgba,
    pub accent: Rgba,
    pub user_message: Rgba,
    pub success: Rgba,
    pub warning: Rgba,
    pub danger: Rgba,
}

impl Default for CodexTheme {
    fn default() -> Self {
        Self {
            background: rgb(0x0017_1717),
            surface: rgb(0x0020_2020),
            elevated_surface: rgb(0x0029_2929),
            border: rgb(0x003a_3a3a),
            text: rgb(0x00f2_f2f2),
            muted_text: rgb(0x00a3_a3a3),
            accent: rgb(0x00d9_7757),
            user_message: rgb(0x0030_3030),
            success: rgb(0x0058_a66f),
            warning: rgb(0x00d6_a84b),
            danger: rgb(0x00d6_6a65),
        }
    }
}

/// Stable virtualized row projected from a transcript.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TranscriptRow {
    Turn { id: String, status: LifecycleStatus },
    Entry(Box<PresentedEntry>),
}

impl TranscriptRow {
    /// Stable identity used to preserve list position across revisions.
    #[must_use]
    pub fn stable_id(&self) -> String {
        match self {
            Self::Turn { id, .. } => format!("turn:{id}"),
            Self::Entry(entry) => format!(
                "item:{}:{}:{}",
                entry.key.thread_id, entry.key.turn_id, entry.key.item_id
            ),
        }
    }
}

/// Flatten a semantic transcript into stable virtualized rows.
#[must_use]
pub fn transcript_rows(presentation: &TranscriptPresentation) -> Vec<TranscriptRow> {
    presentation
        .turns
        .iter()
        .flat_map(|turn| {
            std::iter::once(TranscriptRow::Turn {
                id: turn.turn_id.as_str().to_owned(),
                status: turn.status.clone(),
            })
            .chain(
                turn.entries
                    .iter()
                    .cloned()
                    .map(Box::new)
                    .map(TranscriptRow::Entry),
            )
        })
        .collect()
}

/// Virtualized bottom-aligned Codex transcript.
pub struct CodexTranscript {
    revision: StateRevision,
    rows: Arc<[TranscriptRow]>,
    list_state: ListState,
    theme: CodexTheme,
}

impl CodexTranscript {
    /// Construct a transcript view from one disposable projection.
    #[must_use]
    pub fn new(presentation: &TranscriptPresentation) -> Self {
        let revision = presentation.revision;
        let rows: Arc<[TranscriptRow]> = transcript_rows(presentation).into();
        let list_state = ListState::new(rows.len(), ListAlignment::Bottom, px(800.))
            .with_uniform_item_height(px(76.));
        list_state.set_follow_mode(FollowMode::Tail);
        Self {
            revision,
            rows,
            list_state,
            theme: CodexTheme::default(),
        }
    }

    /// Apply host colors without changing transcript ownership.
    #[must_use]
    pub fn with_theme(mut self, theme: CodexTheme) -> Self {
        self.theme = theme;
        self
    }

    /// Current canonical revision rendered by this view.
    #[must_use]
    pub const fn revision(&self) -> StateRevision {
        self.revision
    }

    /// Shared list state for host scroll controls and inspection.
    #[must_use]
    pub fn list_state(&self) -> ListState {
        self.list_state.clone()
    }

    /// Replace the disposable presentation while retaining viewport state.
    ///
    /// Stable prefixes and suffixes remain in place. Content-only changes are
    /// remeasured, while inserted or removed identities are spliced.
    pub fn set_presentation(
        &mut self,
        presentation: &TranscriptPresentation,
        cx: &mut Context<Self>,
    ) {
        if presentation.revision < self.revision {
            return;
        }

        let next: Arc<[TranscriptRow]> = transcript_rows(presentation).into();
        update_list_state(&self.list_state, &self.rows, &next);
        self.revision = presentation.revision;
        self.rows = next;
        cx.notify();
    }
}

impl Render for CodexTranscript {
    fn render(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        let rows = Arc::clone(&self.rows);
        let theme = self.theme;
        let state = self.list_state.clone();
        div()
            .id("codex-transcript")
            .role(Role::Log)
            .aria_label("Codex transcript")
            .size_full()
            .overflow_hidden()
            .bg(theme.background)
            .text_color(theme.text)
            .child(
                list(state, move |index, _window, _cx| {
                    rows.get(index)
                        .map_or_else(|| div().into_any(), |row| render_row(row, theme))
                })
                .size_full(),
            )
    }
}

fn update_list_state(state: &ListState, old: &[TranscriptRow], new: &[TranscriptRow]) {
    let prefix = old
        .iter()
        .zip(new)
        .take_while(|(left, right)| left.stable_id() == right.stable_id())
        .count();
    let suffix = old[prefix..]
        .iter()
        .rev()
        .zip(new[prefix..].iter().rev())
        .take_while(|(left, right)| left.stable_id() == right.stable_id())
        .count();

    let old_middle_end = old.len() - suffix;
    let new_middle_end = new.len() - suffix;
    if prefix != old_middle_end || prefix != new_middle_end {
        state.splice(prefix..old_middle_end, new_middle_end - prefix);
    }

    let mut changed = Vec::new();
    for index in 0..prefix {
        if old[index] != new[index] {
            changed.push(index);
        }
    }
    for offset in 0..suffix {
        let old_index = old.len() - suffix + offset;
        let new_index = new.len() - suffix + offset;
        if old[old_index] != new[new_index] {
            changed.push(new_index);
        }
    }
    for range in contiguous_ranges(&changed) {
        state.remeasure_items(range);
    }
}

fn contiguous_ranges(indices: &[usize]) -> Vec<std::ops::Range<usize>> {
    let mut ranges: Vec<std::ops::Range<usize>> = Vec::new();
    for &index in indices {
        match ranges.last_mut() {
            Some(range) if range.end == index => range.end += 1,
            _ => ranges.push(index..index + 1),
        }
    }
    ranges
}

fn render_row(row: &TranscriptRow, theme: CodexTheme) -> AnyElement {
    match row {
        TranscriptRow::Turn { id, status } => div()
            .id(row.stable_id())
            .role(Role::Heading)
            .aria_level(2)
            .aria_label(format!("Turn {id}, {}", status.as_raw()))
            .w_full()
            .px_6()
            .pt_5()
            .pb_2()
            .flex()
            .items_center()
            .gap_2()
            .text_xs()
            .text_color(theme.muted_text)
            .child(format!("Turn {id}"))
            .child(status_badge(status, theme))
            .into_any(),
        TranscriptRow::Entry(entry) => render_entry(entry, theme),
    }
}

fn render_entry(entry: &PresentedEntry, theme: CodexTheme) -> AnyElement {
    let shell = div()
        .id(format!(
            "entry:{}:{}:{}",
            entry.key.thread_id, entry.key.turn_id, entry.key.item_id
        ))
        .role(Role::Article)
        .aria_label(entry_accessibility_label(entry))
        .w_full()
        .px_6()
        .py_2()
        .flex()
        .flex_col();

    match &entry.content {
        TranscriptEntry::UserMessage { text } => render_user(shell, text, theme),
        TranscriptEntry::AssistantMessage { text, phase } => {
            render_assistant(shell, text, phase.as_deref(), theme)
        }
        TranscriptEntry::Reasoning { summary, detail } => {
            render_reasoning(shell, summary, detail.as_deref(), theme)
        }
        TranscriptEntry::Activity(activity) => render_activity(shell, activity, theme),
        TranscriptEntry::Command {
            command,
            cwd,
            output,
            exit_code,
        } => render_command(
            shell,
            command,
            cwd.as_deref(),
            output.as_deref(),
            *exit_code,
            theme,
        ),
        TranscriptEntry::FileChanges { changes } => card(
            shell,
            "File changes",
            format!("{} change(s)", changes.len()),
            theme,
        ),
        TranscriptEntry::ToolCall {
            server,
            tool,
            arguments,
            result,
        } => card(
            shell,
            &server
                .as_ref()
                .map_or_else(|| tool.clone(), |server| format!("{server} · {tool}")),
            if result.is_some() {
                "Completed".to_owned()
            } else {
                compact_json(arguments)
            },
            theme,
        ),
        TranscriptEntry::Plan { value } => card(shell, "Plan", compact_json(value), theme),
        TranscriptEntry::Image { path, url } => card(
            shell,
            "Image",
            path.clone()
                .or_else(|| url.clone())
                .unwrap_or_else(|| "Image attachment".to_owned()),
            theme,
        ),
        TranscriptEntry::Notice { text } => render_notice(shell, text, theme),
        TranscriptEntry::Unknown { kind, payload } => card(
            shell,
            &format!("Unsupported item · {kind}"),
            compact_json(payload),
            theme,
        ),
    }
}

type RowShell = gpui::Stateful<gpui::Div>;

fn render_user(shell: RowShell, text: &str, theme: CodexTheme) -> AnyElement {
    shell
        .items_end()
        .child(
            div()
                .max_w(px(720.))
                .rounded_xl()
                .bg(theme.user_message)
                .border_1()
                .border_color(theme.border)
                .px_4()
                .py_3()
                .whitespace_normal()
                .child(text.to_owned()),
        )
        .into_any()
}

fn render_assistant(
    shell: RowShell,
    text: &str,
    phase: Option<&str>,
    theme: CodexTheme,
) -> AnyElement {
    shell
        .gap_2()
        .when_some(phase.map(str::to_owned), |view, phase| {
            view.child(div().text_xs().text_color(theme.muted_text).child(phase))
        })
        .child(
            div()
                .max_w(px(840.))
                .whitespace_normal()
                .line_height(px(22.))
                .child(text.to_owned()),
        )
        .into_any()
}

fn render_reasoning(
    shell: RowShell,
    summary: &str,
    detail: Option<&str>,
    theme: CodexTheme,
) -> AnyElement {
    shell
        .gap_1()
        .text_color(theme.muted_text)
        .child(div().text_sm().child(summary.to_owned()))
        .when_some(detail.map(str::to_owned), |view, detail| {
            view.child(div().text_xs().whitespace_normal().child(detail))
        })
        .into_any()
}

fn render_activity(
    shell: RowShell,
    activity: &ActivityPresentation,
    theme: CodexTheme,
) -> AnyElement {
    shell
        .child(
            div()
                .flex()
                .items_center()
                .gap_2()
                .text_sm()
                .text_color(theme.muted_text)
                .child(activity_glyph(activity.kind))
                .child(activity.label.clone())
                .when_some(activity.detail.clone(), |view, detail| {
                    view.child(div().text_xs().child(detail))
                }),
        )
        .into_any()
}

fn render_command(
    shell: RowShell,
    command: &str,
    cwd: Option<&str>,
    output: Option<&str>,
    exit_code: Option<i64>,
    theme: CodexTheme,
) -> AnyElement {
    shell
        .child(
            div()
                .rounded_lg()
                .border_1()
                .border_color(theme.border)
                .bg(theme.surface)
                .overflow_hidden()
                .child(
                    div()
                        .px_3()
                        .py_2()
                        .bg(theme.elevated_surface)
                        .font_family("monospace")
                        .text_sm()
                        .child(format!("$ {command}")),
                )
                .when_some(cwd.map(str::to_owned), |view, cwd| {
                    view.child(
                        div()
                            .px_3()
                            .pt_2()
                            .text_xs()
                            .text_color(theme.muted_text)
                            .child(cwd),
                    )
                })
                .when_some(output.map(str::to_owned), |view, output| {
                    view.child(
                        div()
                            .px_3()
                            .py_2()
                            .font_family("monospace")
                            .text_sm()
                            .whitespace_normal()
                            .child(output),
                    )
                })
                .when_some(exit_code, |view, code| {
                    view.child(
                        div()
                            .px_3()
                            .pb_2()
                            .text_xs()
                            .text_color(if code == 0 {
                                theme.success
                            } else {
                                theme.danger
                            })
                            .child(format!("exit {code}")),
                    )
                }),
        )
        .into_any()
}

fn render_notice(shell: RowShell, text: &str, theme: CodexTheme) -> AnyElement {
    shell
        .child(
            div()
                .rounded_md()
                .border_1()
                .border_color(theme.border)
                .px_3()
                .py_2()
                .text_sm()
                .text_color(theme.muted_text)
                .child(text.to_owned()),
        )
        .into_any()
}

fn card(shell: RowShell, title: &str, detail: String, theme: CodexTheme) -> AnyElement {
    shell
        .child(
            div()
                .rounded_lg()
                .border_1()
                .border_color(theme.border)
                .bg(theme.surface)
                .px_3()
                .py_2()
                .gap_1()
                .child(div().text_sm().child(title.to_owned()))
                .child(
                    div()
                        .text_xs()
                        .text_color(theme.muted_text)
                        .whitespace_normal()
                        .child(detail),
                ),
        )
        .into_any()
}

fn status_badge(status: &LifecycleStatus, theme: CodexTheme) -> AnyElement {
    let color = match status {
        LifecycleStatus::Completed => theme.success,
        LifecycleStatus::Failed | LifecycleStatus::Declined => theme.danger,
        LifecycleStatus::Interrupted => theme.warning,
        LifecycleStatus::InProgress => theme.accent,
        LifecycleStatus::Unknown(_) => theme.muted_text,
    };
    div()
        .rounded_full()
        .border_1()
        .border_color(color)
        .px_2()
        .text_color(color)
        .child(status.as_raw().to_owned())
        .into_any()
}

fn activity_glyph(kind: ActivityKind) -> &'static str {
    match kind {
        ActivityKind::Read => "R",
        ActivityKind::Search | ActivityKind::Web => "S",
        ActivityKind::List => "L",
        ActivityKind::Edit => "E",
        ActivityKind::Command => ">",
        ActivityKind::Mcp | ActivityKind::DynamicTool => "T",
        ActivityKind::Collaboration => "A",
        ActivityKind::Other => "·",
    }
}

fn compact_json(value: &serde_json::Value) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "<invalid JSON>".to_owned())
}

fn entry_accessibility_label(entry: &PresentedEntry) -> String {
    let label = match &entry.content {
        TranscriptEntry::UserMessage { text } => format!("You: {text}"),
        TranscriptEntry::AssistantMessage { text, phase } => phase.as_ref().map_or_else(
            || format!("Codex: {text}"),
            |phase| format!("Codex {phase}: {text}"),
        ),
        TranscriptEntry::Reasoning { summary, detail } => detail.as_ref().map_or_else(
            || format!("Reasoning: {summary}"),
            |detail| format!("Reasoning: {summary}. {detail}"),
        ),
        TranscriptEntry::Activity(activity) => activity.detail.as_ref().map_or_else(
            || format!("Activity: {}", activity.label),
            |detail| format!("Activity: {}. {detail}", activity.label),
        ),
        TranscriptEntry::Command {
            command, exit_code, ..
        } => exit_code.map_or_else(
            || format!("Command: {command}"),
            |code| format!("Command: {command}. Exit code {code}"),
        ),
        TranscriptEntry::FileChanges { changes } => {
            format!("File changes: {} change(s)", changes.len())
        }
        TranscriptEntry::ToolCall { server, tool, .. } => server.as_ref().map_or_else(
            || format!("Tool call: {tool}"),
            |server| format!("Tool call: {server}, {tool}"),
        ),
        TranscriptEntry::Plan { .. } => "Plan update".to_owned(),
        TranscriptEntry::Image { path, url } => format!(
            "Image: {}",
            path.as_ref()
                .or(url.as_ref())
                .map_or("attachment", String::as_str)
        ),
        TranscriptEntry::Notice { text } => format!("Notice: {text}"),
        TranscriptEntry::Unknown { kind, .. } => format!("Unsupported item: {kind}"),
    };
    truncate_accessibility(label, 512)
}

fn truncate_accessibility(mut label: String, maximum_chars: usize) -> String {
    let Some(byte_index) = label
        .char_indices()
        .nth(maximum_chars)
        .map(|(index, _)| index)
    else {
        return label;
    };
    label.truncate(byte_index);
    label.push('…');
    label
}

#[cfg(test)]
mod tests {
    use super::*;
    use codex_app_server_state::{ItemId, ItemKey, ThreadId, TurnId};
    use codex_presentation::TurnPresentation;

    fn presentation(entries: Vec<PresentedEntry>) -> TranscriptPresentation {
        TranscriptPresentation {
            revision: StateRevision::new(1),
            thread_id: ThreadId::from("thread"),
            turns: vec![TurnPresentation {
                turn_id: TurnId::from("turn"),
                status: LifecycleStatus::InProgress,
                entries,
            }],
        }
    }

    fn entry(id: &str, text: &str) -> PresentedEntry {
        PresentedEntry {
            key: ItemKey {
                thread_id: ThreadId::from("thread"),
                turn_id: TurnId::from("turn"),
                item_id: ItemId::from(id),
            },
            status: LifecycleStatus::Completed,
            content: TranscriptEntry::AssistantMessage {
                text: text.to_owned(),
                phase: None,
            },
        }
    }

    #[test]
    fn rows_have_stable_composite_identities() {
        let rows = transcript_rows(&presentation(vec![entry("same", "hello")]));
        assert_eq!(rows[0].stable_id(), "turn:turn");
        assert_eq!(rows[1].stable_id(), "item:thread:turn:same");
    }

    #[test]
    fn content_changes_do_not_change_row_identity() {
        let first = transcript_rows(&presentation(vec![entry("item", "one")]));
        let second = transcript_rows(&presentation(vec![entry("item", "two")]));
        assert_eq!(first[1].stable_id(), second[1].stable_id());
        assert_ne!(first[1], second[1]);
    }

    #[test]
    fn contiguous_indices_are_coalesced_for_remeasurement() {
        assert_eq!(contiguous_ranges(&[1, 2, 4]), vec![1..3, 4..5]);
    }

    #[test]
    fn accessibility_labels_are_bounded_on_character_boundaries() {
        let projected = entry("item", &"界".repeat(600));
        let label = entry_accessibility_label(&projected);
        assert_eq!(label.chars().count(), 513);
        assert!(label.ends_with('…'));
    }
}
