//! Opt-in live ordered-session smoke test against the exact App Server.

use std::path::PathBuf;

use codex_app_server_client::{AppServerClient, ConnectionPhase, LocalSessionConfig};
use serde_json::json;

#[tokio::test]
#[ignore = "requires CODEX_BINARY pointing to codex-cli 0.148.0"]
async fn initialize_and_list_models() {
    let executable = std::env::var_os("CODEX_BINARY")
        .map(PathBuf::from)
        .expect("CODEX_BINARY must point to codex-cli 0.148.0");
    let client = AppServerClient::connect_local(LocalSessionConfig::app_server(executable))
        .await
        .expect("initialize ordered session");

    let connected = client.snapshot().await.expect("connected snapshot");
    assert_eq!(connected.phase, ConnectionPhase::Connected);
    assert!(!connected.server.user_agent.is_empty());
    assert!(!connected.server.codex_home.is_empty());

    let result = client
        .request("model/list", json!({"limit": 1, "includeHidden": false}))
        .await
        .expect("list models");
    let data = result.value["data"]
        .as_array()
        .expect("model/list data is an array");
    assert!(!data.is_empty());

    let after = client.snapshot().await.expect("post-response snapshot");
    assert_eq!(after.revision, result.committed_revision);
    client.close().await.expect("close and reap");
}
