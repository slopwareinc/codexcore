use std::collections::{BTreeMap, BTreeSet};

use codex_presentation::{
    McpFieldKind, McpFieldPresentation, PromptActionEmphasis, PromptActionKind,
    PromptActionPresentation, PromptPresentation, ServerRequestKey, UserQuestionPresentation,
};
use gpui::{
    AnyElement, Context, Entity, EventEmitter, Render, Role, SharedString, Subscription, Window,
    div, prelude::*, px,
};

use crate::{
    CodexTheme,
    composer::{ComposerInput, InputEvent},
};

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
    pub mcp_content: Option<serde_json::Value>,
    pub url: Option<String>,
}

/// Accessible blocking-prompt card with host-routed semantic actions.
pub struct CodexPrompt {
    presentation: PromptPresentation,
    theme: CodexTheme,
    answers: BTreeMap<String, Vec<String>>,
    custom_inputs: BTreeMap<String, Entity<ComposerInput>>,
    input_subscriptions: Vec<Subscription>,
    mcp_inputs: BTreeMap<String, Entity<ComposerInput>>,
    mcp_values: serde_json::Map<String, serde_json::Value>,
    invalid_mcp_fields: BTreeSet<String>,
}

impl CodexPrompt {
    #[must_use]
    pub fn new(presentation: PromptPresentation, cx: &mut Context<Self>) -> Self {
        let mut this = Self {
            presentation,
            theme: CodexTheme::default(),
            answers: BTreeMap::new(),
            custom_inputs: BTreeMap::new(),
            input_subscriptions: Vec::new(),
            mcp_inputs: BTreeMap::new(),
            mcp_values: serde_json::Map::new(),
            invalid_mcp_fields: BTreeSet::new(),
        };
        this.install_custom_inputs(cx);
        this
    }

    #[must_use]
    pub fn with_theme(mut self, theme: CodexTheme, cx: &mut Context<Self>) -> Self {
        self.set_theme(theme, cx);
        self
    }

    pub fn set_theme(&mut self, theme: CodexTheme, cx: &mut Context<Self>) {
        self.theme = theme;
        for input in self.custom_inputs.values() {
            input.update(cx, |input, cx| input.set_theme(theme, cx));
        }
        cx.notify();
    }

    #[must_use]
    pub const fn presentation(&self) -> &PromptPresentation {
        &self.presentation
    }

    pub fn set_presentation(&mut self, presentation: PromptPresentation, cx: &mut Context<Self>) {
        self.presentation = presentation;
        self.answers.clear();
        self.mcp_values.clear();
        self.invalid_mcp_fields.clear();
        self.install_custom_inputs(cx);
        cx.notify();
    }

    fn install_custom_inputs(&mut self, cx: &mut Context<Self>) {
        self.custom_inputs.clear();
        self.mcp_inputs.clear();
        self.input_subscriptions.clear();
        let questions = self
            .presentation
            .user_input
            .as_ref()
            .map(|form| form.questions.clone())
            .unwrap_or_default();
        for question in questions {
            if !question.options.is_empty() && !question.is_other_allowed {
                continue;
            }
            let placeholder: SharedString = if question.is_other_allowed {
                "Other response…".into()
            } else {
                "Type response…".into()
            };
            let input =
                cx.new(|cx| ComposerInput::new(placeholder, self.theme, question.is_secret, cx));
            let question_id = question.id.clone();
            self.input_subscriptions.push(cx.subscribe(
                &input,
                move |this, input, event: &InputEvent, cx| {
                    if !matches!(event, InputEvent::Changed) {
                        return;
                    }
                    let text = input.read(cx).text().trim().to_owned();
                    if text.is_empty() {
                        this.answers.remove(&question_id);
                    } else {
                        this.answers.insert(question_id.clone(), vec![text]);
                    }
                    cx.notify();
                },
            ));
            self.custom_inputs.insert(question.id, input);
        }
        let fields = self
            .presentation
            .mcp_form
            .as_ref()
            .map(|form| form.fields.clone())
            .unwrap_or_default();
        for field in fields {
            let (placeholder, secret) = match field.kind {
                McpFieldKind::Text { secret } => ("Enter value…", secret),
                McpFieldKind::Number { .. } => ("Enter number…", false),
                _ => continue,
            };
            let input = cx.new(|cx| ComposerInput::new(placeholder.into(), self.theme, secret, cx));
            let field_name = field.name.clone();
            let kind = field.kind.clone();
            self.input_subscriptions.push(cx.subscribe(
                &input,
                move |this, input, event: &InputEvent, cx| {
                    if !matches!(event, InputEvent::Changed) {
                        return;
                    }
                    let text = input.read(cx).text().trim().to_owned();
                    match parse_mcp_input(&kind, &text) {
                        Ok(Some(value)) => {
                            this.mcp_values.insert(field_name.clone(), value);
                            this.invalid_mcp_fields.remove(&field_name);
                        }
                        Ok(None) => {
                            this.mcp_values.remove(&field_name);
                            this.invalid_mcp_fields.remove(&field_name);
                        }
                        Err(()) => {
                            this.mcp_values.remove(&field_name);
                            this.invalid_mcp_fields.insert(field_name.clone());
                        }
                    }
                    cx.notify();
                },
            ));
            self.mcp_inputs.insert(field.name, input);
        }
    }

    fn select_answer(&mut self, question_id: String, answer: String, cx: &mut Context<Self>) {
        self.answers.insert(question_id, vec![answer]);
        cx.notify();
    }

    fn select_mcp_value(&mut self, field: &str, value: serde_json::Value, cx: &mut Context<Self>) {
        self.mcp_values.insert(field.to_owned(), value);
        self.invalid_mcp_fields.remove(field);
        cx.notify();
    }

    fn form_is_complete(&self) -> bool {
        let user_complete = self
            .presentation
            .user_input
            .as_ref()
            .is_none_or(|form| answers_complete(&form.questions, &self.answers));
        let mcp_complete = self.presentation.mcp_form.as_ref().is_none_or(|form| {
            form.unsupported_fields.is_empty()
                && self.invalid_mcp_fields.is_empty()
                && form
                    .fields
                    .iter()
                    .filter(|field| field.required)
                    .all(|field| self.mcp_values.contains_key(&field.name))
        });
        user_complete && mcp_complete
    }

    fn render_elements(&mut self, cx: &mut Context<Self>) -> PromptElements {
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
                render_question(
                    question,
                    index,
                    &self.answers,
                    self.custom_inputs.get(&question.id).cloned(),
                    self.theme,
                    cx,
                )
            })
            .collect();
        let mcp_fields = self
            .presentation
            .mcp_form
            .as_ref()
            .map(|form| form.fields.clone())
            .unwrap_or_default();
        let mcp_elements = mcp_fields
            .iter()
            .enumerate()
            .map(|(index, field)| {
                render_mcp_field(
                    field,
                    index,
                    self.mcp_inputs.get(&field.name).cloned(),
                    self.mcp_values.get(&field.name),
                    self.invalid_mcp_fields.contains(&field.name),
                    self.theme,
                    cx,
                )
            })
            .collect();
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
                    PromptResponseState {
                        answers: &self.answers,
                        mcp_values: &self.mcp_values,
                        has_mcp_form: self.presentation.mcp_form.is_some(),
                        url: self.presentation.mcp_url.clone(),
                    },
                    self.theme,
                    cx,
                )
            })
            .collect();
        PromptElements {
            questions: question_elements,
            mcp_fields: mcp_elements,
            unsupported_mcp_fields: self
                .presentation
                .mcp_form
                .as_ref()
                .map(|form| form.unsupported_fields.clone())
                .unwrap_or_default(),
            actions: action_elements,
        }
    }
}

struct PromptElements {
    questions: Vec<AnyElement>,
    mcp_fields: Vec<AnyElement>,
    unsupported_mcp_fields: Vec<String>,
    actions: Vec<AnyElement>,
}

impl EventEmitter<PromptIntent> for CodexPrompt {}

impl Render for CodexPrompt {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let PromptElements {
            questions,
            mcp_fields,
            unsupported_mcp_fields,
            actions,
        } = self.render_elements(cx);
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
            .children(questions)
            .children(mcp_fields)
            .when(!unsupported_mcp_fields.is_empty(), |view| {
                view.child(
                    div()
                        .rounded_lg()
                        .border_1()
                        .border_color(self.theme.danger)
                        .px_3()
                        .py_2()
                        .text_sm()
                        .text_color(self.theme.danger)
                        .child(format!(
                            "Unsupported MCP form field(s): {}",
                            unsupported_mcp_fields.join(", ")
                        )),
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
                    .children(actions),
            )
    }
}

struct PromptResponseState<'a> {
    answers: &'a BTreeMap<String, Vec<String>>,
    mcp_values: &'a serde_json::Map<String, serde_json::Value>,
    has_mcp_form: bool,
    url: Option<String>,
}

fn render_action(
    key: &ServerRequestKey,
    action: PromptActionPresentation,
    enabled: bool,
    response: PromptResponseState<'_>,
    theme: CodexTheme,
    cx: &mut Context<CodexPrompt>,
) -> AnyElement {
    let event_key = key.clone();
    let event_kind = action.kind;
    let event_answers =
        (action.kind == PromptActionKind::Respond).then(|| response.answers.clone());
    let event_mcp_content = (action.kind == PromptActionKind::Respond && response.has_mcp_form)
        .then(|| serde_json::Value::Object(response.mcp_values.clone()));
    let url = response.url;
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
                        mcp_content: event_mcp_content.clone(),
                        url: url.clone(),
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
    custom_input: Option<Entity<ComposerInput>>,
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
        .when_some(custom_input, |view, input| {
            view.child(
                div()
                    .rounded_lg()
                    .border_1()
                    .border_color(theme.border)
                    .bg(theme.surface)
                    .child(input),
            )
        })
        .into_any()
}

fn render_mcp_field(
    field: &McpFieldPresentation,
    index: usize,
    input: Option<Entity<ComposerInput>>,
    selected: Option<&serde_json::Value>,
    invalid: bool,
    theme: CodexTheme,
    cx: &mut Context<CodexPrompt>,
) -> AnyElement {
    let choices = render_mcp_choices(field, index, selected, theme, cx);
    div()
        .id(("mcp-field", index))
        .role(Role::Group)
        .aria_label(field.title.clone())
        .flex()
        .flex_col()
        .gap_2()
        .child(div().text_sm().child(if field.required {
            format!("{} *", field.title)
        } else {
            field.title.clone()
        }))
        .when_some(field.description.clone(), |view, description| {
            view.child(
                div()
                    .text_xs()
                    .text_color(theme.muted_text)
                    .child(description),
            )
        })
        .when_some(input, |view, input| {
            view.child(
                div()
                    .rounded_lg()
                    .border_1()
                    .border_color(if invalid { theme.danger } else { theme.border })
                    .bg(theme.surface)
                    .child(input),
            )
        })
        .when(!choices.is_empty(), |view| {
            view.child(
                div()
                    .id(("mcp-field-choices", index))
                    .role(Role::RadioGroup)
                    .aria_label(field.title.clone())
                    .flex()
                    .flex_wrap()
                    .gap_2()
                    .children(choices),
            )
        })
        .when(matches!(field.kind, McpFieldKind::Unsupported), |view| {
            view.child(
                div()
                    .text_xs()
                    .text_color(theme.danger)
                    .child("Unsupported field schema"),
            )
        })
        .into_any()
}

fn render_mcp_choices(
    field: &McpFieldPresentation,
    index: usize,
    selected: Option<&serde_json::Value>,
    theme: CodexTheme,
    cx: &mut Context<CodexPrompt>,
) -> Vec<gpui::Stateful<gpui::Div>> {
    match &field.kind {
        McpFieldKind::Choice(choices) => choices
            .iter()
            .enumerate()
            .map(|(choice_index, choice)| {
                let is_selected = selected.and_then(serde_json::Value::as_str) == Some(choice);
                let field_name = field.name.clone();
                let value = choice.clone();
                div()
                    .id(("mcp-choice", index * 1_000 + choice_index))
                    .focusable()
                    .tab_stop(true)
                    .role(Role::RadioButton)
                    .aria_label(choice.clone())
                    .aria_selected(is_selected)
                    .rounded_md()
                    .border_1()
                    .border_color(if is_selected {
                        theme.accent
                    } else {
                        theme.border
                    })
                    .px_3()
                    .py_2()
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.select_mcp_value(
                            &field_name,
                            serde_json::Value::String(value.clone()),
                            cx,
                        );
                    }))
                    .child(choice.clone())
            })
            .collect::<Vec<_>>(),
        McpFieldKind::Boolean => [true, false]
            .into_iter()
            .enumerate()
            .map(|(choice_index, choice)| {
                let is_selected = selected.and_then(serde_json::Value::as_bool) == Some(choice);
                let field_name = field.name.clone();
                div()
                    .id(("mcp-boolean", index * 1_000 + choice_index))
                    .focusable()
                    .tab_stop(true)
                    .role(Role::RadioButton)
                    .aria_label(if choice { "Yes" } else { "No" })
                    .aria_selected(is_selected)
                    .rounded_md()
                    .border_1()
                    .border_color(if is_selected {
                        theme.accent
                    } else {
                        theme.border
                    })
                    .px_3()
                    .py_2()
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.select_mcp_value(&field_name, serde_json::Value::Bool(choice), cx);
                    }))
                    .child(if choice { "Yes" } else { "No" })
            })
            .collect(),
        _ => Vec::new(),
    }
}

fn parse_mcp_input(kind: &McpFieldKind, text: &str) -> Result<Option<serde_json::Value>, ()> {
    if text.is_empty() {
        return Ok(None);
    }
    match kind {
        McpFieldKind::Text { .. } => Ok(Some(serde_json::Value::String(text.to_owned()))),
        McpFieldKind::Number { integer: true } => text
            .parse::<i64>()
            .map(serde_json::Number::from)
            .map(serde_json::Value::Number)
            .map(Some)
            .map_err(|_| ()),
        McpFieldKind::Number { integer: false } => text
            .parse::<f64>()
            .ok()
            .and_then(serde_json::Number::from_f64)
            .map(serde_json::Value::Number)
            .map(Some)
            .ok_or(()),
        _ => Err(()),
    }
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

    #[test]
    fn mcp_numeric_input_is_typed_and_rejects_invalid_values() {
        assert_eq!(
            parse_mcp_input(&McpFieldKind::Number { integer: true }, "42"),
            Ok(Some(serde_json::json!(42)))
        );
        assert_eq!(
            parse_mcp_input(&McpFieldKind::Number { integer: false }, "1.5"),
            Ok(Some(serde_json::json!(1.5)))
        );
        assert_eq!(
            parse_mcp_input(&McpFieldKind::Number { integer: true }, "1.5"),
            Err(())
        );
    }
}
