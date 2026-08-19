//! Opt-in live transport smoke test against the exact App Server binary.

use std::path::PathBuf;

use codex_app_server_transport::{StdioConfig, StdioConnection, TransportLimits};
use codex_app_server_wire::{Envelope, JsonRpcId, decode_frame, encode_request};
use serde_json::json;

#[tokio::test]
#[ignore = "requires CODEX_BINARY pointing to codex-cli 0.148.0"]
async fn initialize_exact_app_server() {
    let executable = std::env::var_os("CODEX_BINARY")
        .map(PathBuf::from)
        .expect("CODEX_BINARY must point to codex-cli 0.148.0");
    let mut connection = StdioConnection::spawn(
        &StdioConfig::app_server(executable),
        TransportLimits::default(),
    )
    .expect("launch App Server");

    let request = encode_request(
        JsonRpcId::Integer(0),
        "initialize",
        Some(json!({
            "clientInfo": {
                "name": "codexcore_rust_live_test",
                "title": "CodexCore Rust Live Test",
                "version": env!("CARGO_PKG_VERSION")
            },
            "capabilities": {
                "experimentalApi": true
            }
        })),
    )
    .expect("encode initialize");
    connection.write(&request).await.expect("write initialize");

    let response = tokio::time::timeout(std::time::Duration::from_secs(15), async {
        loop {
            let frame = connection
                .next_frame()
                .await
                .expect("connection remains open")
                .expect("transport frame");
            let envelope = decode_frame(&frame).expect("valid envelope");
            if matches!(
                envelope,
                Envelope::Response(ref response) if response.id == JsonRpcId::Integer(0)
            ) {
                return envelope;
            }
        }
    })
    .await
    .expect("initialize response timeout");
    assert!(matches!(response, Envelope::Response(_)));
    connection.close().await.expect("close and reap");
}
