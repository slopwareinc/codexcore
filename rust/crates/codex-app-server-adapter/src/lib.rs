//! Deterministic App Server protocol-to-canonical adaptation.
//!
//! Known methods validate against generated types before raw values are mapped
//! into SDK-owned canonical mutations. Unknown future methods remain nonfatal
//! and retain their exact payload for diagnostics.

use std::collections::{BTreeMap, BTreeSet};

use codex_app_server_state::{
    CanonicalItem, CanonicalMutation, CanonicalPlanStep, CanonicalThread, CanonicalThreadGoal,
    CanonicalTurn, ItemDelta, ItemId, ItemKey, ItemLiveOverlay, LifecycleStatus, PlanStepStatus,
    StateCoverage, ThreadGoalStatus, ThreadId, ThreadStatus, TurnId, TurnKey,
};
use serde_json::{Map, Value};
use thiserror::Error;

/// Result of adapting one notification from the pinned protocol.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum NotificationDisposition {
    /// Known notification reduced into typed canonical operations.
    Mutations(Vec<CanonicalMutation>),
    /// Future or intentionally unprojected method retained losslessly.
    Unhandled {
        /// Exact method name.
        method: String,
        /// Exact object parameters.
        params: BTreeMap<String, Value>,
    },
}

/// Result of adapting a correlated client response.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ResponseDisposition {
    /// A known response produced canonical operations.
    Mutations(Vec<CanonicalMutation>),
    /// The response has no canonical projection in this adapter version.
    Unhandled,
}

/// Whether a response method has canonical effects and therefore needs its
/// small request context retained until correlation completes.
#[must_use]
pub fn response_has_canonical_projection(method: &str) -> bool {
    matches!(
        method,
        "thread/goal/set" | "thread/goal/get" | "thread/goal/clear"
    )
}

/// Generated validation or required-field failure.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum AdapterError {
    /// Pinned generated schema rejected a known protocol payload.
    #[error("generated protocol validation failed: {0}")]
    GeneratedValidation(String),
    /// Required field is absent or has an incompatible JSON shape.
    #[error("protocol method {method} has invalid field {field}")]
    InvalidField {
        /// Protocol method.
        method: String,
        /// Dotted field name.
        field: &'static str,
    },
}

/// Adapt a notification using its exact method and object parameters.
///
/// # Errors
///
/// Returns [`AdapterError`] when a known method does not satisfy the generated
/// schema or lacks a canonical identity required by the state engine.
pub fn adapt_notification(
    method: &str,
    params: &BTreeMap<String, Value>,
) -> Result<NotificationDisposition, AdapterError> {
    let params_value = map_value(params);
    match method {
        "thread/started" => {
            validate(method, &params_value)?;
            let thread = object_field(method, params, "thread")?;
            let mut mutations = vec![CanonicalMutation::ThreadUpsert(map_thread(method, thread)?)];
            append_thread_turns(method, thread, &mut mutations)?;
            Ok(NotificationDisposition::Mutations(mutations))
        }
        "thread/status/changed" => {
            validate(method, &params_value)?;
            let thread_id = string_field(method, params, "threadId")?;
            let status = params
                .get("status")
                .ok_or_else(|| invalid(method, "status"))?;
            Ok(NotificationDisposition::Mutations(vec![
                CanonicalMutation::ThreadUpsert(CanonicalThread {
                    id: ThreadId::new(thread_id),
                    status: map_thread_status(status),
                    coverage: StateCoverage::Summary,
                    turn_ids: Vec::new(),
                    goal: None,
                    metadata: BTreeMap::new(),
                }),
            ]))
        }
        "thread/goal/updated" => {
            validate(method, &params_value)?;
            let thread_id = string_field(method, params, "threadId")?;
            let goal = map_goal(method, object_field(method, params, "goal")?)?;
            if goal.thread_id.as_str() != thread_id {
                return Err(invalid(method, "goal.threadId"));
            }
            Ok(NotificationDisposition::Mutations(vec![
                CanonicalMutation::ThreadGoalReplace {
                    thread_id: ThreadId::new(thread_id),
                    goal: Some(goal),
                },
            ]))
        }
        "thread/goal/cleared" => {
            validate(method, &params_value)?;
            Ok(NotificationDisposition::Mutations(vec![
                CanonicalMutation::ThreadGoalReplace {
                    thread_id: ThreadId::new(string_field(method, params, "threadId")?),
                    goal: None,
                },
            ]))
        }
        "turn/started" | "turn/completed" => {
            validate(method, &params_value)?;
            let thread_id = string_field(method, params, "threadId")?;
            let turn = object_field(method, params, "turn")?;
            Ok(NotificationDisposition::Mutations(map_turn_with_items(
                method, thread_id, turn,
            )?))
        }
        "turn/plan/updated" => adapt_plan(method, params, &params_value),
        "item/started" | "item/completed" => {
            validate(method, &params_value)?;
            let thread_id = string_field(method, params, "threadId")?;
            let turn_id = string_field(method, params, "turnId")?;
            let item = object_field(method, params, "item")?;
            let fallback = if method == "item/started" {
                LifecycleStatus::InProgress
            } else {
                LifecycleStatus::Completed
            };
            Ok(NotificationDisposition::Mutations(vec![
                CanonicalMutation::ItemUpsert(map_item(
                    method, thread_id, turn_id, item, fallback,
                )?),
            ]))
        }
        "item/agentMessage/delta"
        | "item/plan/delta"
        | "item/commandExecution/outputDelta"
        | "item/fileChange/outputDelta"
        | "item/fileChange/patchUpdated"
        | "item/mcpToolCall/progress"
        | "item/reasoning/summaryTextDelta"
        | "item/reasoning/summaryPartAdded"
        | "item/reasoning/textDelta" => adapt_live_item_notification(method, params, &params_value),
        _ => Ok(NotificationDisposition::Unhandled {
            method: method.to_owned(),
            params: params.clone(),
        }),
    }
}

fn adapt_live_item_notification(
    method: &str,
    params: &BTreeMap<String, Value>,
    params_value: &Value,
) -> Result<NotificationDisposition, AdapterError> {
    validate(method, params_value)?;
    match method {
        "item/agentMessage/delta" => item_delta(
            method,
            params,
            ItemDelta::AgentMessage(string_field(method, params, "delta")?.to_owned()),
        ),
        "item/plan/delta" => item_delta(
            method,
            params,
            ItemDelta::Plan(string_field(method, params, "delta")?.to_owned()),
        ),
        "item/commandExecution/outputDelta" => item_delta(
            method,
            params,
            ItemDelta::CommandOutput(string_field(method, params, "delta")?.to_owned()),
        ),
        "item/fileChange/outputDelta" => item_delta(
            method,
            params,
            ItemDelta::FileChangeOutput(string_field(method, params, "delta")?.to_owned()),
        ),
        "item/mcpToolCall/progress" => item_delta(
            method,
            params,
            ItemDelta::McpProgress(string_field(method, params, "message")?.to_owned()),
        ),
        "item/reasoning/summaryTextDelta" => item_delta(
            method,
            params,
            ItemDelta::ReasoningSummary {
                index: integer_field(method, params, "summaryIndex")?,
                text: string_field(method, params, "delta")?.to_owned(),
            },
        ),
        "item/reasoning/textDelta" => item_delta(
            method,
            params,
            ItemDelta::ReasoningContent {
                index: integer_field(method, params, "contentIndex")?,
                text: string_field(method, params, "delta")?.to_owned(),
            },
        ),
        "item/fileChange/patchUpdated" => live_field(
            method,
            params,
            "fileChanges".to_owned(),
            params
                .get("changes")
                .cloned()
                .ok_or_else(|| invalid(method, "changes"))?,
        ),
        "item/reasoning/summaryPartAdded" => live_field(
            method,
            params,
            format!(
                "reasoningSummaryPart:{}",
                integer_field(method, params, "summaryIndex")?
            ),
            Value::Bool(true),
        ),
        _ => unreachable!("caller selects only supported live item notifications"),
    }
}

/// Validate and adapt a correlated response before its awaiting caller resumes.
///
/// Only response families with canonical state effects are projected. Unknown
/// and read-only families return [`ResponseDisposition::Unhandled`].
///
/// # Errors
///
/// Returns [`AdapterError`] when a known response fails generated validation,
/// lacks its request identity, or contradicts the requested thread.
pub fn adapt_response(
    method: &str,
    request_params: &Value,
    result: &Value,
) -> Result<ResponseDisposition, AdapterError> {
    match method {
        "thread/goal/set" => {
            validate_response(
                result,
                codex_app_server_types::validate_thread_goal_set_response,
            )?;
            let thread_id = response_thread_id(method, request_params)?;
            let goal =
                adapt_thread_goal(result.get("goal").ok_or_else(|| invalid(method, "goal"))?)?;
            ensure_goal_owner(method, thread_id, &goal)?;
            Ok(ResponseDisposition::Mutations(vec![
                CanonicalMutation::ThreadGoalReplace {
                    thread_id: ThreadId::new(thread_id),
                    goal: Some(goal),
                },
            ]))
        }
        "thread/goal/get" => {
            validate_response(
                result,
                codex_app_server_types::validate_thread_goal_get_response,
            )?;
            let thread_id = response_thread_id(method, request_params)?;
            let goal = match result.get("goal") {
                None | Some(Value::Null) => None,
                Some(value) => {
                    let goal = adapt_thread_goal(value)?;
                    ensure_goal_owner(method, thread_id, &goal)?;
                    Some(goal)
                }
            };
            Ok(ResponseDisposition::Mutations(vec![
                CanonicalMutation::ThreadGoalReplace {
                    thread_id: ThreadId::new(thread_id),
                    goal,
                },
            ]))
        }
        "thread/goal/clear" => {
            validate_response(
                result,
                codex_app_server_types::validate_thread_goal_clear_response,
            )?;
            let thread_id = response_thread_id(method, request_params)?;
            let cleared = result
                .get("cleared")
                .and_then(Value::as_bool)
                .ok_or_else(|| invalid(method, "cleared"))?;
            Ok(ResponseDisposition::Mutations(if cleared {
                vec![CanonicalMutation::ThreadGoalReplace {
                    thread_id: ThreadId::new(thread_id),
                    goal: None,
                }]
            } else {
                Vec::new()
            }))
        }
        _ => Ok(ResponseDisposition::Unhandled),
    }
}

/// Map one already validated raw goal into the stable canonical shape.
///
/// # Errors
///
/// Returns [`AdapterError`] when a required canonical field is absent or has
/// the wrong JSON type.
pub fn adapt_thread_goal(value: &Value) -> Result<CanonicalThreadGoal, AdapterError> {
    let value = value
        .as_object()
        .ok_or_else(|| invalid("thread/goal", "goal"))?;
    map_goal("thread/goal", value)
}

fn validate_response(
    value: &Value,
    validator: fn(&Value) -> Result<(), serde_json::Error>,
) -> Result<(), AdapterError> {
    validator(value).map_err(|error| AdapterError::GeneratedValidation(error.to_string()))
}

fn response_thread_id<'a>(
    method: &str,
    request_params: &'a Value,
) -> Result<&'a str, AdapterError> {
    request_params
        .get("threadId")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(method, "request.threadId"))
}

fn ensure_goal_owner(
    method: &str,
    thread_id: &str,
    goal: &CanonicalThreadGoal,
) -> Result<(), AdapterError> {
    if goal.thread_id.as_str() == thread_id {
        Ok(())
    } else {
        Err(invalid(method, "goal.threadId"))
    }
}

fn adapt_plan(
    method: &str,
    params: &BTreeMap<String, Value>,
    params_value: &Value,
) -> Result<NotificationDisposition, AdapterError> {
    validate(method, params_value)?;
    let plan = params
        .get("plan")
        .and_then(Value::as_array)
        .ok_or_else(|| invalid(method, "plan"))?
        .iter()
        .map(|step| {
            let step = step.as_object().ok_or_else(|| invalid(method, "plan[]"))?;
            Ok(CanonicalPlanStep {
                step: step
                    .get("step")
                    .and_then(Value::as_str)
                    .ok_or_else(|| invalid(method, "plan[].step"))?
                    .to_owned(),
                status: PlanStepStatus::from_raw(
                    step.get("status")
                        .and_then(Value::as_str)
                        .ok_or_else(|| invalid(method, "plan[].status"))?,
                ),
            })
        })
        .collect::<Result<Vec<_>, AdapterError>>()?;
    Ok(NotificationDisposition::Mutations(vec![
        CanonicalMutation::TurnPlanReplace {
            key: TurnKey {
                thread_id: ThreadId::new(string_field(method, params, "threadId")?),
                turn_id: TurnId::new(string_field(method, params, "turnId")?),
            },
            steps: plan,
            explanation: params
                .get("explanation")
                .and_then(Value::as_str)
                .map(str::to_owned),
        },
    ]))
}

/// Validate and map a standalone thread response into canonical mutations.
///
/// # Errors
///
/// Returns [`AdapterError`] when generated validation or identity mapping fails.
pub fn adapt_thread_snapshot(value: &Value) -> Result<Vec<CanonicalMutation>, AdapterError> {
    codex_app_server_types::validate_thread(value)
        .map_err(|error| AdapterError::GeneratedValidation(error.to_string()))?;
    let object = value
        .as_object()
        .ok_or_else(|| invalid("thread", "thread"))?;
    let mut mutations = vec![CanonicalMutation::ThreadUpsert(map_thread(
        "thread", object,
    )?)];
    append_thread_turns("thread", object, &mut mutations)?;
    Ok(mutations)
}

/// Validate and map one standalone turn page record.
///
/// # Errors
///
/// Returns [`AdapterError`] when generated validation or identity mapping fails.
pub fn adapt_turn_snapshot(
    thread_id: &ThreadId,
    value: &Value,
) -> Result<Vec<CanonicalMutation>, AdapterError> {
    codex_app_server_types::validate_turn(value)
        .map_err(|error| AdapterError::GeneratedValidation(error.to_string()))?;
    let object = value.as_object().ok_or_else(|| invalid("turn", "turn"))?;
    map_turn_with_items("turn", thread_id.as_str(), object)
}

/// Validate and map one `thread/items/list` entry.
///
/// # Errors
///
/// Returns [`AdapterError`] when generated validation or identity mapping fails.
pub fn adapt_item_entry(
    thread_id: &ThreadId,
    value: &Value,
) -> Result<CanonicalMutation, AdapterError> {
    codex_app_server_types::validate_thread_item_entry(value)
        .map_err(|error| AdapterError::GeneratedValidation(error.to_string()))?;
    let object = value.as_object().ok_or_else(|| invalid("item", "entry"))?;
    let turn_id = object
        .get("turnId")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("item", "turnId"))?;
    let item = object
        .get("item")
        .and_then(Value::as_object)
        .ok_or_else(|| invalid("item", "item"))?;
    Ok(CanonicalMutation::ItemUpsert(map_item(
        "item",
        thread_id.as_str(),
        turn_id,
        item,
        LifecycleStatus::Completed,
    )?))
}

fn validate(method: &str, params: &Value) -> Result<(), AdapterError> {
    codex_app_server_types::validate_server_notification(method, params)
        .map_err(|error| AdapterError::GeneratedValidation(error.to_string()))
}

fn append_thread_turns(
    method: &str,
    thread: &Map<String, Value>,
    mutations: &mut Vec<CanonicalMutation>,
) -> Result<(), AdapterError> {
    let Some(turns) = thread.get("turns") else {
        return Ok(());
    };
    let turns = turns
        .as_array()
        .ok_or_else(|| invalid(method, "thread.turns"))?;
    let thread_id = thread
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(method, "thread.id"))?;
    for turn in turns {
        let turn = turn
            .as_object()
            .ok_or_else(|| invalid(method, "thread.turns[]"))?;
        mutations.extend(map_turn_with_items(method, thread_id, turn)?);
    }
    Ok(())
}

fn map_thread(method: &str, value: &Map<String, Value>) -> Result<CanonicalThread, AdapterError> {
    let id = value
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(method, "thread.id"))?;
    let status = value
        .get("status")
        .map_or(ThreadStatus::NotLoaded, map_thread_status);
    let turn_ids = value
        .get("turns")
        .and_then(Value::as_array)
        .map(|turns| {
            turns
                .iter()
                .filter_map(|turn| turn.get("id").and_then(Value::as_str))
                .map(TurnId::new)
                .collect()
        })
        .unwrap_or_default();
    Ok(CanonicalThread {
        id: ThreadId::new(id),
        status,
        coverage: StateCoverage::Full,
        turn_ids,
        goal: None,
        metadata: metadata_without(value, &["id", "status", "turns"]),
    })
}

fn map_goal(method: &str, value: &Map<String, Value>) -> Result<CanonicalThreadGoal, AdapterError> {
    let required_string = |field: &'static str| {
        value
            .get(field)
            .and_then(Value::as_str)
            .ok_or_else(|| invalid(method, field))
    };
    let required_integer = |field: &'static str| {
        value
            .get(field)
            .and_then(Value::as_i64)
            .ok_or_else(|| invalid(method, field))
    };
    let token_budget = match value.get("tokenBudget") {
        None | Some(Value::Null) => None,
        Some(value) => Some(
            value
                .as_i64()
                .ok_or_else(|| invalid(method, "tokenBudget"))?,
        ),
    };
    Ok(CanonicalThreadGoal {
        thread_id: ThreadId::new(required_string("threadId")?),
        objective: required_string("objective")?.to_owned(),
        status: ThreadGoalStatus::from_raw(required_string("status")?),
        token_budget,
        tokens_used: required_integer("tokensUsed")?,
        time_used_seconds: required_integer("timeUsedSeconds")?,
        created_at: required_integer("createdAt")?,
        updated_at: required_integer("updatedAt")?,
        extensions: metadata_without(
            value,
            &[
                "threadId",
                "objective",
                "status",
                "tokenBudget",
                "tokensUsed",
                "timeUsedSeconds",
                "createdAt",
                "updatedAt",
            ],
        ),
    })
}

fn map_thread_status(value: &Value) -> ThreadStatus {
    let Some(object) = value.as_object() else {
        return ThreadStatus::Unknown(value.clone());
    };
    match object.get("type").and_then(Value::as_str) {
        Some("notLoaded") => ThreadStatus::NotLoaded,
        Some("idle") => ThreadStatus::Idle,
        Some("active") => ThreadStatus::Active {
            flags: object
                .get("activeFlags")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect::<BTreeSet<_>>(),
        },
        Some("systemError") => ThreadStatus::SystemError(value.clone()),
        _ => ThreadStatus::Unknown(value.clone()),
    }
}

fn map_turn_with_items(
    method: &str,
    thread_id: &str,
    value: &Map<String, Value>,
) -> Result<Vec<CanonicalMutation>, AdapterError> {
    let id = value
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(method, "turn.id"))?;
    let key = TurnKey {
        thread_id: ThreadId::new(thread_id),
        turn_id: TurnId::new(id),
    };
    let items = value
        .get("items")
        .and_then(Value::as_array)
        .ok_or_else(|| invalid(method, "turn.items"))?;
    let status = value.get("status").and_then(Value::as_str).map_or_else(
        || LifecycleStatus::Unknown("unknown".to_owned()),
        LifecycleStatus::from_raw,
    );
    let coverage = match value.get("itemsView").and_then(Value::as_str) {
        Some("full") => StateCoverage::Full,
        Some("summary") => StateCoverage::Summary,
        _ => StateCoverage::NotLoaded,
    };
    let mut mutations = vec![CanonicalMutation::TurnUpsert(CanonicalTurn {
        key: key.clone(),
        status: status.clone(),
        coverage,
        item_ids: items
            .iter()
            .filter_map(|item| item.get("id").and_then(Value::as_str))
            .map(ItemId::new)
            .collect(),
        plan: None,
        plan_explanation: None,
        metadata: metadata_without(value, &["id", "status", "items", "itemsView"]),
    })];
    for item in items {
        let item = item
            .as_object()
            .ok_or_else(|| invalid(method, "turn.items[]"))?;
        mutations.push(CanonicalMutation::ItemUpsert(map_item(
            method,
            thread_id,
            id,
            item,
            status.clone(),
        )?));
    }
    Ok(mutations)
}

fn map_item(
    method: &str,
    thread_id: &str,
    turn_id: &str,
    value: &Map<String, Value>,
    fallback_status: LifecycleStatus,
) -> Result<CanonicalItem, AdapterError> {
    let id = value
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(method, "item.id"))?;
    let kind = value
        .get("type")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(method, "item.type"))?;
    let status = value
        .get("status")
        .and_then(Value::as_str)
        .map_or(fallback_status, LifecycleStatus::from_raw);
    Ok(CanonicalItem {
        key: ItemKey {
            thread_id: ThreadId::new(thread_id),
            turn_id: TurnId::new(turn_id),
            item_id: ItemId::new(id),
        },
        kind: kind.to_owned(),
        status,
        coverage: StateCoverage::Full,
        payload: value
            .iter()
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect(),
        duration_ms: value.get("durationMs").and_then(Value::as_i64),
        error: value.get("error").filter(|value| !value.is_null()).cloned(),
        live_overlay: ItemLiveOverlay::default(),
        live_fields: BTreeMap::new(),
        content_revision: 0,
    })
}

fn metadata_without(value: &Map<String, Value>, excluded: &[&str]) -> BTreeMap<String, Value> {
    value
        .iter()
        .filter(|(key, _)| !excluded.contains(&key.as_str()))
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect()
}

fn item_delta(
    method: &str,
    params: &BTreeMap<String, Value>,
    delta: ItemDelta,
) -> Result<NotificationDisposition, AdapterError> {
    Ok(NotificationDisposition::Mutations(vec![
        CanonicalMutation::ItemDelta {
            key: item_key(method, params)?,
            delta,
        },
    ]))
}

fn live_field(
    method: &str,
    params: &BTreeMap<String, Value>,
    field: String,
    value: Value,
) -> Result<NotificationDisposition, AdapterError> {
    Ok(NotificationDisposition::Mutations(vec![
        CanonicalMutation::ItemLiveFieldReplace {
            key: item_key(method, params)?,
            field,
            value: Some(value),
        },
    ]))
}

fn item_key(method: &str, params: &BTreeMap<String, Value>) -> Result<ItemKey, AdapterError> {
    Ok(ItemKey {
        thread_id: ThreadId::new(string_field(method, params, "threadId")?),
        turn_id: TurnId::new(string_field(method, params, "turnId")?),
        item_id: ItemId::new(string_field(method, params, "itemId")?),
    })
}

fn string_field<'a>(
    method: &str,
    params: &'a BTreeMap<String, Value>,
    field: &'static str,
) -> Result<&'a str, AdapterError> {
    params
        .get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(method, field))
}

fn integer_field(
    method: &str,
    params: &BTreeMap<String, Value>,
    field: &'static str,
) -> Result<i64, AdapterError> {
    params
        .get(field)
        .and_then(Value::as_i64)
        .ok_or_else(|| invalid(method, field))
}

fn object_field<'a>(
    method: &str,
    params: &'a BTreeMap<String, Value>,
    field: &'static str,
) -> Result<&'a Map<String, Value>, AdapterError> {
    params
        .get(field)
        .and_then(Value::as_object)
        .ok_or_else(|| invalid(method, field))
}

fn invalid(method: &str, field: &'static str) -> AdapterError {
    AdapterError::InvalidField {
        method: method.to_owned(),
        field,
    }
}

fn map_value(params: &BTreeMap<String, Value>) -> Value {
    Value::Object(
        params
            .iter()
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn agent_delta_validates_and_maps_to_composite_identity() {
        let params = BTreeMap::from([
            ("threadId".to_owned(), json!("thread")),
            ("turnId".to_owned(), json!("turn")),
            ("itemId".to_owned(), json!("item")),
            ("delta".to_owned(), json!("hello")),
        ]);
        let disposition = adapt_notification("item/agentMessage/delta", &params)
            .expect("generated schema accepts delta");
        assert_eq!(
            disposition,
            NotificationDisposition::Mutations(vec![CanonicalMutation::ItemDelta {
                key: ItemKey {
                    thread_id: ThreadId::from("thread"),
                    turn_id: TurnId::from("turn"),
                    item_id: ItemId::from("item"),
                },
                delta: ItemDelta::AgentMessage("hello".to_owned()),
            }])
        );
    }

    #[test]
    fn malformed_known_notification_fails_generated_validation() {
        let error = adapt_notification(
            "item/agentMessage/delta",
            &BTreeMap::from([("threadId".to_owned(), json!("thread"))]),
        )
        .expect_err("missing generated fields must fail");
        assert!(matches!(error, AdapterError::GeneratedValidation(_)));
    }

    #[test]
    fn unknown_notification_remains_lossless_and_nonfatal() {
        let params = BTreeMap::from([("future".to_owned(), json!({"nested": true}))]);
        assert_eq!(
            adapt_notification("future/method", &params).expect("unknown remains valid"),
            NotificationDisposition::Unhandled {
                method: "future/method".to_owned(),
                params,
            }
        );
    }

    #[test]
    fn plan_update_validates_and_maps_typed_steps() {
        let params = BTreeMap::from([
            ("threadId".to_owned(), json!("thread")),
            ("turnId".to_owned(), json!("turn")),
            (
                "plan".to_owned(),
                json!([
                    {"step": "Inspect", "status": "completed"},
                    {"step": "Build", "status": "inProgress"}
                ]),
            ),
            ("explanation".to_owned(), json!("Implementation plan")),
        ]);
        assert_eq!(
            adapt_notification("turn/plan/updated", &params).expect("valid plan"),
            NotificationDisposition::Mutations(vec![CanonicalMutation::TurnPlanReplace {
                key: TurnKey {
                    thread_id: ThreadId::from("thread"),
                    turn_id: TurnId::from("turn"),
                },
                steps: vec![
                    CanonicalPlanStep {
                        step: "Inspect".to_owned(),
                        status: PlanStepStatus::Completed,
                    },
                    CanonicalPlanStep {
                        step: "Build".to_owned(),
                        status: PlanStepStatus::InProgress,
                    },
                ],
                explanation: Some("Implementation plan".to_owned()),
            }])
        );
    }

    fn raw_goal(status: &str) -> Value {
        json!({
            "threadId": "thread",
            "objective": "Ship parity",
            "status": status,
            "tokenBudget": 4096,
            "tokensUsed": 512,
            "timeUsedSeconds": 45,
            "createdAt": 10,
            "updatedAt": 20,
            "futureGoalField": {"nested": true}
        })
    }

    #[test]
    fn goal_notification_preserves_future_status_and_fields() {
        let params = BTreeMap::from([
            ("threadId".to_owned(), json!("thread")),
            ("turnId".to_owned(), Value::Null),
            ("goal".to_owned(), raw_goal("futureStatus")),
        ]);
        let disposition =
            adapt_notification("thread/goal/updated", &params).expect("future goal remains valid");
        let NotificationDisposition::Mutations(mutations) = disposition else {
            panic!("goal update must be handled");
        };
        let CanonicalMutation::ThreadGoalReplace {
            thread_id,
            goal: Some(goal),
        } = &mutations[0]
        else {
            panic!("goal update must replace canonical goal");
        };
        assert_eq!(thread_id, &ThreadId::from("thread"));
        assert_eq!(
            goal.status,
            ThreadGoalStatus::Unknown("futureStatus".to_owned())
        );
        assert_eq!(goal.extensions["futureGoalField"], json!({"nested": true}));
    }

    #[test]
    fn goal_clear_notification_maps_to_explicit_clear() {
        let params = BTreeMap::from([("threadId".to_owned(), json!("thread"))]);
        assert_eq!(
            adapt_notification("thread/goal/cleared", &params).expect("valid clear"),
            NotificationDisposition::Mutations(vec![CanonicalMutation::ThreadGoalReplace {
                thread_id: ThreadId::from("thread"),
                goal: None,
            }])
        );
    }

    #[test]
    fn goal_responses_validate_owner_and_clear_semantics() {
        let request = json!({"threadId": "thread"});
        let set = adapt_response(
            "thread/goal/set",
            &request,
            &json!({"goal": raw_goal("active")}),
        )
        .expect("valid set response");
        assert!(matches!(
            set,
            ResponseDisposition::Mutations(ref mutations)
                if matches!(mutations.as_slice(), [CanonicalMutation::ThreadGoalReplace { goal: Some(_), .. }])
        ));

        assert_eq!(
            adapt_response("thread/goal/get", &request, &json!({"goal": null}),)
                .expect("valid empty goal"),
            ResponseDisposition::Mutations(vec![CanonicalMutation::ThreadGoalReplace {
                thread_id: ThreadId::from("thread"),
                goal: None,
            }])
        );
        assert_eq!(
            adapt_response("thread/goal/clear", &request, &json!({"cleared": false}),)
                .expect("valid no-op clear"),
            ResponseDisposition::Mutations(Vec::new())
        );

        let mut wrong = raw_goal("active");
        wrong["threadId"] = json!("other");
        assert!(adapt_response("thread/goal/set", &request, &json!({"goal": wrong})).is_err());
    }
}
