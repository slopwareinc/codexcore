use codex_presentation::{ModelChoicePresentation, ModelPickerPresentation};
use gpui::{
    AnyElement, Context, EventEmitter, Render, Role, Window, div, prelude::*, px, uniform_list,
};

use crate::CodexTheme;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelSelectionEvent {
    pub model: String,
    pub effort: String,
}

pub struct CodexModelPicker {
    presentation: ModelPickerPresentation,
    theme: CodexTheme,
}

impl CodexModelPicker {
    #[must_use]
    pub fn new(presentation: ModelPickerPresentation) -> Self {
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
        presentation: ModelPickerPresentation,
        cx: &mut Context<Self>,
    ) {
        self.presentation = presentation;
        cx.notify();
    }

    fn select_model(&mut self, model: String, cx: &mut Context<Self>) {
        let Some(choice) = self
            .presentation
            .models
            .iter()
            .find(|choice| choice.model == model)
        else {
            return;
        };
        self.presentation.selected_model.clone_from(&model);
        self.presentation.selected_effort = choice.default_effort.clone();
        cx.emit(ModelSelectionEvent {
            model,
            effort: choice.default_effort.clone(),
        });
        cx.notify();
    }

    fn select_effort(&mut self, effort: String, cx: &mut Context<Self>) {
        let Some(choice) = self.selected_choice() else {
            return;
        };
        if !choice
            .efforts
            .iter()
            .any(|candidate| candidate.value == effort)
        {
            return;
        }
        let model = choice.model.clone();
        self.presentation.selected_effort.clone_from(&effort);
        cx.emit(ModelSelectionEvent { model, effort });
        cx.notify();
    }

    fn selected_choice(&self) -> Option<&ModelChoicePresentation> {
        self.presentation
            .models
            .iter()
            .find(|model| model.model == self.presentation.selected_model)
    }
}

impl EventEmitter<ModelSelectionEvent> for CodexModelPicker {}

impl Render for CodexModelPicker {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let selected = self.selected_choice().cloned();
        let selected_name = selected
            .as_ref()
            .map_or_else(|| "No model".to_owned(), |model| model.display_name.clone());
        let effort_elements = selected
            .as_ref()
            .map(|model| {
                model
                    .efforts
                    .iter()
                    .enumerate()
                    .map(|(index, effort)| {
                        let selected = effort.value == self.presentation.selected_effort;
                        let value = effort.value.clone();
                        div()
                            .id(("model-effort", index))
                            .focusable()
                            .tab_stop(true)
                            .role(Role::RadioButton)
                            .aria_label(format!(
                                "{} reasoning effort: {}",
                                display_reasoning_effort(&effort.value),
                                effort.description
                            ))
                            .aria_selected(selected)
                            .rounded_md()
                            .border_1()
                            .border_color(if selected {
                                self.theme.accent
                            } else {
                                self.theme.border
                            })
                            .px_2()
                            .py_1()
                            .text_xs()
                            .cursor_pointer()
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.select_effort(value.clone(), cx);
                            }))
                            .child(display_reasoning_effort(&effort.value))
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let count = self.presentation.models.len();

        div()
            .id("codex-model-picker")
            .role(Role::Group)
            .aria_label("Model and reasoning effort")
            .size_full()
            .flex()
            .flex_col()
            .overflow_hidden()
            .bg(self.theme.surface)
            .child(
                div()
                    .flex_shrink_0()
                    .p_3()
                    .border_b_1()
                    .border_color(self.theme.border)
                    .child(div().text_sm().child(selected_name))
                    .child(
                        div()
                            .id("model-efforts")
                            .role(Role::RadioGroup)
                            .aria_label("Reasoning effort")
                            .mt_2()
                            .flex()
                            .flex_wrap()
                            .gap_1()
                            .children(effort_elements),
                    ),
            )
            .child(
                uniform_list(
                    "codex-model-list",
                    count,
                    cx.processor(|this, range: std::ops::Range<usize>, _window, cx| {
                        range
                            .filter_map(|index| {
                                let model = this.presentation.models.get(index)?.clone();
                                let value = model.model.clone();
                                Some(
                                    render_model(
                                        &model,
                                        model.model == this.presentation.selected_model,
                                        index,
                                        this.theme,
                                    )
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.select_model(value.clone(), cx);
                                    }))
                                    .into_any(),
                                )
                            })
                            .collect::<Vec<AnyElement>>()
                    }),
                )
                .flex_1(),
            )
    }
}

/// Convert a wire reasoning-effort value to the human-readable label used by
/// the model picker and compact composer control.
#[must_use]
pub fn display_reasoning_effort(value: &str) -> String {
    let normalized = value.trim().to_ascii_lowercase();
    match normalized.as_str() {
        "" => String::new(),
        "none" => "None".to_owned(),
        "minimal" => "Minimal".to_owned(),
        "low" => "Low".to_owned(),
        "medium" => "Medium".to_owned(),
        "high" => "High".to_owned(),
        "xhigh" => "Extra High".to_owned(),
        "max" | "maximum" => "Maximum".to_owned(),
        "ultra" => "Ultra".to_owned(),
        _ => normalized
            .split(['-', '_', ' '])
            .filter(|part| !part.is_empty())
            .map(title_case_word)
            .collect::<Vec<_>>()
            .join(" "),
    }
}

fn title_case_word(word: &str) -> String {
    let mut characters = word.chars();
    let Some(first) = characters.next() else {
        return String::new();
    };
    first
        .to_uppercase()
        .chain(characters.flat_map(char::to_lowercase))
        .collect()
}

fn render_model(
    model: &ModelChoicePresentation,
    selected: bool,
    index: usize,
    theme: CodexTheme,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(("model-choice", index))
        .focusable()
        .tab_stop(true)
        .role(Role::RadioButton)
        .aria_label(format!("{}. {}", model.display_name, model.description))
        .aria_selected(selected)
        .h(px(68.))
        .w_full()
        .px_3()
        .py_2()
        .border_b_1()
        .border_color(theme.border)
        .bg(if selected {
            theme.elevated_surface
        } else {
            theme.surface
        })
        .hover(move |style| style.bg(theme.elevated_surface))
        .cursor_pointer()
        .child(
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(div().text_sm().child(model.display_name.clone()))
                .when(model.is_default, |view| {
                    view.child(
                        div()
                            .rounded_full()
                            .border_1()
                            .border_color(theme.accent)
                            .px_2()
                            .text_xs()
                            .text_color(theme.accent)
                            .child("Default"),
                    )
                }),
        )
        .child(
            div()
                .mt_1()
                .text_xs()
                .text_color(theme.muted_text)
                .truncate()
                .child(model.description.clone()),
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selection_event_keeps_model_and_effort_together() {
        let event = ModelSelectionEvent {
            model: "model".to_owned(),
            effort: "high".to_owned(),
        };
        assert_eq!(event.model, "model");
        assert_eq!(event.effort, "high");
    }

    #[test]
    fn reasoning_effort_labels_are_human_readable() {
        assert_eq!(display_reasoning_effort("low"), "Low");
        assert_eq!(display_reasoning_effort("medium"), "Medium");
        assert_eq!(display_reasoning_effort("xhigh"), "Extra High");
        assert_eq!(display_reasoning_effort("some_effort"), "Some Effort");
    }
}
