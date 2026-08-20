//! Generated v2 App Server protocol types.
//!
//! Never edit the imported schema by hand. Regenerate it from the exact binary
//! in `Tools/UPSTREAM_VERSION` with `Tools/regenerate.sh`.

#![recursion_limit = "512"]
#![allow(clippy::all, clippy::pedantic)]

typify::import_types!(
    schema = "../../protocol/schema/codex_app_server_protocol.v2.schemas.json",
    struct_builder = false,
);

/// Validate a raw method/params pair against the generated server-notification
/// union without exposing generated enum internals to the public SDK.
///
/// # Errors
///
/// Returns [`serde_json::Error`] when the method is unknown to the pinned
/// schema or its parameters do not satisfy the selected notification type.
pub fn validate_server_notification(
    method: &str,
    params: &serde_json::Value,
) -> Result<(), serde_json::Error> {
    let value = serde_json::json!({
        "method": method,
        "params": params,
    });
    serde_json::from_value::<ServerNotification>(value).map(drop)
}

/// Validate one standalone thread record from a response/page.
///
/// # Errors
///
/// Returns [`serde_json::Error`] when it does not match the pinned schema.
pub fn validate_thread(value: &serde_json::Value) -> Result<(), serde_json::Error> {
    serde_json::from_value::<Thread>(value.clone()).map(drop)
}

/// Validate one standalone turn record from a response/page.
///
/// # Errors
///
/// Returns [`serde_json::Error`] when it does not match the pinned schema.
pub fn validate_turn(value: &serde_json::Value) -> Result<(), serde_json::Error> {
    serde_json::from_value::<Turn>(value.clone()).map(drop)
}

/// Validate one thread item entry returned by `thread/items/list`.
///
/// # Errors
///
/// Returns [`serde_json::Error`] when it does not match the pinned schema.
pub fn validate_thread_item_entry(value: &serde_json::Value) -> Result<(), serde_json::Error> {
    serde_json::from_value::<ThreadItemEntry>(value.clone()).map(drop)
}

/// Validate a `thread/resume` result.
///
/// # Errors
///
/// Returns [`serde_json::Error`] when it does not match the pinned schema.
pub fn validate_thread_resume_response(value: &serde_json::Value) -> Result<(), serde_json::Error> {
    serde_json::from_value::<ThreadResumeResponse>(value.clone()).map(drop)
}

/// Validate a `thread/list` result.
///
/// # Errors
///
/// Returns [`serde_json::Error`] when it does not match the pinned schema.
pub fn validate_thread_list_response(value: &serde_json::Value) -> Result<(), serde_json::Error> {
    serde_json::from_value::<ThreadListResponse>(value.clone()).map(drop)
}

/// Validate a `thread/read` result.
///
/// # Errors
///
/// Returns [`serde_json::Error`] when it does not match the pinned schema.
pub fn validate_thread_read_response(value: &serde_json::Value) -> Result<(), serde_json::Error> {
    serde_json::from_value::<ThreadReadResponse>(value.clone()).map(drop)
}

/// Validate a `model/list` result.
///
/// # Errors
///
/// Returns [`serde_json::Error`] when it does not match the pinned schema.
pub fn validate_model_list_response(value: &serde_json::Value) -> Result<(), serde_json::Error> {
    serde_json::from_value::<ModelListResponse>(value.clone()).map(drop)
}

/// Validate a `thread/turns/list` result.
///
/// # Errors
///
/// Returns [`serde_json::Error`] when it does not match the pinned schema.
pub fn validate_turns_list_response(value: &serde_json::Value) -> Result<(), serde_json::Error> {
    serde_json::from_value::<ThreadTurnsListResponse>(value.clone()).map(drop)
}

/// Validate a `thread/items/list` result.
///
/// # Errors
///
/// Returns [`serde_json::Error`] when it does not match the pinned schema.
pub fn validate_items_list_response(value: &serde_json::Value) -> Result<(), serde_json::Error> {
    serde_json::from_value::<ThreadItemsListResponse>(value.clone()).map(drop)
}

macro_rules! isolated_schema {
    ($module:ident, $path:literal, $type:ident) => {
        mod $module {
            typify::import_types!(schema = $path, struct_builder = false);

            pub(super) fn validate(value: &serde_json::Value) -> Result<(), serde_json::Error> {
                serde_json::from_value::<$type>(value.clone()).map(drop)
            }
        }
    };
}

isolated_schema!(
    command_params,
    "../../protocol/schema/server_requests/CommandExecutionRequestApprovalParams.json",
    CommandExecutionRequestApprovalParams
);
isolated_schema!(
    command_response,
    "../../protocol/schema/server_requests/CommandExecutionRequestApprovalResponse.json",
    CommandExecutionRequestApprovalResponse
);
isolated_schema!(
    file_params,
    "../../protocol/schema/server_requests/FileChangeRequestApprovalParams.json",
    FileChangeRequestApprovalParams
);
isolated_schema!(
    file_response,
    "../../protocol/schema/server_requests/FileChangeRequestApprovalResponse.json",
    FileChangeRequestApprovalResponse
);
isolated_schema!(
    permissions_params,
    "../../protocol/schema/server_requests/PermissionsRequestApprovalParams.json",
    PermissionsRequestApprovalParams
);
isolated_schema!(
    permissions_response,
    "../../protocol/schema/server_requests/PermissionsRequestApprovalResponse.json",
    PermissionsRequestApprovalResponse
);
isolated_schema!(
    input_params,
    "../../protocol/schema/server_requests/ToolRequestUserInputParams.json",
    ToolRequestUserInputParams
);
isolated_schema!(
    input_response,
    "../../protocol/schema/server_requests/ToolRequestUserInputResponse.json",
    ToolRequestUserInputResponse
);
isolated_schema!(
    mcp_response,
    "../../protocol/schema/server_requests/McpServerElicitationRequestResponse.json",
    McpServerElicitationRequestResponse
);
isolated_schema!(
    tool_params,
    "../../protocol/schema/server_requests/DynamicToolCallParams.json",
    DynamicToolCallParams
);
isolated_schema!(
    tool_response,
    "../../protocol/schema/server_requests/DynamicToolCallResponse.json",
    DynamicToolCallResponse
);
isolated_schema!(
    token_params,
    "../../protocol/schema/server_requests/ChatgptAuthTokensRefreshParams.json",
    ChatgptAuthTokensRefreshParams
);
isolated_schema!(
    token_response,
    "../../protocol/schema/server_requests/ChatgptAuthTokensRefreshResponse.json",
    ChatgptAuthTokensRefreshResponse
);
isolated_schema!(
    attestation_params,
    "../../protocol/schema/server_requests/AttestationGenerateParams.json",
    AttestationGenerateParams
);
isolated_schema!(
    attestation_response,
    "../../protocol/schema/server_requests/AttestationGenerateResponse.json",
    AttestationGenerateResponse
);
isolated_schema!(
    time_params,
    "../../protocol/schema/server_requests/CurrentTimeReadParams.json",
    CurrentTimeReadParams
);
isolated_schema!(
    time_response,
    "../../protocol/schema/server_requests/CurrentTimeReadResponse.json",
    CurrentTimeReadResponse
);
isolated_schema!(
    legacy_exec_params,
    "../../protocol/schema/server_requests/ExecCommandApprovalParams.json",
    ExecCommandApprovalParams
);
isolated_schema!(
    legacy_exec_response,
    "../../protocol/schema/server_requests/ExecCommandApprovalResponse.json",
    ExecCommandApprovalResponse
);
isolated_schema!(
    legacy_patch_params,
    "../../protocol/schema/server_requests/ApplyPatchApprovalParams.json",
    ApplyPatchApprovalParams
);
isolated_schema!(
    legacy_patch_response,
    "../../protocol/schema/server_requests/ApplyPatchApprovalResponse.json",
    ApplyPatchApprovalResponse
);

/// Validate parameters for any known server-request method.
///
/// Returns `Ok(false)` for future unknown methods so callers can preserve them
/// explicitly rather than treating them as malformed known requests.
///
/// # Errors
///
/// Returns [`serde_json::Error`] when a known method's parameters are invalid.
pub fn validate_server_request(
    method: &str,
    params: &serde_json::Value,
) -> Result<bool, serde_json::Error> {
    match method {
        "item/commandExecution/requestApproval" => command_params::validate(params)?,
        "item/fileChange/requestApproval" => file_params::validate(params)?,
        "item/permissions/requestApproval" => permissions_params::validate(params)?,
        "item/tool/requestUserInput" => input_params::validate(params)?,
        "mcpServer/elicitation/request" => validate_mcp_params(params)?,
        "item/tool/call" => tool_params::validate(params)?,
        "account/chatgptAuthTokens/refresh" => token_params::validate(params)?,
        "attestation/generate" => attestation_params::validate(params)?,
        "currentTime/read" => time_params::validate(params)?,
        "execCommandApproval" => legacy_exec_params::validate(params)?,
        "applyPatchApproval" => legacy_patch_params::validate(params)?,
        _ => return Ok(false),
    }
    Ok(true)
}

fn validate_mcp_params(value: &serde_json::Value) -> Result<(), serde_json::Error> {
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Request {
        server_name: String,
        thread_id: String,
        #[serde(default)]
        turn_id: Option<String>,
        #[serde(flatten)]
        mode: Mode,
    }

    #[derive(serde::Deserialize)]
    #[serde(tag = "mode")]
    enum Mode {
        #[serde(rename = "form")]
        Form {
            message: String,
            #[serde(rename = "requestedSchema")]
            requested_schema: serde_json::Value,
        },
        #[serde(rename = "openai/form")]
        OpenAiForm {
            message: String,
            #[serde(rename = "requestedSchema")]
            requested_schema: serde_json::Value,
        },
        #[serde(rename = "url")]
        Url {
            message: String,
            #[serde(rename = "elicitationId")]
            elicitation_id: String,
            url: String,
        },
    }

    let request: Request = serde_json::from_value(value.clone())?;
    let _ = (request.server_name, request.thread_id, request.turn_id);
    match request.mode {
        Mode::Form {
            message,
            requested_schema,
        }
        | Mode::OpenAiForm {
            message,
            requested_schema,
        } => {
            let _ = (message, requested_schema);
        }
        Mode::Url {
            message,
            elicitation_id,
            url,
        } => {
            let _ = (message, elicitation_id, url);
        }
    }
    Ok(())
}

/// Validate a result for any known server-request method.
///
/// Returns `Ok(false)` for future unknown methods.
///
/// # Errors
///
/// Returns [`serde_json::Error`] when a known method's result is invalid.
pub fn validate_server_response(
    method: &str,
    result: &serde_json::Value,
) -> Result<bool, serde_json::Error> {
    match method {
        "item/commandExecution/requestApproval" => command_response::validate(result)?,
        "item/fileChange/requestApproval" => file_response::validate(result)?,
        "item/permissions/requestApproval" => permissions_response::validate(result)?,
        "item/tool/requestUserInput" => input_response::validate(result)?,
        "mcpServer/elicitation/request" => mcp_response::validate(result)?,
        "item/tool/call" => tool_response::validate(result)?,
        "account/chatgptAuthTokens/refresh" => token_response::validate(result)?,
        "attestation/generate" => attestation_response::validate(result)?,
        "currentTime/read" => time_response::validate(result)?,
        "execCommandApproval" => legacy_exec_response::validate(result)?,
        "applyPatchApproval" => legacy_patch_response::validate(result)?,
        _ => return Ok(false),
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::ClientRequest;

    #[test]
    fn initialize_request_round_trips_with_experimental_capability() {
        let value = json!({
            "method": "initialize",
            "id": 7,
            "params": {
                "clientInfo": {
                    "name": "codexcore_rust_tests",
                    "title": "CodexCore Rust Tests",
                    "version": env!("CARGO_PKG_VERSION")
                },
                "capabilities": {
                    "experimentalApi": true
                }
            }
        });

        let request: ClientRequest =
            serde_json::from_value(value.clone()).expect("generated request decodes");
        let encoded: Value = serde_json::to_value(request).expect("generated request encodes");
        assert_eq!(encoded["method"], value["method"]);
        assert_eq!(encoded["id"], value["id"]);
        assert_eq!(encoded["params"]["capabilities"]["experimentalApi"], true);
        assert_eq!(
            encoded["params"]["capabilities"]["requestAttestation"],
            false
        );
    }
}
