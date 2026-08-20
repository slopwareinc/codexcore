//! Opt-in SDK facade smoke test against the exact authenticated App Server.

use std::path::PathBuf;

use codex_app_server_client::LocalSessionConfig;
use codex_app_server_sdk::{
    Codex, CodexInput, ListModelsOptions, ListThreadsOptions, PaginatedResumeOptions,
    StartThreadOptions, TurnOptions,
};
use codex_app_server_state::{TurnId, TurnKey};
use serde_json::{Value, json};

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

#[tokio::test]
#[ignore = "requires CODEX_BINARY pointing to authenticated codex-cli 0.148.0"]
async fn list_stored_threads_through_stable_sdk_page() {
    let executable = std::env::var_os("CODEX_BINARY")
        .map(PathBuf::from)
        .expect("CODEX_BINARY must point to codex-cli 0.148.0");
    let codex = Codex::connect_local(LocalSessionConfig::app_server(executable))
        .await
        .expect("connect SDK");
    let page = codex
        .list_threads(ListThreadsOptions {
            limit: Some(5),
            ..ListThreadsOptions::default()
        })
        .await
        .expect("list stable thread page");
    assert!(page.data.len() <= 5);
    assert!(
        page.data
            .iter()
            .all(|thread| !thread.id.as_str().is_empty())
    );
    codex.close().await.expect("close SDK");
}

#[tokio::test]
#[ignore = "requires CODEX_BINARY pointing to authenticated codex-cli 0.148.0"]
async fn list_models_through_stable_sdk_page() {
    let executable = std::env::var_os("CODEX_BINARY")
        .map(PathBuf::from)
        .expect("CODEX_BINARY must point to codex-cli 0.148.0");
    let codex = Codex::connect_local(LocalSessionConfig::app_server(executable))
        .await
        .expect("connect SDK");
    let page = codex
        .list_models(ListModelsOptions {
            limit: Some(20),
            ..ListModelsOptions::default()
        })
        .await
        .expect("list stable model page");
    assert!(!page.data.is_empty());
    assert!(page.data.iter().all(|model| !model.model.is_empty()));
    codex.close().await.expect("close SDK");
}

#[tokio::test]
#[ignore = "requires CODEX_BINARY pointing to authenticated codex-cli 0.148.0"]
async fn resume_legacy_thread_through_declared_history_mode() {
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
            ..StartThreadOptions::default()
        })
        .await
        .expect("start legacy thread");
    let thread_id = thread.id().clone();
    let turn = thread
        .start_turn(
            vec![CodexInput::text("Reply with OK.")],
            TurnOptions::default(),
        )
        .await
        .expect("materialize legacy rollout");
    let turn_key = TurnKey {
        thread_id: thread_id.clone(),
        turn_id: turn.id().clone(),
    };
    let mut reached_terminal = false;
    for _ in 0..120 {
        let canonical = codex
            .client()
            .canonical_snapshot()
            .await
            .expect("turn snapshot");
        if canonical
            .turns
            .get(&turn_key)
            .is_some_and(|turn| turn.status.is_terminal())
        {
            reached_terminal = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    }
    assert!(reached_terminal, "legacy turn did not reach terminal state");
    turn.close().await.expect("release active turn lease");
    thread.close().await.expect("release initial lease");
    let resumed = codex
        .resume_thread_hydrated(thread_id.clone(), PaginatedResumeOptions::default())
        .await
        .expect("read mode and hydrate legacy thread");
    let canonical = codex
        .client()
        .canonical_snapshot()
        .await
        .expect("canonical snapshot");
    assert!(canonical.threads.contains_key(&thread_id));
    resumed.close().await.expect("release resumed lease");
    codex
        .client()
        .request("thread/delete", json!({"threadId": thread_id.as_str()}))
        .await
        .expect("delete test thread");
    codex.close().await.expect("close SDK");
}

#[tokio::test]
#[ignore = "requires CODEX_BINARY pointing to authenticated codex-cli 0.148.0"]
async fn resume_empty_paginated_thread_into_canonical_state() {
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
            extra: [(
                "historyMode".to_owned(),
                Value::String("paginated".to_owned()),
            )]
            .into_iter()
            .collect(),
            ..StartThreadOptions::default()
        })
        .await
        .expect("start persisted paginated thread");
    let thread_id = thread.id().clone();
    let turn = thread
        .start_turn(
            vec![CodexInput::text("Reply with OK.")],
            TurnOptions::default(),
        )
        .await
        .expect("start materializing turn");
    let turn_id = turn.id().clone();
    let turn_key = TurnKey {
        thread_id: thread_id.clone(),
        turn_id: TurnId::new(turn_id.as_str()),
    };
    let mut reached_terminal = false;
    for _ in 0..120 {
        let canonical = codex
            .client()
            .canonical_snapshot()
            .await
            .expect("turn snapshot");
        if canonical
            .turns
            .get(&turn_key)
            .is_some_and(|turn| turn.status.is_terminal())
        {
            reached_terminal = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    }
    assert!(
        reached_terminal,
        "materializing turn did not reach terminal state"
    );
    turn.close().await.expect("release active turn lease");
    thread.close().await.expect("release initial lease");

    let resumed = codex
        .resume_thread_hydrated(thread_id.clone(), PaginatedResumeOptions::default())
        .await
        .expect("resume and install paginated history");
    let canonical = codex
        .client()
        .canonical_snapshot()
        .await
        .expect("canonical snapshot");
    assert!(canonical.threads.contains_key(&thread_id));
    resumed.close().await.expect("release resumed lease");

    codex
        .client()
        .request("thread/delete", json!({"threadId": thread_id.as_str()}))
        .await
        .expect("delete test thread");
    codex.close().await.expect("close SDK");
}
