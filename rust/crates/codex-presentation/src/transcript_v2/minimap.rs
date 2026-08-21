//! Framework-neutral turn-minimap projection.
//!
//! Mirrors the Swift `CodexTranscriptTurnMinimapProjection` oracle: one entry
//! per projected turn with a short user-facing title and a bounded detail
//! preview used by hover cards and accessibility labels.

use super::model::{
    NarrativeEntryV2, TranscriptV2Presentation, TurnStatusV2, TurnV2Presentation, UserMessageV2,
};

/// Maximum title characters before tail truncation with an ellipsis.
pub const TITLE_PREVIEW_LIMIT: usize = 110;
/// Maximum detail characters before tail truncation with an ellipsis.
pub const DETAIL_PREVIEW_LIMIT: usize = 520;

/// One minimap marker describing a single projected turn.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TurnMinimapEntry {
    /// Canonical turn identity.
    pub turn_id: String,
    /// Short single-line label, usually the opening user prompt.
    pub title: String,
    /// Bounded assistant-side preview for hover cards and accessibility help.
    pub detail: String,
}

/// Project one minimap entry per turn, in canonical order.
///
/// Turns without any displayable row are skipped exactly like the Swift
/// oracle, which requires a target render item to exist.
#[must_use]
pub fn turn_minimap_entries(presentation: &TranscriptV2Presentation) -> Vec<TurnMinimapEntry> {
    presentation
        .turns
        .iter()
        .enumerate()
        .filter(|(_, turn)| turn_has_display_row(turn))
        .map(|(index, turn)| TurnMinimapEntry {
            turn_id: turn.turn_id.to_string(),
            title: preview_text(&turn_title(turn, index), TITLE_PREVIEW_LIMIT, true),
            detail: preview_text(&turn_detail(turn), DETAIL_PREVIEW_LIMIT, false),
        })
        .collect()
}

fn turn_has_display_row(turn: &TurnV2Presentation) -> bool {
    turn.opening_user_message.is_some()
        || !turn.steered_messages.is_empty()
        || !turn.conversation_segments.is_empty()
        || turn.final_answer.is_some()
}

fn turn_title(turn: &TurnV2Presentation, index: usize) -> String {
    if let Some(message) = turn
        .opening_user_message
        .as_ref()
        .map(UserMessageV2::display_text)
        .filter(|text| !text.is_empty())
    {
        return message;
    }
    if let Some(message) = turn
        .steered_messages
        .first()
        .map(UserMessageV2::display_text)
        .filter(|text| !text.is_empty())
    {
        return message;
    }
    format!("Turn {}", index + 1)
}

fn turn_detail(turn: &TurnV2Presentation) -> String {
    if let Some(answer) = turn
        .final_answer
        .as_ref()
        .map(|answer| answer.text.clone())
        .filter(|text| !text.is_empty())
    {
        return answer;
    }
    if let Some(tail) = turn.live_tail.as_ref().filter(|text| !text.is_empty()) {
        return tail.clone();
    }
    latest_assistant_text(turn).unwrap_or_else(|| status_text(&turn.status))
}

/// Latest assistant-authored text scanning segments and narrative in reverse,
/// mirroring `CodexTranscriptTurnMinimapProjection.latestAssistantText`.
fn latest_assistant_text(turn: &TurnV2Presentation) -> Option<String> {
    for segment in turn.conversation_segments.iter().rev() {
        for entry in segment.narrative.iter().rev() {
            match entry {
                NarrativeEntryV2::Prose(prose) if !prose.text.is_empty() => {
                    return Some(prose.text.clone());
                }
                NarrativeEntryV2::Notice(notice) if !notice.message.is_empty() => {
                    return Some(notice.message.clone());
                }
                NarrativeEntryV2::WorkGroup(group) if !group.header.is_empty() => {
                    return Some(group.header.clone());
                }
                NarrativeEntryV2::InlineActivity(activity) if !activity.label.is_empty() => {
                    return Some(activity.label.clone());
                }
                NarrativeEntryV2::Prose(_)
                | NarrativeEntryV2::Notice(_)
                | NarrativeEntryV2::WorkGroup(_)
                | NarrativeEntryV2::InlineActivity(_)
                | NarrativeEntryV2::ProductToolCall(_) => {}
            }
        }
    }
    None
}

/// User-facing status fallback when a turn has no assistant content yet.
#[must_use]
pub fn status_text(status: &TurnStatusV2) -> String {
    match status {
        TurnStatusV2::Working { .. } => "Working…".to_owned(),
        TurnStatusV2::Done { .. } => "Completed".to_owned(),
        TurnStatusV2::Interrupted { duration_ms, .. } => {
            let elapsed = duration_ms
                .map(|duration| format!(" after {}", format_duration(duration)))
                .unwrap_or_default();
            format!("Interrupted{elapsed}")
        }
        TurnStatusV2::Failed { message, .. } => message.clone(),
    }
}

/// Collapse or trim whitespace, then tail-truncate with an ellipsis.
#[must_use]
pub fn preview_text(text: &str, limit: usize, collapses_whitespace: bool) -> String {
    let normalized = if collapses_whitespace {
        text.split_whitespace().collect::<Vec<_>>().join(" ")
    } else {
        text.trim().to_owned()
    };
    if normalized.chars().count() <= limit {
        return normalized;
    }
    let truncated: String = normalized.chars().take(limit).collect();
    format!("{}…", truncated.trim_end())
}

fn format_duration(duration_ms: u64) -> String {
    if duration_ms < 1_000 {
        format!("{duration_ms}ms")
    } else if duration_ms < 60_000 {
        let tenths = duration_ms / 100;
        format!("{}.{:01}s", tenths / 10, tenths % 10)
    } else {
        let minutes = duration_ms / 60_000;
        let seconds = (duration_ms % 60_000) / 1_000;
        format!("{minutes}m {seconds}s")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transcript_v2::WorkItemStatusV2;
    use crate::transcript_v2::{
        AssistantTextV2, ConversationSegmentV2, InlineActivityV2, NoticeV2, UserMessageV2,
        WorkGroupV2,
    };
    use crate::{ActivityKind, MarkdownDocument};
    use codex_app_server_state::{LifecycleStatus, StateRevision, ThreadId, TurnId};

    fn user_message(id: &str, text: &str) -> UserMessageV2 {
        UserMessageV2 {
            id: id.to_owned(),
            client_id: None,
            text: text.to_owned(),
            raw_text: text.to_owned(),
            attachments: Vec::new(),
            delegation_source_thread_id: None,
            is_optimistic: false,
            sent_at_unix_seconds: None,
        }
    }

    fn prose(id: &str, text: &str) -> AssistantTextV2 {
        AssistantTextV2 {
            id: id.to_owned(),
            text: text.to_owned(),
            is_streaming: false,
            sent_at_unix_seconds: None,
            markdown: MarkdownDocument::parse(text),
        }
    }

    fn turn(turn_id: &str, status: TurnStatusV2) -> TurnV2Presentation {
        TurnV2Presentation {
            turn_id: TurnId::from(turn_id),
            canonical_status: LifecycleStatus::Completed,
            status,
            opening_user_message: None,
            steered_messages: Vec::new(),
            conversation_segments: Vec::new(),
            narrative: Vec::new(),
            final_answer: None,
            generated_images: Vec::new(),
            live_tail: None,
            plan: None,
            work_disclosure: TurnWorkDisclosureV2::default(),
        }
    }

    use crate::transcript_v2::TurnWorkDisclosureV2;

    fn presentation(turns: Vec<TurnV2Presentation>) -> TranscriptV2Presentation {
        TranscriptV2Presentation {
            revision: StateRevision::ZERO,
            thread_id: ThreadId::from("thread"),
            turns,
        }
    }

    #[test]
    fn titles_prefer_the_opening_user_message() {
        let mut first = turn("t1", TurnStatusV2::Done { duration_ms: None });
        first.opening_user_message = Some(user_message("m1", "Fix the bug"));
        let mut second = turn("t2", TurnStatusV2::Done { duration_ms: None });
        second.opening_user_message = Some(user_message("m2", "Then add tests"));
        let entries = turn_minimap_entries(&presentation(vec![first, second]));
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].title, "Fix the bug");
        assert_eq!(entries[1].title, "Then add tests");
    }

    #[test]
    fn steered_only_turns_fall_back_to_steered_text_then_ordinal() {
        let mut steered = turn(
            "t1",
            TurnStatusV2::Working {
                since_unix_seconds: None,
            },
        );
        steered.steered_messages = vec![user_message("s1", "Also check docs")];
        let bare = turn("t2", TurnStatusV2::Done { duration_ms: None });
        let entries = turn_minimap_entries(&presentation(vec![steered, bare]));
        assert_eq!(entries[0].title, "Also check docs");
        // A turn with no displayable rows is skipped like the Swift oracle.
        assert_eq!(entries.len(), 1);
    }

    #[test]
    fn details_prefer_final_answer_then_live_tail_then_latest_assistant_text() {
        let mut worked = turn(
            "t1",
            TurnStatusV2::Working {
                since_unix_seconds: None,
            },
        );
        worked.opening_user_message = Some(user_message("m1", "q1"));
        worked.final_answer = Some(prose("a1", "All done."));
        let mut streaming = turn(
            "t2",
            TurnStatusV2::Working {
                since_unix_seconds: None,
            },
        );
        streaming.opening_user_message = Some(user_message("m2", "q2"));
        streaming.live_tail = Some("Thinking about tests".to_owned());
        let mut grouped = turn("t3", TurnStatusV2::Done { duration_ms: None });
        grouped.opening_user_message = Some(user_message("m3", "q3"));
        grouped.conversation_segments = vec![ConversationSegmentV2 {
            id: "s1".to_owned(),
            steered_message: None,
            narrative: vec![
                NarrativeEntryV2::InlineActivity(InlineActivityV2 {
                    id: "act".to_owned(),
                    kind: ActivityKind::Read,
                    label: "Read main.rs".to_owned(),
                    detail: None,
                    image_path: None,
                    status: WorkItemStatusV2::Completed,
                }),
                NarrativeEntryV2::WorkGroup(WorkGroupV2 {
                    id: "g".to_owned(),
                    header: "Ran 2 commands".to_owned(),
                    active_header: None,
                    rows: Vec::new(),
                    is_live: false,
                    status: WorkItemStatusV2::Completed,
                    is_expanded_by_default: false,
                }),
                NarrativeEntryV2::Notice(NoticeV2 {
                    id: "n".to_owned(),
                    message: "Skipped a file".to_owned(),
                }),
            ],
        }];
        let entries = turn_minimap_entries(&presentation(vec![worked, streaming, grouped]));
        assert_eq!(entries[0].detail, "All done.");
        assert_eq!(entries[1].detail, "Thinking about tests");
        // Latest narrative wins over earlier activity/group entries.
        assert_eq!(entries[2].detail, "Skipped a file");
    }

    #[test]
    fn status_falls_back_for_turns_without_assistant_content() {
        let mut working = turn(
            "t1",
            TurnStatusV2::Working {
                since_unix_seconds: None,
            },
        );
        working.opening_user_message = Some(user_message("m1", "q1"));
        let mut interrupted = turn(
            "t2",
            TurnStatusV2::Interrupted {
                duration_ms: Some(4_800),
                message: "user stopped".to_owned(),
            },
        );
        interrupted.opening_user_message = Some(user_message("m2", "q2"));
        let mut failed = turn(
            "t3",
            TurnStatusV2::Failed {
                duration_ms: None,
                message: "server exploded".to_owned(),
            },
        );
        failed.opening_user_message = Some(user_message("m3", "q3"));
        let mut done = turn("t4", TurnStatusV2::Done { duration_ms: None });
        done.opening_user_message = Some(user_message("m4", "q4"));
        let entries = turn_minimap_entries(&presentation(vec![working, interrupted, failed, done]));
        assert_eq!(entries[0].detail, "Working…");
        assert_eq!(entries[1].detail, "Interrupted after 4.8s");
        assert_eq!(entries[2].detail, "server exploded");
        assert_eq!(entries[3].detail, "Completed");
    }

    #[test]
    fn previews_collapse_and_truncate() {
        assert_eq!(
            preview_text("  a\n\n b   c ", 100, true),
            "a b c".to_owned()
        );
        let long = "x".repeat(200);
        let preview = preview_text(&long, 110, true);
        assert_eq!(preview.chars().count(), 111);
        assert!(preview.ends_with('…'));
        let multiline = "line one\nline two";
        assert_eq!(
            preview_text(multiline, 520, false),
            "line one\nline two".to_owned()
        );
    }

    #[test]
    fn empty_transcripts_project_no_entries() {
        assert!(turn_minimap_entries(&presentation(Vec::new())).is_empty());
    }
}
