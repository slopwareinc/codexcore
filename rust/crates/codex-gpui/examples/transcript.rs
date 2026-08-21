use codex_app_server_state::{LifecycleStatus, StateRevision, ThreadId, TurnId};
use codex_gpui::CodexTranscriptV2;
use codex_presentation::{
    MarkdownDocument,
    transcript_v2::{
        AssistantTextV2, CommandRowV2, ConversationSegmentV2, NarrativeEntryV2, NoticeV2,
        TranscriptV2Presentation, TurnStatusV2, TurnV2Presentation, TurnWorkDisclosureV2,
        UserMessageV2, WorkCategoryV2, WorkGroupV2, WorkItemStatusV2, WorkRowV2,
    },
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
            |_, cx| cx.new(|_| CodexTranscriptV2::new(&sample_transcript())),
        )
        .expect("open transcript window");
        cx.activate(true);
    });
}

fn sample_transcript() -> TranscriptV2Presentation {
    let thread_id = ThreadId::from("demo-thread");
    let turn_id = TurnId::from("demo-turn");
    let commentary = AssistantTextV2 {
        id: "commentary".to_owned(),
        text: "I’ll keep the session actor authoritative, then render a disposable Transcript V2 projection.".to_owned(),
        is_streaming: false,
        sent_at_unix_seconds: None,
        markdown: MarkdownDocument::parse(
            "I’ll keep the session actor authoritative, then render a disposable Transcript V2 projection.",
        ),
    };
    let command = CommandRowV2 {
        id: "command".to_owned(),
        command: "cargo test --workspace".to_owned(),
        label: "Run tests".to_owned(),
        category: WorkCategoryV2::Run,
        status: WorkItemStatusV2::Completed,
        cwd: Some("/workspace/codexcore".to_owned()),
        exit_code: Some(0),
        duration_ms: Some(1_240),
        output: Some(codex_presentation::CommandOutputPresentation {
            text: "test result: ok".into(),
            total_bytes: 15,
            truncated: false,
        }),
    };
    let work = WorkGroupV2 {
        id: "work-group".to_owned(),
        header: "Ran a command".to_owned(),
        active_header: None,
        rows: vec![WorkRowV2::Command(command)],
        is_live: false,
        status: WorkItemStatusV2::Completed,
        is_expanded_by_default: false,
    };
    let answer_text = "The native Rust SDK now feeds GPUI through the same ordered, lossless projection boundary as CodexCore’s Transcript V2.";
    TranscriptV2Presentation {
        revision: StateRevision::new(1),
        thread_id,
        turns: vec![TurnV2Presentation {
            turn_id,
            canonical_status: LifecycleStatus::Completed,
            status: TurnStatusV2::Done {
                duration_ms: Some(1_500),
            },
            opening_user_message: Some(UserMessageV2 {
                id: "user".to_owned(),
                client_id: None,
                text: "Build a native Codex client with GPUI.".to_owned(),
                raw_text: "Build a native Codex client with GPUI.".to_owned(),
                attachments: vec![],
                delegation_source_thread_id: None,
                is_optimistic: false,
                sent_at_unix_seconds: None,
            }),
            steered_messages: vec![],
            conversation_segments: vec![ConversationSegmentV2 {
                id: "turn:initial".to_owned(),
                steered_message: None,
                narrative: vec![
                    NarrativeEntryV2::Prose(commentary),
                    NarrativeEntryV2::WorkGroup(work),
                    NarrativeEntryV2::Notice(NoticeV2 {
                        id: "notice".to_owned(),
                        message: "All requested checks passed.".to_owned(),
                    }),
                ],
            }],
            narrative: vec![],
            final_answer: Some(AssistantTextV2 {
                id: "answer".to_owned(),
                text: answer_text.to_owned(),
                is_streaming: false,
                sent_at_unix_seconds: None,
                markdown: MarkdownDocument::parse(answer_text),
            }),
            generated_images: vec![],
            live_tail: None,
            plan: None,
            work_disclosure: TurnWorkDisclosureV2 {
                is_visible: true,
                is_expanded_by_default: false,
                is_tail_mode: false,
            },
        }],
    }
}
