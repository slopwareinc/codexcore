use std::collections::BTreeSet;

use super::{CollaborationActionV2, WorkCategoryV2, WorkItemStatusV2, WorkRowV2};

/// Synthesize Swift's completed work summary in fixed semantic order.
#[must_use]
pub fn synthesize_work_group_header(rows: &[WorkRowV2]) -> String {
    let summary = WorkSummary::from_rows(rows);
    let mut phrases = Vec::new();
    if !summary.mcp_apps.is_empty() {
        phrases.push(format!("used {}", summary.mcp_apps.join(" and ")));
    }
    append_counted(
        &mut phrases,
        summary.loaded_tools,
        "loaded a tool",
        "loaded tools",
    );
    append_counted(
        &mut phrases,
        summary.edited_files,
        "edited a file",
        "edited files",
    );
    if summary.exploration > 0 {
        phrases.push("read files".to_owned());
    }
    append_counted(
        &mut phrases,
        summary.commands,
        "ran a command",
        "ran commands",
    );
    if summary.web_searches > 0 {
        phrases.push("searched the web".to_owned());
    }
    append_counted(
        &mut phrases,
        summary.created_agents,
        "created an agent",
        &format!("created {} agents", summary.created_agents),
    );
    append_counted(
        &mut phrases,
        summary.closed_agents,
        "closed an agent",
        &format!("closed {} agents", summary.closed_agents),
    );
    if summary.waits > 0 {
        phrases.push("working".to_owned());
    }
    append_counted(
        &mut phrases,
        summary.worked_agents,
        "worked with an agent",
        &format!("worked with {} agents", summary.worked_agents),
    );
    append_counted(
        &mut phrases,
        summary.generated_images,
        "generated an image",
        &format!("generated {} images", summary.generated_images),
    );
    let Some(first) = phrases.first_mut() else {
        return String::new();
    };
    uppercase_first(first);
    phrases.join(", ")
}

/// Aggregate work status with Swift's failure/running/declined/unknown precedence.
#[must_use]
pub fn work_group_status(rows: &[WorkRowV2], is_live: bool) -> WorkItemStatusV2 {
    let mut has_in_progress = is_live;
    let mut has_declined = false;
    let mut first_unknown = None;
    for row in rows {
        match row.status() {
            WorkItemStatusV2::Failed => return WorkItemStatusV2::Failed,
            WorkItemStatusV2::InProgress => has_in_progress = true,
            WorkItemStatusV2::Declined => has_declined = true,
            WorkItemStatusV2::Unknown(value) if first_unknown.is_none() => {
                first_unknown = Some(value.clone());
            }
            WorkItemStatusV2::Unknown(_) | WorkItemStatusV2::Completed => {}
        }
    }
    if has_in_progress {
        WorkItemStatusV2::InProgress
    } else if has_declined {
        WorkItemStatusV2::Declined
    } else if let Some(value) = first_unknown {
        WorkItemStatusV2::Unknown(value)
    } else {
        WorkItemStatusV2::Completed
    }
}

/// Label for the last active row in a live group.
#[must_use]
pub fn active_work_label(row: &WorkRowV2) -> String {
    match row {
        WorkRowV2::Command(value) => value.label.clone(),
        WorkRowV2::FileChange(_) => "Editing files".to_owned(),
        WorkRowV2::McpToolCall(value) => format!("Using {}", app_name(value)),
        WorkRowV2::WebSearch(_) => "Searching the web".to_owned(),
        WorkRowV2::Collaboration(value) => match value.action {
            CollaborationActionV2::Created | CollaborationActionV2::Started => {
                "Creating an agent".to_owned()
            }
            CollaborationActionV2::SentInput | CollaborationActionV2::Interacted => {
                "Messaging an agent".to_owned()
            }
            CollaborationActionV2::Waited => "Waiting for agents".to_owned(),
            CollaborationActionV2::Closed => "Closing agents".to_owned(),
            CollaborationActionV2::Interrupted => "Interrupting an agent".to_owned(),
        },
        WorkRowV2::Other(value) => value.label.clone(),
    }
}

fn app_name(value: &super::McpToolCallRowV2) -> &str {
    if value.app_name.is_empty() {
        &value.server
    } else {
        &value.app_name
    }
}

fn append_counted(phrases: &mut Vec<String>, count: usize, singular: &str, plural: &str) {
    match count {
        0 => {}
        1 => phrases.push(singular.to_owned()),
        _ => phrases.push(plural.to_owned()),
    }
}

fn uppercase_first(value: &mut String) {
    let Some(first) = value.chars().next() else {
        return;
    };
    let replacement = first.to_uppercase().collect::<String>();
    value.replace_range(0..first.len_utf8(), &replacement);
}

#[derive(Default)]
struct WorkSummary {
    mcp_apps: Vec<String>,
    loaded_tools: usize,
    edited_files: usize,
    exploration: usize,
    commands: usize,
    web_searches: usize,
    created_agents: usize,
    closed_agents: usize,
    waits: usize,
    worked_agents: usize,
    generated_images: usize,
}

impl WorkSummary {
    fn from_rows(rows: &[WorkRowV2]) -> Self {
        let mut result = Self::default();
        let mut seen_apps = BTreeSet::new();
        for row in rows {
            match row {
                WorkRowV2::Command(value) => match &value.category {
                    WorkCategoryV2::LoadedTool => result.loaded_tools += 1,
                    WorkCategoryV2::Read | WorkCategoryV2::List | WorkCategoryV2::Search => {
                        result.exploration += 1;
                    }
                    WorkCategoryV2::Run => result.commands += 1,
                    WorkCategoryV2::WebSearch => result.web_searches += 1,
                    WorkCategoryV2::Edit => result.edited_files += 1,
                    WorkCategoryV2::Mcp(app) => {
                        push_unique_app(&mut result.mcp_apps, &mut seen_apps, app);
                    }
                    WorkCategoryV2::CollaborationCreated => result.created_agents += 1,
                    WorkCategoryV2::CollaborationClosed => result.closed_agents += 1,
                    WorkCategoryV2::CollaborationWait => result.waits += 1,
                    WorkCategoryV2::CollaborationWorked => result.worked_agents += 1,
                    WorkCategoryV2::ImageGeneration => result.generated_images += 1,
                },
                WorkRowV2::FileChange(value) => {
                    result.edited_files += value.changes.len().max(1);
                }
                WorkRowV2::McpToolCall(value) => {
                    push_unique_app(&mut result.mcp_apps, &mut seen_apps, app_name(value));
                }
                WorkRowV2::WebSearch(_) => result.web_searches += 1,
                WorkRowV2::Collaboration(value) => {
                    let count = value.agent_names.len().max(1);
                    match value.action {
                        CollaborationActionV2::Created => result.created_agents += count,
                        CollaborationActionV2::Closed => result.closed_agents += count,
                        CollaborationActionV2::Waited => result.waits += count,
                        CollaborationActionV2::SentInput
                        | CollaborationActionV2::Started
                        | CollaborationActionV2::Interacted
                        | CollaborationActionV2::Interrupted => result.worked_agents += count,
                    }
                }
                WorkRowV2::Other(value) if value.label == "Generating an image" => {
                    result.generated_images += 1;
                }
                WorkRowV2::Other(_) => {}
            }
        }
        result
    }
}

fn push_unique_app(values: &mut Vec<String>, seen: &mut BTreeSet<String>, value: &str) {
    if seen.insert(value.to_owned()) {
        values.push(value.to_owned());
    }
}
