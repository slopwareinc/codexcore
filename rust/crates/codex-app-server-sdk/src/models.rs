use codex_app_server_client::AppServerClient;
use serde::Deserialize;
use serde_json::{Map, Value, json};

use crate::SdkError;

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ListModelsOptions {
    pub cursor: Option<String>,
    pub limit: Option<u32>,
    pub include_hidden: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReasoningEffortSummary {
    pub value: String,
    pub description: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelSummary {
    pub id: String,
    pub model: String,
    pub display_name: String,
    pub description: String,
    pub is_default: bool,
    pub hidden: bool,
    pub default_reasoning_effort: String,
    pub supported_reasoning_efforts: Vec<ReasoningEffortSummary>,
    pub raw: Value,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelPage {
    pub data: Vec<ModelSummary>,
    pub next_cursor: Option<String>,
}

pub(crate) async fn list_models(
    client: &AppServerClient,
    options: ListModelsOptions,
) -> Result<ModelPage, SdkError> {
    let mut params = Map::new();
    if let Some(cursor) = options.cursor {
        params.insert("cursor".to_owned(), Value::String(cursor));
    }
    if let Some(limit) = options.limit {
        params.insert("limit".to_owned(), json!(limit));
    }
    if options.include_hidden {
        params.insert("includeHidden".to_owned(), Value::Bool(true));
    }
    let result = client.request("model/list", Value::Object(params)).await?;
    parse_model_page(result.value)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawPage {
    data: Vec<Value>,
    next_cursor: Option<String>,
}

fn parse_model_page(value: Value) -> Result<ModelPage, SdkError> {
    codex_app_server_types::validate_model_list_response(&value).map_err(|error| {
        SdkError::ResponseValidation {
            method: "model/list",
            message: error.to_string(),
        }
    })?;
    let raw: RawPage =
        serde_json::from_value(value).map_err(|error| SdkError::ResponseValidation {
            method: "model/list",
            message: error.to_string(),
        })?;
    Ok(ModelPage {
        data: raw
            .data
            .into_iter()
            .map(parse_model)
            .collect::<Result<Vec<_>, _>>()?,
        next_cursor: raw.next_cursor,
    })
}

fn parse_model(raw: Value) -> Result<ModelSummary, SdkError> {
    let string = |field: &'static str| {
        raw.get(field)
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| projection_error(format!("model.{field} is missing or invalid")))
    };
    let efforts = raw
        .get("supportedReasoningEfforts")
        .and_then(Value::as_array)
        .ok_or_else(|| projection_error("model.supportedReasoningEfforts is missing or invalid"))?
        .iter()
        .map(|effort| {
            Ok(ReasoningEffortSummary {
                value: effort
                    .get("reasoningEffort")
                    .and_then(Value::as_str)
                    .ok_or_else(|| projection_error("reasoning effort value is invalid"))?
                    .to_owned(),
                description: effort
                    .get("description")
                    .and_then(Value::as_str)
                    .ok_or_else(|| projection_error("reasoning effort description is invalid"))?
                    .to_owned(),
            })
        })
        .collect::<Result<Vec<_>, SdkError>>()?;
    Ok(ModelSummary {
        id: string("id")?,
        model: string("model")?,
        display_name: string("displayName")?,
        description: string("description")?,
        is_default: raw
            .get("isDefault")
            .and_then(Value::as_bool)
            .ok_or_else(|| projection_error("model.isDefault is missing or invalid"))?,
        hidden: raw
            .get("hidden")
            .and_then(Value::as_bool)
            .ok_or_else(|| projection_error("model.hidden is missing or invalid"))?,
        default_reasoning_effort: string("defaultReasoningEffort")?,
        supported_reasoning_efforts: efforts,
        raw,
    })
}

fn projection_error(message: impl Into<String>) -> SdkError {
    SdkError::ResponseValidation {
        method: "model/list",
        message: message.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_and_projects_model_catalog() {
        let page = parse_model_page(json!({
            "data": [{
                "id": "gpt",
                "model": "gpt",
                "displayName": "GPT",
                "description": "General model",
                "isDefault": true,
                "hidden": false,
                "defaultReasoningEffort": "medium",
                "supportedReasoningEfforts": [{
                    "reasoningEffort": "medium",
                    "description": "Balanced"
                }]
            }]
        }))
        .expect("model page");
        assert_eq!(page.data[0].display_name, "GPT");
        assert_eq!(page.data[0].supported_reasoning_efforts[0].value, "medium");
        assert!(page.data[0].is_default);
    }
}
