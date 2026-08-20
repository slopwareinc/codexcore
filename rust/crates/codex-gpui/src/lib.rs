//! Embeddable native GPUI views for Codex.
//!
//! The views consume disposable [`codex_presentation`] projections. They do
//! not own an App Server session, Tokio runtime, window, or application
//! lifecycle, so hosts can compose them into an existing GPUI product.

mod auth;
mod composer;
mod goal;
mod markdown;
mod model_picker;
mod prompt;
mod queue;
mod subagent_navigator;
mod thread_list;
mod transcript;
mod transcript_v2;

pub use auth::{CodexAuthentication, LoginEvent};
pub use composer::{ActiveSubmitBehavior, CodexComposer, ComposerEvent, init as init_composer};
pub use goal::{CodexGoal, GoalEvent};
pub use model_picker::{CodexModelPicker, ModelSelectionEvent};
pub use prompt::{CodexPrompt, PromptIntent};
pub use queue::{CodexQueue, QueueEvent};
pub use subagent_navigator::{CodexSubagentNavigator, SubagentSelectionEvent};
pub use thread_list::{CodexThreadList, ThreadListCommand, ThreadSelectionEvent};
pub use transcript::{
    CodexTheme, CodexTranscript, GPUI_REVISION, TranscriptEvent, TranscriptLayoutMetrics,
    TranscriptRow, transcript_rows,
};
pub use transcript_v2::{CodexTranscriptV2, TranscriptV2Row, transcript_v2_rows};
