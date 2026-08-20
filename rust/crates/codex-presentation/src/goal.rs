//! Framework-neutral thread-goal presentation.

use codex_app_server_state::{CanonicalThreadGoal, ThreadGoalStatus};

/// Visual emphasis for a goal status without exposing protocol lifecycle types.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum GoalStatusTone {
    Neutral,
    Positive,
    Warning,
    Negative,
}

/// Lifecycle control the native surface may offer for the current goal.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum GoalLifecycleAction {
    Pause,
    Resume,
}

/// Disposable projection of one authoritative thread goal.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GoalPresentation {
    pub objective: String,
    pub status_label: String,
    pub status_tone: GoalStatusTone,
    pub lifecycle_action: Option<GoalLifecycleAction>,
    pub token_budget: Option<i64>,
    pub tokens_used: i64,
    pub time_used_seconds: i64,
    pub token_usage_label: String,
    pub time_usage_label: String,
}

/// Project an optional canonical goal for a controlled native component.
#[must_use]
pub fn project_goal(goal: Option<&CanonicalThreadGoal>) -> Option<GoalPresentation> {
    goal.map(|goal| {
        let (status_label, status_tone, lifecycle_action) = project_status(&goal.status);
        GoalPresentation {
            objective: goal.objective.clone(),
            status_label,
            status_tone,
            lifecycle_action,
            token_budget: goal.token_budget,
            tokens_used: goal.tokens_used,
            time_used_seconds: goal.time_used_seconds,
            token_usage_label: format_token_usage(goal.tokens_used, goal.token_budget),
            time_usage_label: format_time_usage(goal.time_used_seconds),
        }
    })
}

fn project_status(
    status: &ThreadGoalStatus,
) -> (String, GoalStatusTone, Option<GoalLifecycleAction>) {
    match status {
        ThreadGoalStatus::Active => (
            "Active".to_owned(),
            GoalStatusTone::Positive,
            Some(GoalLifecycleAction::Pause),
        ),
        ThreadGoalStatus::Paused => (
            "Paused".to_owned(),
            GoalStatusTone::Neutral,
            Some(GoalLifecycleAction::Resume),
        ),
        ThreadGoalStatus::Blocked => (
            "Blocked".to_owned(),
            GoalStatusTone::Warning,
            Some(GoalLifecycleAction::Resume),
        ),
        ThreadGoalStatus::UsageLimited => (
            "Usage limited".to_owned(),
            GoalStatusTone::Negative,
            Some(GoalLifecycleAction::Resume),
        ),
        ThreadGoalStatus::BudgetLimited => (
            "Budget limited".to_owned(),
            GoalStatusTone::Negative,
            Some(GoalLifecycleAction::Resume),
        ),
        ThreadGoalStatus::Complete => ("Complete".to_owned(), GoalStatusTone::Positive, None),
        ThreadGoalStatus::Unknown(value) => {
            (format!("Unknown ({value})"), GoalStatusTone::Neutral, None)
        }
    }
}

fn format_token_usage(tokens_used: i64, token_budget: Option<i64>) -> String {
    let used = format_count(tokens_used.max(0));
    token_budget.filter(|budget| *budget > 0).map_or_else(
        || format!("{used} tokens used"),
        |budget| format!("{used} / {} tokens", format_count(budget)),
    )
}

fn format_time_usage(seconds: i64) -> String {
    let seconds = seconds.max(0);
    let hours = seconds / 3_600;
    let minutes = (seconds % 3_600) / 60;
    let seconds = seconds % 60;
    if hours > 0 {
        format!("{hours}h {minutes}m elapsed")
    } else if minutes > 0 {
        format!("{minutes}m {seconds}s elapsed")
    } else {
        format!("{seconds}s elapsed")
    }
}

fn format_count(value: i64) -> String {
    let digits = value.to_string();
    let mut formatted = String::with_capacity(digits.len() + digits.len() / 3);
    for (index, character) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index).is_multiple_of(3) {
            formatted.push(',');
        }
        formatted.push(character);
    }
    formatted
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use codex_app_server_state::ThreadId;

    use super::*;

    fn goal(status: ThreadGoalStatus) -> CanonicalThreadGoal {
        CanonicalThreadGoal {
            thread_id: ThreadId::from("thread"),
            objective: "Ship native parity".to_owned(),
            status,
            token_budget: Some(12_000),
            tokens_used: 1_234,
            time_used_seconds: 3_661,
            created_at: 1,
            updated_at: 2,
            extensions: BTreeMap::new(),
        }
    }

    #[test]
    fn active_goal_projects_usage_and_pause_affordance() {
        let projected = project_goal(Some(&goal(ThreadGoalStatus::Active))).expect("goal");
        assert_eq!(projected.status_label, "Active");
        assert_eq!(projected.status_tone, GoalStatusTone::Positive);
        assert_eq!(projected.lifecycle_action, Some(GoalLifecycleAction::Pause));
        assert_eq!(projected.token_usage_label, "1,234 / 12,000 tokens");
        assert_eq!(projected.time_usage_label, "1h 1m elapsed");
    }

    #[test]
    fn limited_and_unknown_statuses_use_safe_controls() {
        let limited =
            project_goal(Some(&goal(ThreadGoalStatus::BudgetLimited))).expect("limited goal");
        assert_eq!(limited.lifecycle_action, Some(GoalLifecycleAction::Resume));
        assert_eq!(limited.status_tone, GoalStatusTone::Negative);

        let unknown = project_goal(Some(&goal(ThreadGoalStatus::Unknown(
            "futureStatus".to_owned(),
        ))))
        .expect("unknown goal");
        assert_eq!(unknown.status_label, "Unknown (futureStatus)");
        assert_eq!(unknown.lifecycle_action, None);
    }

    #[test]
    fn missing_goal_and_unbounded_usage_remain_explicit() {
        assert_eq!(project_goal(None), None);
        let mut value = goal(ThreadGoalStatus::Paused);
        value.token_budget = None;
        value.tokens_used = -1;
        value.time_used_seconds = 65;
        let projected = project_goal(Some(&value)).expect("goal");
        assert_eq!(projected.token_usage_label, "0 tokens used");
        assert_eq!(projected.time_usage_label, "1m 5s elapsed");
    }
}
