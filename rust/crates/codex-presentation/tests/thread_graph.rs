use std::collections::BTreeMap;

use codex_app_server_state::{
    CanonicalItem, CanonicalState, CanonicalThread, CanonicalTurn, ItemId, ItemKey,
    ItemLiveOverlay, LifecycleStatus, StateCoverage, StateRevision, ThreadId, ThreadStatus, TurnId,
};
use codex_presentation::{
    CollabAction, CollabActionStatus, CollabAgentLifecycle, ThreadGraphKey, ThreadGraphProjector,
};
use serde_json::{Value, json};

#[test]
fn nested_graph_reconciles_metadata_and_collaboration_out_of_order() {
    let mut child = thread("child", Some("middle"), false);
    child.metadata.insert(
        "source".to_owned(),
        json!({
            "subagent": {
                "thread_spawn": {
                    "parent_thread_id": "middle",
                    "depth": 2,
                    "agent_path": "/root/middle/child",
                    "agent_nickname": "Parfit",
                    "agent_role": "researcher"
                }
            }
        }),
    );
    let mut middle = thread("middle", Some("root"), true);
    middle
        .metadata
        .insert("agentNickname".to_owned(), json!("Galileo"));
    let state = fixture(
        &["child", "root", "middle"],
        vec![child, thread("root", None, true), middle],
        vec![
            collab_item(
                "root",
                "turn-root",
                "spawn-middle",
                &["middle"],
                "spawnAgent",
                "completed",
                &[("middle", "running", None)],
            ),
            collab_item(
                "middle",
                "turn-middle",
                "spawn-child",
                &["child"],
                "spawnAgent",
                "completed",
                &[("child", "pendingInit", Some("booting"))],
            ),
        ],
    );

    let graph = ThreadGraphProjector::project(&state, "host");
    let root = key("root");
    let middle = key("middle");
    let child = key("child");
    assert_eq!(graph.roots, vec![root.clone()]);
    assert_eq!(graph.nodes[&root].children, vec![middle.clone()]);
    assert_eq!(graph.nodes[&middle].children, vec![child.clone()]);
    assert_eq!(graph.nodes[&child].depth, Some(2));
    assert_eq!(
        graph.nodes[&child].lifecycle,
        Some(CollabAgentLifecycle::PendingInit)
    );
    assert_eq!(
        graph.nodes[&middle].agent_nickname.as_deref(),
        Some("Galileo")
    );
    assert_eq!(
        graph.nodes[&child].agent_nickname.as_deref(),
        Some("Parfit")
    );
    assert_eq!(
        graph.nodes[&child].agent_path.as_deref(),
        Some("/root/middle/child")
    );
    assert_eq!(graph.descendants(&root), vec![middle, child]);
}

#[test]
fn every_lifecycle_and_message_remains_exact() {
    let states = [
        "pendingInit",
        "running",
        "completed",
        "interrupted",
        "shutdown",
        "errored",
        "notFound",
        "futureState",
    ];
    let items = states
        .iter()
        .enumerate()
        .map(|(index, lifecycle)| {
            let child = format!("child-{index}");
            collab_item(
                "parent",
                "turn",
                &format!("item-{index}"),
                &[&child],
                "spawnAgent",
                if index == 5 { "failed" } else { "completed" },
                &[(&child, lifecycle, Some(&format!("message-{index}")))],
            )
        })
        .collect();
    let graph = ThreadGraphProjector::project(
        &fixture(&["parent"], vec![thread("parent", None, true)], items),
        "host",
    );

    assert_eq!(
        graph.nodes[&key("child-0")].lifecycle,
        Some(CollabAgentLifecycle::PendingInit)
    );
    assert_eq!(
        graph.nodes[&key("child-1")].lifecycle,
        Some(CollabAgentLifecycle::Running)
    );
    assert_eq!(
        graph.nodes[&key("child-2")].result_message.as_deref(),
        Some("message-2")
    );
    assert_eq!(
        graph.nodes[&key("child-3")].lifecycle,
        Some(CollabAgentLifecycle::Interrupted)
    );
    assert_eq!(
        graph.nodes[&key("child-4")].lifecycle,
        Some(CollabAgentLifecycle::Shutdown)
    );
    assert_eq!(
        graph.nodes[&key("child-5")].error_message.as_deref(),
        Some("message-5")
    );
    assert_eq!(
        graph.nodes[&key("child-6")].lifecycle,
        Some(CollabAgentLifecycle::NotFound)
    );
    assert_eq!(
        graph.nodes[&key("child-7")].lifecycle,
        Some(CollabAgentLifecycle::Unknown("futureState".to_owned()))
    );
}

#[test]
fn stable_action_identity_preserves_exact_receiver_ids_and_future_values() {
    let receivers = [
        "child::019f670d-ce61-7cb2-a1eb-3b9bc5256026",
        "child::019f670d-ce61-7cb2-a1eb-3b9bc5256026",
    ];
    let started = collab_item(
        "parent",
        "turn",
        "call",
        &receivers,
        "futureAgentTool",
        "futureCallState",
        &[(receivers[0], "pendingInit", None)],
    );
    let completed = collab_item(
        "parent",
        "turn",
        "call",
        &receivers,
        "spawnAgent",
        "completed",
        &[(receivers[0], "completed", Some("done"))],
    );
    let first = ThreadGraphProjector::project(
        &fixture(
            &["parent"],
            vec![thread("parent", None, true)],
            vec![started],
        ),
        "host",
    );
    let second = ThreadGraphProjector::project(
        &fixture(
            &["parent"],
            vec![thread("parent", None, true)],
            vec![completed],
        ),
        "host",
    );

    assert_eq!(first.actions[0].source_item, second.actions[0].source_item);
    assert_eq!(
        first.actions[0].action,
        CollabAction::Unknown("futureAgentTool".to_owned())
    );
    assert_eq!(first.actions[0].action.as_raw(), "futureAgentTool");
    assert_eq!(
        first.actions[0].status,
        CollabActionStatus::Unknown("futureCallState".to_owned())
    );
    assert_eq!(first.actions[0].status.as_raw(), "futureCallState");
    assert_eq!(first.actions[0].receivers.len(), 2);
    assert_eq!(
        first.actions[0].receivers[0].thread_id.as_str(),
        receivers[0]
    );
    assert_eq!(first.actions[0].receivers[0], first.actions[0].receivers[1]);
    assert_eq!(first.nodes[&key(receivers[0])].parent, Some(key("parent")));
    assert_eq!(
        first.nodes[&key("parent")].children,
        vec![key(receivers[0])]
    );
    assert_eq!(second.actions[0].status, CollabActionStatus::Completed);
}

#[test]
fn activity_creates_partial_child_before_thread_hydration() {
    let child_id = "agent/path::019f670d-ce61-7cb2-a1eb-3b9bc5256026";
    let item = canonical_item(
        "parent",
        "turn",
        "activity",
        "subAgentActivity",
        LifecycleStatus::Completed,
        json!({
            "type": "subAgentActivity",
            "id": "activity",
            "agentThreadId": child_id,
            "agentPath": "/root/extra_subagent_4",
            "kind": "started"
        }),
    );
    let graph = ThreadGraphProjector::project(
        &fixture(&["parent"], vec![thread("parent", None, true)], vec![item]),
        "host",
    );
    let child = key(child_id);

    assert_eq!(graph.nodes[&child].parent, Some(key("parent")));
    assert_eq!(
        graph.nodes[&child].lifecycle,
        Some(CollabAgentLifecycle::Running)
    );
    assert_eq!(
        graph.nodes[&child].agent_path.as_deref(),
        Some("/root/extra_subagent_4")
    );
    assert!(!graph.nodes[&child].is_loaded);
}

#[test]
fn rollout_storage_path_never_becomes_logical_agent_path() {
    let child_id = "child::exact";
    let mut child = thread(child_id, None, true);
    child.metadata.extend(BTreeMap::from([
        (
            "path".to_owned(),
            json!("/Users/test/.codex/sessions/rollout-child.jsonl"),
        ),
        ("agentNickname".to_owned(), json!("Direct Name")),
        (
            "source".to_owned(),
            json!({
                "subAgent": {
                    "threadSpawn": {
                        "parentThreadId": "parent",
                        "depth": 1,
                        "agentPath": "/root/extra_subagent_4",
                        "agentNickname": "Nested Name",
                        "agentRole": "reviewer"
                    }
                }
            }),
        ),
    ]));
    let graph = ThreadGraphProjector::project(
        &fixture(
            &["parent", child_id],
            vec![thread("parent", None, true), child],
            vec![],
        ),
        "host",
    );
    let node = &graph.nodes[&key(child_id)];

    assert_eq!(node.parent, Some(key("parent")));
    assert_eq!(node.agent_nickname.as_deref(), Some("Direct Name"));
    assert_eq!(node.agent_role.as_deref(), Some("reviewer"));
    assert_eq!(node.agent_path.as_deref(), Some("/root/extra_subagent_4"));
    assert_ne!(
        node.agent_path.as_deref(),
        Some("/Users/test/.codex/sessions/rollout-child.jsonl")
    );
}

#[test]
fn close_without_agent_state_projects_shutdown() {
    let graph = ThreadGraphProjector::project(
        &fixture(
            &["parent"],
            vec![thread("parent", None, true)],
            vec![collab_item(
                "parent",
                "turn",
                "close",
                &["child"],
                "closeAgent",
                "completed",
                &[],
            )],
        ),
        "host",
    );

    assert_eq!(
        graph.nodes[&key("child")].lifecycle,
        Some(CollabAgentLifecycle::Shutdown)
    );
}

#[test]
fn ordering_is_deterministic_when_thread_order_is_partial_or_duplicated() {
    let threads = vec![
        thread("z", Some("root"), true),
        thread("root", None, true),
        thread("a", Some("root"), true),
    ];
    let unique =
        ThreadGraphProjector::project(&fixture(&["root"], threads.clone(), vec![]), "host");
    let duplicated =
        ThreadGraphProjector::project(&fixture(&["root", "root", "root"], threads, vec![]), "host");

    assert_eq!(duplicated, unique);
    assert_eq!(
        unique.nodes[&key("root")].children,
        vec![key("a"), key("z")]
    );
}

#[test]
fn cycles_are_reported_and_traversal_terminates() {
    let graph = ThreadGraphProjector::project(
        &fixture(
            &["a", "b", "c"],
            vec![
                thread("a", Some("c"), true),
                thread("b", Some("a"), true),
                thread("c", Some("b"), true),
            ],
            vec![],
        ),
        "host",
    );

    assert_eq!(graph.cycle_edges.len(), 1);
    let descendants = graph.descendants(&key("a"));
    assert_eq!(descendants.len(), 2);
    assert_eq!(
        descendants
            .into_iter()
            .collect::<std::collections::BTreeSet<_>>(),
        [key("b"), key("c")].into_iter().collect()
    );
}

fn key(id: &str) -> ThreadGraphKey {
    ThreadGraphKey::new("host", ThreadId::from(id))
}

fn thread(id: &str, parent: Option<&str>, loaded: bool) -> CanonicalThread {
    let mut metadata = BTreeMap::new();
    if let Some(parent) = parent {
        metadata.insert("parentThreadId".to_owned(), json!(parent));
    }
    CanonicalThread {
        id: ThreadId::from(id),
        status: if loaded {
            ThreadStatus::Idle
        } else {
            ThreadStatus::NotLoaded
        },
        coverage: if loaded {
            StateCoverage::Full
        } else {
            StateCoverage::NotLoaded
        },
        turn_ids: Vec::new(),
        goal: None,
        metadata,
    }
}

fn fixture(
    thread_order: &[&str],
    threads: Vec<CanonicalThread>,
    items: Vec<CanonicalItem>,
) -> CanonicalState {
    let mut state = CanonicalState {
        revision: StateRevision::new(42),
        thread_order: thread_order.iter().copied().map(ThreadId::from).collect(),
        threads: threads
            .into_iter()
            .map(|thread| (thread.id.clone(), thread))
            .collect(),
        ..CanonicalState::default()
    };
    for item in items {
        let turn_key = item.key.turn_key();
        let turn = state
            .turns
            .entry(turn_key.clone())
            .or_insert_with(|| CanonicalTurn {
                key: turn_key.clone(),
                status: LifecycleStatus::Completed,
                coverage: StateCoverage::Full,
                item_ids: Vec::new(),
                plan: None,
                plan_explanation: None,
                metadata: BTreeMap::new(),
            });
        if !turn.item_ids.contains(&item.key.item_id) {
            turn.item_ids.push(item.key.item_id.clone());
        }
        if let Some(thread) = state.threads.get_mut(&item.key.thread_id)
            && !thread.turn_ids.contains(&item.key.turn_id)
        {
            thread.turn_ids.push(item.key.turn_id.clone());
        }
        state.items.insert(item.key.clone(), item);
    }
    state
}

#[allow(clippy::too_many_arguments)]
fn collab_item(
    parent: &str,
    turn: &str,
    item: &str,
    receivers: &[&str],
    tool: &str,
    status: &str,
    agent_states: &[(&str, &str, Option<&str>)],
) -> CanonicalItem {
    let state_payloads = agent_states
        .iter()
        .map(|(thread_id, lifecycle, message)| {
            (
                (*thread_id).to_owned(),
                json!({
                    "status": lifecycle,
                    "message": message
                }),
            )
        })
        .collect::<serde_json::Map<_, _>>();
    canonical_item(
        parent,
        turn,
        item,
        "collabAgentToolCall",
        LifecycleStatus::from_raw(status),
        json!({
            "type": "collabAgentToolCall",
            "id": item,
            "tool": tool,
            "status": status,
            "senderThreadId": parent,
            "receiverThreadIds": receivers,
            "prompt": "work",
            "model": "gpt",
            "reasoningEffort": "high",
            "agentsStates": state_payloads
        }),
    )
}

fn canonical_item(
    thread: &str,
    turn: &str,
    item: &str,
    kind: &str,
    status: LifecycleStatus,
    payload: Value,
) -> CanonicalItem {
    CanonicalItem {
        key: ItemKey {
            thread_id: ThreadId::from(thread),
            turn_id: TurnId::from(turn),
            item_id: ItemId::from(item),
        },
        kind: kind.to_owned(),
        status,
        coverage: StateCoverage::Full,
        payload: match payload {
            Value::Object(payload) => payload.into_iter().collect(),
            _ => panic!("fixture payload is an object"),
        },
        duration_ms: None,
        error: None,
        live_overlay: ItemLiveOverlay::default(),
        live_fields: BTreeMap::new(),
        content_revision: 0,
    }
}
