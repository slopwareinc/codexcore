use codex_app_server_state::ThreadId;
use codex_presentation::{TaskStatusPresentation, ThreadListPresentation, ThreadListRow};
use gpui::{
    AnyElement, Context, EventEmitter, Render, Rgba, Role, Window, div, prelude::*, px,
    uniform_list,
};

use crate::CodexTheme;

/// Stable task selection routed to the host.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ThreadSelectionEvent {
    pub thread_id: ThreadId,
}

/// Sidebar route command routed to the host.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ThreadListCommand {
    NewChat,
    Search,
}

/// Accessible virtualized stored-task navigation.
pub struct CodexThreadList {
    presentation: ThreadListPresentation,
    theme: CodexTheme,
}

impl CodexThreadList {
    #[must_use]
    pub fn new(presentation: ThreadListPresentation) -> Self {
        Self {
            presentation,
            theme: CodexTheme::default(),
        }
    }

    #[must_use]
    pub const fn with_theme(mut self, theme: CodexTheme) -> Self {
        self.theme = theme;
        self
    }

    pub fn set_presentation(
        &mut self,
        presentation: ThreadListPresentation,
        cx: &mut Context<Self>,
    ) {
        self.presentation = presentation;
        cx.notify();
    }

    fn select(&mut self, thread_id: ThreadId, cx: &mut Context<Self>) {
        for row in &mut self.presentation.rows {
            row.is_selected = row.thread_id == thread_id;
        }
        cx.emit(ThreadSelectionEvent { thread_id });
        cx.notify();
    }
}

impl EventEmitter<ThreadSelectionEvent> for CodexThreadList {}
impl EventEmitter<ThreadListCommand> for CodexThreadList {}

impl Render for CodexThreadList {
    #[allow(clippy::too_many_lines)]
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let item_count = self.presentation.rows.len();
        div()
            .id("codex-thread-navigation")
            .role(Role::Navigation)
            .aria_label("Codex tasks")
            .size_full()
            .overflow_hidden()
            .bg(self.theme.surface)
            .child(
                div()
                    .h(px(78.))
                    .flex_shrink_0()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .p_3()
                    .child(
                        div()
                            .id("codex-new-chat")
                            .role(Role::Button)
                            .focusable()
                            .tab_stop(true)
                            .h(px(30.))
                            .rounded_lg()
                            .px_2()
                            .flex()
                            .items_center()
                            .text_sm()
                            .text_color(self.theme.text)
                            .cursor_pointer()
                            .aria_label("New chat")
                            .on_click(
                                cx.listener(|_, _, _, cx| cx.emit(ThreadListCommand::NewChat)),
                            )
                            .child("＋   New chat"),
                    )
                    .child(
                        div()
                            .id("codex-search-chats")
                            .role(Role::Button)
                            .focusable()
                            .tab_stop(true)
                            .h(px(28.))
                            .rounded_lg()
                            .px_2()
                            .flex()
                            .items_center()
                            .text_xs()
                            .text_color(self.theme.tertiary_text)
                            .cursor_pointer()
                            .aria_label("Search chats")
                            .on_click(cx.listener(|_, _, _, cx| cx.emit(ThreadListCommand::Search)))
                            .child("⌕   Search chats"),
                    ),
            )
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .flex()
                    .flex_col()
                    .child(
                        div()
                            .flex_shrink_0()
                            .px_3()
                            .pt_3()
                            .pb_2()
                            .text_xs()
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .text_color(self.theme.muted_text)
                            .child(format!("Chats  ·  {item_count}")),
                    )
                    .child(
                        uniform_list(
                            "codex-thread-list",
                            item_count,
                            cx.processor(|this, range: std::ops::Range<usize>, _window, cx| {
                                range
                                    .filter_map(|index| {
                                        let row = this.presentation.rows.get(index)?.clone();
                                        let thread_id = row.thread_id.clone();
                                        Some(
                                            render_row(&row, this.theme)
                                                .on_click(cx.listener(move |this, _, _, cx| {
                                                    this.select(thread_id.clone(), cx);
                                                }))
                                                .into_any(),
                                        )
                                    })
                                    .collect::<Vec<AnyElement>>()
                            }),
                        )
                        .size_full(),
                    ),
            )
    }
}

fn render_row(row: &ThreadListRow, theme: CodexTheme) -> gpui::Stateful<gpui::Div> {
    let (status, _) = status_presentation(row.status, theme);
    div()
        .id(format!("thread:{}", row.thread_id))
        .role(Role::ListItem)
        .aria_label(format!("{}. {status}. {}", row.title, row.cwd))
        .h(px(54.))
        .w_full()
        .mx_2()
        .px_3()
        .py_1()
        .flex()
        .items_center()
        .rounded_lg()
        .bg(if row.is_selected {
            theme.elevated_surface
        } else {
            theme.surface
        })
        .hover(move |style| style.bg(theme.elevated_surface))
        .cursor_pointer()
        .child(
            div()
                .min_w_0()
                .flex_1()
                .flex()
                .flex_col()
                .gap_1()
                .child(
                    div()
                        .text_sm()
                        .text_color(theme.text)
                        .truncate()
                        .child(row.title.clone()),
                )
                .child(
                    div()
                        .text_xs()
                        .text_color(theme.tertiary_text)
                        .truncate()
                        .child(row.cwd.clone()),
                ),
        )
}

fn status_presentation(status: TaskStatusPresentation, theme: CodexTheme) -> (&'static str, Rgba) {
    match status {
        TaskStatusPresentation::NotLoaded => ("Not loaded", theme.muted_text),
        TaskStatusPresentation::Idle => ("Idle", theme.muted_text),
        TaskStatusPresentation::Running => ("Running", theme.accent),
        TaskStatusPresentation::WaitingOnApproval => ("Waiting for approval", theme.warning),
        TaskStatusPresentation::WaitingOnUserInput => ("Waiting for input", theme.warning),
        TaskStatusPresentation::Failed => ("Failed", theme.danger),
        TaskStatusPresentation::Unknown => ("Unknown status", theme.muted_text),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_labels_distinguish_blocking_attention() {
        let theme = CodexTheme::default();
        assert_eq!(
            status_presentation(TaskStatusPresentation::WaitingOnApproval, theme).0,
            "Waiting for approval"
        );
        assert_eq!(
            status_presentation(TaskStatusPresentation::WaitingOnUserInput, theme).0,
            "Waiting for input"
        );
    }
}
