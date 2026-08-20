//! Swift Transcript V2-equivalent, framework-neutral presentation.

mod model;
mod projector;
mod work_group;

pub use model::{
    AgentDisplayStatusV2, AssistantTextV2, CollaborationActionV2, CollaborationRowV2, CommandRowV2,
    ConversationSegmentV2, FileChangeRowV2, GeneratedImageV2, InlineActivityV2, McpToolCallRowV2,
    NarrativeEntryV2, NoticeV2, OptimisticSubmissionStateV2, OptimisticSubmissionV2,
    OtherWorkRowV2, ProductToolCallV2, TranscriptV2Presentation, TurnStatusV2, TurnV2Presentation,
    TurnWorkDisclosureV2, UserAttachmentV2, UserMessageV2, WebSearchRowV2, WorkCategoryV2,
    WorkGroupV2, WorkItemStatusV2, WorkRowV2,
};
pub use projector::TranscriptV2Projector;
pub use work_group::{active_work_label, synthesize_work_group_header, work_group_status};
