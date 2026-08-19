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
