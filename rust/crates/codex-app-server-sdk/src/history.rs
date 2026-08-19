use std::collections::VecDeque;

use codex_app_server_adapter::{adapt_item_entry, adapt_thread_snapshot, adapt_turn_snapshot};
use codex_app_server_client::ThreadLease;
use codex_app_server_history::{
    HistoryEffect, HistoryInstallation, HistoryPolicy, InitialTurnsPage, ItemRecord,
    PaginatedHistoryCoordinator, TurnRecord,
};
use codex_app_server_lease::LeaseReason;
use codex_app_server_state::{ItemId, ThreadId, TurnId};
use serde_json::{Value, json};

use crate::{Codex, CodexThread, ResumeThreadOptions, SdkError};

/// Paginated resume configuration.
#[derive(Clone, Debug, Default)]
pub struct PaginatedResumeOptions {
    /// Ordinary resume overrides.
    pub resume: ResumeThreadOptions,
    /// Page sizes and concurrent item chain bound.
    pub policy: HistoryPolicy,
}

pub(crate) async fn resume_paginated(
    codex: &Codex,
    thread_id: ThreadId,
    options: PaginatedResumeOptions,
) -> Result<CodexThread, SdkError> {
    let snapshot = codex.client.snapshot().await?;
    let policy = options.policy;
    let mut runner = Runner {
        codex,
        thread_id: thread_id.clone(),
        options,
        coordinator: PaginatedHistoryCoordinator::new(policy)
            .map_err(|error| SdkError::History(error.to_string()))?,
        resume_thread: None,
        selected_lease: None,
        history_lease: None,
    };
    let effects = runner
        .coordinator
        .begin(thread_id, snapshot.connection_epoch, 1)
        .map_err(|error| SdkError::History(error.to_string()))?;
    runner.run(effects).await
}

struct Runner<'a> {
    codex: &'a Codex,
    thread_id: ThreadId,
    options: PaginatedResumeOptions,
    coordinator: PaginatedHistoryCoordinator,
    resume_thread: Option<Value>,
    selected_lease: Option<ThreadLease>,
    history_lease: Option<ThreadLease>,
}

impl Runner<'_> {
    async fn run(mut self, effects: Vec<HistoryEffect>) -> Result<CodexThread, SdkError> {
        let mut queue: VecDeque<_> = effects.into();
        while let Some(effect) = queue.pop_front() {
            match effect {
                HistoryEffect::RequestResume { request_id, .. } => {
                    queue.extend(self.request_resume(request_id).await?);
                }
                HistoryEffect::RequestTurns {
                    request_id,
                    cursor,
                    limit,
                    ..
                } => {
                    queue.extend(self.request_turns(request_id, cursor, limit).await?);
                }
                HistoryEffect::RequestItems {
                    request_id,
                    turn_id,
                    cursor,
                    limit,
                    ..
                } => {
                    queue.extend(
                        self.request_items(request_id, turn_id, cursor, limit)
                            .await?,
                    );
                }
                HistoryEffect::Install(installation) => return self.install(installation).await,
                HistoryEffect::Failed(failure) => {
                    return Err(SdkError::History(failure.reason.to_string()));
                }
                HistoryEffect::MarkStale { .. } => {
                    return Err(SdkError::History(
                        "scope became stale during resume".to_owned(),
                    ));
                }
            }
        }
        Err(SdkError::History(
            "history coordinator produced no installation".to_owned(),
        ))
    }

    async fn request_resume(
        &mut self,
        request_id: codex_app_server_history::HistoryRequestId,
    ) -> Result<Vec<HistoryEffect>, SdkError> {
        let mut params = self.options.resume.extra.clone();
        params.insert(
            "threadId".to_owned(),
            Value::String(self.thread_id.to_string()),
        );
        params.insert("excludeTurns".to_owned(), Value::Bool(true));
        params.insert(
            "initialTurnsPage".to_owned(),
            json!({
                "limit": self.options.policy.turn_page_limit,
                "sortDirection": "desc",
                "itemsView": "summary"
            }),
        );
        if let Some(permissions) = &self.options.resume.permissions {
            params.insert("permissions".to_owned(), Value::String(permissions.clone()));
        }
        let result = self
            .codex
            .client
            .request("thread/resume", object(params))
            .await?;
        codex_app_server_types::validate_thread_resume_response(&result.value)
            .map_err(|error| SdkError::History(error.to_string()))?;
        let thread = result
            .value
            .get("thread")
            .cloned()
            .ok_or(SdkError::MissingResponseField {
                method: "thread/resume",
                field: "thread",
            })?;
        let mode = thread.get("historyMode").and_then(Value::as_str);
        if mode != Some("paginated") {
            return Err(SdkError::History(format!(
                "thread declares non-paginated history mode {mode:?}"
            )));
        }
        let turns_cursor = nullable_cursor(&result.value, "turnsBackwardsCursor")?;
        let items_cursor = nullable_cursor(&result.value, "itemsBackwardsCursor")?;
        let initial = result
            .value
            .get("initialTurnsPage")
            .filter(|value| !value.is_null())
            .map(parse_initial_turns_page)
            .transpose()?;
        self.selected_lease = Some(
            self.codex
                .client
                .adopt_thread(self.thread_id.clone(), LeaseReason::Selected)
                .await?,
        );
        self.history_lease = Some(
            self.codex
                .client
                .acquire_thread(self.thread_id.clone(), LeaseReason::History)
                .await?,
        );
        self.resume_thread = Some(thread);
        Ok(self.coordinator.receive_resume_cut(
            &self.thread_id,
            request_id,
            turns_cursor,
            items_cursor,
            initial,
        ))
    }

    async fn request_turns(
        &mut self,
        request_id: codex_app_server_history::HistoryRequestId,
        cursor: String,
        limit: u32,
    ) -> Result<Vec<HistoryEffect>, SdkError> {
        let result = self
            .codex
            .client
            .request(
                "thread/turns/list",
                json!({
                    "threadId": self.thread_id.as_str(), "cursor": cursor,
                    "limit": limit, "sortDirection": "desc", "itemsView": "summary"
                }),
            )
            .await?;
        codex_app_server_types::validate_turns_list_response(&result.value)
            .map_err(|error| SdkError::History(error.to_string()))?;
        let records = array_field(&result.value, "thread/turns/list", "data")?
            .iter()
            .map(turn_record)
            .collect::<Result<Vec<_>, _>>()?;
        let next = optional_cursor(&result.value, "nextCursor")?;
        Ok(self
            .coordinator
            .receive_turns_page(&self.thread_id, request_id, records, next))
    }

    async fn request_items(
        &mut self,
        request_id: codex_app_server_history::HistoryRequestId,
        turn_id: TurnId,
        cursor: String,
        limit: u32,
    ) -> Result<Vec<HistoryEffect>, SdkError> {
        let result = self
            .codex
            .client
            .request(
                "thread/items/list",
                json!({
                    "threadId": self.thread_id.as_str(), "turnId": turn_id.as_str(),
                    "cursor": cursor, "limit": limit, "sortDirection": "desc"
                }),
            )
            .await?;
        codex_app_server_types::validate_items_list_response(&result.value)
            .map_err(|error| SdkError::History(error.to_string()))?;
        let records = array_field(&result.value, "thread/items/list", "data")?
            .iter()
            .map(item_record)
            .collect::<Result<Vec<_>, _>>()?;
        let next = optional_cursor(&result.value, "nextCursor")?;
        Ok(self.coordinator.receive_items_page(
            &self.thread_id,
            &turn_id,
            request_id,
            records,
            next,
        ))
    }

    async fn install(mut self, installation: HistoryInstallation) -> Result<CodexThread, SdkError> {
        let thread = self
            .resume_thread
            .take()
            .ok_or_else(|| SdkError::History("missing resume thread".to_owned()))?;
        let mut mutations =
            adapt_thread_snapshot(&thread).map_err(|error| SdkError::History(error.to_string()))?;
        for turn in installation.turns {
            mutations.extend(
                adapt_turn_snapshot(&self.thread_id, &turn.value)
                    .map_err(|error| SdkError::History(error.to_string()))?,
            );
        }
        for item in installation.items {
            mutations.push(
                adapt_item_entry(&self.thread_id, &item.value)
                    .map_err(|error| SdkError::History(error.to_string()))?,
            );
        }
        self.codex.client.apply_canonical(mutations).await?;
        if let Some(lease) = self.history_lease.take() {
            lease.close().await?;
        }
        let lease = self
            .selected_lease
            .take()
            .ok_or_else(|| SdkError::History("missing selected lease".to_owned()))?;
        Ok(CodexThread {
            client: self.codex.client.clone(),
            id: self.thread_id,
            lease: Some(lease),
        })
    }
}

fn object(values: std::collections::BTreeMap<String, Value>) -> Value {
    Value::Object(values.into_iter().collect())
}

fn nullable_cursor(value: &Value, field: &'static str) -> Result<Option<String>, SdkError> {
    let Some(value) = value.get(field) else {
        return Err(SdkError::MissingResponseField {
            method: "thread/resume",
            field,
        });
    };
    optional_cursor_value(value, "thread/resume", field)
}

fn optional_cursor(value: &Value, field: &'static str) -> Result<Option<String>, SdkError> {
    value.get(field).map_or(Ok(None), |value| {
        optional_cursor_value(value, "history page", field)
    })
}

fn optional_cursor_value(
    value: &Value,
    method: &'static str,
    field: &'static str,
) -> Result<Option<String>, SdkError> {
    match value {
        Value::Null => Ok(None),
        Value::String(value) => Ok(Some(value.clone())),
        _ => Err(SdkError::MissingResponseField { method, field }),
    }
}

fn array_field<'a>(
    value: &'a Value,
    method: &'static str,
    field: &'static str,
) -> Result<&'a Vec<Value>, SdkError> {
    value
        .get(field)
        .and_then(Value::as_array)
        .ok_or(SdkError::MissingResponseField { method, field })
}

fn parse_initial_turns_page(value: &Value) -> Result<InitialTurnsPage, SdkError> {
    Ok(InitialTurnsPage {
        data: array_field(value, "thread/resume", "data")?
            .iter()
            .map(turn_record)
            .collect::<Result<Vec<_>, _>>()?,
        backwards_cursor: optional_cursor(value, "backwardsCursor")?,
        next_cursor: optional_cursor(value, "nextCursor")?,
    })
}

fn turn_record(value: &Value) -> Result<TurnRecord, SdkError> {
    let id = value
        .get("id")
        .and_then(Value::as_str)
        .ok_or(SdkError::MissingResponseField {
            method: "thread/turns/list",
            field: "data[].id",
        })?;
    Ok(TurnRecord {
        turn_id: TurnId::new(id),
        value: value.clone(),
    })
}

fn item_record(value: &Value) -> Result<ItemRecord, SdkError> {
    let turn =
        value
            .get("turnId")
            .and_then(Value::as_str)
            .ok_or(SdkError::MissingResponseField {
                method: "thread/items/list",
                field: "data[].turnId",
            })?;
    let item = value.pointer("/item/id").and_then(Value::as_str).ok_or(
        SdkError::MissingResponseField {
            method: "thread/items/list",
            field: "data[].item.id",
        },
    )?;
    Ok(ItemRecord {
        turn_id: TurnId::new(turn),
        item_id: ItemId::new(item),
        value: value.clone(),
    })
}
