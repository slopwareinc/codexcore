use std::collections::BTreeMap;

use codex_presentation::{
    PromptActionEmphasis, PromptActionKind, PromptActionPresentation, PromptPresentation,
    ServerRequestKey, UserQuestionPresentation,
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
    pub answers: Option<BTreeMap<String, Vec<String>>>,
}

/// Accessible blocking-prompt card with host-routed semantic actions.
pub struct CodexPrompt {
    presentation: PromptPresentation,
    theme: CodexTheme,
    answers: BTreeMap<String, Vec<String>>,
}

impl CodexPrompt {
    #[must_use]
    pub fn new(presentation: PromptPresentation) -> Self {
        Self {
            presentation,
            theme: CodexTheme::default(),
            answers: BTreeMap::new(),
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
        self.answers.clear();
        cx.notify();
    }

    fn select_answer(&mut self, question_id: String, answer: String, cx: &mut Context<Self>) {
        self.answers.insert(question_id, vec![answer]);
        cx.notify();
    }

    fn form_is_complete(&self) -> bool {
        self.presentation
            .user_input
            .as_ref()
            .is_none_or(|form| answers_complete(&form.questions, &self.answers))
    }
}

impl EventEmitter<PromptIntent> for CodexPrompt {}

impl Render for CodexPrompt {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let questions = self
            .presentation
            .user_input
            .as_ref()
            .map(|form| form.questions.clone())
            .unwrap_or_default();
        let question_elements = questions
            .iter()
            .enumerate()
            .map(|(index, question)| {
                render_question(question, index, &self.answers, self.theme, cx)
            })
            .collect::<Vec<_>>();
        let form_complete = self.form_is_complete();
        let action_elements = self
            .presentation
            .actions
            .iter()
            .cloned()
            .map(|action| {
                let enabled = action.kind != PromptActionKind::Respond || form_complete;
                render_action(
                    &self.presentation.key,
                    action,
                    enabled,
                    &self.answers,
                    self.theme,
                    cx,
                )
            })
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
            .children(question_elements)
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
    enabled: bool,
    answers: &BTreeMap<String, Vec<String>>,
    theme: CodexTheme,
    cx: &mut Context<CodexPrompt>,
) -> AnyElement {
    let event_key = key.clone();
    let event_kind = action.kind;
    let event_answers = (action.kind == PromptActionKind::Respond).then(|| answers.clone());
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
        .bg(if enabled { background } else { theme.surface })
        .text_color(if enabled {
            foreground
        } else {
            theme.muted_text
        })
        .text_sm()
        .text_center()
        .when(enabled, |button| {
            button
                .cursor_pointer()
                .hover(move |style| style.bg(background.opacity(0.82)))
                .on_click(cx.listener(move |_, _, _, cx| {
                    cx.emit(PromptIntent {
                        key: event_key.clone(),
                        action: event_kind,
                        answers: event_answers.clone(),
                    });
                }))
        })
        .child(action.label)
        .into_any()
}

fn render_question(
    question: &UserQuestionPresentation,
    index: usize,
    answers: &BTreeMap<String, Vec<String>>,
    theme: CodexTheme,
    cx: &mut Context<CodexPrompt>,
) -> AnyElement {
    let selected = answers
        .get(&question.id)
        .and_then(|answers| answers.first());
    let options = question
        .options
        .iter()
        .enumerate()
        .map(|(option_index, option)| {
            let is_selected = selected == Some(&option.label);
            let question_id = question.id.clone();
            let answer = option.label.clone();
            div()
                .id(("question-option", index * 1_000 + option_index))
                .focusable()
                .tab_stop(true)
                .role(Role::RadioButton)
                .aria_label(option.label.clone())
                .aria_selected(is_selected)
                .rounded_lg()
                .border_1()
                .border_color(if is_selected {
                    theme.accent
                } else {
                    theme.border
                })
                .bg(if is_selected {
                    theme.surface
                } else {
                    theme.elevated_surface
                })
                .px_3()
                .py_2()
                .cursor_pointer()
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.select_answer(question_id.clone(), answer.clone(), cx);
                }))
                .child(option.label.clone())
                .when_some(option.description.clone(), |view, description| {
                    view.child(
                        div()
                            .ml_2()
                            .text_xs()
                            .text_color(theme.muted_text)
                            .child(description),
                    )
                })
        })
        .collect::<Vec<_>>();
    div()
        .id(("prompt-question", index))
        .role(Role::Group)
        .aria_label(question.question.clone())
        .flex()
        .flex_col()
        .gap_2()
        .child(
            div()
                .text_sm()
                .child(question.question.clone())
                .when(question.is_secret, |view| {
                    view.child(
                        div()
                            .ml_2()
                            .text_xs()
                            .text_color(theme.warning)
                            .child("Secret response"),
                    )
                }),
        )
        .child(
            div()
                .id(("question-options", index))
                .role(Role::RadioGroup)
                .aria_label(question.header.clone())
                .flex()
                .flex_col()
                .gap_2()
                .children(options),
        )
        .when(question.is_other_allowed, |view| {
            view.child(
                div()
                    .text_xs()
                    .text_color(theme.muted_text)
                    .child("Custom response entry is not available yet."),
            )
        })
        .into_any()
}

fn prompt_identity(key: &ServerRequestKey) -> String {
    format!(
        "{}:{}",
        key.connection_epoch,
        serde_json::to_string(&key.request_id).unwrap_or_else(|_| "invalid".to_owned())
    )
}

fn answers_complete(
    questions: &[UserQuestionPresentation],
    answers: &BTreeMap<String, Vec<String>>,
) -> bool {
    questions.iter().all(|question| {
        answers
            .get(&question.id)
            .is_some_and(|answers| !answers.is_empty())
    })
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

    #[test]
    fn every_question_requires_a_nonempty_answer() {
        let questions = vec![UserQuestionPresentation {
            id: "choice".to_owned(),
            header: "Choice".to_owned(),
            question: "Pick one".to_owned(),
            is_secret: false,
            is_other_allowed: false,
            options: Vec::new(),
        }];
        assert!(!answers_complete(&questions, &BTreeMap::new()));
        assert!(answers_complete(
            &questions,
            &BTreeMap::from([("choice".to_owned(), vec!["Safe".to_owned()])])
        ));
    }
}
