//! Framework-neutral transcript, activity, and prompt presentation.

mod collaboration_graph;
mod goal;
mod markdown;
pub mod transcript_v2;

pub use collaboration_graph::{
    CollabAction, CollabActionStatus, CollabAgentLifecycle, CollabAgentState, ThreadGraphAction,
    ThreadGraphEdge, ThreadGraphEdgeSource, ThreadGraphKey, ThreadGraphKind, ThreadGraphNode,
    ThreadGraphProjector, ThreadGraphSnapshot,
};
pub use goal::{GoalLifecycleAction, GoalPresentation, GoalStatusTone, project_goal};
pub use markdown::{
    MarkdownAlignment, MarkdownBlock, MarkdownDocument, MarkdownLink, MarkdownNode,
    MarkdownQuoteKind,
};

use std::sync::Arc;

pub use codex_app_server_client::ServerRequestKey;
use codex_app_server_interaction::{McpElicitationMode, ServerRequestBody, TypedServerRequest};
use codex_app_server_sdk::{
    AccountKind, AccountSnapshot, LoginChallenge, ModelPage, QueuePage, ThreadPage, ThreadSummary,
};
use codex_app_server_state::{
    CanonicalItem, CanonicalState, ItemKey, LifecycleStatus, PlanStepStatus, StateRevision,
    ThreadId, TurnId,
};
use serde_json::Value;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AuthenticationPresentation {
    SignedOut {
        requires_openai_auth: bool,
    },
    Authenticated {
        label: String,
    },
    BrowserChallenge {
        login_id: String,
        url: String,
    },
    DeviceChallenge {
        login_id: String,
        user_code: String,
        verification_url: String,
    },
    Failed {
        message: String,
    },
}

#[must_use]
pub fn project_account(account: &AccountSnapshot) -> AuthenticationPresentation {
    let Some(account) = &account.account else {
        return AuthenticationPresentation::SignedOut {
            requires_openai_auth: account.requires_openai_auth,
        };
    };
    AuthenticationPresentation::Authenticated {
        label: match account {
            AccountKind::ApiKey => "API key".to_owned(),
            AccountKind::ChatGpt { email, plan_type } => email
                .as_ref()
                .map_or_else(|| format!("ChatGPT · {plan_type}"), Clone::clone),
            AccountKind::AmazonBedrock { .. } => "Amazon Bedrock".to_owned(),
        },
    }
}

#[must_use]
pub fn project_login_challenge(challenge: LoginChallenge) -> AuthenticationPresentation {
    match challenge {
        LoginChallenge::Complete => AuthenticationPresentation::Authenticated {
            label: "Authenticated".to_owned(),
        },
        LoginChallenge::Browser { login_id, auth_url } => {
            AuthenticationPresentation::BrowserChallenge {
                login_id,
                url: auth_url,
            }
        }
        LoginChallenge::DeviceCode {
            login_id,
            user_code,
            verification_url,
        } => AuthenticationPresentation::DeviceChallenge {
            login_id,
            user_code,
            verification_url,
        },
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct QueuePresentation {
    pub rows: Vec<QueueRowPresentation>,
    pub next_cursor: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct QueueRowPresentation {
    pub id: String,
    pub text: String,
}

#[must_use]
pub fn project_queue(page: &QueuePage) -> QueuePresentation {
    QueuePresentation {
        rows: page
            .data
            .iter()
            .map(|submission| QueueRowPresentation {
                id: submission.id.clone(),
                text: queue_input_text(&submission.input),
            })
            .collect(),
        next_cursor: page.next_cursor.clone(),
    }
}

fn queue_input_text(input: &[Value]) -> String {
    let parts = input
        .iter()
        .map(|value| match value.get("type").and_then(Value::as_str) {
            Some("text") => value
                .get("text")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            Some(kind) => format!("[{kind}]"),
            None => "[input]".to_owned(),
        })
        .collect::<Vec<_>>();
    truncate_text(&parts.join(" "), 240)
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelPickerPresentation {
    pub models: Vec<ModelChoicePresentation>,
    pub selected_model: String,
    pub selected_effort: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelChoicePresentation {
    pub model: String,
    pub display_name: String,
    pub description: String,
    pub is_default: bool,
    pub default_effort: String,
    pub efforts: Vec<ReasoningEffortPresentation>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReasoningEffortPresentation {
    pub value: String,
    pub description: String,
}

#[must_use]
pub fn project_model_picker(
    page: &ModelPage,
    selected_model: Option<&str>,
    selected_effort: Option<&str>,
) -> ModelPickerPresentation {
    let selected = selected_model
        .and_then(|selected| page.data.iter().find(|model| model.model == selected))
        .or_else(|| page.data.iter().find(|model| model.is_default))
        .or_else(|| page.data.first());
    let selected_model = selected.map_or_else(String::new, |model| model.model.clone());
    let selected_effort = selected_effort
        .filter(|effort| {
            selected.is_some_and(|model| {
                model
                    .supported_reasoning_efforts
                    .iter()
                    .any(|option| option.value == *effort)
            })
        })
        .map(str::to_owned)
        .or_else(|| selected.map(|model| model.default_reasoning_effort.clone()))
        .unwrap_or_default();
    ModelPickerPresentation {
        models: page
            .data
            .iter()
            .filter(|model| !model.hidden)
            .map(|model| ModelChoicePresentation {
                model: model.model.clone(),
                display_name: model.display_name.clone(),
                description: model.description.clone(),
                is_default: model.is_default,
                default_effort: model.default_reasoning_effort.clone(),
                efforts: model
                    .supported_reasoning_efforts
                    .iter()
                    .map(|effort| ReasoningEffortPresentation {
                        value: effort.value.clone(),
                        description: effort.description.clone(),
                    })
                    .collect(),
            })
            .collect(),
        selected_model,
        selected_effort,
    }
}

/// Disposable stored-thread list projection.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ThreadListPresentation {
    pub rows: Vec<ThreadListRow>,
    pub next_cursor: Option<String>,
    pub backwards_cursor: Option<String>,
}

/// One stable task-navigation row.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ThreadListRow {
    pub thread_id: ThreadId,
    pub title: String,
    pub cwd: String,
    pub updated_at: i64,
    pub status: TaskStatusPresentation,
    pub is_selected: bool,
}

/// Compact task status independent of protocol union evolution.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TaskStatusPresentation {
    NotLoaded,
    Idle,
    Running,
    WaitingOnApproval,
    WaitingOnUserInput,
    Failed,
    Unknown,
}

/// Project a validated SDK thread page for native task navigation.
#[must_use]
pub fn project_thread_list(
    page: &ThreadPage,
    selected: Option<&ThreadId>,
) -> ThreadListPresentation {
    ThreadListPresentation {
        rows: page
            .data
            .iter()
            .map(|thread| project_thread_row(thread, selected))
            .collect(),
        next_cursor: page.next_cursor.clone(),
        backwards_cursor: page.backwards_cursor.clone(),
    }
}

fn project_thread_row(thread: &ThreadSummary, selected: Option<&ThreadId>) -> ThreadListRow {
    let title = thread
        .name
        .as_deref()
        .filter(|name| !name.trim().is_empty())
        .unwrap_or(&thread.preview);
    let title = title.lines().next().unwrap_or_default().trim();
    ThreadListRow {
        thread_id: thread.id.clone(),
        title: if title.is_empty() {
            "Untitled task".to_owned()
        } else {
            truncate_text(title, 120)
        },
        cwd: thread.cwd.to_string_lossy().into_owned(),
        updated_at: thread.updated_at,
        status: project_task_status(&thread.status),
        is_selected: selected == Some(&thread.id),
    }
}

fn project_task_status(status: &Value) -> TaskStatusPresentation {
    match status.get("type").and_then(Value::as_str) {
        Some("notLoaded") => TaskStatusPresentation::NotLoaded,
        Some("idle") => TaskStatusPresentation::Idle,
        Some("systemError") => TaskStatusPresentation::Failed,
        Some("active") => {
            let flags = status
                .get("activeFlags")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>();
            if flags.contains(&"waitingOnApproval") {
                TaskStatusPresentation::WaitingOnApproval
            } else if flags.contains(&"waitingOnUserInput") {
                TaskStatusPresentation::WaitingOnUserInput
            } else {
                TaskStatusPresentation::Running
            }
        }
        Some(_) | None => TaskStatusPresentation::Unknown,
    }
}

fn truncate_text(value: &str, maximum_chars: usize) -> String {
    let Some(index) = value
        .char_indices()
        .nth(maximum_chars)
        .map(|(index, _)| index)
    else {
        return value.to_owned();
    };
    format!("{}…", &value[..index])
}

/// Complete disposable transcript projection for one thread.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TranscriptPresentation {
    /// Source canonical revision.
    pub revision: StateRevision,
    /// Thread identity.
    pub thread_id: ThreadId,
    /// Turns in canonical display order.
    pub turns: Vec<TurnPresentation>,
}

/// One projected turn.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TurnPresentation {
    pub turn_id: TurnId,
    pub status: LifecycleStatus,
    pub entries: Vec<PresentedEntry>,
    pub plan: Option<PlanPresentation>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PlanPresentation {
    pub explanation: Option<String>,
    pub steps: Vec<PlanStepPresentation>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PlanStepPresentation {
    pub step: String,
    pub status: PlanStepStatus,
}

/// Stable transcript element.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PresentedEntry {
    pub key: ItemKey,
    pub status: LifecycleStatus,
    pub content: TranscriptEntry,
}

/// Semantic transcript content independent of a UI framework.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TranscriptEntry {
    UserMessage {
        text: String,
    },
    AssistantMessage {
        text: String,
        phase: Option<String>,
        markdown: MarkdownDocument,
    },
    Reasoning {
        summary: String,
        detail: Option<String>,
    },
    Activity(ActivityPresentation),
    Command {
        command: String,
        cwd: Option<String>,
        output: Option<CommandOutputPresentation>,
        exit_code: Option<i64>,
    },
    FileChanges {
        changes: Vec<FileChangePresentation>,
    },
    ToolCall {
        server: Option<String>,
        tool: String,
        arguments: Value,
        result: Option<Value>,
    },
    Plan {
        value: Value,
    },
    Image {
        path: Option<String>,
        url: Option<String>,
    },
    Notice {
        text: String,
    },
    Unknown {
        kind: String,
        payload: Value,
    },
}

/// One semantic file change with lossless malformed fallback.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FileChangePresentation {
    pub path: String,
    pub destination_path: Option<String>,
    pub kind: FileChangeKind,
    pub diff: Arc<str>,
    pub malformed_raw: Option<Value>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum FileChangeKind {
    Added,
    Deleted,
    Modified,
    Renamed,
    Unknown(String),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CommandOutputPresentation {
    pub text: Arc<str>,
    pub total_bytes: usize,
    pub truncated: bool,
}

/// Compact semantic activity row.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ActivityPresentation {
    pub id: String,
    pub kind: ActivityKind,
    pub label: String,
    pub detail: Option<String>,
}

/// Official-style work categories.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum ActivityKind {
    Read,
    Search,
    List,
    Edit,
    Command,
    Mcp,
    DynamicTool,
    Collaboration,
    Web,
    Other,
}

/// Host override for one canonical item.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ItemPresentationDecision {
    Standard,
    Hidden,
    InlineActivity(ActivityPresentation),
}

/// Product semantic override seam.
pub trait ItemPresentationPolicy: Send + Sync {
    /// Decide how one canonical item should appear.
    fn decide(&self, item: &CanonicalItem) -> ItemPresentationDecision;
}

/// Default policy preserving every item.
pub struct StandardItemPolicy;

impl ItemPresentationPolicy for StandardItemPolicy {
    fn decide(&self, _item: &CanonicalItem) -> ItemPresentationDecision {
        ItemPresentationDecision::Standard
    }
}

/// Deterministic transcript projector.
pub struct TranscriptProjector;

impl TranscriptProjector {
    /// Project one thread from current canonical state.
    #[must_use]
    pub fn project(
        state: &CanonicalState,
        thread_id: &ThreadId,
        policy: &dyn ItemPresentationPolicy,
    ) -> TranscriptPresentation {
        let turns = state
            .threads
            .get(thread_id)
            .map_or_else(Vec::new, |thread| {
                thread
                    .turn_ids
                    .iter()
                    .filter_map(|turn_id| {
                        let key = codex_app_server_state::TurnKey {
                            thread_id: thread_id.clone(),
                            turn_id: turn_id.clone(),
                        };
                        let turn = state.turns.get(&key)?;
                        let entries = turn
                            .item_ids
                            .iter()
                            .filter_map(|item_id| {
                                let key = ItemKey {
                                    thread_id: thread_id.clone(),
                                    turn_id: turn_id.clone(),
                                    item_id: item_id.clone(),
                                };
                                let item = state.items.get(&key)?;
                                match policy.decide(item) {
                                    ItemPresentationDecision::Hidden => None,
                                    ItemPresentationDecision::InlineActivity(activity) => {
                                        Some(PresentedEntry {
                                            key,
                                            status: item.status.clone(),
                                            content: TranscriptEntry::Activity(activity),
                                        })
                                    }
                                    ItemPresentationDecision::Standard => Some(PresentedEntry {
                                        key,
                                        status: item.status.clone(),
                                        content: project_item(item),
                                    }),
                                }
                            })
                            .collect();
                        Some(TurnPresentation {
                            turn_id: turn_id.clone(),
                            status: turn.status.clone(),
                            entries,
                            plan: turn.plan.as_ref().map(|steps| PlanPresentation {
                                explanation: turn.plan_explanation.clone(),
                                steps: steps
                                    .iter()
                                    .map(|step| PlanStepPresentation {
                                        step: step.step.clone(),
                                        status: step.status.clone(),
                                    })
                                    .collect(),
                            }),
                        })
                    })
                    .collect()
            });
        TranscriptPresentation {
            revision: state.revision,
            thread_id: thread_id.clone(),
            turns,
        }
    }
}

fn project_item(item: &CanonicalItem) -> TranscriptEntry {
    let payload = Value::Object(
        item.payload
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect(),
    );
    match item.kind.as_str() {
        "userMessage" => TranscriptEntry::UserMessage {
            text: message_text(&payload),
        },
        "agentMessage" => {
            let text = string(&payload, "text").unwrap_or_default();
            TranscriptEntry::AssistantMessage {
                markdown: MarkdownDocument::parse(&text),
                text,
                phase: string(&payload, "phase"),
            }
        }
        "reasoning" => TranscriptEntry::Reasoning {
            summary: string(&payload, "summary")
                .or_else(|| string(&payload, "text"))
                .unwrap_or_default(),
            detail: string(&payload, "content"),
        },
        "commandExecution" => TranscriptEntry::Command {
            command: string(&payload, "command").unwrap_or_default(),
            cwd: string(&payload, "cwd"),
            output: payload
                .get("aggregatedOutput")
                .or_else(|| payload.get("output"))
                .and_then(Value::as_str)
                .map(project_command_output),
            exit_code: payload.get("exitCode").and_then(Value::as_i64),
        },
        "fileChange" => TranscriptEntry::FileChanges {
            changes: payload
                .get("changes")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(project_file_change)
                .collect(),
        },
        "mcpToolCall" => TranscriptEntry::ToolCall {
            server: string(&payload, "server"),
            tool: string(&payload, "tool").unwrap_or_else(|| "MCP tool".to_owned()),
            arguments: payload.get("arguments").cloned().unwrap_or(Value::Null),
            result: payload.get("result").cloned(),
        },
        "dynamicToolCall" => TranscriptEntry::Activity(activity(
            item,
            ActivityKind::DynamicTool,
            humanize(&string(&payload, "tool").unwrap_or_else(|| "tool".into())),
        )),
        "collabAgentToolCall" => TranscriptEntry::Activity(activity(
            item,
            ActivityKind::Collaboration,
            "Coordinating subagent".to_owned(),
        )),
        "webSearch" => TranscriptEntry::Activity(activity(
            item,
            ActivityKind::Web,
            "Searching the web".to_owned(),
        )),
        "plan" => TranscriptEntry::Plan { value: payload },
        "imageView" => TranscriptEntry::Image {
            path: string(&payload, "path"),
            url: string(&payload, "url"),
        },
        "enteredReviewMode" | "exitedReviewMode" => TranscriptEntry::Notice {
            text: humanize(&item.kind),
        },
        kind => TranscriptEntry::Unknown {
            kind: kind.to_owned(),
            payload,
        },
    }
}

fn project_command_output(output: &str) -> CommandOutputPresentation {
    const MAXIMUM_OUTPUT_BYTES: usize = 256 * 1_024;
    let mut end = output.len().min(MAXIMUM_OUTPUT_BYTES);
    while !output.is_char_boundary(end) {
        end -= 1;
    }
    CommandOutputPresentation {
        text: Arc::from(&output[..end]),
        total_bytes: output.len(),
        truncated: end < output.len(),
    }
}

fn project_file_change(value: &Value) -> Option<FileChangePresentation> {
    let object = value.as_object()?;
    let path = object.get("path")?.as_str()?.to_owned();
    if path.is_empty() {
        return None;
    }
    let kind_object = object.get("kind").and_then(Value::as_object);
    let raw_kind = kind_object
        .and_then(|kind| kind.get("type"))
        .and_then(Value::as_str)
        .or_else(|| object.get("kind").and_then(Value::as_str));
    let destination_path = kind_object
        .and_then(|kind| kind.get("move_path").or_else(|| kind.get("movePath")))
        .and_then(Value::as_str)
        .map(str::to_owned);
    let kind = match (raw_kind, destination_path.is_some()) {
        (Some("add"), _) => FileChangeKind::Added,
        (Some("delete"), _) => FileChangeKind::Deleted,
        (Some("update"), true) => FileChangeKind::Renamed,
        (Some("update"), false) => FileChangeKind::Modified,
        (Some(kind), _) => FileChangeKind::Unknown(kind.to_owned()),
        (None, _) => FileChangeKind::Unknown("unknown".to_owned()),
    };
    let diff = object
        .get("diff")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let malformed = raw_kind.is_none()
        || object.get("diff").is_some_and(|diff| !diff.is_string())
        || kind_object.is_some_and(|kind| {
            kind.get("move_path")
                .or_else(|| kind.get("movePath"))
                .is_some_and(|path| !path.is_string() && !path.is_null())
        });
    Some(FileChangePresentation {
        path,
        destination_path,
        kind,
        diff: Arc::from(diff),
        malformed_raw: malformed.then(|| value.clone()),
    })
}

fn activity(item: &CanonicalItem, kind: ActivityKind, label: String) -> ActivityPresentation {
    ActivityPresentation {
        id: item.key.item_id.as_str().to_owned(),
        kind,
        label,
        detail: item
            .payload
            .get("detail")
            .and_then(Value::as_str)
            .map(str::to_owned),
    }
}

fn message_text(payload: &Value) -> String {
    if let Some(text) = string(payload, "text") {
        return text;
    }
    let parts = payload
        .get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(user_input_part_text)
        .collect::<Vec<_>>();
    parts.join("\n")
}

fn user_input_part_text(part: &Value) -> Option<String> {
    if let Some(text) = part.get("text").and_then(Value::as_str) {
        return Some(text.to_owned());
    }
    let kind = part.get("type").and_then(Value::as_str)?;
    let value = match kind {
        "image" | "localImage" => "📎 image".to_owned(),
        "audio" | "localAudio" => "📎 audio".to_owned(),
        "skill" => part
            .get("name")
            .and_then(Value::as_str)
            .map_or_else(|| "◈ skill".to_owned(), |name| format!("◈ {name}")),
        "mention" => part
            .get("name")
            .and_then(Value::as_str)
            .map_or_else(|| "@mention".to_owned(), |name| format!("@{name}")),
        _ => return None,
    };
    Some(value)
}

fn string(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn humanize(value: &str) -> String {
    let mut output = String::new();
    for (index, character) in value.chars().enumerate() {
        if character == '_' || character == '-' {
            output.push(' ');
        } else if character.is_uppercase() && index > 0 {
            output.push(' ');
            output.extend(character.to_lowercase());
        } else {
            output.push(character);
        }
    }
    let mut chars = output.chars();
    chars.next().map_or(output.clone(), |first| {
        first.to_uppercase().collect::<String>() + chars.as_str()
    })
}

/// Framework-neutral blocking prompt.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PromptPresentation {
    /// Exact epoch-qualified request identity.
    pub key: ServerRequestKey,
    pub title: String,
    pub message: Option<String>,
    pub kind: PromptKind,
    pub is_destructive: bool,
    /// Ordered host-facing actions appropriate for this request family.
    pub actions: Vec<PromptActionPresentation>,
    /// Structured user questions when this prompt requires answers.
    pub user_input: Option<UserInputPresentation>,
    pub mcp_form: Option<McpFormPresentation>,
    pub mcp_url: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct McpFormPresentation {
    pub fields: Vec<McpFieldPresentation>,
    pub unsupported_fields: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct McpFieldPresentation {
    pub name: String,
    pub title: String,
    pub description: Option<String>,
    pub required: bool,
    pub kind: McpFieldKind,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum McpFieldKind {
    Text { secret: bool },
    Number { integer: bool },
    Boolean,
    Choice(Vec<String>),
    Unsupported,
}

/// Structured user-input form independent of a UI framework.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UserInputPresentation {
    pub questions: Vec<UserQuestionPresentation>,
}

/// One projected question and its advertised choices.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UserQuestionPresentation {
    pub id: String,
    pub header: String,
    pub question: String,
    pub is_secret: bool,
    pub is_other_allowed: bool,
    pub options: Vec<UserQuestionOptionPresentation>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UserQuestionOptionPresentation {
    pub label: String,
    pub description: Option<String>,
}

/// One action exposed by a blocking prompt.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PromptActionPresentation {
    /// Stable action identity within the prompt.
    pub id: String,
    pub label: String,
    pub kind: PromptActionKind,
    pub emphasis: PromptActionEmphasis,
}

/// Semantic action routed back to the host.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PromptActionKind {
    Approve,
    Decline,
    Respond,
    OpenUrl,
}

/// Visual and accessibility emphasis independent of a UI framework.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PromptActionEmphasis {
    Primary,
    Secondary,
    Danger,
}

/// Prompt family for host routing.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PromptKind {
    Command,
    FileChange,
    Permission,
    UserInput,
    Mcp,
    Legacy,
    Unknown,
}

/// Project one typed server request into host-facing prompt semantics.
#[must_use]
pub fn project_prompt(request: &TypedServerRequest) -> PromptPresentation {
    let mut prompt = prompt_for_request(request);
    if prompt.is_destructive
        && let Some(approve) = prompt
            .actions
            .iter_mut()
            .find(|action| action.kind == PromptActionKind::Approve)
    {
        approve.emphasis = PromptActionEmphasis::Danger;
    }
    prompt
}

fn prompt_for_request(request: &TypedServerRequest) -> PromptPresentation {
    match &request.body {
        ServerRequestBody::CommandApproval {
            command, reason, ..
        } => approval_prompt(
            request,
            command.clone().unwrap_or_else(|| "Run command".into()),
            reason.clone(),
            PromptKind::Command,
            false,
        ),
        ServerRequestBody::FileChangeApproval { reason, .. } => approval_prompt(
            request,
            "Apply file changes".into(),
            reason.clone(),
            PromptKind::FileChange,
            false,
        ),
        ServerRequestBody::PermissionsApproval { reason, .. } => approval_prompt(
            request,
            "Grant additional permissions".into(),
            reason.clone(),
            PromptKind::Permission,
            true,
        ),
        ServerRequestBody::UserInput { questions, .. } => user_input_prompt(request, questions),
        ServerRequestBody::McpElicitation {
            server_name,
            message,
            mode,
            ..
        } => mcp_prompt(request, server_name, message, mode),
        ServerRequestBody::LegacyExecApproval { reason, .. }
        | ServerRequestBody::LegacyPatchApproval { reason, .. } => approval_prompt(
            request,
            "Legacy approval".into(),
            reason.clone(),
            PromptKind::Legacy,
            false,
        ),
        ServerRequestBody::DynamicToolCall { tool, .. } => prompt(
            request,
            humanize(tool),
            None,
            PromptKind::Unknown,
            false,
            vec![primary_action(
                "respond",
                "Review",
                PromptActionKind::Respond,
            )],
        ),
        ServerRequestBody::TokenRefresh { .. }
        | ServerRequestBody::Attestation
        | ServerRequestBody::CurrentTime { .. } => {
            host_action_prompt(request, "Host action required".into())
        }
        ServerRequestBody::Unknown { method, .. } => host_action_prompt(request, humanize(method)),
    }
}

fn approval_prompt(
    request: &TypedServerRequest,
    title: String,
    message: Option<String>,
    kind: PromptKind,
    is_destructive: bool,
) -> PromptPresentation {
    prompt(
        request,
        title,
        message,
        kind,
        is_destructive,
        approval_actions(),
    )
}

fn user_input_prompt(
    request: &TypedServerRequest,
    questions: &[codex_app_server_interaction::UserQuestion],
) -> PromptPresentation {
    let mut prompt = prompt(
        request,
        questions
            .first()
            .map_or_else(|| "Input required".into(), |q| q.header.clone()),
        questions.first().map(|q| q.question.clone()),
        PromptKind::UserInput,
        false,
        vec![primary_action(
            "respond",
            "Respond",
            PromptActionKind::Respond,
        )],
    );
    prompt.user_input = Some(UserInputPresentation {
        questions: questions
            .iter()
            .map(|question| UserQuestionPresentation {
                id: question.id.clone(),
                header: question.header.clone(),
                question: question.question.clone(),
                is_secret: question.is_secret,
                is_other_allowed: question.is_other_allowed,
                options: question
                    .options
                    .iter()
                    .map(|option| UserQuestionOptionPresentation {
                        label: option.label.clone(),
                        description: option.description.clone(),
                    })
                    .collect(),
            })
            .collect(),
    });
    prompt
}

fn mcp_prompt(
    request: &TypedServerRequest,
    server_name: &str,
    message: &str,
    mode: &McpElicitationMode,
) -> PromptPresentation {
    let is_url = matches!(mode, McpElicitationMode::Url { .. });
    let mut prompt = prompt(
        request,
        format!("{server_name} requests input"),
        Some(match mode {
            McpElicitationMode::Url { url, .. } => format!("{message}\n{url}"),
            _ => message.to_owned(),
        }),
        PromptKind::Mcp,
        false,
        vec![
            primary_action(
                "respond",
                if is_url { "Open link" } else { "Respond" },
                if is_url {
                    PromptActionKind::OpenUrl
                } else {
                    PromptActionKind::Respond
                },
            ),
            secondary_action("decline", "Decline", PromptActionKind::Decline),
        ],
    );
    match mode {
        McpElicitationMode::Form { requested_schema }
        | McpElicitationMode::OpenAiForm { requested_schema } => {
            prompt.mcp_form = Some(project_mcp_form(requested_schema));
        }
        McpElicitationMode::Url { url, .. } => prompt.mcp_url = Some(url.clone()),
    }
    prompt
}

fn host_action_prompt(request: &TypedServerRequest, title: String) -> PromptPresentation {
    prompt(
        request,
        title,
        None,
        PromptKind::Unknown,
        false,
        vec![primary_action(
            "respond",
            "Review",
            PromptActionKind::Respond,
        )],
    )
}

fn prompt(
    request: &TypedServerRequest,
    title: String,
    message: Option<String>,
    kind: PromptKind,
    is_destructive: bool,
    actions: Vec<PromptActionPresentation>,
) -> PromptPresentation {
    PromptPresentation {
        key: request.key.clone(),
        title,
        message,
        kind,
        is_destructive,
        actions,
        user_input: None,
        mcp_form: None,
        mcp_url: None,
    }
}

fn project_mcp_form(schema: &Value) -> McpFormPresentation {
    let required = schema
        .get("required")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect::<std::collections::BTreeSet<_>>();
    let Some(properties) = schema.get("properties").and_then(Value::as_object) else {
        return McpFormPresentation {
            fields: Vec::new(),
            unsupported_fields: vec!["<root>".to_owned()],
        };
    };
    let mut unsupported_fields = Vec::new();
    let fields = properties
        .iter()
        .map(|(name, schema)| {
            let kind = project_mcp_field_kind(schema);
            if kind == McpFieldKind::Unsupported {
                unsupported_fields.push(name.clone());
            }
            McpFieldPresentation {
                name: name.clone(),
                title: schema
                    .get("title")
                    .and_then(Value::as_str)
                    .unwrap_or(name)
                    .to_owned(),
                description: schema
                    .get("description")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                required: required.contains(name.as_str()),
                kind,
            }
        })
        .collect();
    McpFormPresentation {
        fields,
        unsupported_fields,
    }
}

fn project_mcp_field_kind(schema: &Value) -> McpFieldKind {
    if let Some(choices) = schema.get("enum").and_then(Value::as_array) {
        let choices = choices
            .iter()
            .map(Value::as_str)
            .collect::<Option<Vec<_>>>();
        return choices.map_or(McpFieldKind::Unsupported, |choices| {
            McpFieldKind::Choice(choices.into_iter().map(str::to_owned).collect())
        });
    }
    match schema.get("type").and_then(Value::as_str) {
        Some("string") => McpFieldKind::Text {
            secret: schema.get("format").and_then(Value::as_str) == Some("password")
                || schema.get("writeOnly").and_then(Value::as_bool) == Some(true),
        },
        Some("number") => McpFieldKind::Number { integer: false },
        Some("integer") => McpFieldKind::Number { integer: true },
        Some("boolean") => McpFieldKind::Boolean,
        _ => McpFieldKind::Unsupported,
    }
}

fn approval_actions() -> Vec<PromptActionPresentation> {
    vec![
        primary_action("approve", "Approve", PromptActionKind::Approve),
        secondary_action("decline", "Decline", PromptActionKind::Decline),
    ]
}

fn primary_action(id: &str, label: &str, kind: PromptActionKind) -> PromptActionPresentation {
    PromptActionPresentation {
        id: id.to_owned(),
        label: label.to_owned(),
        kind,
        emphasis: PromptActionEmphasis::Primary,
    }
}

fn secondary_action(id: &str, label: &str, kind: PromptActionKind) -> PromptActionPresentation {
    PromptActionPresentation {
        id: id.to_owned(),
        label: label.to_owned(),
        kind,
        emphasis: PromptActionEmphasis::Secondary,
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;
    use codex_app_server_interaction::{InteractionScope, QuestionOption, UserQuestion};
    use codex_app_server_sdk::{ModelSummary, QueuedSubmission, ReasoningEffortSummary};
    use codex_app_server_state::{
        CanonicalItem, CanonicalMutation, CanonicalStateReducer, ItemLiveOverlay, StateCoverage,
    };
    use codex_app_server_wire::JsonRpcId;
    use std::collections::BTreeMap;

    #[test]
    fn transcript_projection_preserves_item_order_and_unknowns() {
        let thread = ThreadId::from("thread");
        let turn = TurnId::from("turn");
        let mut reducer = CanonicalStateReducer::default();
        for (id, kind, payload) in [
            (
                "user",
                "userMessage",
                BTreeMap::from([("text".into(), Value::String("Hello".into()))]),
            ),
            (
                "future",
                "futureItem",
                BTreeMap::from([("value".into(), Value::Bool(true))]),
            ),
        ] {
            reducer
                .apply(&[CanonicalMutation::ItemUpsert(CanonicalItem {
                    key: ItemKey {
                        thread_id: thread.clone(),
                        turn_id: turn.clone(),
                        item_id: id.into(),
                    },
                    kind: kind.into(),
                    status: LifecycleStatus::Completed,
                    coverage: StateCoverage::Full,
                    payload,
                    duration_ms: None,
                    error: None,
                    started_at_ms: None,
                    completed_at_ms: None,
                    live_overlay: ItemLiveOverlay::default(),
                    live_fields: BTreeMap::new(),
                    content_revision: 0,
                })])
                .expect("reduce");
        }
        let projected =
            TranscriptProjector::project(reducer.snapshot(), &thread, &StandardItemPolicy);
        assert!(matches!(
            projected.turns[0].entries[0].content,
            TranscriptEntry::UserMessage { .. }
        ));
        assert!(matches!(
            projected.turns[0].entries[1].content,
            TranscriptEntry::Unknown { .. }
        ));
    }

    #[test]
    fn user_message_projection_keeps_non_text_input_chips_visible() {
        let payload = serde_json::json!({
            "content": [
                {"type": "text", "text": "Review this"},
                {"type": "localImage", "path": "/tmp/diagram.png"},
                {"type": "mention", "name": "src"}
            ]
        });
        assert_eq!(message_text(&payload), "Review this\n📎 image\n@src");
    }

    #[test]
    fn turn_plan_projects_independently_of_item_order() {
        let thread = ThreadId::from("thread");
        let turn = TurnId::from("turn");
        let mut reducer = CanonicalStateReducer::default();
        reducer
            .apply(&[CanonicalMutation::TurnPlanReplace {
                key: codex_app_server_state::TurnKey {
                    thread_id: thread.clone(),
                    turn_id: turn.clone(),
                },
                steps: vec![codex_app_server_state::CanonicalPlanStep {
                    step: "Build".to_owned(),
                    status: PlanStepStatus::InProgress,
                }],
                explanation: Some("Current plan".to_owned()),
            }])
            .expect("plan commit");
        let projected =
            TranscriptProjector::project(reducer.snapshot(), &thread, &StandardItemPolicy);
        let plan = projected.turns[0].plan.as_ref().expect("projected plan");
        assert_eq!(plan.explanation.as_deref(), Some("Current plan"));
        assert_eq!(plan.steps[0].status, PlanStepStatus::InProgress);
    }

    #[test]
    fn humanizes_tool_names() {
        assert_eq!(humanize("create_issue"), "Create issue");
        assert_eq!(humanize("webSearch"), "Web search");
    }

    #[test]
    fn file_change_projection_preserves_move_and_diff_semantics() {
        let change = project_file_change(&serde_json::json!({
            "path": "old.rs",
            "kind": {"type": "update", "move_path": "new.rs"},
            "diff": "@@ -1 +1 @@\n-old\n+new"
        }))
        .expect("file change");
        assert_eq!(change.path, "old.rs");
        assert_eq!(change.destination_path.as_deref(), Some("new.rs"));
        assert_eq!(change.kind, FileChangeKind::Renamed);
        assert!(change.diff.contains("+new"));
        assert!(change.malformed_raw.is_none());
    }

    #[test]
    fn malformed_file_change_remains_visible_and_lossless() {
        let raw = serde_json::json!({
            "path": "file.rs",
            "kind": {"unexpected": true},
            "diff": 7
        });
        let change = project_file_change(&raw).expect("file change");
        assert_eq!(change.kind, FileChangeKind::Unknown("unknown".to_owned()));
        assert_eq!(change.malformed_raw, Some(raw));
    }

    #[test]
    fn command_output_projection_is_bounded_and_utf8_safe() {
        let output = "界".repeat(100_000);
        let projected = project_command_output(&output);
        assert!(projected.truncated);
        assert_eq!(projected.total_bytes, output.len());
        assert!(projected.text.len() <= 256 * 1_024);
        assert!(projected.text.is_char_boundary(projected.text.len()));
    }

    #[test]
    fn destructive_permission_prompt_preserves_identity_and_marks_approval() {
        let request = interaction(ServerRequestBody::PermissionsApproval {
            scope: scope(),
            cwd: "/workspace".to_owned(),
            permissions: Value::Object(serde_json::Map::default()),
            reason: Some("Needs broader access".to_owned()),
            environment_id: None,
        });
        let prompt = project_prompt(&request);
        assert_eq!(prompt.key, request.key);
        assert!(prompt.is_destructive);
        assert_eq!(prompt.actions[0].kind, PromptActionKind::Approve);
        assert_eq!(prompt.actions[0].emphasis, PromptActionEmphasis::Danger);
        assert_eq!(prompt.actions[1].kind, PromptActionKind::Decline);
    }

    #[test]
    fn mcp_url_prompt_routes_open_link_before_any_reply() {
        let request = interaction(ServerRequestBody::McpElicitation {
            scope: scope(),
            server_name: "docs".to_owned(),
            message: "Authenticate".to_owned(),
            mode: McpElicitationMode::Url {
                elicitation_id: "elicitation".to_owned(),
                url: "https://example.com/auth".to_owned(),
            },
            metadata: None,
        });
        let prompt = project_prompt(&request);
        assert_eq!(prompt.actions[0].kind, PromptActionKind::OpenUrl);
        assert_eq!(prompt.actions[1].kind, PromptActionKind::Decline);
        assert_eq!(prompt.mcp_url.as_deref(), Some("https://example.com/auth"));
    }

    #[test]
    fn mcp_form_projects_supported_primitives_and_blocks_nested_objects() {
        let form = project_mcp_form(&serde_json::json!({
            "type": "object",
            "required": ["name", "mode"],
            "properties": {
                "name": {"type": "string", "title": "Name"},
                "count": {"type": "integer"},
                "enabled": {"type": "boolean"},
                "mode": {"type": "string", "enum": ["safe", "fast"]},
                "nested": {"type": "object", "properties": {}}
            }
        }));
        assert!(form.fields.iter().any(|field| field.name == "count"));
        assert!(form.fields.iter().any(|field| {
            field.name == "mode"
                && field.kind == McpFieldKind::Choice(vec!["safe".to_owned(), "fast".to_owned()])
                && field.required
        }));
        assert_eq!(form.unsupported_fields, vec!["nested"]);
    }

    #[test]
    fn user_input_prompt_preserves_every_question_and_option() {
        let request = interaction(ServerRequestBody::UserInput {
            scope: scope(),
            is_blocking: true,
            questions: vec![UserQuestion {
                id: "choice".to_owned(),
                header: "Approach".to_owned(),
                question: "Which approach?".to_owned(),
                is_secret: false,
                is_other_allowed: true,
                options: vec![QuestionOption {
                    label: "Safe".to_owned(),
                    description: Some("Use the conservative path".to_owned()),
                }],
            }],
        });
        let prompt = project_prompt(&request);
        let form = prompt.user_input.expect("user input form");
        assert_eq!(form.questions[0].id, "choice");
        assert_eq!(form.questions[0].options[0].label, "Safe");
        assert!(form.questions[0].is_other_allowed);
        assert_eq!(prompt.actions[0].kind, PromptActionKind::Respond);
    }

    fn interaction(body: ServerRequestBody) -> TypedServerRequest {
        TypedServerRequest {
            key: ServerRequestKey {
                connection_epoch: 9,
                request_id: JsonRpcId::String("request".to_owned()),
            },
            body,
            raw_params: BTreeMap::new(),
        }
    }

    fn scope() -> InteractionScope {
        InteractionScope {
            thread_id: ThreadId::from("thread"),
            turn_id: Some(TurnId::from("turn")),
            item_id: None,
        }
    }

    #[test]
    fn thread_list_prefers_name_and_surfaces_waiting_status() {
        let page = ThreadPage {
            data: vec![ThreadSummary {
                id: ThreadId::from("thread"),
                name: Some("Named task".to_owned()),
                preview: "fallback".to_owned(),
                cwd: PathBuf::from("/workspace"),
                model_provider: "openai".to_owned(),
                created_at: 1,
                updated_at: 2,
                recency_at: Some(3),
                ephemeral: false,
                parent_thread_id: None,
                status: serde_json::json!({
                    "type": "active",
                    "activeFlags": ["waitingOnApproval"]
                }),
                raw: Value::Null,
            }],
            next_cursor: Some("next".to_owned()),
            backwards_cursor: None,
        };
        let projected = project_thread_list(&page, Some(&ThreadId::from("thread")));
        assert_eq!(projected.rows[0].title, "Named task");
        assert_eq!(
            projected.rows[0].status,
            TaskStatusPresentation::WaitingOnApproval
        );
        assert!(projected.rows[0].is_selected);
        assert_eq!(projected.next_cursor.as_deref(), Some("next"));
    }

    #[test]
    fn model_picker_uses_catalog_default_and_validates_effort_selection() {
        let page = ModelPage {
            data: vec![ModelSummary {
                id: "model".to_owned(),
                model: "model".to_owned(),
                display_name: "Model".to_owned(),
                description: "Description".to_owned(),
                is_default: true,
                hidden: false,
                default_reasoning_effort: "medium".to_owned(),
                supported_reasoning_efforts: vec![ReasoningEffortSummary {
                    value: "medium".to_owned(),
                    description: "Balanced".to_owned(),
                }],
                raw: Value::Null,
            }],
            next_cursor: None,
        };
        let projected = project_model_picker(&page, None, Some("unsupported"));
        assert_eq!(projected.selected_model, "model");
        assert_eq!(projected.selected_effort, "medium");
        assert_eq!(projected.models[0].efforts[0].description, "Balanced");
    }

    #[test]
    fn queue_projection_preserves_order_and_summarizes_nontext_inputs() {
        let projected = project_queue(&QueuePage {
            data: vec![QueuedSubmission {
                id: "queued".to_owned(),
                client_user_message_id: "client".to_owned(),
                input: vec![
                    serde_json::json!({"type": "text", "text": "Follow up"}),
                    serde_json::json!({"type": "image", "url": "https://example.com"}),
                ],
            }],
            next_cursor: None,
        });
        assert_eq!(projected.rows[0].id, "queued");
        assert_eq!(projected.rows[0].text, "Follow up [image]");
    }

    #[test]
    fn account_projection_never_exposes_secret_material() {
        assert_eq!(
            project_account(&AccountSnapshot {
                account: Some(AccountKind::ChatGpt {
                    email: Some("user@example.com".to_owned()),
                    plan_type: "pro".to_owned(),
                }),
                requires_openai_auth: true,
            }),
            AuthenticationPresentation::Authenticated {
                label: "user@example.com".to_owned()
            }
        );
        assert_eq!(
            project_account(&AccountSnapshot {
                account: None,
                requires_openai_auth: true,
            }),
            AuthenticationPresentation::SignedOut {
                requires_openai_auth: true
            }
        );
    }
}
