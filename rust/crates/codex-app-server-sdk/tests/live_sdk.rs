//! Opt-in SDK facade smoke test against the exact authenticated App Server.

use std::path::PathBuf;

use codex_app_server_client::LocalSessionConfig;
use codex_app_server_sdk::{Codex, StartThreadOptions};

#[tokio::test]
#[ignore = "requires CODEX_BINARY pointing to authenticated codex-cli 0.148.0"]
async fn start_and_release_ephemeral_thread() {
    let executable = std::env::var_os("CODEX_BINARY")
        .map(PathBuf::from)
        .expect("CODEX_BINARY must point to codex-cli 0.148.0");
    let workspace = tempfile::tempdir().expect("temporary workspace");
    let codex = Codex::connect_local(LocalSessionConfig::app_server(executable))
        .await
        .expect("connect SDK");
    let thread = codex
        .start_thread(StartThreadOptions {
            cwd: Some(workspace.path().to_owned()),
            ephemeral: Some(true),
            ..StartThreadOptions::default()
        })
        .await
        .expect("start ephemeral thread");
    assert!(!thread.id().as_str().is_empty());
    thread.close().await.expect("release thread lease");
    codex.close().await.expect("close SDK");
}
