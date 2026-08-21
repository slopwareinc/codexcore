use std::collections::BTreeMap;

use codex_app_server_adapter::adapt_thread_goal;
use codex_app_server_client::AppServerClient;
use codex_app_server_state::{CanonicalThreadGoal, ThreadGoalStatus, ThreadId};
use serde_json::{Value, json};

use crate::{SdkError, validate_response};

/// Partial values accepted by `thread/goal/set`.
///
/// Omitted values preserve the server's current value. Clear the complete goal
/// with [`crate::CodexThread::clear_goal`].
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct SetGoalOptions {
    /// New objective, or `None` to preserve it.
    pub objective: Option<String>,
    /// New lifecycle status, or `None` to preserve it.
    pub status: Option<ThreadGoalStatus>,
    /// New token limit, or `None` to preserve it.
    pub token_budget: Option<i64>,
}

pub(crate) async fn set(
    client: &AppServerClient,
    thread_id: &ThreadId,
    options: SetGoalOptions,
) -> Result<CanonicalThreadGoal, SdkError> {
    let response = client
        .request(
            "thread/goal/set",
            Value::Object(set_params(thread_id, options).into_iter().collect()),
        )
        .await?;
    validate_response(
        "thread/goal/set",
        &response.value,
        codex_app_server_types::validate_thread_goal_set_response,
    )?;
    let goal = response
        .value
        .get("goal")
        .ok_or(SdkError::MissingResponseField {
            method: "thread/goal/set",
            field: "goal",
        })?;
    project("thread/goal/set", thread_id, goal)
}

pub(crate) async fn get(
    client: &AppServerClient,
    thread_id: &ThreadId,
) -> Result<Option<CanonicalThreadGoal>, SdkError> {
    let response = client
        .request("thread/goal/get", json!({"threadId": thread_id.as_str()}))
        .await?;
    validate_response(
        "thread/goal/get",
        &response.value,
        codex_app_server_types::validate_thread_goal_get_response,
    )?;
    match response.value.get("goal") {
        None | Some(Value::Null) => Ok(None),
        Some(goal) => project("thread/goal/get", thread_id, goal).map(Some),
    }
}

pub(crate) async fn clear(
    client: &AppServerClient,
    thread_id: &ThreadId,
) -> Result<bool, SdkError> {
    let response = client
        .request("thread/goal/clear", json!({"threadId": thread_id.as_str()}))
        .await?;
    validate_response(
        "thread/goal/clear",
        &response.value,
        codex_app_server_types::validate_thread_goal_clear_response,
    )?;
    response
        .value
        .get("cleared")
        .and_then(Value::as_bool)
        .ok_or(SdkError::MissingResponseField {
            method: "thread/goal/clear",
            field: "cleared",
        })
}

fn set_params(thread_id: &ThreadId, options: SetGoalOptions) -> BTreeMap<String, Value> {
    let mut params =
        BTreeMap::from([("threadId".to_owned(), Value::String(thread_id.to_string()))]);
    if let Some(objective) = options.objective {
        params.insert("objective".to_owned(), Value::String(objective));
    }
    if let Some(status) = options.status {
        params.insert(
            "status".to_owned(),
            Value::String(status.as_raw().to_owned()),
        );
    }
    if let Some(token_budget) = options.token_budget {
        params.insert("tokenBudget".to_owned(), Value::Number(token_budget.into()));
    }
    params
}

fn project(
    method: &'static str,
    thread_id: &ThreadId,
    value: &Value,
) -> Result<CanonicalThreadGoal, SdkError> {
    let goal = adapt_thread_goal(value).map_err(|error| SdkError::ResponseValidation {
        method,
        message: error.to_string(),
    })?;
    if &goal.thread_id != thread_id {
        return Err(SdkError::ResponseValidation {
            method,
            message: "goal.threadId does not match the requested thread".to_owned(),
        });
    }
    Ok(goal)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_params_omit_unspecified_values_and_keep_exact_status() {
        let params = set_params(
            &ThreadId::from("thread"),
            SetGoalOptions {
                objective: Some("Ship parity".to_owned()),
                status: Some(ThreadGoalStatus::Unknown("futureStatus".to_owned())),
                token_budget: None,
            },
        );
        assert_eq!(params["threadId"], json!("thread"));
        assert_eq!(params["objective"], json!("Ship parity"));
        assert_eq!(params["status"], json!("futureStatus"));
        assert!(!params.contains_key("tokenBudget"));
    }

    #[test]
    fn stable_projection_retains_unknown_goal_fields() {
        let goal = project(
            "thread/goal/get",
            &ThreadId::from("thread"),
            &json!({
                "threadId": "thread",
                "objective": "Ship parity",
                "status": "futureStatus",
                "tokenBudget": null,
                "tokensUsed": 4,
                "timeUsedSeconds": 5,
                "createdAt": 6,
                "updatedAt": 7,
                "futureGoalField": true
            }),
        )
        .expect("stable goal");
        assert_eq!(
            goal.status,
            ThreadGoalStatus::Unknown("futureStatus".to_owned())
        );
        assert_eq!(goal.extensions["futureGoalField"], Value::Bool(true));
    }
}
