use codex_app_server_state::{
    LifecycleStatus, StateRevision, SubmissionIntentId, ThreadId, TurnId,
};
use serde_json::Value;

use crate::{
    ActivityKind, CommandOutputPresentation, FileChangePresentation, MarkdownDocument,
    PlanPresentation,
};

/// Complete disposable Transcript V2 projection for one canonical thread.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TranscriptV2Presentation {
    /// Source canonical revision.
    pub revision: StateRevision,
    /// Projected thread identity.
    pub thread_id: ThreadId,
    /// Turns in canonical order followed by unresolved local submissions.
    pub turns: Vec<TurnV2Presentation>,
}

/// One user/assistant turn following the Swift Transcript V2 grammar.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TurnV2Presentation {
    pub turn_id: TurnId,
    /// Lossless canonical lifecycle alongside the renderer-oriented status.
    pub canonical_status: LifecycleStatus,
    pub status: TurnStatusV2,
    /// First visible user message for this turn.
    pub opening_user_message: Option<UserMessageV2>,
    /// Additional user messages accepted by `turn/steer`.
    pub steered_messages: Vec<UserMessageV2>,
    /// Work slices in canonical conversation order.
    pub conversation_segments: Vec<ConversationSegmentV2>,
    /// Flattened compatibility view of every segment's narrative.
    pub narrative: Vec<NarrativeEntryV2>,
    /// The promoted assistant answer, separate from collapsible commentary.
    pub final_answer: Option<AssistantTextV2>,
    /// Successful image-generation outputs retained beside the final answer.
    pub generated_images: Vec<GeneratedImageV2>,
    /// The last active model-authored reasoning summary, if any.
    pub live_tail: Option<String>,
    /// Turn-level plan, independent of item ordering.
    pub plan: Option<PlanPresentation>,
    /// Exact default work visibility/expansion behavior.
    pub work_disclosure: TurnWorkDisclosureV2,
}

/// Renderer-oriented turn lifecycle with terminal metadata retained directly.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TurnStatusV2 {
    Working {
        since_unix_seconds: Option<i64>,
    },
    Done {
        duration_ms: Option<u64>,
    },
    Interrupted {
        duration_ms: Option<u64>,
        message: String,
    },
    Failed {
        duration_ms: Option<u64>,
        message: String,
    },
}

/// Swift's work-header disclosure decisions, made outside any UI framework.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct TurnWorkDisclosureV2 {
    /// Whether lifecycle/work chrome belongs between the opening user and answer.
    pub is_visible: bool,
    /// Working turns open automatically; terminal turns start collapsed.
    pub is_expanded_by_default: bool,
    /// A streaming final answer shows only still-running work in its open tail.
    pub is_tail_mode: bool,
}

/// One chronological narrative slice. Later slices begin with a steer message.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationSegmentV2 {
    pub id: String,
    pub steered_message: Option<UserMessageV2>,
    pub narrative: Vec<NarrativeEntryV2>,
}

/// A normalized user input attachment/chip.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UserAttachmentV2 {
    pub kind: String,
    pub label: String,
    pub source: Option<String>,
    /// Exact input part for future kinds and host-specific presentation.
    pub raw: Value,
}

/// One visible canonical or optimistic user message.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UserMessageV2 {
    pub id: String,
    pub client_id: Option<String>,
    pub text: String,
    pub raw_text: String,
    pub attachments: Vec<UserAttachmentV2>,
    pub delegation_source_thread_id: Option<ThreadId>,
    pub is_optimistic: bool,
    pub sent_at_unix_seconds: Option<i64>,
}

impl UserMessageV2 {
    /// User text followed by stable attachment labels.
    #[must_use]
    pub fn display_text(&self) -> String {
        let request = self.text.trim();
        let attachments = self
            .attachments
            .iter()
            .map(|attachment| format!("📎 {}", attachment.label))
            .collect::<Vec<_>>()
            .join("  ");
        [request, attachments.as_str()]
            .into_iter()
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>()
            .join("\n\n")
    }
}

/// Assistant-authored prose with Markdown pre-parsed for native renderers.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AssistantTextV2 {
    pub id: String,
    pub text: String,
    pub is_streaming: bool,
    pub sent_at_unix_seconds: Option<i64>,
    pub markdown: MarkdownDocument,
}

impl AssistantTextV2 {
    pub(crate) fn new(
        id: String,
        text: String,
        is_streaming: bool,
        sent_at_unix_seconds: Option<i64>,
    ) -> Self {
        let markdown = MarkdownDocument::parse(&text);
        Self {
            id,
            text,
            is_streaming,
            sent_at_unix_seconds,
            markdown,
        }
    }
}

/// Persistent media produced by a completed image-generation item.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GeneratedImageV2 {
    pub id: String,
    pub source: String,
    pub revised_prompt: Option<String>,
    pub has_transparent_background: Option<bool>,
}

/// Chronological assistant work content.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum NarrativeEntryV2 {
    Prose(AssistantTextV2),
    WorkGroup(WorkGroupV2),
    ProductToolCall(ProductToolCallV2),
    InlineActivity(InlineActivityV2),
    Notice(NoticeV2),
}

impl NarrativeEntryV2 {
    /// Stable source identity used for in-place replacement.
    #[must_use]
    pub fn id(&self) -> &str {
        match self {
            Self::Prose(value) => &value.id,
            Self::WorkGroup(value) => &value.id,
            Self::ProductToolCall(value) => &value.id,
            Self::InlineActivity(value) => &value.id,
            Self::Notice(value) => &value.id,
        }
    }
}

/// Consecutive command/file/tool activity collapsed behind one semantic row.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkGroupV2 {
    pub id: String,
    /// Stable completed summary in Swift's fixed semantic order.
    pub header: String,
    /// Current activity label used while this group is live.
    pub active_header: Option<String>,
    pub rows: Vec<WorkRowV2>,
    pub is_live: bool,
    pub status: WorkItemStatusV2,
    /// Individual group details always begin collapsed.
    pub is_expanded_by_default: bool,
}

impl WorkGroupV2 {
    /// Header shown by default for the current group lifecycle.
    #[must_use]
    pub fn display_header(&self) -> &str {
        if self.is_live {
            self.active_header.as_deref().unwrap_or(&self.header)
        } else {
            &self.header
        }
    }
}

/// Lossless user-facing lifecycle for one work row.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkItemStatusV2 {
    InProgress,
    Completed,
    Failed,
    Declined,
    Unknown(String),
}

impl WorkItemStatusV2 {
    #[must_use]
    pub const fn is_in_progress(&self) -> bool {
        matches!(self, Self::InProgress)
    }
}

/// Semantic action category used for summaries and icons.
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub enum WorkCategoryV2 {
    Read,
    List,
    Search,
    LoadedTool,
    WebSearch,
    Run,
    Edit,
    Mcp(String),
    CollaborationCreated,
    CollaborationClosed,
    CollaborationWait,
    CollaborationWorked,
    ImageGeneration,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CommandRowV2 {
    pub id: String,
    pub command: String,
    pub label: String,
    pub category: WorkCategoryV2,
    pub status: WorkItemStatusV2,
    pub cwd: Option<String>,
    pub exit_code: Option<i64>,
    pub duration_ms: Option<u64>,
    pub output: Option<CommandOutputPresentation>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FileChangeRowV2 {
    pub id: String,
    pub changes: Vec<FileChangePresentation>,
    pub status: WorkItemStatusV2,
    pub duration_ms: Option<u64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct McpToolCallRowV2 {
    pub id: String,
    pub app_name: String,
    pub server: String,
    pub tool: String,
    pub status: WorkItemStatusV2,
    /// Ordered live progress text, when the MCP call is still running.
    pub progress: Option<String>,
    pub duration_ms: Option<u64>,
    pub error_first_line: Option<String>,
    pub arguments: Option<Value>,
    pub result: Option<Value>,
    pub read_only_hint: Option<bool>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WebSearchRowV2 {
    pub id: String,
    pub query: String,
    pub status: WorkItemStatusV2,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CollaborationActionV2 {
    Created,
    SentInput,
    Waited,
    Closed,
    Started,
    Interacted,
    Interrupted,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AgentDisplayStatusV2 {
    Starting,
    Working,
    Done,
    Failed,
    Closed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CollaborationRowV2 {
    pub id: String,
    pub action: CollaborationActionV2,
    pub agent_names: Vec<String>,
    pub agent_thread_ids: Vec<String>,
    pub instructions: Option<String>,
    pub agent_messages: Vec<(String, String)>,
    pub timeline: Vec<CollaborationActionV2>,
    pub status: WorkItemStatusV2,
    pub display_status: AgentDisplayStatusV2,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OtherWorkRowV2 {
    pub id: String,
    pub label: String,
    pub status: WorkItemStatusV2,
}

/// One typed row inside a work group.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WorkRowV2 {
    Command(CommandRowV2),
    FileChange(FileChangeRowV2),
    McpToolCall(McpToolCallRowV2),
    WebSearch(WebSearchRowV2),
    Collaboration(CollaborationRowV2),
    Other(OtherWorkRowV2),
}

impl WorkRowV2 {
    #[must_use]
    pub fn id(&self) -> &str {
        match self {
            Self::Command(value) => &value.id,
            Self::FileChange(value) => &value.id,
            Self::McpToolCall(value) => &value.id,
            Self::WebSearch(value) => &value.id,
            Self::Collaboration(value) => &value.id,
            Self::Other(value) => &value.id,
        }
    }

    #[must_use]
    pub fn status(&self) -> &WorkItemStatusV2 {
        match self {
            Self::Command(value) => &value.status,
            Self::FileChange(value) => &value.status,
            Self::McpToolCall(value) => &value.status,
            Self::WebSearch(value) => &value.status,
            Self::Collaboration(value) => &value.status,
            Self::Other(value) => &value.status,
        }
    }

    #[must_use]
    pub fn is_in_progress(&self) -> bool {
        self.status().is_in_progress()
    }
}

/// Dynamic/product tool kept outside generic work groups.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProductToolCallV2 {
    pub id: String,
    pub tool: String,
    pub namespace: Option<String>,
    pub arguments: Option<Value>,
    pub status: WorkItemStatusV2,
    pub content_items: Vec<Value>,
    pub success: Option<bool>,
}

/// Host-coalescible compact activity.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InlineActivityV2 {
    pub id: String,
    pub kind: ActivityKind,
    pub label: String,
    pub detail: Option<String>,
    pub image_path: Option<String>,
    pub status: WorkItemStatusV2,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NoticeV2 {
    pub id: String,
    pub message: String,
}

/// UI-local submission intent supplied explicitly because drafts are not canonical state.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OptimisticSubmissionV2 {
    pub id: SubmissionIntentId,
    pub thread_id: ThreadId,
    /// A steer binds to an existing turn; `None` creates a provisional turn.
    pub expected_turn_id: Option<TurnId>,
    pub input: Vec<Value>,
    pub local_ordinal: u64,
    pub state: OptimisticSubmissionStateV2,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum OptimisticSubmissionStateV2 {
    Pending,
    Reconciled,
    Indeterminate(Option<String>),
    Failed(String),
}
