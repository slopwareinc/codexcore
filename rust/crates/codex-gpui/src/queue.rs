use codex_presentation::{QueuePresentation, QueueRowPresentation};
use gpui::{
    AnyElement, Context, EventEmitter, Render, Role, Window, div, prelude::*, px, uniform_list,
};

use crate::CodexTheme;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum QueueEvent {
    Remove { id: String },
    Reorder { ids: Vec<String> },
}

pub struct CodexQueue {
    presentation: QueuePresentation,
    theme: CodexTheme,
}

impl CodexQueue {
    #[must_use]
    pub fn new(presentation: QueuePresentation) -> Self {
        Self {
            presentation,
            theme: CodexTheme::default(),
        }
    }

    pub fn set_presentation(&mut self, presentation: QueuePresentation, cx: &mut Context<Self>) {
        self.presentation = presentation;
        cx.notify();
    }

    fn remove(&mut self, id: String, cx: &mut Context<Self>) {
        self.presentation.rows.retain(|row| row.id != id);
        cx.emit(QueueEvent::Remove { id });
        cx.notify();
    }

    fn move_by(&mut self, id: &str, delta: isize, cx: &mut Context<Self>) {
        let Some(index) = self.presentation.rows.iter().position(|row| row.id == id) else {
            return;
        };
        let destination = index.saturating_add_signed(delta);
        if destination >= self.presentation.rows.len() || destination == index {
            return;
        }
        self.presentation.rows.swap(index, destination);
        cx.emit(QueueEvent::Reorder {
            ids: self
                .presentation
                .rows
                .iter()
                .map(|row| row.id.clone())
                .collect(),
        });
        cx.notify();
    }
}

impl EventEmitter<QueueEvent> for CodexQueue {}

impl Render for CodexQueue {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let count = self.presentation.rows.len();
        let content = (count > 0).then(|| {
            div()
                .size_full()
                .child(
                    div()
                        .px_5()
                        .py_2()
                        .text_xs()
                        .text_color(self.theme.muted_text)
                        .child(format!("Queued follow-ups · {count}")),
                )
                .child(
                    uniform_list(
                        "codex-queue-list",
                        count,
                        cx.processor(|this, range: std::ops::Range<usize>, _window, cx| {
                            let count = this.presentation.rows.len();
                            range
                                .filter_map(|index| {
                                    let row = this.presentation.rows.get(index)?.clone();
                                    Some(render_row(&row, index, count, this.theme, cx))
                                })
                                .collect::<Vec<AnyElement>>()
                        }),
                    )
                    .max_h(px(144.)),
                )
        });
        div()
            .id("codex-queue")
            .role(Role::Region)
            .aria_label(format!("Queued follow-ups: {count}"))
            .w_full()
            .max_h(px(180.))
            .border_t_1()
            .border_color(self.theme.border)
            .bg(self.theme.surface)
            .when_some(content, gpui::ParentElement::child)
    }
}

fn render_row(
    row: &QueueRowPresentation,
    index: usize,
    count: usize,
    theme: CodexTheme,
    cx: &mut Context<CodexQueue>,
) -> AnyElement {
    let up_id = row.id.clone();
    let down_id = row.id.clone();
    let remove_id = row.id.clone();
    div()
        .id(("queue-row", index))
        .role(Role::ListItem)
        .aria_label(row.text.clone())
        .h(px(44.))
        .w_full()
        .px_5()
        .flex()
        .items_center()
        .gap_2()
        .border_t_1()
        .border_color(theme.border)
        .child(
            div()
                .min_w_0()
                .flex_1()
                .text_sm()
                .truncate()
                .child(row.text.clone()),
        )
        .child(
            action_button("up", index, "Move up", index > 0, theme).when(index > 0, |button| {
                button.on_click(cx.listener(move |this, _, _, cx| {
                    this.move_by(&up_id, -1, cx);
                }))
            }),
        )
        .child(
            action_button("down", index, "Move down", index + 1 < count, theme).when(
                index + 1 < count,
                |button| {
                    button.on_click(cx.listener(move |this, _, _, cx| {
                        this.move_by(&down_id, 1, cx);
                    }))
                },
            ),
        )
        .child(
            action_button("remove", index, "Remove", true, theme).on_click(cx.listener(
                move |this, _, _, cx| {
                    this.remove(remove_id.clone(), cx);
                },
            )),
        )
        .into_any()
}

fn action_button(
    id: &'static str,
    index: usize,
    label: &'static str,
    enabled: bool,
    theme: CodexTheme,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id((id, index))
        .focusable()
        .tab_stop(enabled)
        .role(Role::Button)
        .aria_label(label)
        .px_2()
        .py_1()
        .text_xs()
        .text_color(if enabled {
            theme.text
        } else {
            theme.muted_text
        })
        .when(enabled, gpui::Styled::cursor_pointer)
        .child(label)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn queue_events_preserve_server_id_order() {
        assert_eq!(
            QueueEvent::Reorder {
                ids: vec!["b".to_owned(), "a".to_owned()]
            },
            QueueEvent::Reorder {
                ids: vec!["b".to_owned(), "a".to_owned()]
            }
        );
    }
}
