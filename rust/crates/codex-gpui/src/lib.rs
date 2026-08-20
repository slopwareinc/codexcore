//! Embeddable native GPUI views for Codex.
//!
//! The views consume disposable [`codex_presentation`] projections. They do
//! not own an App Server session, Tokio runtime, window, or application
//! lifecycle, so hosts can compose them into an existing GPUI product.

mod auth;
mod composer;
mod model_picker;
mod prompt;
mod queue;
mod thread_list;
mod transcript;

pub use auth::{CodexAuthentication, LoginEvent};
pub use composer::{ActiveSubmitBehavior, CodexComposer, ComposerEvent, init as init_composer};
pub use model_picker::{CodexModelPicker, ModelSelectionEvent};
pub use prompt::{CodexPrompt, PromptIntent};
pub use queue::{CodexQueue, QueueEvent};
pub use thread_list::{CodexThreadList, ThreadSelectionEvent};
pub use transcript::{CodexTheme, CodexTranscript, GPUI_REVISION, TranscriptRow, transcript_rows};
