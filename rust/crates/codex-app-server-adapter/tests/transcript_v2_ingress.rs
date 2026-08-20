use std::collections::BTreeMap;

use codex_app_server_adapter::{NotificationDisposition, adapt_notification};
use codex_app_server_state::{
    CanonicalStateReducer, ItemId, ItemKey, LifecycleStatus, ThreadId, TurnId,
};
use serde_json::Value;

const ORDERED_DELTAS: &str = include_str!("fixtures/transcript_v2_ordered_deltas.jsonl");

fn key(item_id: &str) -> ItemKey {
    ItemKey {
        thread_id: ThreadId::from("thread"),
        turn_id: TurnId::from("turn"),
        item_id: ItemId::from(item_id),
    }
}

#[test]
fn pinned_notifications_reduce_live_deltas_in_wire_order() {
    let mut reducer = CanonicalStateReducer::default();
    let mut ignored_terminal_delta = false;

    for line in ORDERED_DELTAS.lines() {
        let frame: Value = serde_json::from_str(line).expect("fixture frame is JSON");
        let method = frame["method"].as_str().expect("fixture method");
        let params = frame["params"]
            .as_object()
            .expect("fixture params")
            .iter()
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect::<BTreeMap<_, _>>();
        let NotificationDisposition::Mutations(mutations) =
            adapt_notification(method, &params).expect("pinned fixture validates")
        else {
            panic!("fixture method must have a canonical projection: {method}");
        };
        let revision = reducer.snapshot().revision;
        let batch = reducer.apply(&mutations).expect("fixture mutation reduces");
        if method == "item/commandExecution/outputDelta"
            && params.get("delta") == Some(&Value::String("late".to_owned()))
        {
            ignored_terminal_delta = batch.is_none() && reducer.snapshot().revision == revision;
        }
    }

    let command = &reducer.snapshot().items[&key("command-live")];
    assert_eq!(
        command.live_overlay.command_output.chunks(),
        ["alpha", "-beta"]
    );
    assert_eq!(command.live_overlay.command_output.joined(), "alpha-beta");

    let reasoning = &reducer.snapshot().items[&key("reasoning-live")];
    assert_eq!(
        reasoning.live_overlay.reasoning_summary[&0].chunks(),
        ["first", " second"]
    );
    assert_eq!(
        reasoning.live_overlay.reasoning_summary[&0].joined(),
        "first second"
    );
    assert_eq!(
        reasoning.live_overlay.reasoning_summary[&1].joined(),
        "next"
    );
    assert_eq!(
        reasoning.live_overlay.reasoning_content[&0].chunks(),
        ["detail", " body"]
    );
    assert_eq!(
        reasoning.live_fields["reasoningSummaryPart:0"],
        Value::Bool(true)
    );

    let file = &reducer.snapshot().items[&key("file-live")];
    assert_eq!(
        file.live_overlay.file_change_output.joined(),
        "patch applied"
    );
    assert_eq!(
        file.live_fields["fileChanges"][0]["path"],
        "Sources/App.swift"
    );

    let mcp = &reducer.snapshot().items[&key("mcp-live")];
    assert_eq!(
        mcp.live_overlay.mcp_progress.chunks(),
        ["phase one", " then two"]
    );

    let completed = &reducer.snapshot().items[&key("command-final")];
    assert_eq!(completed.status, LifecycleStatus::Failed);
    assert_eq!(completed.duration_ms, Some(37));
    assert_eq!(
        completed
            .error
            .as_ref()
            .and_then(|value| value["code"].as_str()),
        Some("E_FUTURE")
    );
    assert_eq!(completed.payload["futureField"]["nested"], true);
    assert!(completed.live_overlay.is_empty());
    assert!(completed.live_fields.is_empty());
    assert!(ignored_terminal_delta);
}
