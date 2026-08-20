//! Virtualized Codex transcript implementation.

use std::{collections::BTreeSet, sync::Arc};

use codex_app_server_state::{LifecycleStatus, PlanStepStatus, StateRevision};
use codex_presentation::{
    ActivityKind, ActivityPresentation, CommandOutputPresentation, FileChangeKind,
    FileChangePresentation, MarkdownDocument, PlanPresentation, PresentedEntry, TranscriptEntry,
    TranscriptPresentation,
};
use gpui::{
    AnyElement, Context, EventEmitter, FollowMode, ListAlignment, ListState, Render, Rgba, Role,
    WeakEntity, Window, div, list, prelude::*, px, rgb,
};

/// Exact Zed revision supplying GPUI for this crate.
pub const GPUI_REVISION: &str = "8bbbeb3d15a7b08c852d6c941cefdbbbaeab82fe";

/// Host-owned action emitted by transcript content.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TranscriptEvent {
    OpenLink { destination: String, label: String },
}

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
            // CodexCoreUI's official Slate palette.
            background: rgb(0x000f_0f10),
            surface: rgb(0x0016_1618),
            elevated_surface: rgb(0x001f_1f22),
            border: rgb(0x0033_3338),
            text: rgb(0x00fa_fafa),
            muted_text: rgb(0x00a8_a8b0),
            accent: rgb(0x0081_89ff),
            user_message: rgb(0x002a_2a2c),
            success: rgb(0x0044_d17e),
            warning: rgb(0x00e7_a23c),
            danger: rgb(0x00ff_6b66),
        }
    }
}

/// Stable virtualized row projected from a transcript.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TranscriptRow {
    Turn {
        id: String,
        status: LifecycleStatus,
    },
    Entry(Box<PresentedEntry>),
    WorkGroup {
        id: String,
        entries: Arc<[PresentedEntry]>,
        status: LifecycleStatus,
    },
    Plan {
        turn_id: String,
        plan: Box<PlanPresentation>,
    },
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
            Self::WorkGroup { id, .. } => format!("work-group:{id}"),
            Self::Plan { turn_id, .. } => format!("turn:{turn_id}:plan"),
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
            let mut rows = Vec::new();
            let mut work_entries: Vec<PresentedEntry> = Vec::new();
            for entry in &turn.entries {
                if is_work_entry(entry) {
                    work_entries.push(entry.clone());
                } else {
                    flush_work_group(&mut rows, &mut work_entries);
                    rows.push(TranscriptRow::Entry(Box::new(entry.clone())));
                }
            }
            flush_work_group(&mut rows, &mut work_entries);
            if let Some(plan) = turn.plan.clone() {
                rows.push(TranscriptRow::Plan {
                    turn_id: turn.turn_id.as_str().to_owned(),
                    plan: Box::new(plan),
                });
            }
            // Swift's V2 transcript keeps lifecycle chrome at the end of a
            // turn; the conversation itself begins with the user's bubble.
            rows.push(TranscriptRow::Turn {
                id: turn.turn_id.as_str().to_owned(),
                status: turn.status.clone(),
            });
            rows.into_iter()
        })
        .collect()
}

fn is_work_entry(entry: &PresentedEntry) -> bool {
    matches!(
        entry.content,
        TranscriptEntry::Activity(_)
            | TranscriptEntry::Command { .. }
            | TranscriptEntry::FileChanges { .. }
            | TranscriptEntry::ToolCall { .. }
    )
}

fn flush_work_group(rows: &mut Vec<TranscriptRow>, entries: &mut Vec<PresentedEntry>) {
    if entries.is_empty() {
        return;
    }
    let id = entries
        .first()
        .map(|entry| {
            format!(
                "{}:{}:{}",
                entry.key.thread_id, entry.key.turn_id, entry.key.item_id
            )
        })
        .unwrap_or_default();
    let status = if entries.iter().any(|entry| !entry.status.is_terminal()) {
        LifecycleStatus::InProgress
    } else {
        LifecycleStatus::Completed
    };
    rows.push(TranscriptRow::WorkGroup {
        id,
        entries: std::mem::take(entries).into(),
        status,
    });
}

/// Virtualized bottom-aligned Codex transcript.
pub struct CodexTranscript {
    revision: StateRevision,
    rows: Arc<[TranscriptRow]>,
    list_state: ListState,
    theme: CodexTheme,
    expanded_work_groups: BTreeSet<String>,
    expanded_work_rows: BTreeSet<String>,
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
            expanded_work_groups: BTreeSet::new(),
            expanded_work_rows: BTreeSet::new(),
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

    fn toggle_work_group(&mut self, id: String, cx: &mut Context<Self>) {
        if !self.expanded_work_groups.remove(&id) {
            self.expanded_work_groups.insert(id);
        }
        cx.notify();
    }

    fn toggle_work_row(&mut self, id: String, cx: &mut Context<Self>) {
        if !self.expanded_work_rows.remove(&id) {
            self.expanded_work_rows.insert(id);
        }
        cx.notify();
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

impl EventEmitter<TranscriptEvent> for CodexTranscript {}

impl Render for CodexTranscript {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let rows = Arc::clone(&self.rows);
        let theme = self.theme;
        let state = self.list_state.clone();
        let emitter = cx.entity().downgrade();
        let expanded_work_groups = self.expanded_work_groups.clone();
        let expanded_work_rows = self.expanded_work_rows.clone();
        div()
            .id("codex-transcript")
            .role(Role::Log)
            .aria_label("Codex transcript")
            .size_full()
            .overflow_hidden()
            .bg(theme.background)
            .text_color(theme.text)
            .child(
                div().flex().justify_center().size_full().child(
                    div().w_full().max_w(px(920.)).h_full().child(
                        list(state, move |index, _window, _cx| {
                            rows.get(index).map_or_else(
                                || div().into_any(),
                                |row| {
                                    render_row(
                                        row,
                                        theme,
                                        &emitter,
                                        expanded_work_groups.contains(&row.stable_id()),
                                        &expanded_work_rows,
                                    )
                                },
                            )
                        })
                        .size_full(),
                    ),
                ),
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

fn render_row(
    row: &TranscriptRow,
    theme: CodexTheme,
    emitter: &WeakEntity<CodexTranscript>,
    work_group_expanded: bool,
    expanded_work_rows: &BTreeSet<String>,
) -> AnyElement {
    match row {
        TranscriptRow::Turn { id, status } => div()
            .id(row.stable_id())
            .role(Role::Status)
            .aria_level(2)
            .aria_label(format!("Turn {id}, {}", status.as_raw()))
            .w_full()
            .px_6()
            .pt_3()
            .pb_2()
            .justify_end()
            .flex()
            .items_center()
            .gap_2()
            .text_xs()
            .text_color(theme.muted_text)
            .child(status_badge(status, theme))
            .into_any(),
        TranscriptRow::Entry(entry) => render_entry(entry, theme, emitter),
        TranscriptRow::WorkGroup {
            id,
            entries,
            status,
        } => render_work_group(
            id,
            entries,
            status,
            theme,
            emitter,
            work_group_expanded,
            expanded_work_rows,
        ),
        TranscriptRow::Plan { plan, .. } => render_plan(row.stable_id(), plan, theme),
    }
}

fn render_plan(id: String, plan: &PlanPresentation, theme: CodexTheme) -> AnyElement {
    let steps = plan
        .steps
        .iter()
        .enumerate()
        .map(|(index, step)| {
            let (marker, color) = match &step.status {
                PlanStepStatus::Pending => ("○", theme.muted_text),
                PlanStepStatus::InProgress => ("◉", theme.accent),
                PlanStepStatus::Completed => ("●", theme.success),
                PlanStepStatus::Unknown(_) => ("?", theme.warning),
            };
            div()
                .id(("plan-step", index))
                .role(Role::ListItem)
                .aria_label(format!(
                    "{}: {}",
                    plan_status_label(&step.status),
                    step.step
                ))
                .flex()
                .gap_2()
                .child(div().text_color(color).child(marker))
                .child(div().flex_1().whitespace_normal().child(step.step.clone()))
        })
        .collect::<Vec<_>>();
    div()
        .id(id)
        .role(Role::Region)
        .aria_label("Turn plan")
        .w_full()
        .px_6()
        .py_2()
        .child(
            div()
                .rounded_lg()
                .border_1()
                .border_color(theme.border)
                .bg(theme.surface)
                .p_3()
                .child(div().text_sm().child("Plan"))
                .when_some(plan.explanation.clone(), |view, explanation| {
                    view.child(
                        div()
                            .mt_1()
                            .text_xs()
                            .text_color(theme.muted_text)
                            .whitespace_normal()
                            .child(explanation),
                    )
                })
                .child(
                    div()
                        .id("plan-steps")
                        .role(Role::List)
                        .aria_label("Plan steps")
                        .mt_2()
                        .flex()
                        .flex_col()
                        .gap_2()
                        .children(steps),
                ),
        )
        .into_any()
}

fn plan_status_label(status: &PlanStepStatus) -> &'static str {
    match status {
        PlanStepStatus::Pending => "Pending",
        PlanStepStatus::InProgress => "In progress",
        PlanStepStatus::Completed => "Completed",
        PlanStepStatus::Unknown(_) => "Unknown",
    }
}

fn render_work_group(
    id: &str,
    entries: &[PresentedEntry],
    status: &LifecycleStatus,
    theme: CodexTheme,
    emitter: &WeakEntity<CodexTranscript>,
    expanded: bool,
    expanded_work_rows: &BTreeSet<String>,
) -> AnyElement {
    let label = if status.is_terminal() {
        "Completed work"
    } else {
        "Working"
    };
    let group_id = format!("work-group:{id}");
    let toggle_id = id.to_owned();
    div()
        .id(group_id)
        .role(Role::Group)
        .aria_label(format!("{label}, {} activity item(s)", entries.len()))
        .w_full()
        .px_6()
        .py_1()
        .child(
            div()
                .h(px(22.))
                .flex()
                .items_center()
                .gap_2()
                .text_sm()
                .text_color(theme.muted_text)
                .child(if expanded { "⌄" } else { "›" })
                .child(label)
                .child(
                    div()
                        .rounded_full()
                        .border_1()
                        .border_color(theme.border)
                        .px_2()
                        .text_xs()
                        .child(entries.len().to_string()),
                ),
        )
        .on_click({
            let emitter = emitter.clone();
            move |_, _, cx| {
                emitter
                    .update(cx, |transcript, cx| {
                        transcript.toggle_work_group(toggle_id.clone(), cx);
                    })
                    .ok();
            }
        })
        .when(expanded, |view| {
            view.children(entries.iter().map(|entry| {
                render_work_entry(
                    entry,
                    theme,
                    emitter,
                    expanded_work_rows.contains(&work_entry_id(entry)),
                )
            }))
        })
        .into_any()
}

#[allow(clippy::too_many_lines)]
fn render_work_entry(
    entry: &PresentedEntry,
    theme: CodexTheme,
    emitter: &WeakEntity<CodexTranscript>,
    expanded: bool,
) -> AnyElement {
    let (label, status, detail) = match &entry.content {
        TranscriptEntry::Activity(activity) => (
            activity.label.clone(),
            entry.status.clone(),
            activity.detail.clone(),
        ),
        TranscriptEntry::Command {
            command, output, ..
        } => (
            format!("$ {command}"),
            entry.status.clone(),
            output.as_ref().map(|output| output.text.to_string()),
        ),
        TranscriptEntry::FileChanges { changes } => {
            let paths = changes
                .iter()
                .take(3)
                .map(|change| change.destination_path.as_deref().unwrap_or(&change.path))
                .collect::<Vec<_>>()
                .join(" · ");
            let suffix = changes.len().saturating_sub(3);
            let detail = changes
                .iter()
                .flat_map(|change| {
                    std::iter::once(change.path.clone())
                        .chain(change.diff.lines().take(16).map(str::to_owned))
                })
                .collect::<Vec<_>>()
                .join("\n");
            (
                if suffix == 0 {
                    format!("Edited {paths}")
                } else {
                    format!("Edited {paths} · +{suffix} more")
                },
                entry.status.clone(),
                (!detail.is_empty()).then_some(detail),
            )
        }
        TranscriptEntry::ToolCall {
            server,
            tool,
            arguments,
            result,
        } => (
            server.as_ref().map_or_else(
                || format!("Called {tool}"),
                |server| format!("Called {server} · {tool}"),
            ),
            entry.status.clone(),
            Some(result.as_ref().map_or_else(
                || compact_json(arguments),
                |result| {
                    format!(
                        "Arguments\n{}\n\nResult\n{}",
                        compact_json(arguments),
                        compact_json(result)
                    )
                },
            )),
        ),
        _ => ("Activity".to_owned(), entry.status.clone(), None),
    };
    let row_id = work_entry_id(entry);
    let emitter = emitter.clone();
    div()
        .id(format!("work-entry:{row_id}"))
        .role(Role::ListItem)
        .aria_label(label.clone())
        .h(px(28.))
        .w_full()
        .pl(px(22.))
        .pr_2()
        .flex()
        .items_center()
        .gap_2()
        .text_xs()
        .text_color(theme.muted_text)
        .child(status_glyph(&status, theme))
        .child(div().min_w_0().flex_1().truncate().child(label))
        .when(detail.is_some(), |view| {
            view.child(div().text_xs().child(if expanded { "⌄" } else { "›" }))
        })
        .on_click(move |_, _, cx| {
            emitter
                .update(cx, |transcript, cx| {
                    transcript.toggle_work_row(row_id.clone(), cx);
                })
                .ok();
        })
        .when(expanded, |view| {
            view.child(
                div()
                    .pl(px(38.))
                    .pb_2()
                    .w_full()
                    .font_family("monospace")
                    .text_xs()
                    .text_color(theme.muted_text)
                    .whitespace_normal()
                    .when_some(detail, gpui::ParentElement::child),
            )
        })
        .into_any()
}

fn work_entry_id(entry: &PresentedEntry) -> String {
    format!(
        "{}:{}:{}",
        entry.key.thread_id, entry.key.turn_id, entry.key.item_id
    )
}

fn status_glyph(status: &LifecycleStatus, theme: CodexTheme) -> gpui::Div {
    let (glyph, color) = match status {
        LifecycleStatus::InProgress => ("◌", theme.accent),
        LifecycleStatus::Completed => ("✓", theme.success),
        LifecycleStatus::Interrupted => ("Ⅱ", theme.warning),
        LifecycleStatus::Failed => ("×", theme.danger),
        LifecycleStatus::Declined => ("—", theme.warning),
        LifecycleStatus::Unknown(_) => ("?", theme.warning),
    };
    div().w(px(14.)).text_color(color).child(glyph)
}

fn render_entry(
    entry: &PresentedEntry,
    theme: CodexTheme,
    emitter: &WeakEntity<CodexTranscript>,
) -> AnyElement {
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
        TranscriptEntry::AssistantMessage {
            text: _,
            phase,
            markdown,
        } => render_assistant(shell, markdown, phase.as_deref(), theme, emitter),
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
            output.as_ref(),
            *exit_code,
            theme,
        ),
        TranscriptEntry::FileChanges { changes } => render_file_changes(shell, changes, theme),
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
    markdown: &MarkdownDocument,
    phase: Option<&str>,
    theme: CodexTheme,
    emitter: &WeakEntity<CodexTranscript>,
) -> AnyElement {
    shell
        .gap_2()
        .when_some(phase.map(str::to_owned), |view, phase| {
            view.child(div().text_xs().text_color(theme.muted_text).child(phase))
        })
        .child(
            div()
                .max_w(px(840.))
                .child(crate::markdown::render_markdown(markdown, theme, emitter)),
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
    output: Option<&CommandOutputPresentation>,
    exit_code: Option<i64>,
    theme: CodexTheme,
) -> AnyElement {
    let output_text = output.map(|output| output.text.to_string());
    let omitted_bytes = output
        .filter(|output| output.truncated)
        .map(|output| output.total_bytes - output.text.len());
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
                .when_some(output_text, |view, output| {
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
                .when_some(omitted_bytes, |view, omitted| {
                    view.child(
                        div()
                            .px_3()
                            .pb_2()
                            .text_xs()
                            .text_color(theme.warning)
                            .child(format!("{omitted} output byte(s) omitted")),
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

fn render_file_changes(
    shell: RowShell,
    changes: &[FileChangePresentation],
    theme: CodexTheme,
) -> AnyElement {
    const MAXIMUM_FILES: usize = 12;
    let files = changes
        .iter()
        .take(MAXIMUM_FILES)
        .enumerate()
        .map(|(index, change)| render_file_change(change, index, theme))
        .collect::<Vec<_>>();
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
                        .text_sm()
                        .child(format!("File changes · {}", changes.len())),
                )
                .children(files)
                .when(changes.len() > MAXIMUM_FILES, |view| {
                    view.child(
                        div()
                            .px_3()
                            .py_2()
                            .text_xs()
                            .text_color(theme.muted_text)
                            .child(format!(
                                "{} additional file(s) hidden",
                                changes.len() - MAXIMUM_FILES
                            )),
                    )
                }),
        )
        .into_any()
}

fn render_file_change(
    change: &FileChangePresentation,
    index: usize,
    theme: CodexTheme,
) -> AnyElement {
    const MAXIMUM_LINES: usize = 16;
    let (kind, kind_color) = file_change_kind(&change.kind, theme);
    let lines = change
        .diff
        .lines()
        .take(MAXIMUM_LINES)
        .enumerate()
        .map(|(line_index, line)| {
            let color = if line.starts_with('+') && !line.starts_with("+++") {
                theme.success
            } else if line.starts_with('-') && !line.starts_with("---") {
                theme.danger
            } else {
                theme.muted_text
            };
            div()
                .id(("diff-line", index * 1_000 + line_index))
                .font_family("monospace")
                .text_xs()
                .text_color(color)
                .whitespace_nowrap()
                .child(line.to_owned())
        })
        .collect::<Vec<_>>();
    let line_count = change.diff.lines().count();
    div()
        .id(("file-change", index))
        .border_t_1()
        .border_color(theme.border)
        .child(
            div()
                .px_3()
                .py_2()
                .flex()
                .items_center()
                .gap_2()
                .child(div().text_xs().text_color(kind_color).child(kind))
                .child(
                    div()
                        .min_w_0()
                        .flex_1()
                        .font_family("monospace")
                        .text_sm()
                        .truncate()
                        .child(change.path.clone()),
                )
                .when_some(change.destination_path.clone(), |view, destination| {
                    view.child(
                        div()
                            .text_xs()
                            .text_color(theme.muted_text)
                            .child(format!("→ {destination}")),
                    )
                }),
        )
        .when(!lines.is_empty(), |view| {
            view.child(
                div()
                    .px_3()
                    .pb_2()
                    .overflow_hidden()
                    .flex()
                    .flex_col()
                    .children(lines),
            )
        })
        .when(line_count > MAXIMUM_LINES, |view| {
            view.child(
                div()
                    .px_3()
                    .pb_2()
                    .text_xs()
                    .text_color(theme.muted_text)
                    .child(format!("{} additional line(s)", line_count - MAXIMUM_LINES)),
            )
        })
        .into_any()
}

fn file_change_kind(kind: &FileChangeKind, theme: CodexTheme) -> (String, Rgba) {
    match kind {
        FileChangeKind::Added => ("A".to_owned(), theme.success),
        FileChangeKind::Deleted => ("D".to_owned(), theme.danger),
        FileChangeKind::Modified => ("M".to_owned(), theme.warning),
        FileChangeKind::Renamed => ("R".to_owned(), theme.accent),
        FileChangeKind::Unknown(kind) => (kind.clone(), theme.muted_text),
    }
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
    truncate_accessibility(
        serde_json::to_string(value).unwrap_or_else(|_| "<invalid JSON>".to_owned()),
        12_000,
    )
}

fn entry_accessibility_label(entry: &PresentedEntry) -> String {
    let label = match &entry.content {
        TranscriptEntry::UserMessage { text } => format!("You: {text}"),
        TranscriptEntry::AssistantMessage {
            text,
            phase,
            markdown: _,
        } => phase.as_ref().map_or_else(
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
    use codex_presentation::{PlanPresentation, PlanStepPresentation, TurnPresentation};

    fn presentation(entries: Vec<PresentedEntry>) -> TranscriptPresentation {
        TranscriptPresentation {
            revision: StateRevision::new(1),
            thread_id: ThreadId::from("thread"),
            turns: vec![TurnPresentation {
                turn_id: TurnId::from("turn"),
                status: LifecycleStatus::InProgress,
                entries,
                plan: None,
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
                markdown: codex_presentation::MarkdownDocument::parse(text),
            },
        }
    }

    #[test]
    fn rows_have_stable_composite_identities() {
        let rows = transcript_rows(&presentation(vec![entry("same", "hello")]));
        assert_eq!(rows[0].stable_id(), "item:thread:turn:same");
        assert_eq!(rows[1].stable_id(), "turn:turn");
    }

    #[test]
    fn content_changes_do_not_change_row_identity() {
        let first = transcript_rows(&presentation(vec![entry("item", "one")]));
        let second = transcript_rows(&presentation(vec![entry("item", "two")]));
        assert_eq!(first[0].stable_id(), second[0].stable_id());
        assert_ne!(first[0], second[0]);
    }

    #[test]
    fn consecutive_work_items_share_a_swift_style_group_row() {
        let mut first = entry("read", "Read files");
        first.content = TranscriptEntry::Activity(ActivityPresentation {
            id: "read".to_owned(),
            kind: ActivityKind::Read,
            label: "Read files".to_owned(),
            detail: None,
        });
        let mut second = entry("search", "Search files");
        second.content = TranscriptEntry::Activity(ActivityPresentation {
            id: "search".to_owned(),
            kind: ActivityKind::Search,
            label: "Search files".to_owned(),
            detail: None,
        });
        let rows = transcript_rows(&presentation(vec![first, second]));
        assert!(matches!(rows[0], TranscriptRow::WorkGroup { .. }));
        assert_eq!(rows[0].stable_id(), "work-group:thread:turn:read");
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

    #[test]
    fn plan_row_has_turn_scoped_stable_identity() {
        let mut presentation = presentation(Vec::new());
        presentation.turns[0].plan = Some(PlanPresentation {
            explanation: None,
            steps: vec![PlanStepPresentation {
                step: "Build".to_owned(),
                status: PlanStepStatus::Pending,
            }],
        });
        let rows = transcript_rows(&presentation);
        assert_eq!(rows[0].stable_id(), "turn:turn:plan");
    }
}
