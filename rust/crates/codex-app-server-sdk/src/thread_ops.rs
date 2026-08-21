use std::{collections::BTreeMap, num::NonZeroU32, path::PathBuf};

use codex_app_server_client::AppServerClient;
use codex_app_server_lease::LeaseReason;
use codex_app_server_state::{ThreadId, TurnId};
use serde_json::{Value, json};

use crate::{CodexThread, SdkError};

/// History boundary for a fork.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ForkPoint {
    /// Exclude this turn and every later turn.
    Before(TurnId),
    /// Include this turn and exclude every later turn.
    Through(TurnId),
}

/// Stable SDK options for `thread/fork`.
///
/// Known fields are projected explicitly while `extra` preserves access to
/// additional fields supported by the pinned protocol schema.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ForkThreadOptions {
    pub point: Option<ForkPoint>,
    pub cwd: Option<PathBuf>,
    pub model: Option<String>,
    pub model_provider: Option<String>,
    pub permissions: Option<String>,
    pub service_tier: Option<String>,
    pub base_instructions: Option<String>,
    pub developer_instructions: Option<String>,
    pub ephemeral: Option<bool>,
    pub exclude_turns: Option<bool>,
    pub defer_goal_continuation: Option<bool>,
    pub runtime_workspace_roots: Option<Vec<PathBuf>>,
    pub approval_policy: Option<Value>,
    pub approvals_reviewer: Option<Value>,
    pub sandbox: Option<Value>,
    pub thread_source: Option<Value>,
    pub config: Option<Value>,
    pub extra: BTreeMap<String, Value>,
}

/// Generated-schema-validated thread result with the original response kept
/// losslessly in `raw`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ThreadLifecycleResult {
    pub thread_id: ThreadId,
    pub thread: Value,
    pub turns_backwards_cursor: Option<String>,
    pub items_backwards_cursor: Option<String>,
    pub raw: Value,
}

/// A retained fork plus its complete validated App Server result.
pub struct ForkThreadResult {
    pub thread: CodexThread,
    pub response: ThreadLifecycleResult,
}

pub(crate) async fn rename(
    client: &AppServerClient,
    thread_id: &ThreadId,
    name: &str,
) -> Result<(), SdkError> {
    let params = json!({"threadId": thread_id.as_str(), "name": name});
    validate_request(
        "thread/name/set",
        &params,
        codex_app_server_types::validate_thread_set_name_params,
    )?;
    let response = client.request("thread/name/set", params).await?;
    validate_response(
        "thread/name/set",
        &response.value,
        codex_app_server_types::validate_thread_set_name_response,
    )
}

pub(crate) async fn archive(
    client: &AppServerClient,
    thread_id: &ThreadId,
) -> Result<(), SdkError> {
    let params = json!({"threadId": thread_id.as_str()});
    validate_request(
        "thread/archive",
        &params,
        codex_app_server_types::validate_thread_archive_params,
    )?;
    let response = client.request("thread/archive", params).await?;
    validate_response(
        "thread/archive",
        &response.value,
        codex_app_server_types::validate_thread_archive_response,
    )
}

pub(crate) async fn unarchive(
    client: &AppServerClient,
    thread_id: &ThreadId,
) -> Result<ThreadLifecycleResult, SdkError> {
    let params = json!({"threadId": thread_id.as_str()});
    validate_request(
        "thread/unarchive",
        &params,
        codex_app_server_types::validate_thread_unarchive_params,
    )?;
    let response = client.request("thread/unarchive", params).await?;
    parse_thread_result(
        "thread/unarchive",
        response.value,
        codex_app_server_types::validate_thread_unarchive_response,
        Some(thread_id),
    )
}

pub(crate) async fn fork(
    client: &AppServerClient,
    thread_id: &ThreadId,
    options: ForkThreadOptions,
) -> Result<ForkThreadResult, SdkError> {
    let params = fork_params(thread_id, options);
    validate_request(
        "thread/fork",
        &params,
        codex_app_server_types::validate_thread_fork_params,
    )?;
    let response = client.request("thread/fork", params).await?;
    let response = parse_thread_result(
        "thread/fork",
        response.value,
        codex_app_server_types::validate_thread_fork_response,
        None,
    )?;
    let lease = client
        .adopt_thread(response.thread_id.clone(), LeaseReason::Selected)
        .await?;
    Ok(ForkThreadResult {
        thread: CodexThread {
            client: client.clone(),
            id: response.thread_id.clone(),
            lease: Some(lease),
        },
        response,
    })
}

pub(crate) async fn revert(
    client: &AppServerClient,
    thread_id: &ThreadId,
    before_turn_id: &TurnId,
) -> Result<ThreadLifecycleResult, SdkError> {
    let params = json!({
        "threadId": thread_id.as_str(),
        "beforeTurnId": before_turn_id.as_str(),
    });
    validate_request(
        "thread/revert",
        &params,
        codex_app_server_types::validate_thread_revert_params,
    )?;
    let response = client.request("thread/revert", params).await?;
    parse_thread_result(
        "thread/revert",
        response.value,
        codex_app_server_types::validate_thread_revert_response,
        Some(thread_id),
    )
}

pub(crate) async fn rollback(
    client: &AppServerClient,
    thread_id: &ThreadId,
    num_turns: NonZeroU32,
) -> Result<ThreadLifecycleResult, SdkError> {
    let params = json!({
        "threadId": thread_id.as_str(),
        "numTurns": num_turns.get(),
    });
    validate_request(
        "thread/rollback",
        &params,
        codex_app_server_types::validate_thread_rollback_params,
    )?;
    let response = client.request("thread/rollback", params).await?;
    parse_thread_result(
        "thread/rollback",
        response.value,
        codex_app_server_types::validate_thread_rollback_response,
        Some(thread_id),
    )
}

fn fork_params(thread_id: &ThreadId, options: ForkThreadOptions) -> Value {
    let mut params = options.extra;
    params.insert("threadId".to_owned(), Value::String(thread_id.to_string()));
    if let Some(point) = options.point {
        params.remove("beforeTurnId");
        params.remove("lastTurnId");
        match point {
            ForkPoint::Before(turn_id) => {
                params.insert(
                    "beforeTurnId".to_owned(),
                    Value::String(turn_id.to_string()),
                );
            }
            ForkPoint::Through(turn_id) => {
                params.insert("lastTurnId".to_owned(), Value::String(turn_id.to_string()));
            }
        }
    }
    insert_option(
        &mut params,
        "cwd",
        options
            .cwd
            .map(|path| Value::String(path.to_string_lossy().into_owned())),
    );
    insert_option(&mut params, "model", options.model.map(Value::String));
    insert_option(
        &mut params,
        "modelProvider",
        options.model_provider.map(Value::String),
    );
    insert_option(
        &mut params,
        "permissions",
        options.permissions.map(Value::String),
    );
    insert_option(
        &mut params,
        "serviceTier",
        options.service_tier.map(Value::String),
    );
    insert_option(
        &mut params,
        "baseInstructions",
        options.base_instructions.map(Value::String),
    );
    insert_option(
        &mut params,
        "developerInstructions",
        options.developer_instructions.map(Value::String),
    );
    insert_option(&mut params, "ephemeral", options.ephemeral.map(Value::Bool));
    insert_option(
        &mut params,
        "excludeTurns",
        options.exclude_turns.map(Value::Bool),
    );
    insert_option(
        &mut params,
        "deferGoalContinuation",
        options.defer_goal_continuation.map(Value::Bool),
    );
    insert_option(
        &mut params,
        "runtimeWorkspaceRoots",
        options.runtime_workspace_roots.map(|paths| {
            Value::Array(
                paths
                    .into_iter()
                    .map(|path| Value::String(path.to_string_lossy().into_owned()))
                    .collect(),
            )
        }),
    );
    insert_option(&mut params, "approvalPolicy", options.approval_policy);
    insert_option(&mut params, "approvalsReviewer", options.approvals_reviewer);
    insert_option(&mut params, "sandbox", options.sandbox);
    insert_option(&mut params, "threadSource", options.thread_source);
    insert_option(&mut params, "config", options.config);
    Value::Object(params.into_iter().collect())
}

fn insert_option(params: &mut BTreeMap<String, Value>, key: &str, value: Option<Value>) {
    if let Some(value) = value {
        params.insert(key.to_owned(), value);
    }
}

fn parse_thread_result(
    method: &'static str,
    raw: Value,
    validator: fn(&Value) -> Result<(), serde_json::Error>,
    expected_thread_id: Option<&ThreadId>,
) -> Result<ThreadLifecycleResult, SdkError> {
    validate_response(method, &raw, validator)?;
    let thread = raw
        .get("thread")
        .cloned()
        .ok_or(SdkError::MissingResponseField {
            method,
            field: "thread",
        })?;
    let thread_id = thread
        .get("id")
        .and_then(Value::as_str)
        .map(ThreadId::new)
        .ok_or(SdkError::MissingResponseField {
            method,
            field: "thread.id",
        })?;
    if let Some(expected) = expected_thread_id
        && expected != &thread_id
    {
        return Err(SdkError::ResponseValidation {
            method,
            message: format!(
                "response thread id {:?} does not match requested thread id {:?}",
                thread_id.as_str(),
                expected.as_str()
            ),
        });
    }
    let turns_backwards_cursor = optional_string(&raw, "turnsBackwardsCursor");
    let items_backwards_cursor = optional_string(&raw, "itemsBackwardsCursor");
    Ok(ThreadLifecycleResult {
        thread_id,
        thread,
        turns_backwards_cursor,
        items_backwards_cursor,
        raw,
    })
}

fn optional_string(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn validate_request(
    method: &'static str,
    value: &Value,
    validator: fn(&Value) -> Result<(), serde_json::Error>,
) -> Result<(), SdkError> {
    validator(value).map_err(|error| SdkError::RequestValidation {
        method,
        message: error.to_string(),
    })
}

fn validate_response(
    method: &'static str,
    value: &Value,
    validator: fn(&Value) -> Result<(), serde_json::Error>,
) -> Result<(), SdkError> {
    validator(value).map_err(|error| SdkError::ResponseValidation {
        method,
        message: error.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn fork_params_encode_one_history_boundary_and_validate() {
        let params = fork_params(
            &ThreadId::from("source"),
            ForkThreadOptions {
                point: Some(ForkPoint::Before(TurnId::from("turn-2"))),
                cwd: Some(PathBuf::from("/workspace")),
                permissions: Some(":workspace".to_owned()),
                runtime_workspace_roots: Some(vec![PathBuf::from("/workspace")]),
                approval_policy: Some(json!("never")),
                ..ForkThreadOptions::default()
            },
        );

        assert_eq!(params["threadId"], "source");
        assert_eq!(params["beforeTurnId"], "turn-2");
        assert!(params.get("lastTurnId").is_none());
        assert_eq!(params["runtimeWorkspaceRoots"], json!(["/workspace"]));
        codex_app_server_types::validate_thread_fork_params(&params).expect("pinned fork request");
    }

    #[test]
    fn malformed_known_fork_field_fails_generated_validation() {
        let mut extra = BTreeMap::new();
        extra.insert("ephemeral".to_owned(), json!("yes"));
        let params = fork_params(
            &ThreadId::from("source"),
            ForkThreadOptions {
                extra,
                ..ForkThreadOptions::default()
            },
        );

        assert!(codex_app_server_types::validate_thread_fork_params(&params).is_err());
    }

    #[test]
    fn lifecycle_result_is_validated_projected_and_lossless() {
        let value = json!({
            "thread": thread("thread"),
            "turnsBackwardsCursor": "turn-cursor",
            "itemsBackwardsCursor": "item-cursor",
            "futureResponseField": {"kept": true}
        });
        let result = parse_thread_result(
            "thread/revert",
            value.clone(),
            codex_app_server_types::validate_thread_revert_response,
            Some(&ThreadId::from("thread")),
        )
        .expect("valid revert result");

        assert_eq!(result.thread_id, ThreadId::from("thread"));
        assert_eq!(
            result.turns_backwards_cursor.as_deref(),
            Some("turn-cursor")
        );
        assert_eq!(
            result.items_backwards_cursor.as_deref(),
            Some("item-cursor")
        );
        assert_eq!(result.raw, value);
    }

    #[test]
    fn lifecycle_result_rejects_malformed_or_mismatched_thread() {
        let malformed = json!({});
        assert!(
            parse_thread_result(
                "thread/unarchive",
                malformed,
                codex_app_server_types::validate_thread_unarchive_response,
                None,
            )
            .is_err()
        );

        let mismatched = json!({"thread": thread("other")});
        let error = parse_thread_result(
            "thread/unarchive",
            mismatched,
            codex_app_server_types::validate_thread_unarchive_response,
            Some(&ThreadId::from("requested")),
        )
        .expect_err("identity mismatch");
        assert!(matches!(error, SdkError::ResponseValidation { .. }));
    }

    fn thread(id: &str) -> Value {
        json!({
            "cliVersion": "0.148.0",
            "createdAt": 10,
            "cwd": "/workspace",
            "ephemeral": false,
            "id": id,
            "modelProvider": "openai",
            "preview": "Build it",
            "sessionId": "session",
            "source": "appServer",
            "status": {"type": "idle"},
            "turns": [],
            "updatedAt": 12,
            "futureThreadField": true
        })
    }
}
