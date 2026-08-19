//! Stable, SDK-owned server-request prompt and response models.

use std::collections::BTreeMap;

use codex_app_server_client::{PendingServerRequest, ServerRequestKey, ServerRequestResolution};
use codex_app_server_state::{ItemId, ThreadId, TurnId};
use codex_app_server_wire::JsonRpcErrorObject;
use serde_json::{Value, json};
use thiserror::Error;

/// Thread/turn/item scope carried by an interaction.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InteractionScope {
    /// Owning thread.
    pub thread_id: ThreadId,
    /// Active/owning turn when present.
    pub turn_id: Option<TurnId>,
    /// Owning item/call when present.
    pub item_id: Option<ItemId>,
}

/// User-input option supplied by the model/tool.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct QuestionOption {
    /// Display label.
    pub label: String,
    /// Optional explanatory detail.
    pub description: Option<String>,
}

/// One blocking/nonblocking user question.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UserQuestion {
    pub id: String,
    pub header: String,
    pub question: String,
    pub is_secret: bool,
    pub is_other_allowed: bool,
    pub options: Vec<QuestionOption>,
}

/// MCP elicitation mode.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum McpElicitationMode {
    Form { requested_schema: Value },
    OpenAiForm { requested_schema: Value },
    Url { elicitation_id: String, url: String },
}

/// Parsed request family.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ServerRequestBody {
    CommandApproval {
        scope: InteractionScope,
        command: Option<String>,
        cwd: Option<String>,
        reason: Option<String>,
        available_decisions: Vec<Value>,
        additional_permissions: Option<Value>,
    },
    FileChangeApproval {
        scope: InteractionScope,
        reason: Option<String>,
        grant_root: Option<String>,
    },
    PermissionsApproval {
        scope: InteractionScope,
        cwd: String,
        permissions: Value,
        reason: Option<String>,
        environment_id: Option<String>,
    },
    UserInput {
        scope: InteractionScope,
        is_blocking: bool,
        questions: Vec<UserQuestion>,
    },
    McpElicitation {
        scope: InteractionScope,
        server_name: String,
        message: String,
        mode: McpElicitationMode,
        metadata: Option<Value>,
    },
    DynamicToolCall {
        scope: InteractionScope,
        call_id: String,
        namespace: Option<String>,
        tool: String,
        arguments: Value,
    },
    TokenRefresh {
        reason: String,
        previous_account_id: Option<String>,
    },
    Attestation,
    CurrentTime {
        thread_id: ThreadId,
    },
    LegacyExecApproval {
        scope: InteractionScope,
        call_id: String,
        approval_id: Option<String>,
        command: Vec<String>,
        cwd: String,
        parsed_command: Vec<Value>,
        reason: Option<String>,
    },
    LegacyPatchApproval {
        scope: InteractionScope,
        call_id: String,
        file_changes: BTreeMap<String, Value>,
        grant_root: Option<String>,
        reason: Option<String>,
    },
    Unknown {
        method: String,
        params: BTreeMap<String, Value>,
    },
}

/// Validated, typed interaction with exact epoch-qualified identity.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TypedServerRequest {
    pub key: ServerRequestKey,
    pub body: ServerRequestBody,
    /// Exact params retained for forward compatibility/debugging.
    pub raw_params: BTreeMap<String, Value>,
}

/// Stable response builders. The actor performs final generated validation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ServerRequestReply {
    CommandDecision(Value),
    FileDecision(Value),
    Permissions {
        permissions: Value,
        scope: Option<String>,
        strict_auto_review: Option<bool>,
    },
    UserInput {
        answers: BTreeMap<String, Vec<String>>,
    },
    McpElicitation {
        action: String,
        content: Option<Value>,
        metadata: Option<Value>,
    },
    DynamicTool {
        success: bool,
        content_items: Vec<DynamicToolContent>,
    },
    TokenRefresh {
        access_token: String,
        account_id: String,
        plan_type: Option<String>,
    },
    Attestation {
        token: String,
    },
    CurrentTime {
        unix_seconds: i64,
    },
    LegacyDecision(Value),
    Raw(Value),
    Error(JsonRpcErrorObject),
}

/// Dynamic tool result content.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DynamicToolContent {
    Text(String),
    Image(String),
    Audio(String),
}

impl ServerRequestReply {
    /// Encode into the raw resolution accepted by the ordered actor.
    #[must_use]
    pub fn into_resolution(self) -> ServerRequestResolution {
        let result = match self {
            Self::CommandDecision(decision)
            | Self::FileDecision(decision)
            | Self::LegacyDecision(decision) => json!({"decision": decision}),
            Self::Permissions {
                permissions,
                scope,
                strict_auto_review,
            } => {
                let mut value =
                    serde_json::Map::from_iter([("permissions".to_owned(), permissions)]);
                if let Some(scope) = scope {
                    value.insert("scope".to_owned(), Value::String(scope));
                }
                if let Some(strict) = strict_auto_review {
                    value.insert("strictAutoReview".to_owned(), Value::Bool(strict));
                }
                Value::Object(value)
            }
            Self::UserInput { answers } => json!({
                "answers": answers.into_iter().map(|(id, answers)| (id, json!({"answers": answers}))).collect::<BTreeMap<_, _>>()
            }),
            Self::McpElicitation {
                action,
                content,
                metadata,
            } => {
                let mut value =
                    serde_json::Map::from_iter([("action".to_owned(), Value::String(action))]);
                if let Some(content) = content {
                    value.insert("content".to_owned(), content);
                }
                if let Some(metadata) = metadata {
                    value.insert("_meta".to_owned(), metadata);
                }
                Value::Object(value)
            }
            Self::DynamicTool {
                success,
                content_items,
            } => json!({
                "success": success,
                "contentItems": content_items.into_iter().map(DynamicToolContent::into_value).collect::<Vec<_>>()
            }),
            Self::TokenRefresh {
                access_token,
                account_id,
                plan_type,
            } => {
                let mut value = serde_json::Map::from_iter([
                    ("accessToken".to_owned(), Value::String(access_token)),
                    ("chatgptAccountId".to_owned(), Value::String(account_id)),
                ]);
                if let Some(plan) = plan_type {
                    value.insert("chatgptPlanType".to_owned(), Value::String(plan));
                }
                Value::Object(value)
            }
            Self::Attestation { token } => json!({"token": token}),
            Self::CurrentTime { unix_seconds } => json!({"currentTimeAt": unix_seconds}),
            Self::Raw(value) => value,
            Self::Error(error) => return ServerRequestResolution::Error(error),
        };
        ServerRequestResolution::Result(result)
    }
}

impl DynamicToolContent {
    fn into_value(self) -> Value {
        match self {
            Self::Text(text) => json!({"type": "inputText", "text": text}),
            Self::Image(image_url) => json!({"type": "inputImage", "imageUrl": image_url}),
            Self::Audio(audio_url) => json!({"type": "inputAudio", "audioUrl": audio_url}),
        }
    }
}

/// Parsing failure after generated schema validation.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum InteractionError {
    #[error("server request schema validation failed: {0}")]
    Validation(String),
    #[error("server request {method} has invalid field {field}")]
    InvalidField { method: String, field: &'static str },
}

/// Parse one raw inbox entry into a stable request family.
///
/// # Errors
///
/// Returns [`InteractionError`] for malformed known requests.
pub fn parse_request(
    request: &PendingServerRequest,
) -> Result<TypedServerRequest, InteractionError> {
    let params = object(&request.params);
    codex_app_server_types::validate_server_request(&request.method, &params)
        .map_err(|error| InteractionError::Validation(error.to_string()))?;
    let body = match request.method.as_str() {
        "item/commandExecution/requestApproval" => ServerRequestBody::CommandApproval {
            scope: scope(&request.method, &request.params, true)?,
            command: optional_string(&request.params, "command"),
            cwd: optional_string(&request.params, "cwd"),
            reason: optional_string(&request.params, "reason"),
            available_decisions: request
                .params
                .get("availableDecisions")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default(),
            additional_permissions: request
                .params
                .get("additionalPermissions")
                .filter(|v| !v.is_null())
                .cloned(),
        },
        "item/fileChange/requestApproval" => ServerRequestBody::FileChangeApproval {
            scope: scope(&request.method, &request.params, true)?,
            reason: optional_string(&request.params, "reason"),
            grant_root: optional_string(&request.params, "grantRoot"),
        },
        "item/permissions/requestApproval" => ServerRequestBody::PermissionsApproval {
            scope: scope(&request.method, &request.params, true)?,
            cwd: required_string(&request.method, &request.params, "cwd")?,
            permissions: required(&request.method, &request.params, "permissions")?,
            reason: optional_string(&request.params, "reason"),
            environment_id: optional_string(&request.params, "environmentId"),
        },
        "item/tool/requestUserInput" => ServerRequestBody::UserInput {
            scope: scope(&request.method, &request.params, true)?,
            is_blocking: request
                .params
                .get("isBlocking")
                .and_then(Value::as_bool)
                .ok_or_else(|| invalid(&request.method, "isBlocking"))?,
            questions: parse_questions(&request.method, &request.params)?,
        },
        "mcpServer/elicitation/request" => parse_mcp(&request.method, &request.params)?,
        "item/tool/call" => ServerRequestBody::DynamicToolCall {
            scope: scope(&request.method, &request.params, false)?,
            call_id: required_string(&request.method, &request.params, "callId")?,
            namespace: optional_string(&request.params, "namespace"),
            tool: required_string(&request.method, &request.params, "tool")?,
            arguments: required(&request.method, &request.params, "arguments")?,
        },
        "account/chatgptAuthTokens/refresh" => ServerRequestBody::TokenRefresh {
            reason: required_string(&request.method, &request.params, "reason")?,
            previous_account_id: optional_string(&request.params, "previousAccountId"),
        },
        "attestation/generate" => ServerRequestBody::Attestation,
        "currentTime/read" => ServerRequestBody::CurrentTime {
            thread_id: ThreadId::new(required_string(
                &request.method,
                &request.params,
                "threadId",
            )?),
        },
        "execCommandApproval" => ServerRequestBody::LegacyExecApproval {
            scope: legacy_scope(&request.method, &request.params)?,
            call_id: required_string(&request.method, &request.params, "callId")?,
            approval_id: optional_string(&request.params, "approvalId"),
            command: string_array(&request.method, &request.params, "command")?,
            cwd: required_string(&request.method, &request.params, "cwd")?,
            parsed_command: request
                .params
                .get("parsedCmd")
                .and_then(Value::as_array)
                .cloned()
                .ok_or_else(|| invalid(&request.method, "parsedCmd"))?,
            reason: optional_string(&request.params, "reason"),
        },
        "applyPatchApproval" => ServerRequestBody::LegacyPatchApproval {
            scope: legacy_scope(&request.method, &request.params)?,
            call_id: required_string(&request.method, &request.params, "callId")?,
            file_changes: request
                .params
                .get("fileChanges")
                .and_then(Value::as_object)
                .ok_or_else(|| invalid(&request.method, "fileChanges"))?
                .iter()
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect(),
            grant_root: optional_string(&request.params, "grantRoot"),
            reason: optional_string(&request.params, "reason"),
        },
        _ => ServerRequestBody::Unknown {
            method: request.method.clone(),
            params: request.params.clone(),
        },
    };
    Ok(TypedServerRequest {
        key: request.key.clone(),
        body,
        raw_params: request.params.clone(),
    })
}

fn scope(
    method: &str,
    params: &BTreeMap<String, Value>,
    require_item: bool,
) -> Result<InteractionScope, InteractionError> {
    Ok(InteractionScope {
        thread_id: ThreadId::new(required_string(method, params, "threadId")?),
        turn_id: optional_string(params, "turnId").map(TurnId::new),
        item_id: if require_item {
            Some(ItemId::new(required_string(method, params, "itemId")?))
        } else {
            None
        },
    })
}

fn legacy_scope(
    method: &str,
    params: &BTreeMap<String, Value>,
) -> Result<InteractionScope, InteractionError> {
    Ok(InteractionScope {
        thread_id: ThreadId::new(required_string(method, params, "conversationId")?),
        turn_id: None,
        item_id: Some(ItemId::new(required_string(method, params, "callId")?)),
    })
}

fn parse_questions(
    method: &str,
    params: &BTreeMap<String, Value>,
) -> Result<Vec<UserQuestion>, InteractionError> {
    params
        .get("questions")
        .and_then(Value::as_array)
        .ok_or_else(|| invalid(method, "questions"))?
        .iter()
        .map(|value| {
            let value = value
                .as_object()
                .ok_or_else(|| invalid(method, "questions[]"))?;
            let options = value
                .get("options")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .map(|option| {
                    let option = option
                        .as_object()
                        .ok_or_else(|| invalid(method, "questions[].options[]"))?;
                    Ok(QuestionOption {
                        label: required_string_map(method, option, "label")?,
                        description: option
                            .get("description")
                            .and_then(Value::as_str)
                            .map(str::to_owned),
                    })
                })
                .collect::<Result<Vec<_>, InteractionError>>()?;
            Ok(UserQuestion {
                id: required_string_map(method, value, "id")?,
                header: required_string_map(method, value, "header")?,
                question: required_string_map(method, value, "question")?,
                is_secret: value
                    .get("isSecret")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                is_other_allowed: value
                    .get("isOther")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                options,
            })
        })
        .collect()
}

fn parse_mcp(
    method: &str,
    params: &BTreeMap<String, Value>,
) -> Result<ServerRequestBody, InteractionError> {
    let mode = required_string(method, params, "mode")?;
    let mode = match mode.as_str() {
        "form" => McpElicitationMode::Form {
            requested_schema: required(method, params, "requestedSchema")?,
        },
        "openai/form" => McpElicitationMode::OpenAiForm {
            requested_schema: required(method, params, "requestedSchema")?,
        },
        "url" => McpElicitationMode::Url {
            elicitation_id: required_string(method, params, "elicitationId")?,
            url: required_string(method, params, "url")?,
        },
        _ => return Err(invalid(method, "mode")),
    };
    Ok(ServerRequestBody::McpElicitation {
        scope: scope(method, params, false)?,
        server_name: required_string(method, params, "serverName")?,
        message: required_string(method, params, "message")?,
        mode,
        metadata: params.get("_meta").cloned(),
    })
}

fn object(params: &BTreeMap<String, Value>) -> Value {
    Value::Object(params.iter().map(|(k, v)| (k.clone(), v.clone())).collect())
}
fn required(
    method: &str,
    params: &BTreeMap<String, Value>,
    field: &'static str,
) -> Result<Value, InteractionError> {
    params
        .get(field)
        .cloned()
        .ok_or_else(|| invalid(method, field))
}
fn required_string(
    method: &str,
    params: &BTreeMap<String, Value>,
    field: &'static str,
) -> Result<String, InteractionError> {
    params
        .get(field)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| invalid(method, field))
}
fn required_string_map(
    method: &str,
    params: &serde_json::Map<String, Value>,
    field: &'static str,
) -> Result<String, InteractionError> {
    params
        .get(field)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| invalid(method, field))
}
fn optional_string(params: &BTreeMap<String, Value>, field: &str) -> Option<String> {
    params.get(field).and_then(Value::as_str).map(str::to_owned)
}
fn string_array(
    method: &str,
    params: &BTreeMap<String, Value>,
    field: &'static str,
) -> Result<Vec<String>, InteractionError> {
    params
        .get(field)
        .and_then(Value::as_array)
        .ok_or_else(|| invalid(method, field))?
        .iter()
        .map(|v| {
            v.as_str()
                .map(str::to_owned)
                .ok_or_else(|| invalid(method, field))
        })
        .collect()
}
fn invalid(method: &str, field: &'static str) -> InteractionError {
    InteractionError::InvalidField {
        method: method.to_owned(),
        field,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use codex_app_server_wire::JsonRpcId;

    fn pending(method: &str, params: &Value) -> PendingServerRequest {
        PendingServerRequest {
            key: ServerRequestKey {
                connection_epoch: 1,
                request_id: JsonRpcId::Integer(7),
            },
            method: method.to_owned(),
            params: params
                .as_object()
                .expect("object")
                .iter()
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect(),
        }
    }

    #[test]
    fn parses_command_approval_and_builds_valid_decline() {
        let request = pending(
            "item/commandExecution/requestApproval",
            &json!({
                "threadId":"thread","turnId":"turn","itemId":"item","startedAtMs":1,"command":"echo ok"
            }),
        );
        let typed = parse_request(&request).expect("parse command");
        assert!(matches!(
            typed.body,
            ServerRequestBody::CommandApproval { .. }
        ));
        let ServerRequestResolution::Result(value) =
            ServerRequestReply::CommandDecision(json!("decline")).into_resolution()
        else {
            panic!("result")
        };
        assert!(
            codex_app_server_types::validate_server_response(&request.method, &value)
                .expect("validate response")
        );
    }

    #[test]
    fn dynamic_tool_content_uses_exact_wire_variants() {
        let ServerRequestResolution::Result(value) = ServerRequestReply::DynamicTool {
            success: true,
            content_items: vec![
                DynamicToolContent::Text("ok".into()),
                DynamicToolContent::Image("data:image/png;base64,x".into()),
            ],
        }
        .into_resolution() else {
            panic!("result")
        };
        assert_eq!(value["contentItems"][0]["type"], "inputText");
        assert_eq!(value["contentItems"][1]["type"], "inputImage");
    }
}
