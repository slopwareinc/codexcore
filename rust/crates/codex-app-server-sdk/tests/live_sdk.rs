//! Opt-in SDK facade smoke test against the exact authenticated App Server.

use std::path::PathBuf;

use codex_app_server_client::LocalSessionConfig;
use codex_app_server_sdk::{
    Codex, CodexInput, ForkPoint, ForkThreadOptions, ListModelsOptions, ListThreadsOptions,
    PaginatedResumeOptions, SectionAppearance, SectionAppearanceUpdate, StartThreadOptions,
    TurnOptions,
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
async fn read_authenticated_account_through_stable_sdk() {
    let executable = std::env::var_os("CODEX_BINARY")
        .map(PathBuf::from)
        .expect("CODEX_BINARY must point to codex-cli 0.148.0");
    let codex = Codex::connect_local(LocalSessionConfig::app_server(executable))
        .await
        .expect("connect SDK");
    let account = codex.account(false).await.expect("read account");
    assert!(account.account.is_some());
    codex.close().await.expect("close SDK");
}

#[tokio::test]
#[ignore = "requires CODEX_BINARY pointing to authenticated codex-cli 0.148.0"]
async fn thread_lifecycle_operations_round_trip() {
    let executable = std::env::var_os("CODEX_BINARY")
        .map(PathBuf::from)
        .expect("CODEX_BINARY must point to codex-cli 0.148.0");
    let workspace = tempfile::tempdir().expect("temporary workspace");
    let codex = Codex::connect_local(LocalSessionConfig::app_server(executable))
        .await
        .expect("connect SDK");
    let source = codex
        .start_thread(StartThreadOptions {
            cwd: Some(workspace.path().to_owned()),
            ..StartThreadOptions::default()
        })
        .await
        .expect("start source thread");
    let source_id = source.id().clone();
    let turn = source
        .start_turn(
            vec![CodexInput::text("Reply with OK.")],
            TurnOptions::default(),
        )
        .await
        .expect("materialize source thread");
    let turn_id = turn.id().clone();
    let turn_key = TurnKey {
        thread_id: source_id.clone(),
        turn_id: turn_id.clone(),
    };
    let mut terminal = false;
    for _ in 0..120 {
        let state = codex
            .client()
            .canonical_snapshot()
            .await
            .expect("turn snapshot");
        if state
            .turns
            .get(&turn_key)
            .is_some_and(|turn| turn.status.is_terminal())
        {
            terminal = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    }
    assert!(terminal, "source turn did not reach terminal state");
    turn.close().await.expect("release source turn");

    source
        .rename("Rust lifecycle source")
        .await
        .expect("rename");
    let fork = source
        .fork(ForkThreadOptions {
            point: Some(ForkPoint::Through(turn_id.clone())),
            ..ForkThreadOptions::default()
        })
        .await
        .expect("fork thread");
    let fork_id = fork.thread.id().clone();
    assert_ne!(fork_id, source_id);
    fork.thread
        .rename("Rust lifecycle fork")
        .await
        .expect("rename fork");
    fork.thread.archive().await.expect("archive fork");
    fork.thread.close().await.expect("release fork lease");
    let unarchived = codex
        .unarchive_thread(&fork_id)
        .await
        .expect("unarchive fork");
    assert_eq!(unarchived.thread_id, fork_id);

    let reverted = source.revert(&turn_id).await.expect("revert source");
    assert_eq!(reverted.thread_id, source_id);
    source.close().await.expect("release source lease");
    for id in [&fork_id, &source_id] {
        codex
            .client()
            .request("thread/delete", json!({"threadId": id.as_str()}))
            .await
            .expect("delete lifecycle test thread");
    }
    codex.close().await.expect("close SDK");
}

#[tokio::test]
#[ignore = "requires CODEX_BINARY pointing to authenticated codex-cli 0.148.0"]
async fn durable_queue_add_list_update_reorder_delete() {
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
        .expect("start queue thread");
    let thread_id = thread.id().clone();
    let turn = thread
        .start_turn(
            vec![CodexInput::text(
                "Write a detailed multi-section explanation of Rust ownership with many examples.",
            )],
            TurnOptions::default(),
        )
        .await
        .expect("start seed turn");
    let queued = thread
        .queue_add(
            vec![CodexInput::text("first")],
            "live-queue-client-message".to_owned(),
        )
        .await
        .expect("add queued submission");
    let mut listed = false;
    for _ in 0..20 {
        let page = thread.queue_list(None, Some(20)).await.expect("list queue");
        if page.data.iter().any(|item| item.id == queued.id) {
            listed = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    assert!(listed, "queued submission did not become list-visible");
    let updated = thread
        .queue_update(&queued.id, vec![CodexInput::text("updated")])
        .await
        .expect("update queue");
    assert_eq!(updated.id, queued.id);
    thread
        .queue_reorder(vec![queued.id.clone()])
        .await
        .expect("reorder queue");
    assert!(thread.queue_delete(&queued.id).await.expect("delete queue"));
    turn.interrupt().await.expect("interrupt seed turn");
    turn.close().await.expect("release active turn");
    thread.close().await.expect("release thread");
    codex
        .client()
        .request("thread/delete", json!({"threadId": thread_id.as_str()}))
        .await
        .expect("delete queue test thread");
    codex.close().await.expect("close SDK");
}

#[tokio::test]
#[ignore = "requires CODEX_BINARY pointing to authenticated codex-cli 0.148.0"]
async fn section_crud_and_thread_move() {
    let executable = std::env::var_os("CODEX_BINARY")
        .map(PathBuf::from)
        .expect("CODEX_BINARY must point to codex-cli 0.148.0");
    let workspace = tempfile::tempdir().expect("temporary workspace");
    let codex = Codex::connect_local(LocalSessionConfig::app_server(executable))
        .await
        .expect("connect SDK");
    let section = codex
        .create_section(
            "Rust SDK live test".to_owned(),
            Some(SectionAppearance {
                icon: Some("test".to_owned()),
                color: None,
            }),
        )
        .await
        .expect("create section");
    let updated = codex
        .update_section(
            &section.id,
            "Rust SDK live test updated".to_owned(),
            SectionAppearanceUpdate::Clear,
        )
        .await
        .expect("update section");
    assert_eq!(updated.name, "Rust SDK live test updated");
    let page = codex
        .list_sections(None, Some(100))
        .await
        .expect("list sections");
    assert!(page.data.iter().any(|candidate| candidate.id == section.id));
    let thread = codex
        .start_thread(StartThreadOptions {
            cwd: Some(workspace.path().to_owned()),
            ..StartThreadOptions::default()
        })
        .await
        .expect("start movable thread");
    let thread_id = thread.id().clone();
    let turn = thread
        .start_turn(
            vec![CodexInput::text("Reply with OK.")],
            TurnOptions::default(),
        )
        .await
        .expect("materialize movable thread");
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
    assert!(
        reached_terminal,
        "movable turn did not reach terminal state"
    );
    turn.close().await.expect("release active turn");
    codex
        .move_thread_to_section(&thread_id, Some(&section.id), None)
        .await
        .expect("move into section");
    codex
        .move_thread_to_section(&thread_id, None, None)
        .await
        .expect("move out of section");
    thread.close().await.expect("release thread");
    codex
        .client()
        .request("thread/delete", json!({"threadId": thread_id.as_str()}))
        .await
        .expect("delete movable thread");
    codex
        .delete_section(&section.id)
        .await
        .expect("delete section");
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
