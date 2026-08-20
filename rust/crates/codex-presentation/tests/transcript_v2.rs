use std::collections::BTreeMap;

use codex_app_server_state::{
    CanonicalItem, CanonicalState, CanonicalThread, CanonicalTurn, ItemId, ItemKey,
    ItemLiveOverlay, LifecycleStatus, StateCoverage, StateRevision, SubmissionIntentId, ThreadId,
    ThreadStatus, TurnId, TurnKey,
};
use codex_presentation::{StandardItemPolicy, transcript_v2::*};
use serde_json::{Value, json};

#[test]
fn swift_fixture_preserves_turn_grammar_and_semantic_grouping() {
    let items = vec![
        item(
            "user",
            "userMessage",
            LifecycleStatus::Completed,
            json!({"content": [{"type": "text", "text": "Question"}]}),
        ),
        item(
            "commentary",
            "agentMessage",
            LifecycleStatus::Completed,
            json!({"phase": "commentary", "text": "Checking"}),
        ),
        item(
            "command",
            "commandExecution",
            LifecycleStatus::Completed,
            json!({
                "command": "sed App.swift",
                "commandActions": [{
                    "type": "read", "command": "sed App.swift", "name": "App.swift"
                }],
                "status": "completed",
                "exitCode": 0
            }),
        ),
        item(
            "file",
            "fileChange",
            LifecycleStatus::Completed,
            json!({
                "status": "completed",
                "changes": [{"path": "A.swift", "kind": {"type": "update"}, "diff": "+line"}]
            }),
        ),
        item(
            "dynamic",
            "dynamicToolCall",
            LifecycleStatus::Completed,
            json!({"namespace": "product", "tool": "show", "status": "completed"}),
        ),
        item(
            "review",
            "enteredReviewMode",
            LifecycleStatus::Completed,
            json!({}),
        ),
        item(
            "answer",
            "agentMessage",
            LifecycleStatus::Completed,
            json!({"phase": "final_answer", "text": "Answer"}),
        ),
    ];
    let state = one_turn_state(LifecycleStatus::Completed, items, json!({"durationMs": 20}));

    let projected = TranscriptV2Projector::project(&state, &thread_id(), &StandardItemPolicy);
    let turn = &projected.turns[0];
    assert_eq!(turn.opening_user_message.as_ref().unwrap().text, "Question");
    assert_eq!(turn.final_answer.as_ref().unwrap().text, "Answer");
    assert!(!turn.final_answer.as_ref().unwrap().is_streaming);
    assert_eq!(
        turn.narrative
            .iter()
            .map(NarrativeEntryV2::id)
            .collect::<Vec<_>>(),
        ["commentary", "group-command", "dynamic", "review"]
    );
    let NarrativeEntryV2::WorkGroup(group) = &turn.narrative[1] else {
        panic!("expected work group");
    };
    assert_eq!(group.rows.len(), 2);
    assert_eq!(group.header, "Edited a file, read files");
    assert_eq!(group.status, WorkItemStatusV2::Completed);
    assert_eq!(
        turn.status,
        TurnStatusV2::Done {
            duration_ms: Some(20)
        }
    );
    assert!(turn.work_disclosure.is_visible);
    assert!(!turn.work_disclosure.is_expanded_by_default);
}

#[test]
fn steer_messages_split_chronological_conversation_segments() {
    let items = vec![
        item(
            "user",
            "userMessage",
            LifecycleStatus::Completed,
            json!({"content": [{"type": "text", "text": "Start"}]}),
        ),
        item(
            "before",
            "agentMessage",
            LifecycleStatus::Completed,
            json!({"phase": "commentary", "text": "Before steer"}),
        ),
        item(
            "steer",
            "userMessage",
            LifecycleStatus::Completed,
            json!({"clientId": "steer-client", "content": [{"type": "text", "text": "New direction"}]}),
        ),
        item(
            "command",
            "commandExecution",
            LifecycleStatus::Completed,
            json!({"command": "pwd", "commandActions": [], "status": "completed"}),
        ),
        item(
            "after",
            "agentMessage",
            LifecycleStatus::Completed,
            json!({"phase": "commentary", "text": "After steer"}),
        ),
    ];
    let state = one_turn_state(
        LifecycleStatus::InProgress,
        items,
        json!({"startedAt": 100}),
    );

    let projected = TranscriptV2Projector::project(&state, &thread_id(), &StandardItemPolicy);
    let turn = &projected.turns[0];
    assert_eq!(turn.steered_messages.len(), 1);
    assert_eq!(turn.conversation_segments.len(), 2);
    assert_eq!(turn.conversation_segments[0].id, "turn:initial");
    assert_eq!(turn.conversation_segments[0].narrative[0].id(), "before");
    assert_eq!(turn.conversation_segments[1].id, "turn:steer:steer-client");
    assert_eq!(
        turn.conversation_segments[1]
            .steered_message
            .as_ref()
            .unwrap()
            .text,
        "New direction"
    );
    assert_eq!(
        turn.conversation_segments[1]
            .narrative
            .iter()
            .map(NarrativeEntryV2::id)
            .collect::<Vec<_>>(),
        ["group-command", "after"]
    );
}

#[test]
fn live_overlays_feed_streaming_answer_reasoning_tail_and_command_output() {
    let mut answer = item(
        "answer",
        "agentMessage",
        LifecycleStatus::InProgress,
        json!({"phase": "final_answer", "text": "Hel"}),
    );
    answer.live_overlay = overlay(json!({"agent_message": ["lo"]}));
    let mut reasoning = item(
        "reasoning",
        "reasoning",
        LifecycleStatus::InProgress,
        json!({"summary": []}),
    );
    reasoning.live_overlay = overlay(json!({
        "reasoning_summary": {"0": ["**Evaluating changes**"]}
    }));
    let mut command = item(
        "command",
        "commandExecution",
        LifecycleStatus::InProgress,
        json!({
            "command": "swift test", "commandActions": [],
            "status": "inProgress", "aggregatedOutput": "start\n"
        }),
    );
    command.live_overlay = overlay(json!({"command_output": ["done\n"]}));
    let state = one_turn_state(
        LifecycleStatus::InProgress,
        vec![reasoning, command, answer],
        json!({"startedAt": 10}),
    );

    let projected = TranscriptV2Projector::project(&state, &thread_id(), &StandardItemPolicy);
    let turn = &projected.turns[0];
    assert_eq!(turn.live_tail.as_deref(), Some("**Evaluating changes**"));
    assert_eq!(turn.final_answer.as_ref().unwrap().text, "Hello");
    assert!(turn.final_answer.as_ref().unwrap().is_streaming);
    let NarrativeEntryV2::WorkGroup(group) = &turn.narrative[0] else {
        panic!("expected work group");
    };
    let WorkRowV2::Command(command) = &group.rows[0] else {
        panic!("expected command");
    };
    assert_eq!(
        command.output.as_ref().unwrap().text.as_ref(),
        "start\ndone\n"
    );
    assert!(turn.work_disclosure.is_visible);
    assert!(turn.work_disclosure.is_expanded_by_default);
    assert!(turn.work_disclosure.is_tail_mode);
}

#[test]
fn unphased_assistant_messages_promote_latest_and_demote_previous_to_prose() {
    let state = one_turn_state(
        LifecycleStatus::Completed,
        vec![
            item(
                "first",
                "agentMessage",
                LifecycleStatus::Completed,
                json!({"text": "First candidate"}),
            ),
            item(
                "second",
                "agentMessage",
                LifecycleStatus::Completed,
                json!({"text": "Final candidate"}),
            ),
        ],
        json!({}),
    );

    let projected = TranscriptV2Projector::project(&state, &thread_id(), &StandardItemPolicy);
    let turn = &projected.turns[0];
    assert_eq!(turn.final_answer.as_ref().unwrap().id, "second");
    assert_eq!(turn.final_answer.as_ref().unwrap().text, "Final candidate");
    let NarrativeEntryV2::Prose(previous) = &turn.narrative[0] else {
        panic!("expected demoted prose");
    };
    assert_eq!(previous.id, "first");
}

#[test]
fn optimistic_submission_owns_placeholder_turn_until_echo_reconciles() {
    let placeholder = one_turn_state(
        LifecycleStatus::InProgress,
        Vec::new(),
        json!({"startedAt": 10}),
    );
    let submission = OptimisticSubmissionV2 {
        id: SubmissionIntentId::new("client-message"),
        thread_id: thread_id(),
        expected_turn_id: None,
        input: vec![json!({"type": "text", "text": "hello"})],
        local_ordinal: 0,
        state: OptimisticSubmissionStateV2::Pending,
    };

    let pending = TranscriptV2Projector::project_with_submissions(
        &placeholder,
        &thread_id(),
        &StandardItemPolicy,
        std::slice::from_ref(&submission),
    );
    assert_eq!(pending.turns.len(), 1);
    assert_eq!(pending.turns[0].turn_id.as_str(), "local-client-message");
    assert!(
        pending.turns[0]
            .opening_user_message
            .as_ref()
            .unwrap()
            .is_optimistic
    );

    let echoed = one_turn_state(
        LifecycleStatus::InProgress,
        vec![item(
            "user",
            "userMessage",
            LifecycleStatus::Completed,
            json!({
                "clientId": "client-message",
                "content": [{"type": "text", "text": "hello"}]
            }),
        )],
        json!({"startedAt": 10}),
    );
    let reconciled = TranscriptV2Projector::project_with_submissions(
        &echoed,
        &thread_id(),
        &StandardItemPolicy,
        &[submission],
    );
    assert_eq!(reconciled.turns.len(), 1);
    assert_eq!(reconciled.turns[0].turn_id.as_str(), "turn");
    assert!(
        !reconciled.turns[0]
            .opening_user_message
            .as_ref()
            .unwrap()
            .is_optimistic
    );
}

#[test]
fn terminal_status_retains_duration_failure_and_interruption_metadata() {
    let mut state = CanonicalState {
        revision: StateRevision::new(3),
        ..CanonicalState::default()
    };
    let thread = thread_id();
    let statuses = [
        (
            "done",
            LifecycleStatus::Completed,
            json!({"durationMs": 1200}),
        ),
        (
            "stopped",
            LifecycleStatus::Interrupted,
            json!({"startedAt": 10, "completedAt": 22, "error": {"message": "Stopped by user"}}),
        ),
        (
            "failed",
            LifecycleStatus::Failed,
            json!({"durationMs": 9, "error": {"message": "Backend failed"}}),
        ),
    ];
    let turn_ids = statuses
        .iter()
        .map(|(id, _, _)| TurnId::new(*id))
        .collect::<Vec<_>>();
    state.threads.insert(
        thread.clone(),
        CanonicalThread {
            id: thread.clone(),
            status: ThreadStatus::Idle,
            coverage: StateCoverage::Full,
            turn_ids: turn_ids.clone(),
            goal: None,
            metadata: BTreeMap::new(),
        },
    );
    state.thread_order.push(thread.clone());
    for ((_, status, metadata), turn_id) in statuses.into_iter().zip(turn_ids) {
        let key = TurnKey {
            thread_id: thread.clone(),
            turn_id,
        };
        state.turns.insert(
            key.clone(),
            CanonicalTurn {
                key,
                status,
                coverage: StateCoverage::Full,
                item_ids: Vec::new(),
                plan: None,
                plan_explanation: None,
                metadata: object_map(metadata),
            },
        );
    }

    let projected = TranscriptV2Projector::project(&state, &thread, &StandardItemPolicy);
    assert_eq!(
        projected.turns[0].status,
        TurnStatusV2::Done {
            duration_ms: Some(1_200)
        }
    );
    assert_eq!(
        projected.turns[1].status,
        TurnStatusV2::Interrupted {
            duration_ms: Some(12_000),
            message: "Stopped by user".to_owned()
        }
    );
    assert_eq!(
        projected.turns[2].status,
        TurnStatusV2::Failed {
            duration_ms: Some(9),
            message: "Backend failed".to_owned()
        }
    );
}

#[test]
fn successful_image_generation_is_persistent_media_and_work() {
    let state = one_turn_state(
        LifecycleStatus::Completed,
        vec![item(
            "image",
            "imageGeneration",
            LifecycleStatus::Completed,
            json!({
                "status": "completed",
                "savedPath": "/tmp/generated.png",
                "result": "fallback",
                "revisedPrompt": "Precise workspace",
                "transparentBackground": true
            }),
        )],
        json!({}),
    );

    let projected = TranscriptV2Projector::project(&state, &thread_id(), &StandardItemPolicy);
    let turn = &projected.turns[0];
    assert_eq!(
        turn.generated_images,
        [GeneratedImageV2 {
            id: "image".to_owned(),
            source: "/tmp/generated.png".to_owned(),
            revised_prompt: Some("Precise workspace".to_owned()),
            has_transparent_background: Some(true),
        }]
    );
    assert!(matches!(turn.narrative[0], NarrativeEntryV2::WorkGroup(_)));
}

fn one_turn_state(
    status: LifecycleStatus,
    items: Vec<CanonicalItem>,
    metadata: Value,
) -> CanonicalState {
    let thread = thread_id();
    let turn = TurnId::new("turn");
    let key = TurnKey {
        thread_id: thread.clone(),
        turn_id: turn.clone(),
    };
    CanonicalState {
        revision: StateRevision::new(1),
        thread_order: vec![thread.clone()],
        threads: BTreeMap::from([(
            thread.clone(),
            CanonicalThread {
                id: thread.clone(),
                status: ThreadStatus::Idle,
                coverage: StateCoverage::Full,
                turn_ids: vec![turn.clone()],
                goal: None,
                metadata: BTreeMap::new(),
            },
        )]),
        turns: BTreeMap::from([(
            key.clone(),
            CanonicalTurn {
                key,
                status,
                coverage: StateCoverage::Full,
                item_ids: items.iter().map(|item| item.key.item_id.clone()).collect(),
                plan: None,
                plan_explanation: None,
                metadata: object_map(metadata),
            },
        )]),
        items: items
            .into_iter()
            .map(|item| (item.key.clone(), item))
            .collect(),
    }
}

fn item(id: &str, kind: &str, status: LifecycleStatus, payload: Value) -> CanonicalItem {
    CanonicalItem {
        key: ItemKey {
            thread_id: thread_id(),
            turn_id: TurnId::new("turn"),
            item_id: ItemId::new(id),
        },
        kind: kind.to_owned(),
        status,
        coverage: StateCoverage::Full,
        payload: object_map(payload),
        duration_ms: None,
        error: None,
        live_overlay: ItemLiveOverlay::default(),
        live_fields: BTreeMap::new(),
        content_revision: 0,
    }
}

fn overlay(overrides: Value) -> ItemLiveOverlay {
    let mut value = json!({
        "agent_message": [],
        "plan": [],
        "reasoning_summary": {},
        "reasoning_content": {},
        "command_output": [],
        "file_change_output": [],
        "mcp_progress": []
    });
    let Value::Object(overrides) = overrides else {
        panic!("overlay overrides must be an object");
    };
    value.as_object_mut().unwrap().extend(overrides);
    serde_json::from_value(value).unwrap()
}

fn object_map(value: Value) -> BTreeMap<String, Value> {
    let Value::Object(value) = value else {
        panic!("fixture payload must be an object");
    };
    value.into_iter().collect()
}

fn thread_id() -> ThreadId {
    ThreadId::new("thread")
}
