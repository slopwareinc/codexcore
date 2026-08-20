use codex_app_server_state::{ItemId, ItemKey, LifecycleStatus, StateRevision, ThreadId, TurnId};
use codex_gpui::CodexTranscript;
use codex_presentation::{
    CommandOutputPresentation, PresentedEntry, TranscriptEntry, TranscriptPresentation,
    TurnPresentation,
};
use gpui::{App, AppContext, Bounds, WindowBounds, WindowOptions, px, size};
use gpui_platform::application;

fn main() {
    application().run(|cx: &mut App| {
        let bounds = Bounds::centered(None, size(px(920.), px(720.)), cx);
        cx.open_window(
            WindowOptions {
                focus: true,
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                ..Default::default()
            },
            |_, cx| cx.new(|_| CodexTranscript::new(&sample_transcript())),
        )
        .expect("open transcript window");
        cx.activate(true);
    });
}

fn sample_transcript() -> TranscriptPresentation {
    let thread_id = ThreadId::from("demo-thread");
    let turn_id = TurnId::from("demo-turn");
    let entries = vec![
        PresentedEntry {
            key: key(&thread_id, &turn_id, "user"),
            status: LifecycleStatus::Completed,
            content: TranscriptEntry::UserMessage {
                text: "Build a native Codex client with GPUI.".to_owned(),
            },
        },
        PresentedEntry {
            key: key(&thread_id, &turn_id, "assistant"),
            status: LifecycleStatus::InProgress,
            content: TranscriptEntry::AssistantMessage {
                text: "The SDK owns protocol ordering and canonical state. This view consumes a disposable projection and can be embedded in any GPUI host.".to_owned(),
                phase: Some("commentary".to_owned()),
                markdown: codex_presentation::MarkdownDocument::parse(
                    "The SDK owns protocol ordering and canonical state. This view consumes a disposable projection and can be embedded in any GPUI host.",
                ),
            },
        },
        PresentedEntry {
            key: key(&thread_id, &turn_id, "command"),
            status: LifecycleStatus::Completed,
            content: TranscriptEntry::Command {
                command: "cargo test --workspace".to_owned(),
                cwd: Some("/workspace/codexcore".to_owned()),
                output: Some(CommandOutputPresentation {
                    text: "test result: ok".into(),
                    total_bytes: 15,
                    truncated: false,
                }),
                exit_code: Some(0),
            },
        },
    ];
    TranscriptPresentation {
        revision: StateRevision::new(1),
        thread_id,
        turns: vec![TurnPresentation {
            turn_id,
            status: LifecycleStatus::InProgress,
            entries,
            plan: None,
        }],
    }
}

fn key(thread_id: &ThreadId, turn_id: &TurnId, item_id: &str) -> ItemKey {
    ItemKey {
        thread_id: thread_id.clone(),
        turn_id: turn_id.clone(),
        item_id: ItemId::from(item_id),
    }
}
