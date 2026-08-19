//! Lossless JSON-RPC framing for the Codex App Server.
//!
//! App Server uses JSON-RPC-shaped messages but permits inbound frames to omit
//! the `jsonrpc` member. This crate validates the envelope before generated
//! protocol types or canonical state see the payload.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Number, Value};
use thiserror::Error;

/// Codex CLI version from which the committed protocol contract is generated.
pub const PINNED_CODEX_CLI_VERSION: &str = "0.148.0";

/// Exact JSON-RPC identity shared by responses and server requests.
///
/// Integer `7` and string `"7"` intentionally remain distinct values.
#[derive(Clone, Debug, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(untagged)]
pub enum JsonRpcId {
    /// Signed integer identity.
    Integer(i64),
    /// String identity.
    String(String),
}

impl JsonRpcId {
    fn decode(value: Option<&Value>) -> Result<Self, EnvelopeError> {
        match value {
            Some(Value::Number(number)) => number.as_i64().map(Self::Integer).ok_or_else(|| {
                EnvelopeError::InvalidIdentifier(Some(Value::Number(number.clone())))
            }),
            Some(Value::String(value)) => Ok(Self::String(value.clone())),
            value => Err(EnvelopeError::InvalidIdentifier(value.cloned())),
        }
    }

    fn into_value(self) -> Value {
        match self {
            Self::Integer(value) => Value::Number(Number::from(value)),
            Self::String(value) => Value::String(value),
        }
    }
}

/// Monotonic position of one frame within one physical connection.
///
/// This is a diagnostic/order coordinate, not an App Server resume cursor.
#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
pub struct WireCursor {
    /// Physical connection generation.
    pub connection_epoch: u64,
    /// One-based ordinal within the connection.
    pub ordinal: u64,
}

/// Structured JSON-RPC error returned by App Server.
#[derive(Clone, Debug, Deserialize, Eq, Error, PartialEq, Serialize)]
#[error("JSON-RPC error {code}: {message}")]
pub struct JsonRpcErrorObject {
    /// Protocol-specific numeric error code.
    pub code: i64,
    /// Human-readable error message.
    pub message: String,
    /// Optional structured error data.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

/// Successful or failed response payload.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ResponseOutcome {
    /// Successful result, including explicit JSON `null`.
    Result(Value),
    /// Structured failure.
    Error(JsonRpcErrorObject),
}

/// Response to an earlier client request.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResponseEnvelope {
    /// Correlation identity from the client request.
    pub id: JsonRpcId,
    /// Result or error payload.
    pub outcome: ResponseOutcome,
}

/// Server notification that does not require a response.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NotificationEnvelope {
    /// App Server method name.
    pub method: String,
    /// Object parameters; absent parameters normalize to an empty object.
    pub params: BTreeMap<String, Value>,
}

/// Server-initiated request that requires an exact-ID response.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ServerRequestEnvelope {
    /// Server-provided correlation identity.
    pub id: JsonRpcId,
    /// App Server method name.
    pub method: String,
    /// Object parameters; absent parameters normalize to an empty object.
    pub params: BTreeMap<String, Value>,
}

/// One validated inbound frame.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Envelope {
    /// Response to a client request.
    Response(ResponseEnvelope),
    /// Fire-and-forget server notification.
    Notification(NotificationEnvelope),
    /// Server request requiring a client response.
    ServerRequest(ServerRequestEnvelope),
}

/// Envelope validation or JSON encoding failure.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum EnvelopeError {
    /// Frame is not valid JSON.
    #[error("invalid JSON-RPC JSON: {0}")]
    InvalidJson(String),
    /// Top-level JSON value is not an object.
    #[error("a JSON-RPC frame must contain one top-level object")]
    TopLevelMustBeObject,
    /// Present `jsonrpc` member is not exactly `"2.0"`.
    #[error("an App Server frame jsonrpc member must be 2.0 when present")]
    InvalidVersion(Option<Value>),
    /// Method is absent, empty, or not a string where required.
    #[error("a JSON-RPC request or notification must contain a non-empty string method")]
    InvalidMethod(Option<Value>),
    /// Identifier is missing, null, non-integral, or neither integer nor string.
    #[error("a JSON-RPC id must be a non-null signed integer or string")]
    InvalidIdentifier(Option<Value>),
    /// App Server parameters are present but are not an object.
    #[error("App Server JSON-RPC params must be an object when present")]
    ParamsMustBeObject(Value),
    /// Response has neither or both outcome members.
    #[error("a JSON-RPC response must contain exactly one of result or error")]
    ResponseMustContainExactlyOneOutcome,
    /// Error member is not an object.
    #[error("a JSON-RPC error member must be an object")]
    ErrorMustBeObject(Value),
    /// Error code is absent or is not a signed integer.
    #[error("a JSON-RPC error object must contain an integer code")]
    InvalidErrorCode(Option<Value>),
    /// Error message is absent or is not a string.
    #[error("a JSON-RPC error object must contain a string message")]
    InvalidErrorMessage(Option<Value>),
    /// Frame combines request/notification members with response members.
    #[error("a JSON-RPC frame mixes request and response members")]
    MixedMessageShape,
}

/// Decode and validate one complete App Server frame.
///
/// # Errors
///
/// Returns [`EnvelopeError`] when the JSON is malformed or its envelope does
/// not match the App Server JSON-RPC contract.
pub fn decode_frame(frame: &[u8]) -> Result<Envelope, EnvelopeError> {
    let value: Value = serde_json::from_slice(frame)
        .map_err(|error| EnvelopeError::InvalidJson(error.to_string()))?;
    let object = value
        .as_object()
        .ok_or(EnvelopeError::TopLevelMustBeObject)?;

    if let Some(version) = object.get("jsonrpc")
        && version != "2.0"
    {
        return Err(EnvelopeError::InvalidVersion(Some(version.clone())));
    }

    if let Some(raw_method) = object.get("method") {
        let method = raw_method
            .as_str()
            .filter(|method| !method.is_empty())
            .ok_or_else(|| EnvelopeError::InvalidMethod(Some(raw_method.clone())))?;
        if object.contains_key("result") || object.contains_key("error") {
            return Err(EnvelopeError::MixedMessageShape);
        }
        let params = decode_params(object.get("params"))?;
        if object.contains_key("id") {
            return Ok(Envelope::ServerRequest(ServerRequestEnvelope {
                id: JsonRpcId::decode(object.get("id"))?,
                method: method.to_owned(),
                params,
            }));
        }
        return Ok(Envelope::Notification(NotificationEnvelope {
            method: method.to_owned(),
            params,
        }));
    }

    if object.contains_key("params") {
        return Err(EnvelopeError::MixedMessageShape);
    }
    let id = JsonRpcId::decode(object.get("id"))?;
    let has_result = object.contains_key("result");
    let has_error = object.contains_key("error");
    if has_result == has_error {
        return Err(EnvelopeError::ResponseMustContainExactlyOneOutcome);
    }

    let outcome = if has_result {
        ResponseOutcome::Result(object.get("result").cloned().unwrap_or(Value::Null))
    } else {
        ResponseOutcome::Error(decode_error(
            object
                .get("error")
                .ok_or(EnvelopeError::ResponseMustContainExactlyOneOutcome)?,
        )?)
    };
    Ok(Envelope::Response(ResponseEnvelope { id, outcome }))
}

/// Encode a client request with the explicit JSON-RPC version marker.
///
/// # Errors
///
/// Returns [`EnvelopeError`] for an empty method, non-object parameters, or a
/// JSON encoding failure.
pub fn encode_request(
    id: JsonRpcId,
    method: &str,
    params: Option<Value>,
) -> Result<Vec<u8>, EnvelopeError> {
    let mut object = outbound_base(method)?;
    object.insert("id".to_owned(), id.into_value());
    insert_params(&mut object, params)?;
    encode_object(object)
}

/// Encode a client notification with the explicit JSON-RPC version marker.
///
/// # Errors
///
/// Returns [`EnvelopeError`] for an empty method, non-object parameters, or a
/// JSON encoding failure.
pub fn encode_notification(method: &str, params: Option<Value>) -> Result<Vec<u8>, EnvelopeError> {
    let mut object = outbound_base(method)?;
    insert_params(&mut object, params)?;
    encode_object(object)
}

/// Encode a successful response to a server request.
///
/// # Errors
///
/// Returns [`EnvelopeError`] if JSON encoding fails.
pub fn encode_result(id: JsonRpcId, result: Value) -> Result<Vec<u8>, EnvelopeError> {
    let mut object = versioned_object();
    object.insert("id".to_owned(), id.into_value());
    object.insert("result".to_owned(), result);
    encode_object(object)
}

/// Encode a failed response to a server request.
///
/// # Errors
///
/// Returns [`EnvelopeError`] if structured error or envelope encoding fails.
pub fn encode_error(id: JsonRpcId, error: JsonRpcErrorObject) -> Result<Vec<u8>, EnvelopeError> {
    let mut object = versioned_object();
    object.insert("id".to_owned(), id.into_value());
    object.insert(
        "error".to_owned(),
        serde_json::to_value(error)
            .map_err(|error| EnvelopeError::InvalidJson(error.to_string()))?,
    );
    encode_object(object)
}

fn decode_params(value: Option<&Value>) -> Result<BTreeMap<String, Value>, EnvelopeError> {
    match value {
        None => Ok(BTreeMap::new()),
        Some(Value::Object(object)) => Ok(object
            .iter()
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect()),
        Some(value) => Err(EnvelopeError::ParamsMustBeObject(value.clone())),
    }
}

fn decode_error(value: &Value) -> Result<JsonRpcErrorObject, EnvelopeError> {
    let object = value
        .as_object()
        .ok_or_else(|| EnvelopeError::ErrorMustBeObject(value.clone()))?;
    let code = object
        .get("code")
        .and_then(Value::as_i64)
        .ok_or_else(|| EnvelopeError::InvalidErrorCode(object.get("code").cloned()))?;
    let message = object
        .get("message")
        .and_then(Value::as_str)
        .ok_or_else(|| EnvelopeError::InvalidErrorMessage(object.get("message").cloned()))?;
    Ok(JsonRpcErrorObject {
        code,
        message: message.to_owned(),
        data: object.get("data").cloned(),
    })
}

fn outbound_base(method: &str) -> Result<Map<String, Value>, EnvelopeError> {
    if method.is_empty() {
        return Err(EnvelopeError::InvalidMethod(Some(Value::String(
            method.to_owned(),
        ))));
    }
    let mut object = versioned_object();
    object.insert("method".to_owned(), Value::String(method.to_owned()));
    Ok(object)
}

fn versioned_object() -> Map<String, Value> {
    Map::from_iter([("jsonrpc".to_owned(), Value::String("2.0".to_owned()))])
}

fn insert_params(
    object: &mut Map<String, Value>,
    params: Option<Value>,
) -> Result<(), EnvelopeError> {
    if let Some(params) = params {
        if !params.is_object() {
            return Err(EnvelopeError::ParamsMustBeObject(params));
        }
        object.insert("params".to_owned(), params);
    }
    Ok(())
}

fn encode_object(object: Map<String, Value>) -> Result<Vec<u8>, EnvelopeError> {
    serde_json::to_vec(&Value::Object(object))
        .map_err(|error| EnvelopeError::InvalidJson(error.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn inbound_frames_may_omit_version() {
        let response = decode_frame(br#"{"id":1,"result":{"codexHome":"/tmp/home"}}"#)
            .expect("response must decode");
        assert!(matches!(
            response,
            Envelope::Response(ResponseEnvelope {
                id: JsonRpcId::Integer(1),
                ..
            })
        ));

        let notification = decode_frame(br#"{"method":"thread/started","params":{}}"#)
            .expect("notification must decode");
        assert!(matches!(notification, Envelope::Notification(_)));

        let request = decode_frame(
            br#"{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{}}"#,
        )
        .expect("server request must decode");
        assert!(matches!(request, Envelope::ServerRequest(_)));
    }

    #[test]
    fn integer_and_string_identifiers_remain_distinct() {
        let integer = decode_frame(br#"{"id":7,"result":null}"#).expect("integer response");
        let string = decode_frame(br#"{"id":"7","result":null}"#).expect("string response");
        assert_ne!(integer, string);
    }

    #[test]
    fn rejects_conflicting_version_and_mixed_shape() {
        assert_eq!(
            decode_frame(br#"{"jsonrpc":"1.0","method":"thread/started"}"#),
            Err(EnvelopeError::InvalidVersion(Some(json!("1.0"))))
        );
        assert_eq!(
            decode_frame(br#"{"id":1,"method":"thread/start","result":{}}"#),
            Err(EnvelopeError::MixedMessageShape)
        );
    }

    #[test]
    fn rejects_invalid_identifiers_params_and_outcomes() {
        assert!(matches!(
            decode_frame(br#"{"id":null,"result":{}}"#),
            Err(EnvelopeError::InvalidIdentifier(Some(Value::Null)))
        ));
        assert!(matches!(
            decode_frame(br#"{"method":"thread/started","params":[]}"#),
            Err(EnvelopeError::ParamsMustBeObject(_))
        ));
        assert_eq!(
            decode_frame(br#"{"id":1}"#),
            Err(EnvelopeError::ResponseMustContainExactlyOneOutcome)
        );
        assert_eq!(
            decode_frame(br#"{"id":1,"result":{},"error":{}}"#),
            Err(EnvelopeError::ResponseMustContainExactlyOneOutcome)
        );
    }

    #[test]
    fn outbound_messages_are_versioned_and_round_trip() {
        let encoded = encode_request(
            JsonRpcId::Integer(10),
            "thread/start",
            Some(json!({"model": "gpt-5.6-terra"})),
        )
        .expect("request encodes");
        let value: Value = serde_json::from_slice(&encoded).expect("valid JSON");
        assert_eq!(value["jsonrpc"], "2.0");
        assert_eq!(value["id"], 10);
        assert_eq!(value["method"], "thread/start");
    }

    #[test]
    fn runtime_pin_matches_repository_authority() {
        let version_file = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../Tools/UPSTREAM_VERSION");
        let value = std::fs::read_to_string(version_file).expect("read runtime pin");
        assert_eq!(
            value.trim(),
            format!("codex-cli {PINNED_CODEX_CLI_VERSION}")
        );
    }
}
