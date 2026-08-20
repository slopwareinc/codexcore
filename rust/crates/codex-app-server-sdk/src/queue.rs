use codex_app_server_client::AppServerClient;
use serde::Deserialize;
use serde_json::Value;

use crate::{CodexInput, SdkError};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct QueuedSubmission {
    pub id: String,
    pub client_user_message_id: String,
    pub input: Vec<Value>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct QueuePage {
    pub data: Vec<QueuedSubmission>,
    pub next_cursor: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawSubmission {
    id: String,
    client_user_message_id: String,
    input: Vec<Value>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawPage {
    data: Vec<RawSubmission>,
    next_cursor: Option<String>,
}

pub(crate) fn input_values(input: Vec<CodexInput>) -> Vec<Value> {
    input.into_iter().map(CodexInput::into_value).collect()
}

pub(crate) fn parse_submission(
    method: &'static str,
    value: &Value,
) -> Result<QueuedSubmission, SdkError> {
    let raw: RawSubmission =
        serde_json::from_value(value.clone()).map_err(|error| SdkError::ResponseValidation {
            method,
            message: error.to_string(),
        })?;
    Ok(QueuedSubmission {
        id: raw.id,
        client_user_message_id: raw.client_user_message_id,
        input: raw.input,
    })
}

pub(crate) fn parse_page(value: Value) -> Result<QueuePage, SdkError> {
    codex_app_server_types::validate_thread_queue_list_response(&value).map_err(|error| {
        SdkError::ResponseValidation {
            method: "thread/queue/list",
            message: error.to_string(),
        }
    })?;
    let raw: RawPage =
        serde_json::from_value(value).map_err(|error| SdkError::ResponseValidation {
            method: "thread/queue/list",
            message: error.to_string(),
        })?;
    Ok(QueuePage {
        data: raw
            .data
            .into_iter()
            .map(|submission| QueuedSubmission {
                id: submission.id,
                client_user_message_id: submission.client_user_message_id,
                input: submission.input,
            })
            .collect(),
        next_cursor: raw.next_cursor,
    })
}

pub(crate) async fn list(
    client: &AppServerClient,
    thread_id: &str,
    cursor: Option<String>,
    limit: Option<u32>,
) -> Result<QueuePage, SdkError> {
    let mut params =
        serde_json::Map::from_iter([("threadId".to_owned(), Value::String(thread_id.to_owned()))]);
    if let Some(cursor) = cursor {
        params.insert("cursor".to_owned(), Value::String(cursor));
    }
    if let Some(limit) = limit {
        params.insert("limit".to_owned(), Value::Number(limit.into()));
    }
    let response = client
        .request("thread/queue/list", Value::Object(params))
        .await?;
    parse_page(response.value)
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn queue_page_preserves_typed_input_values_losslessly() {
        let page = parse_page(json!({
            "data": [{
                "id": "queued",
                "clientUserMessageId": "client",
                "input": [
                    {"type": "text", "text": "hello"},
                    {"type": "mention", "name": "file", "path": "/file"}
                ]
            }],
            "nextCursor": null
        }))
        .expect("queue page");
        assert_eq!(page.data[0].id, "queued");
        assert_eq!(page.data[0].input[1]["type"], "mention");
    }
}
