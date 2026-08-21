use std::{collections::BTreeMap, path::PathBuf};

use codex_app_server_client::AppServerClient;
use codex_app_server_state::ThreadId;
use serde::Deserialize;
use serde_json::{Map, Value};

use crate::SdkError;

/// Stored-thread ordering field.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ThreadSortKey {
    CreatedAt,
    UpdatedAt,
    RecencyAt,
    SectionPosition,
}

impl ThreadSortKey {
    const fn as_str(self) -> &'static str {
        match self {
            Self::CreatedAt => "created_at",
            Self::UpdatedAt => "updated_at",
            Self::RecencyAt => "recency_at",
            Self::SectionPosition => "section_position",
        }
    }
}

/// Page traversal direction.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SortDirection {
    Ascending,
    Descending,
}

impl SortDirection {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Ascending => "asc",
            Self::Descending => "desc",
        }
    }
}

/// Stable SDK options for `thread/list`.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ListThreadsOptions {
    pub cursor: Option<String>,
    pub limit: Option<u32>,
    pub archived: Option<bool>,
    pub search_term: Option<String>,
    pub cwd: Vec<PathBuf>,
    pub model_providers: Vec<String>,
    pub source_kinds: Vec<String>,
    pub sort_key: Option<ThreadSortKey>,
    pub sort_direction: Option<SortDirection>,
    pub use_state_db_only: bool,
}

/// Stable stored-thread summary; `raw` preserves future pinned-schema fields.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ThreadSummary {
    pub id: ThreadId,
    pub name: Option<String>,
    pub preview: String,
    pub cwd: PathBuf,
    pub model_provider: String,
    pub created_at: i64,
    pub updated_at: i64,
    pub recency_at: Option<i64>,
    pub ephemeral: bool,
    pub parent_thread_id: Option<ThreadId>,
    pub status: Value,
    pub raw: Value,
}

/// One stable stored-thread page with opaque cursors.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ThreadPage {
    pub data: Vec<ThreadSummary>,
    pub next_cursor: Option<String>,
    pub backwards_cursor: Option<String>,
}

pub(crate) async fn list_threads(
    client: &AppServerClient,
    options: ListThreadsOptions,
) -> Result<ThreadPage, SdkError> {
    let result = client
        .request("thread/list", Value::Object(list_params(options)))
        .await?;
    parse_thread_page(result.value)
}

fn list_params(options: ListThreadsOptions) -> Map<String, Value> {
    let mut params = BTreeMap::new();
    insert_option(&mut params, "cursor", options.cursor);
    insert_option(&mut params, "limit", options.limit.map(u64::from));
    insert_option(&mut params, "archived", options.archived);
    insert_option(&mut params, "searchTerm", options.search_term);
    if !options.cwd.is_empty() {
        params.insert(
            "cwd".to_owned(),
            Value::Array(
                options
                    .cwd
                    .into_iter()
                    .map(|path| Value::String(path.to_string_lossy().into_owned()))
                    .collect(),
            ),
        );
    }
    insert_array(&mut params, "modelProviders", options.model_providers);
    insert_array(&mut params, "sourceKinds", options.source_kinds);
    insert_option(
        &mut params,
        "sortKey",
        options.sort_key.map(|value| value.as_str().to_owned()),
    );
    insert_option(
        &mut params,
        "sortDirection",
        options
            .sort_direction
            .map(|value| value.as_str().to_owned()),
    );
    if options.use_state_db_only {
        params.insert("useStateDbOnly".to_owned(), Value::Bool(true));
    }
    params.into_iter().collect()
}

fn insert_option<T: Into<Value>>(
    params: &mut BTreeMap<String, Value>,
    key: &str,
    value: Option<T>,
) {
    if let Some(value) = value {
        params.insert(key.to_owned(), value.into());
    }
}

fn insert_array(params: &mut BTreeMap<String, Value>, key: &str, values: Vec<String>) {
    if !values.is_empty() {
        params.insert(
            key.to_owned(),
            Value::Array(values.into_iter().map(Value::String).collect()),
        );
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawPage {
    data: Vec<Value>,
    next_cursor: Option<String>,
    backwards_cursor: Option<String>,
}

fn parse_thread_page(value: Value) -> Result<ThreadPage, SdkError> {
    codex_app_server_types::validate_thread_list_response(&value).map_err(|error| {
        SdkError::ResponseValidation {
            method: "thread/list",
            message: error.to_string(),
        }
    })?;
    let raw: RawPage =
        serde_json::from_value(value).map_err(|error| SdkError::ResponseValidation {
            method: "thread/list",
            message: error.to_string(),
        })?;
    Ok(ThreadPage {
        data: raw
            .data
            .into_iter()
            .map(parse_summary)
            .collect::<Result<Vec<_>, _>>()?,
        next_cursor: raw.next_cursor,
        backwards_cursor: raw.backwards_cursor,
    })
}

fn parse_summary(raw: Value) -> Result<ThreadSummary, SdkError> {
    let field = |name: &'static str| {
        raw.get(name)
            .ok_or_else(|| projection_error(format!("missing thread.{name}")))
    };
    let string = |name| {
        field(name)?
            .as_str()
            .map(str::to_owned)
            .ok_or_else(|| projection_error(format!("thread.{name} is not a string")))
    };
    let integer = |name| {
        field(name)?
            .as_i64()
            .ok_or_else(|| projection_error(format!("thread.{name} is not an integer")))
    };
    Ok(ThreadSummary {
        id: ThreadId::new(string("id")?),
        name: optional_string(&raw, "name"),
        preview: string("preview")?,
        cwd: PathBuf::from(string("cwd")?),
        model_provider: string("modelProvider")?,
        created_at: integer("createdAt")?,
        updated_at: integer("updatedAt")?,
        recency_at: raw.get("recencyAt").and_then(Value::as_i64),
        ephemeral: field("ephemeral")?
            .as_bool()
            .ok_or_else(|| projection_error("thread.ephemeral is not a boolean"))?,
        parent_thread_id: optional_string(&raw, "parentThreadId").map(ThreadId::new),
        status: field("status")?.clone(),
        raw,
    })
}

fn optional_string(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn projection_error(message: impl Into<String>) -> SdkError {
    SdkError::ResponseValidation {
        method: "thread/list",
        message: message.into(),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn encodes_filters_without_null_or_empty_noise() {
        let params = list_params(ListThreadsOptions {
            limit: Some(25),
            cwd: vec![PathBuf::from("/workspace")],
            sort_key: Some(ThreadSortKey::RecencyAt),
            sort_direction: Some(SortDirection::Descending),
            ..ListThreadsOptions::default()
        });
        assert_eq!(params["limit"], json!(25));
        assert_eq!(params["cwd"], json!(["/workspace"]));
        assert_eq!(params["sortKey"], json!("recency_at"));
        assert!(!params.contains_key("archived"));
    }

    #[test]
    fn validates_and_projects_thread_page_losslessly() {
        let value = json!({
            "data": [{
                "cliVersion": "0.148.0",
                "createdAt": 10,
                "cwd": "/workspace",
                "ephemeral": false,
                "id": "thread",
                "modelProvider": "openai",
                "preview": "Build it",
                "sessionId": "session",
                "source": "appServer",
                "status": {"type": "idle"},
                "turns": [],
                "updatedAt": 12,
                "futureStableField": true
            }],
            "nextCursor": "next"
        });
        let page = parse_thread_page(value).expect("valid page");
        assert_eq!(page.next_cursor.as_deref(), Some("next"));
        assert_eq!(page.data[0].id, ThreadId::from("thread"));
        assert_eq!(page.data[0].raw["futureStableField"], Value::Bool(true));
    }
}
