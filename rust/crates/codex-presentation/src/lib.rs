//! Framework-neutral transcript, activity, and prompt presentation.

use codex_app_server_interaction::{McpElicitationMode, ServerRequestBody, TypedServerRequest};
use codex_app_server_state::{
    CanonicalItem, CanonicalState, ItemKey, LifecycleStatus, StateRevision, ThreadId, TurnId,
};
use serde_json::Value;

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
    },
    Reasoning {
        summary: String,
        detail: Option<String>,
    },
    Activity(ActivityPresentation),
    Command {
        command: String,
        cwd: Option<String>,
        output: Option<String>,
        exit_code: Option<i64>,
    },
    FileChanges {
        changes: Vec<Value>,
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
        "agentMessage" => TranscriptEntry::AssistantMessage {
            text: string(&payload, "text").unwrap_or_default(),
            phase: string(&payload, "phase"),
        },
        "reasoning" => TranscriptEntry::Reasoning {
            summary: string(&payload, "summary")
                .or_else(|| string(&payload, "text"))
                .unwrap_or_default(),
            detail: string(&payload, "content"),
        },
        "commandExecution" => TranscriptEntry::Command {
            command: string(&payload, "command").unwrap_or_default(),
            cwd: string(&payload, "cwd"),
            output: string(&payload, "aggregatedOutput").or_else(|| string(&payload, "output")),
            exit_code: payload.get("exitCode").and_then(Value::as_i64),
        },
        "fileChange" => TranscriptEntry::FileChanges {
            changes: payload
                .get("changes")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default(),
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
    payload
        .get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|part| part.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
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
    pub title: String,
    pub message: Option<String>,
    pub kind: PromptKind,
    pub is_destructive: bool,
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
    match &request.body {
        ServerRequestBody::CommandApproval {
            command, reason, ..
        } => PromptPresentation {
            title: command.clone().unwrap_or_else(|| "Run command".into()),
            message: reason.clone(),
            kind: PromptKind::Command,
            is_destructive: false,
        },
        ServerRequestBody::FileChangeApproval { reason, .. } => PromptPresentation {
            title: "Apply file changes".into(),
            message: reason.clone(),
            kind: PromptKind::FileChange,
            is_destructive: false,
        },
        ServerRequestBody::PermissionsApproval { reason, .. } => PromptPresentation {
            title: "Grant additional permissions".into(),
            message: reason.clone(),
            kind: PromptKind::Permission,
            is_destructive: true,
        },
        ServerRequestBody::UserInput { questions, .. } => PromptPresentation {
            title: questions
                .first()
                .map_or_else(|| "Input required".into(), |q| q.header.clone()),
            message: questions.first().map(|q| q.question.clone()),
            kind: PromptKind::UserInput,
            is_destructive: false,
        },
        ServerRequestBody::McpElicitation {
            server_name,
            message,
            mode,
            ..
        } => PromptPresentation {
            title: format!("{server_name} requests input"),
            message: Some(match mode {
                McpElicitationMode::Url { url, .. } => format!("{message}\n{url}"),
                _ => message.clone(),
            }),
            kind: PromptKind::Mcp,
            is_destructive: false,
        },
        ServerRequestBody::LegacyExecApproval { reason, .. }
        | ServerRequestBody::LegacyPatchApproval { reason, .. } => PromptPresentation {
            title: "Legacy approval".into(),
            message: reason.clone(),
            kind: PromptKind::Legacy,
            is_destructive: false,
        },
        ServerRequestBody::DynamicToolCall { tool, .. } => PromptPresentation {
            title: humanize(tool),
            message: None,
            kind: PromptKind::Unknown,
            is_destructive: false,
        },
        ServerRequestBody::TokenRefresh { .. }
        | ServerRequestBody::Attestation
        | ServerRequestBody::CurrentTime { .. } => PromptPresentation {
            title: "Host action required".into(),
            message: None,
            kind: PromptKind::Unknown,
            is_destructive: false,
        },
        ServerRequestBody::Unknown { method, .. } => PromptPresentation {
            title: humanize(method),
            message: None,
            kind: PromptKind::Unknown,
            is_destructive: false,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use codex_app_server_state::{
        CanonicalItem, CanonicalMutation, CanonicalStateReducer, StateCoverage,
    };
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
    fn humanizes_tool_names() {
        assert_eq!(humanize("create_issue"), "Create issue");
        assert_eq!(humanize("webSearch"), "Web search");
    }
}
