use codex_app_server_sdk::{CodexThread, SetGoalOptions};
use codex_app_server_state::ThreadGoalStatus;
use codex_gpui::GoalEvent;

#[derive(Clone, Debug, Eq, PartialEq)]
enum GoalOperation {
    Set(SetGoalOptions),
    Clear,
}

#[must_use]
fn operation_for_event(event: GoalEvent) -> GoalOperation {
    match event {
        GoalEvent::Set {
            objective,
            token_budget,
        } => GoalOperation::Set(SetGoalOptions {
            objective: Some(objective),
            status: None,
            token_budget,
        }),
        GoalEvent::Pause => GoalOperation::Set(SetGoalOptions {
            status: Some(ThreadGoalStatus::Paused),
            ..SetGoalOptions::default()
        }),
        GoalEvent::Resume => GoalOperation::Set(SetGoalOptions {
            status: Some(ThreadGoalStatus::Active),
            ..SetGoalOptions::default()
        }),
        GoalEvent::Clear => GoalOperation::Clear,
    }
}

pub(crate) async fn execute_goal_event(
    thread: &CodexThread,
    event: GoalEvent,
) -> Result<&'static str, String> {
    match operation_for_event(event) {
        GoalOperation::Set(options) => {
            let status = match options.status.as_ref() {
                Some(ThreadGoalStatus::Paused) => "Goal paused",
                Some(ThreadGoalStatus::Active) => "Goal resumed",
                _ => "Goal updated",
            };
            thread
                .set_goal(options)
                .await
                .map(|_| status)
                .map_err(|error| error.to_string())
        }
        GoalOperation::Clear => thread
            .clear_goal()
            .await
            .map(|cleared| {
                if cleared {
                    "Goal cleared"
                } else {
                    "Goal was already clear"
                }
            })
            .map_err(|error| error.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_semantic_events_to_partial_sdk_operations() {
        assert_eq!(
            operation_for_event(GoalEvent::Set {
                objective: "Ship parity".to_owned(),
                token_budget: Some(8_192),
            }),
            GoalOperation::Set(SetGoalOptions {
                objective: Some("Ship parity".to_owned()),
                status: None,
                token_budget: Some(8_192),
            })
        );
        assert_eq!(
            operation_for_event(GoalEvent::Pause),
            GoalOperation::Set(SetGoalOptions {
                status: Some(ThreadGoalStatus::Paused),
                ..SetGoalOptions::default()
            })
        );
        assert_eq!(
            operation_for_event(GoalEvent::Resume),
            GoalOperation::Set(SetGoalOptions {
                status: Some(ThreadGoalStatus::Active),
                ..SetGoalOptions::default()
            })
        );
        assert_eq!(operation_for_event(GoalEvent::Clear), GoalOperation::Clear);
    }
}
