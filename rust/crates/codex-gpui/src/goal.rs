use codex_presentation::{GoalLifecycleAction, GoalPresentation, GoalStatusTone};
use gpui::{
    App, Context, Entity, EventEmitter, Render, Role, Subscription, Window, div, prelude::*, px,
};

use crate::{
    CodexTheme,
    composer::{ComposerInput, InputEvent},
};

/// Semantic goal intent routed to the host that owns the selected thread.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum GoalEvent {
    Set {
        objective: String,
        token_budget: Option<i64>,
    },
    Pause,
    Resume,
    Clear,
}

/// Controlled native editor and status panel for one selected thread goal.
pub struct CodexGoal {
    presentation: Option<GoalPresentation>,
    objective_input: Entity<ComposerInput>,
    budget_input: Entity<ComposerInput>,
    objective_draft: String,
    budget_draft: String,
    theme: CodexTheme,
    _objective_subscription: Subscription,
    _budget_subscription: Subscription,
}

impl CodexGoal {
    #[must_use]
    pub fn new(presentation: Option<GoalPresentation>, cx: &mut Context<Self>) -> Self {
        let theme = CodexTheme::default();
        let objective_draft = presentation
            .as_ref()
            .map_or_else(String::new, |goal| goal.objective.clone());
        let budget_draft = presentation
            .as_ref()
            .and_then(|goal| goal.token_budget)
            .map_or_else(String::new, |budget| budget.to_string());
        let objective_input = cx.new(|cx| {
            ComposerInput::new("Goal objective…".into(), theme, false, cx)
                .with_accessibility_label("Goal objective")
        });
        objective_input.update(cx, |input, cx| input.set_text(&objective_draft, cx));
        let budget_input = cx.new(|cx| {
            ComposerInput::new("Optional token budget…".into(), theme, false, cx)
                .with_accessibility_label("Goal token budget")
        });
        budget_input.update(cx, |input, cx| input.set_text(&budget_draft, cx));
        let objective_subscription = cx.subscribe(
            &objective_input,
            |this, input, event: &InputEvent, cx| match event {
                InputEvent::Changed => {
                    input.read(cx).text().clone_into(&mut this.objective_draft);
                    cx.notify();
                }
                InputEvent::Submit => this.submit(cx),
            },
        );
        let budget_subscription = cx.subscribe(
            &budget_input,
            |this, input, event: &InputEvent, cx| match event {
                InputEvent::Changed => {
                    input.read(cx).text().clone_into(&mut this.budget_draft);
                    cx.notify();
                }
                InputEvent::Submit => this.submit(cx),
            },
        );
        Self {
            presentation,
            objective_input,
            budget_input,
            objective_draft,
            budget_draft,
            theme,
            _objective_subscription: objective_subscription,
            _budget_subscription: budget_subscription,
        }
    }

    /// Replace authoritative presentation while retaining unrelated local edits.
    pub fn set_presentation(
        &mut self,
        presentation: Option<GoalPresentation>,
        cx: &mut Context<Self>,
    ) {
        let objective_changed = self.presentation.as_ref().map(|goal| &goal.objective)
            != presentation.as_ref().map(|goal| &goal.objective);
        let budget_changed = self
            .presentation
            .as_ref()
            .and_then(|goal| goal.token_budget)
            != presentation.as_ref().and_then(|goal| goal.token_budget);
        self.presentation = presentation;
        if objective_changed {
            self.objective_draft = self
                .presentation
                .as_ref()
                .map_or_else(String::new, |goal| goal.objective.clone());
            self.objective_input.update(cx, |input, cx| {
                input.set_text(&self.objective_draft, cx);
            });
        }
        if budget_changed {
            self.budget_draft = self
                .presentation
                .as_ref()
                .and_then(|goal| goal.token_budget)
                .map_or_else(String::new, |budget| budget.to_string());
            self.budget_input.update(cx, |input, cx| {
                input.set_text(&self.budget_draft, cx);
            });
        }
        cx.notify();
    }

    /// Apply a host-provided theme to the panel and both native inputs.
    pub fn set_theme(&mut self, theme: CodexTheme, cx: &mut Context<Self>) {
        self.theme = theme;
        self.objective_input
            .update(cx, |input, cx| input.set_theme(theme, cx));
        self.budget_input
            .update(cx, |input, cx| input.set_theme(theme, cx));
        cx.notify();
    }

    #[must_use]
    pub fn objective(&self, cx: &App) -> String {
        self.objective_input.read(cx).text().to_owned()
    }

    fn submit(&mut self, cx: &mut Context<Self>) {
        let objective = self.objective_draft.trim().to_owned();
        let Ok(token_budget) = parse_token_budget(&self.budget_draft) else {
            return;
        };
        if objective.is_empty() {
            return;
        }
        cx.emit(GoalEvent::Set {
            objective,
            token_budget,
        });
    }

    fn clear(&mut self, cx: &mut Context<Self>) {
        if self.presentation.is_some() {
            cx.emit(GoalEvent::Clear);
        }
    }
}

impl EventEmitter<GoalEvent> for CodexGoal {}

impl Render for CodexGoal {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let has_goal = self.presentation.is_some();
        let budget = parse_token_budget(&self.budget_draft);
        let can_submit = !self.objective_draft.trim().is_empty() && budget.is_ok();
        let status = self.presentation.as_ref().map(|goal| {
            (
                goal.status_label.clone(),
                status_color(goal.status_tone, self.theme),
            )
        });
        let usage = self.presentation.as_ref().map(|goal| {
            (
                goal.token_usage_label.clone(),
                goal.time_usage_label.clone(),
            )
        });
        let lifecycle = self
            .presentation
            .as_ref()
            .and_then(|goal| goal.lifecycle_action);
        let theme = self.theme;

        div()
            .id("codex-goal")
            .role(Role::Region)
            .aria_label(if has_goal {
                "Thread goal"
            } else {
                "Set a thread goal"
            })
            .w_full()
            .flex()
            .flex_col()
            .gap_2()
            .bg(theme.surface)
            .p_3()
            .child(render_header(status))
            .when(!has_goal, |view| {
                view.child(
                    div()
                        .text_xs()
                        .text_color(theme.muted_text)
                        .child("Keep this task pursuing one objective."),
                )
            })
            .child(input_field(
                "Objective",
                self.objective_input.clone(),
                theme,
            ))
            .child(input_field(
                "Token budget",
                self.budget_input.clone(),
                theme,
            ))
            .when(budget.is_err(), |view| {
                view.child(
                    div()
                        .text_xs()
                        .text_color(theme.danger)
                        .child("Token budget must be a positive whole number."),
                )
            })
            .when_some(usage, |view, (tokens, time)| {
                view.child(render_usage(tokens, time, theme))
            })
            .child(render_actions(has_goal, can_submit, lifecycle, theme, cx))
    }
}

fn render_header(status: Option<(String, gpui::Rgba)>) -> gpui::Div {
    div()
        .flex()
        .items_center()
        .justify_between()
        .child(div().text_sm().child("Goal"))
        .when_some(status, |view, (label, color)| {
            view.child(
                div()
                    .rounded_full()
                    .border_1()
                    .border_color(color)
                    .px_2()
                    .py_1()
                    .text_xs()
                    .text_color(color)
                    .child(label),
            )
        })
}

fn render_usage(tokens: String, time: String, theme: CodexTheme) -> gpui::Div {
    div()
        .flex()
        .flex_col()
        .gap_1()
        .text_xs()
        .text_color(theme.muted_text)
        .child(tokens)
        .child(time)
}

fn render_actions(
    has_goal: bool,
    can_submit: bool,
    lifecycle: Option<GoalLifecycleAction>,
    theme: CodexTheme,
    cx: &mut Context<CodexGoal>,
) -> gpui::Div {
    div()
        .flex()
        .flex_wrap()
        .gap_2()
        .child(
            goal_button(
                "goal-save",
                if has_goal { "Update" } else { "Set goal" },
                can_submit,
                true,
                theme,
            )
            .when(can_submit, |button| {
                button.on_click(cx.listener(|this, _, _, cx| this.submit(cx)))
            }),
        )
        .when_some(lifecycle, |view, action| {
            let (label, event) = match action {
                GoalLifecycleAction::Pause => ("Pause", GoalEvent::Pause),
                GoalLifecycleAction::Resume => ("Resume", GoalEvent::Resume),
            };
            view.child(
                goal_button("goal-lifecycle", label, true, false, theme)
                    .on_click(cx.listener(move |_, _, _, cx| cx.emit(event.clone()))),
            )
        })
        .when(has_goal, |view| {
            view.child(
                goal_button("goal-clear", "Clear", true, false, theme)
                    .on_click(cx.listener(|this, _, _, cx| this.clear(cx))),
            )
        })
}

fn input_field(label: &'static str, input: Entity<ComposerInput>, theme: CodexTheme) -> gpui::Div {
    div()
        .flex()
        .flex_col()
        .gap_1()
        .child(div().text_xs().text_color(theme.muted_text).child(label))
        .child(
            div()
                .h(px(44.))
                .rounded_lg()
                .border_1()
                .border_color(theme.border)
                .bg(theme.elevated_surface)
                .child(input),
        )
}

fn goal_button(
    id: &'static str,
    label: &'static str,
    enabled: bool,
    primary: bool,
    theme: CodexTheme,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .focusable()
        .tab_stop(enabled)
        .role(Role::Button)
        .aria_label(label)
        .rounded_lg()
        .border_1()
        .border_color(if primary && enabled {
            theme.accent
        } else {
            theme.border
        })
        .bg(if primary && enabled {
            theme.accent
        } else {
            theme.surface
        })
        .px_3()
        .py_2()
        .text_xs()
        .text_color(if primary && enabled {
            theme.background
        } else if enabled {
            theme.text
        } else {
            theme.muted_text
        })
        .when(enabled, gpui::Styled::cursor_pointer)
        .child(label)
}

fn status_color(tone: GoalStatusTone, theme: CodexTheme) -> gpui::Rgba {
    match tone {
        GoalStatusTone::Neutral => theme.muted_text,
        GoalStatusTone::Positive => theme.success,
        GoalStatusTone::Warning => theme.warning,
        GoalStatusTone::Negative => theme.danger,
    }
}

fn parse_token_budget(value: &str) -> Result<Option<i64>, ()> {
    let value = value.trim();
    if value.is_empty() {
        return Ok(None);
    }
    value
        .parse::<i64>()
        .ok()
        .filter(|budget| *budget > 0)
        .map(Some)
        .ok_or(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_budget_accepts_blank_or_positive_integer_only() {
        assert_eq!(parse_token_budget(""), Ok(None));
        assert_eq!(parse_token_budget(" 4096 "), Ok(Some(4_096)));
        assert_eq!(parse_token_budget("0"), Err(()));
        assert_eq!(parse_token_budget("-1"), Err(()));
        assert_eq!(parse_token_budget("4.5"), Err(()));
    }

    #[test]
    fn set_event_contains_only_host_facing_values() {
        assert_eq!(
            GoalEvent::Set {
                objective: "Ship parity".to_owned(),
                token_budget: Some(4_096),
            },
            GoalEvent::Set {
                objective: "Ship parity".to_owned(),
                token_budget: Some(4_096),
            }
        );
    }
}
