use codex_presentation::{
    PromptActionEmphasis, PromptActionKind, PromptActionPresentation, PromptPresentation,
    ServerRequestKey,
};
use gpui::{AnyElement, Context, EventEmitter, Render, Role, Window, div, prelude::*, px};

use crate::CodexTheme;

/// User intent emitted by an interactive prompt.
///
/// The host maps this semantic intent to an exact validated App Server reply.
/// `Respond` and `OpenUrl` commonly open a richer host-owned form before any
/// reply is sent.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PromptIntent {
    pub key: ServerRequestKey,
    pub action: PromptActionKind,
}

/// Accessible blocking-prompt card with host-routed semantic actions.
pub struct CodexPrompt {
    presentation: PromptPresentation,
    theme: CodexTheme,
}

impl CodexPrompt {
    #[must_use]
    pub fn new(presentation: PromptPresentation) -> Self {
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

    #[must_use]
    pub const fn presentation(&self) -> &PromptPresentation {
        &self.presentation
    }

    pub fn set_presentation(&mut self, presentation: PromptPresentation, cx: &mut Context<Self>) {
        self.presentation = presentation;
        cx.notify();
    }
}

impl EventEmitter<PromptIntent> for CodexPrompt {}

impl Render for CodexPrompt {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let action_elements = self
            .presentation
            .actions
            .iter()
            .cloned()
            .map(|action| render_action(&self.presentation.key, action, self.theme, cx))
            .collect::<Vec<_>>();
        let identity = prompt_identity(&self.presentation.key);

        div()
            .id(format!("codex-prompt:{identity}"))
            .role(Role::AlertDialog)
            .aria_label(self.presentation.title.clone())
            .aria_description(
                self.presentation
                    .message
                    .clone()
                    .unwrap_or_else(|| self.presentation.title.clone()),
            )
            .w_full()
            .rounded_xl()
            .border_1()
            .border_color(if self.presentation.is_destructive {
                self.theme.danger
            } else {
                self.theme.border
            })
            .bg(self.theme.elevated_surface)
            .p_4()
            .flex()
            .flex_col()
            .gap_3()
            .text_color(self.theme.text)
            .child(
                div()
                    .id("prompt-title")
                    .role(Role::Heading)
                    .aria_level(2)
                    .text_lg()
                    .child(self.presentation.title.clone()),
            )
            .when_some(self.presentation.message.clone(), |view, message| {
                view.child(
                    div()
                        .id("prompt-message")
                        .role(Role::Paragraph)
                        .whitespace_normal()
                        .text_sm()
                        .text_color(self.theme.muted_text)
                        .child(message),
                )
            })
            .child(
                div()
                    .id("prompt-actions")
                    .role(Role::Group)
                    .aria_label("Prompt actions")
                    .flex()
                    .flex_wrap()
                    .gap_2()
                    .children(action_elements),
            )
    }
}

fn render_action(
    key: &ServerRequestKey,
    action: PromptActionPresentation,
    theme: CodexTheme,
    cx: &mut Context<CodexPrompt>,
) -> AnyElement {
    let event_key = key.clone();
    let event_kind = action.kind;
    let (background, foreground, border) = match action.emphasis {
        PromptActionEmphasis::Primary => (theme.accent, theme.background, theme.accent),
        PromptActionEmphasis::Secondary => (theme.surface, theme.text, theme.border),
        PromptActionEmphasis::Danger => (theme.danger, theme.background, theme.danger),
    };
    div()
        .id(format!("prompt-action:{}", action.id))
        .focusable()
        .tab_stop(true)
        .role(Role::Button)
        .aria_label(action.label.clone())
        .px_3()
        .py_2()
        .min_w(px(88.))
        .rounded_lg()
        .border_1()
        .border_color(border)
        .bg(background)
        .text_color(foreground)
        .text_sm()
        .text_center()
        .cursor_pointer()
        .hover(move |style| style.bg(background.opacity(0.82)))
        .on_click(cx.listener(move |_, _, _, cx| {
            cx.emit(PromptIntent {
                key: event_key.clone(),
                action: event_kind,
            });
        }))
        .child(action.label)
        .into_any()
}

fn prompt_identity(key: &ServerRequestKey) -> String {
    format!(
        "{}:{}",
        key.connection_epoch,
        serde_json::to_string(&key.request_id).unwrap_or_else(|_| "invalid".to_owned())
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use codex_app_server_wire::JsonRpcId;

    #[test]
    fn prompt_identity_keeps_integer_and_string_ids_distinct() {
        let integer = ServerRequestKey {
            connection_epoch: 4,
            request_id: JsonRpcId::Integer(7),
        };
        let string = ServerRequestKey {
            connection_epoch: 4,
            request_id: JsonRpcId::String("7".to_owned()),
        };
        assert_ne!(prompt_identity(&integer), prompt_identity(&string));
    }
}
