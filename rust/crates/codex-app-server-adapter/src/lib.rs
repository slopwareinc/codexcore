//! Deterministic App Server protocol-to-canonical adaptation.
//!
//! Known methods validate against generated types before raw values are mapped
//! into SDK-owned canonical mutations. Unknown future methods remain nonfatal
//! and retain their exact payload for diagnostics.

use std::collections::{BTreeMap, BTreeSet};

use codex_app_server_state::{
    CanonicalItem, CanonicalMutation, CanonicalThread, CanonicalTurn, ItemId, ItemKey,
    ItemTextDelta, LifecycleStatus, StateCoverage, ThreadId, ThreadStatus, TurnId, TurnKey,
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

/// Generated validation or required-field failure.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum AdapterError {
    /// Pinned generated schema rejected a known notification.
    #[error("generated notification validation failed: {0}")]
    GeneratedValidation(String),
    /// Required field is absent or has an incompatible JSON shape.
    #[error("notification {method} has invalid field {field}")]
    InvalidField {
        /// Notification method.
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
                    metadata: BTreeMap::new(),
                }),
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
        "item/agentMessage/delta" => {
            validate(method, &params_value)?;
            Ok(NotificationDisposition::Mutations(vec![
                CanonicalMutation::ItemDelta(ItemTextDelta {
                    key: ItemKey {
                        thread_id: ThreadId::new(string_field(method, params, "threadId")?),
                        turn_id: TurnId::new(string_field(method, params, "turnId")?),
                        item_id: ItemId::new(string_field(method, params, "itemId")?),
                    },
                    field: "text".to_owned(),
                    text: string_field(method, params, "delta")?.to_owned(),
                }),
            ]))
        }
        _ => Ok(NotificationDisposition::Unhandled {
            method: method.to_owned(),
            params: params.clone(),
        }),
    }
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
        metadata: metadata_without(value, &["id", "status", "turns"]),
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
            NotificationDisposition::Mutations(vec![CanonicalMutation::ItemDelta(ItemTextDelta {
                key: ItemKey {
                    thread_id: ThreadId::from("thread"),
                    turn_id: TurnId::from("turn"),
                    item_id: ItemId::from("item"),
                },
                field: "text".to_owned(),
                text: "hello".to_owned(),
            })])
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
}
