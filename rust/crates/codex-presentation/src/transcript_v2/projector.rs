use std::collections::{BTreeMap, BTreeSet};

use codex_app_server_state::{
    CanonicalItem, CanonicalState, CanonicalTurn, ItemKey, LifecycleStatus, ThreadId, TurnId,
    TurnKey,
};
use serde_json::{Map, Value};

use crate::{
    ActivityKind, ItemPresentationDecision, ItemPresentationPolicy, PlanPresentation,
    PlanStepPresentation, project_command_output, project_file_change,
};

use super::{
    AgentDisplayStatusV2, AssistantTextV2, CollaborationActionV2, CollaborationRowV2, CommandRowV2,
    ConversationSegmentV2, FileChangeRowV2, GeneratedImageV2, InlineActivityV2, McpToolCallRowV2,
    NarrativeEntryV2, NoticeV2, OptimisticSubmissionStateV2, OptimisticSubmissionV2,
    OtherWorkRowV2, ProductToolCallV2, TranscriptV2Presentation, TurnStatusV2, TurnV2Presentation,
    TurnWorkDisclosureV2, UserAttachmentV2, UserMessageV2, WebSearchRowV2, WorkCategoryV2,
    WorkGroupV2, WorkItemStatusV2, WorkRowV2, active_work_label, synthesize_work_group_header,
    work_group_status,
};

/// Pure canonical-state to Swift Transcript V2-equivalent projection.
pub struct TranscriptV2Projector;

impl TranscriptV2Projector {
    /// Project canonical state without UI-local submission intent.
    #[must_use]
    pub fn project(
        state: &CanonicalState,
        thread_id: &ThreadId,
        policy: &dyn ItemPresentationPolicy,
    ) -> TranscriptV2Presentation {
        Self::project_with_submissions(state, thread_id, policy, &[])
    }

    /// Project canonical state plus explicitly supplied optimistic submissions.
    ///
    /// Canonical state intentionally does not own drafts or delivery UI. Hosts
    /// that retain submission intent can pass it here for Swift-equivalent echo
    /// reconciliation and provisional-turn ordering.
    #[must_use]
    pub fn project_with_submissions(
        state: &CanonicalState,
        thread_id: &ThreadId,
        policy: &dyn ItemPresentationPolicy,
        submissions: &[OptimisticSubmissionV2],
    ) -> TranscriptV2Presentation {
        let mut unresolved = submissions
            .iter()
            .filter(|submission| {
                &submission.thread_id == thread_id
                    && !matches!(submission.state, OptimisticSubmissionStateV2::Reconciled)
            })
            .collect::<Vec<_>>();
        unresolved.sort_by(|left, right| {
            left.local_ordinal
                .cmp(&right.local_ordinal)
                .then_with(|| left.id.cmp(&right.id))
        });

        let echoed = echoed_submission_ids(state, thread_id);
        unresolved.retain(|submission| !echoed.contains(submission.id.as_str()));
        let grouped = group_submissions(&unresolved);
        let order = projected_turn_order(state, thread_id, &unresolved);
        let turns = order
            .into_iter()
            .filter_map(|turn_id| {
                let key = TurnKey {
                    thread_id: thread_id.clone(),
                    turn_id: turn_id.clone(),
                };
                project_turn(
                    state,
                    thread_id,
                    &turn_id,
                    state.turns.get(&key),
                    grouped.get(&key.turn_id).map_or(&[], Vec::as_slice),
                    policy,
                )
            })
            .collect();
        TranscriptV2Presentation {
            revision: state.revision,
            thread_id: thread_id.clone(),
            turns,
        }
    }
}

fn group_submissions<'a>(
    submissions: &[&'a OptimisticSubmissionV2],
) -> BTreeMap<TurnId, Vec<&'a OptimisticSubmissionV2>> {
    let mut result = BTreeMap::new();
    for submission in submissions {
        result
            .entry(
                submission
                    .expected_turn_id
                    .clone()
                    .unwrap_or_else(|| TurnId::new(format!("local-{}", submission.id.as_str()))),
            )
            .or_insert_with(Vec::new)
            .push(*submission);
    }
    result
}

fn echoed_submission_ids(state: &CanonicalState, thread_id: &ThreadId) -> BTreeSet<String> {
    let mut result = BTreeSet::new();
    let Some(thread) = state.threads.get(thread_id) else {
        return result;
    };
    for turn_id in &thread.turn_ids {
        let turn_key = TurnKey {
            thread_id: thread_id.clone(),
            turn_id: turn_id.clone(),
        };
        let Some(turn) = state.turns.get(&turn_key) else {
            continue;
        };
        for item_id in &turn.item_ids {
            let key = ItemKey {
                thread_id: thread_id.clone(),
                turn_id: turn_id.clone(),
                item_id: item_id.clone(),
            };
            let Some(item) = state.items.get(&key) else {
                continue;
            };
            if item.kind == "userMessage"
                && let Some(client_id) = item.payload.get("clientId").and_then(Value::as_str)
            {
                result.insert(client_id.to_owned());
            }
        }
    }
    result
}

fn projected_turn_order(
    state: &CanonicalState,
    thread_id: &ThreadId,
    submissions: &[&OptimisticSubmissionV2],
) -> Vec<TurnId> {
    let mut result = Vec::new();
    let mut seen = BTreeSet::new();
    let has_unbound_submission = submissions
        .iter()
        .any(|submission| submission.expected_turn_id.is_none());
    if let Some(thread) = state.threads.get(thread_id) {
        for turn_id in &thread.turn_ids {
            let key = TurnKey {
                thread_id: thread_id.clone(),
                turn_id: turn_id.clone(),
            };
            let Some(turn) = state.turns.get(&key) else {
                continue;
            };
            if has_unbound_submission
                && !turn.status.is_terminal()
                && !turn_contains_user_message(state, turn)
            {
                continue;
            }
            if seen.insert(turn_id.clone()) {
                result.push(turn_id.clone());
            }
        }
    }
    for submission in submissions {
        let turn_id = submission
            .expected_turn_id
            .clone()
            .unwrap_or_else(|| TurnId::new(format!("local-{}", submission.id.as_str())));
        if seen.insert(turn_id.clone()) {
            result.push(turn_id);
        }
    }
    result
}

fn turn_contains_user_message(state: &CanonicalState, turn: &CanonicalTurn) -> bool {
    turn.item_ids.iter().any(|item_id| {
        state
            .items
            .get(&ItemKey {
                thread_id: turn.key.thread_id.clone(),
                turn_id: turn.key.turn_id.clone(),
                item_id: item_id.clone(),
            })
            .is_some_and(|item| item.kind == "userMessage")
    })
}

#[allow(clippy::too_many_lines)]
fn project_turn(
    state: &CanonicalState,
    thread_id: &ThreadId,
    turn_id: &TurnId,
    canonical: Option<&CanonicalTurn>,
    submissions: &[&OptimisticSubmissionV2],
    policy: &dyn ItemPresentationPolicy,
) -> Option<TurnV2Presentation> {
    if canonical.is_none() && submissions.is_empty() {
        return None;
    }
    let canonical_status = canonical.map_or_else(
        || LifecycleStatus::Unknown("optimistic".to_owned()),
        |turn| turn.status.clone(),
    );
    let mut projected = TurnV2Presentation {
        turn_id: turn_id.clone(),
        canonical_status: canonical_status.clone(),
        status: project_turn_status(canonical, submissions.first().copied()),
        opening_user_message: None,
        steered_messages: Vec::new(),
        conversation_segments: Vec::new(),
        narrative: Vec::new(),
        final_answer: None,
        generated_images: Vec::new(),
        live_tail: None,
        plan: canonical.and_then(project_plan),
        work_disclosure: TurnWorkDisclosureV2::default(),
    };
    let mut active_reasoning = Vec::new();
    let mut segments = Vec::new();
    let mut current_steer = None;
    let mut has_context_compaction = canonical.is_some_and(|turn| {
        turn.metadata
            .get("contextCompacted")
            .and_then(Value::as_bool)
            == Some(true)
    });

    if let Some(turn) = canonical {
        for item_id in &turn.item_ids {
            let key = ItemKey {
                thread_id: thread_id.clone(),
                turn_id: turn_id.clone(),
                item_id: item_id.clone(),
            };
            let Some(item) = state.items.get(&key) else {
                continue;
            };
            let completed = item.status.is_terminal() || turn.status.is_terminal();
            match policy.decide(item) {
                ItemPresentationDecision::Hidden => continue,
                ItemPresentationDecision::InlineActivity(activity) => {
                    append_inline_activity(
                        InlineActivityV2 {
                            id: activity.id,
                            kind: activity.kind,
                            label: activity.label,
                            detail: activity.detail,
                            image_path: None,
                            status: work_status(item, completed),
                        },
                        &mut segments,
                        &mut projected,
                    );
                    continue;
                }
                ItemPresentationDecision::Standard => {}
            }
            match item.kind.as_str() {
                "userMessage" => {
                    let is_opening = projected.opening_user_message.is_none();
                    let sent_at = item_timestamp(item, "startedAt")
                        .or_else(|| is_opening.then(|| canonical_started_at(turn)).flatten());
                    let Some(message) = user_message(item, sent_at) else {
                        continue;
                    };
                    if projected.opening_user_message.is_none() {
                        projected.opening_user_message = Some(message);
                    } else {
                        seal_segment(&mut projected, &mut current_steer, &mut segments, true);
                        projected.steered_messages.push(message.clone());
                        current_steer = Some(message);
                    }
                }
                "agentMessage" => append_agent_message(
                    item,
                    completed,
                    item_timestamp(item, "startedAt").or_else(|| canonical_completed_at(turn)),
                    &mut projected,
                ),
                "plan" => append_plan_item(item, completed, &mut projected),
                "reasoning" if !completed => {
                    let text = reasoning_text(item);
                    active_reasoning.push(if text.is_empty() {
                        "Thinking".to_owned()
                    } else {
                        text
                    });
                }
                "hookPrompt" | "reasoning" => {}
                "dynamicToolCall" => append_product_tool(item, completed, &mut projected),
                "enteredReviewMode" => {
                    append_notice(item_id.as_str(), "Entered review mode", &mut projected);
                }
                "exitedReviewMode" => {
                    append_notice(item_id.as_str(), "Exited review mode", &mut projected);
                }
                "contextCompaction" => has_context_compaction = true,
                "imageView" => {
                    let path = string(item, "path").filter(|path| !path.trim().is_empty());
                    if let Some(path) = path {
                        append_inline_activity(
                            InlineActivityV2 {
                                id: item_id.as_str().to_owned(),
                                kind: ActivityKind::Other,
                                label: "Viewed an image".to_owned(),
                                detail: None,
                                image_path: Some(path),
                                status: work_status(item, completed),
                            },
                            &mut segments,
                            &mut projected,
                        );
                    } else {
                        append_notice(item_id.as_str(), "Viewed an image", &mut projected);
                    }
                }
                "sleep" => append_notice(item_id.as_str(), "Waiting", &mut projected),
                "imageGeneration" => {
                    for row in make_work_rows(item, completed) {
                        append_work_row(row, &mut projected);
                    }
                    if completed
                        && work_status(item, true) == WorkItemStatusV2::Completed
                        && let Some(source) = generated_image_source(item)
                    {
                        upsert_generated_image(
                            GeneratedImageV2 {
                                id: item_id.as_str().to_owned(),
                                source,
                                revised_prompt: string(item, "revisedPrompt"),
                                has_transparent_background: bool_value(
                                    &item.payload,
                                    "transparentBackground",
                                ),
                            },
                            &mut projected.generated_images,
                        );
                    }
                }
                "collabAgentToolCall" => {
                    let status = work_status(item, completed);
                    if string(item, "tool").as_deref() == Some("wait") {
                        reconcile_agent_wait(item, &status, &mut projected.narrative);
                    } else {
                        for row in make_work_rows(item, completed) {
                            append_work_row(row, &mut projected);
                        }
                    }
                }
                "commandExecution" | "fileChange" | "mcpToolCall" | "subAgentActivity"
                | "webSearch" => {
                    for row in make_work_rows(item, completed) {
                        append_work_row(row, &mut projected);
                    }
                }
                _ => append_notice(item_id.as_str(), "Activity", &mut projected),
            }
        }
    }

    if has_context_compaction {
        append_notice(
            &format!("context-compacted-{}", turn_id.as_str()),
            "Compacted context",
            &mut projected,
        );
    }

    let mut remaining = submissions.iter().copied();
    if projected.opening_user_message.is_none()
        && let Some(submission) = remaining.next()
    {
        projected.opening_user_message = Some(optimistic_user_message(submission));
        append_submission_state(submission, &mut projected);
    }
    for submission in remaining {
        seal_segment(&mut projected, &mut current_steer, &mut segments, true);
        let message = optimistic_user_message(submission);
        projected.steered_messages.push(message.clone());
        current_steer = Some(message);
        append_submission_state(submission, &mut projected);
    }
    seal_segment(&mut projected, &mut current_steer, &mut segments, false);
    projected.conversation_segments = segments;
    projected.narrative = projected
        .conversation_segments
        .iter()
        .flat_map(|segment| segment.narrative.iter().cloned())
        .collect();

    if canonical.is_some_and(|turn| turn.status.is_terminal()) {
        finish_turn(&mut projected);
    } else {
        projected.live_tail = active_reasoning.pop();
    }
    projected.work_disclosure = work_disclosure(&projected);
    Some(projected)
}

fn project_plan(turn: &CanonicalTurn) -> Option<PlanPresentation> {
    turn.plan.as_ref().map(|steps| PlanPresentation {
        explanation: turn.plan_explanation.clone(),
        steps: steps
            .iter()
            .map(|step| PlanStepPresentation {
                step: step.step.clone(),
                status: step.status.clone(),
            })
            .collect(),
    })
}

fn project_turn_status(
    turn: Option<&CanonicalTurn>,
    fallback: Option<&OptimisticSubmissionV2>,
) -> TurnStatusV2 {
    if let Some(turn) = turn {
        let duration_ms = turn_duration_ms(turn);
        return match &turn.status {
            LifecycleStatus::Completed => TurnStatusV2::Done { duration_ms },
            LifecycleStatus::Interrupted => TurnStatusV2::Interrupted {
                duration_ms,
                message: turn_error_message(turn).unwrap_or_else(|| "Turn interrupted".to_owned()),
            },
            LifecycleStatus::Failed | LifecycleStatus::Declined => TurnStatusV2::Failed {
                duration_ms,
                message: turn_error_message(turn).unwrap_or_else(|| "Turn failed".to_owned()),
            },
            LifecycleStatus::InProgress | LifecycleStatus::Unknown(_) => TurnStatusV2::Working {
                since_unix_seconds: canonical_started_at(turn),
            },
        };
    }
    match fallback.map(|submission| &submission.state) {
        Some(OptimisticSubmissionStateV2::Failed(message)) => TurnStatusV2::Failed {
            duration_ms: None,
            message: message.clone(),
        },
        _ => TurnStatusV2::Working {
            since_unix_seconds: None,
        },
    }
}

fn user_message(item: &CanonicalItem, sent_at: Option<i64>) -> Option<UserMessageV2> {
    let (raw_text, attachments) = input_text_and_attachments(
        item.payload
            .get("content")
            .and_then(Value::as_array)
            .map_or(&[], Vec::as_slice),
        item.payload.get("text").and_then(Value::as_str),
    );
    if raw_text
        .trim()
        .to_ascii_lowercase()
        .starts_with("<realtime_delegation")
    {
        return None;
    }
    let delegation = decode_delegation(&raw_text);
    Some(UserMessageV2 {
        id: item.key.item_id.as_str().to_owned(),
        client_id: string(item, "clientId"),
        text: delegation
            .as_ref()
            .map_or_else(|| raw_text.clone(), |(_, input)| input.clone()),
        raw_text,
        attachments,
        delegation_source_thread_id: delegation.map(|(source, _)| ThreadId::new(source)),
        is_optimistic: false,
        sent_at_unix_seconds: sent_at,
    })
}

fn optimistic_user_message(submission: &OptimisticSubmissionV2) -> UserMessageV2 {
    let (raw_text, attachments) = input_text_and_attachments(&submission.input, None);
    let delegation = decode_delegation(&raw_text);
    UserMessageV2 {
        id: format!("local-{}", submission.id.as_str()),
        client_id: Some(submission.id.as_str().to_owned()),
        text: delegation
            .as_ref()
            .map_or_else(|| raw_text.clone(), |(_, input)| input.clone()),
        raw_text,
        attachments,
        delegation_source_thread_id: delegation.map(|(source, _)| ThreadId::new(source)),
        is_optimistic: true,
        sent_at_unix_seconds: None,
    }
}

fn input_text_and_attachments(
    input: &[Value],
    fallback_text: Option<&str>,
) -> (String, Vec<UserAttachmentV2>) {
    let mut text = String::new();
    let mut attachments = Vec::new();
    for part in input {
        if let Some(raw) = part.as_str() {
            text.push_str(raw);
            continue;
        }
        let Some(object) = part.as_object() else {
            continue;
        };
        let kind = object
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or("input");
        if kind == "text" {
            if let Some(value) = object
                .get("text")
                .or_else(|| object.get("content"))
                .and_then(Value::as_str)
            {
                text.push_str(value);
            }
            continue;
        }
        let source = object
            .get("path")
            .or_else(|| object.get("url"))
            .and_then(Value::as_str)
            .map(str::to_owned);
        let label = object
            .get("name")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .or_else(|| {
                source
                    .as_deref()
                    .and_then(last_path_component)
                    .map(str::to_owned)
            })
            .unwrap_or_else(|| match kind {
                "image" | "localImage" => "image".to_owned(),
                "audio" | "localAudio" => "audio".to_owned(),
                "skill" => "skill".to_owned(),
                "mention" => "mention".to_owned(),
                _ => kind.to_owned(),
            });
        attachments.push(UserAttachmentV2 {
            kind: kind.to_owned(),
            label,
            source,
            raw: part.clone(),
        });
    }
    if text.is_empty() {
        text.push_str(fallback_text.unwrap_or_default());
    }
    (text, attachments)
}

fn last_path_component(value: &str) -> Option<&str> {
    value
        .trim_end_matches(['/', '\\'])
        .rsplit(['/', '\\'])
        .next()
        .filter(|component| !component.is_empty())
}

fn decode_delegation(text: &str) -> Option<(String, String)> {
    let trimmed = text.trim();
    if !trimmed.starts_with("<codex_delegation>") || !trimmed.ends_with("</codex_delegation>") {
        return None;
    }
    let source = xml_element(trimmed, "source_thread_id")?;
    let input = xml_element(trimmed, "input")?;
    Some((xml_unescape(source.trim()), xml_unescape(input.trim())))
}

fn xml_element<'a>(value: &'a str, name: &str) -> Option<&'a str> {
    let start_tag = format!("<{name}>");
    let end_tag = format!("</{name}>");
    let start = value.find(&start_tag)? + start_tag.len();
    let end = value[start..].find(&end_tag)? + start;
    Some(&value[start..end])
}

fn xml_unescape(value: &str) -> String {
    value
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&")
}

fn append_agent_message(
    item: &CanonicalItem,
    completed: bool,
    sent_at: Option<i64>,
    turn: &mut TurnV2Presentation,
) {
    let mut text = string(item, "text").unwrap_or_default();
    if !completed {
        text.push_str(&item.live_overlay.agent_message.joined());
    }
    let message = AssistantTextV2::new(
        item.key.item_id.as_str().to_owned(),
        text,
        !completed,
        sent_at,
    );
    match string(item, "phase").as_deref() {
        Some("commentary") => {
            close_work_group(turn);
            upsert_narrative(NarrativeEntryV2::Prose(message), turn);
        }
        Some("final_answer") => turn.final_answer = Some(message),
        _ => {
            if let Some(previous) = turn.final_answer.take()
                && previous.id != message.id
            {
                turn.narrative.push(NarrativeEntryV2::Prose(previous));
            }
            turn.final_answer = Some(message);
        }
    }
}

fn append_plan_item(item: &CanonicalItem, completed: bool, turn: &mut TurnV2Presentation) {
    let mut text = string(item, "text").unwrap_or_default();
    if !completed {
        text.push_str(&item.live_overlay.plan.joined());
    }
    if text.is_empty() {
        return;
    }
    close_work_group(turn);
    upsert_narrative(
        NarrativeEntryV2::Prose(AssistantTextV2::new(
            item.key.item_id.as_str().to_owned(),
            text,
            !completed,
            None,
        )),
        turn,
    );
}

fn reasoning_text(item: &CanonicalItem) -> String {
    let mut text = text_value(item.payload.get("summary"));
    for buffer in item.live_overlay.reasoning_summary.values() {
        text.push_str(&buffer.joined());
    }
    text.trim().to_owned()
}

fn text_value(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(value)) => value.clone(),
        Some(Value::Array(values)) => values
            .iter()
            .filter_map(|value| {
                value.as_str().or_else(|| {
                    value
                        .as_object()
                        .and_then(|object| object.get("text"))
                        .and_then(Value::as_str)
                })
            })
            .collect(),
        _ => String::new(),
    }
}

fn append_product_tool(item: &CanonicalItem, completed: bool, turn: &mut TurnV2Presentation) {
    close_work_group(turn);
    let call = ProductToolCallV2 {
        id: item.key.item_id.as_str().to_owned(),
        tool: string(item, "tool").unwrap_or_else(|| "Tool".to_owned()),
        namespace: string(item, "namespace"),
        arguments: item.payload.get("arguments").cloned(),
        status: work_status(item, completed),
        content_items: item
            .payload
            .get("contentItems")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default(),
        success: bool_value(&item.payload, "success"),
    };
    upsert_narrative(NarrativeEntryV2::ProductToolCall(call), turn);
}

fn append_notice(id: &str, message: &str, turn: &mut TurnV2Presentation) {
    close_work_group(turn);
    upsert_narrative(
        NarrativeEntryV2::Notice(NoticeV2 {
            id: id.to_owned(),
            message: message.to_owned(),
        }),
        turn,
    );
}

fn append_inline_activity(
    activity: InlineActivityV2,
    segments: &mut [ConversationSegmentV2],
    turn: &mut TurnV2Presentation,
) {
    close_work_group(turn);
    for segment in segments {
        segment.narrative.retain(|entry| {
            !matches!(entry, NarrativeEntryV2::InlineActivity(existing) if existing.id == activity.id)
        });
    }
    upsert_narrative(NarrativeEntryV2::InlineActivity(activity), turn);
}

fn upsert_narrative(entry: NarrativeEntryV2, turn: &mut TurnV2Presentation) {
    if let Some(index) = turn
        .narrative
        .iter()
        .position(|existing| existing.id() == entry.id())
    {
        turn.narrative[index] = entry;
    } else {
        turn.narrative.push(entry);
    }
}

fn seal_segment(
    turn: &mut TurnV2Presentation,
    current_steer: &mut Option<UserMessageV2>,
    segments: &mut Vec<ConversationSegmentV2>,
    close_work: bool,
) {
    if close_work {
        close_work_group(turn);
    }
    let id = current_steer.as_ref().map_or_else(
        || format!("{}:initial", turn.turn_id.as_str()),
        |message| {
            format!(
                "{}:steer:{}",
                turn.turn_id.as_str(),
                message.client_id.as_deref().unwrap_or(&message.id)
            )
        },
    );
    segments.push(ConversationSegmentV2 {
        id,
        steered_message: current_steer.take(),
        narrative: std::mem::take(&mut turn.narrative),
    });
}

fn append_submission_state(submission: &OptimisticSubmissionV2, turn: &mut TurnV2Presentation) {
    let message = match &submission.state {
        OptimisticSubmissionStateV2::Indeterminate(message) => Some(
            message
                .clone()
                .unwrap_or_else(|| "Delivery status unknown".to_owned()),
        ),
        OptimisticSubmissionStateV2::Failed(message) => Some(message.clone()),
        OptimisticSubmissionStateV2::Pending | OptimisticSubmissionStateV2::Reconciled => None,
    };
    if let Some(message) = message {
        append_notice(
            &format!("intent-{}-status", submission.id.as_str()),
            &message,
            turn,
        );
    }
}

fn generated_image_source(item: &CanonicalItem) -> Option<String> {
    ["savedPath", "result"].into_iter().find_map(|key| {
        string(item, key).and_then(|value| {
            let trimmed = value.trim();
            (!trimmed.is_empty()).then(|| trimmed.to_owned())
        })
    })
}

fn upsert_generated_image(image: GeneratedImageV2, images: &mut Vec<GeneratedImageV2>) {
    if let Some(index) = images.iter().position(|existing| existing.id == image.id) {
        images[index] = image;
    } else {
        images.push(image);
    }
}

#[allow(clippy::too_many_lines)]
fn make_work_rows(item: &CanonicalItem, completed: bool) -> Vec<WorkRowV2> {
    let id = item.key.item_id.as_str();
    let status = work_status(item, completed);
    match item.kind.as_str() {
        "commandExecution" => {
            let fallback = string(item, "command").unwrap_or_else(|| "Command".to_owned());
            let actions = command_actions(item, &fallback);
            let mut output = item
                .payload
                .get("aggregatedOutput")
                .or_else(|| item.payload.get("output"))
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            if !completed {
                output.push_str(&item.live_overlay.command_output.joined());
            }
            let output = (!output.is_empty()).then(|| project_command_output(&output));
            let action_count = actions.len();
            actions
                .into_iter()
                .enumerate()
                .map(|(index, action)| {
                    let label = command_action_label(&action, status.is_in_progress());
                    let category = command_action_category(&action.kind);
                    WorkRowV2::Command(CommandRowV2 {
                        id: if action_count > 1 {
                            format!("{id}:{index}")
                        } else {
                            id.to_owned()
                        },
                        command: action.command,
                        label,
                        category,
                        status: status.clone(),
                        cwd: string(item, "cwd"),
                        exit_code: integer(&item.payload, "exitCode"),
                        duration_ms: item_duration_ms(item),
                        output: output.clone(),
                    })
                })
                .collect()
        }
        "fileChange" => {
            let changes = item
                .live_fields
                .get("fileChanges")
                .or_else(|| item.payload.get("fileChanges"))
                .or_else(|| item.payload.get("changes"))
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(project_file_change)
                .collect();
            vec![WorkRowV2::FileChange(FileChangeRowV2 {
                id: id.to_owned(),
                changes,
                status,
                duration_ms: item_duration_ms(item),
            })]
        }
        "mcpToolCall" => {
            let app_name = item
                .payload
                .get("appContext")
                .and_then(Value::as_object)
                .and_then(|context| context.get("appName"))
                .and_then(Value::as_str)
                .map(str::to_owned)
                .or_else(|| string(item, "server"))
                .unwrap_or_else(|| "Tool".to_owned());
            let server = string(item, "server").unwrap_or_else(|| app_name.clone());
            vec![WorkRowV2::McpToolCall(McpToolCallRowV2 {
                id: id.to_owned(),
                app_name,
                server,
                tool: string(item, "tool").unwrap_or_else(|| "Tool".to_owned()),
                error_first_line: (status == WorkItemStatusV2::Failed)
                    .then(|| mcp_error(item))
                    .flatten(),
                status,
                duration_ms: item_duration_ms(item),
                arguments: item.payload.get("arguments").cloned(),
                result: item.payload.get("result").cloned(),
                read_only_hint: bool_value(&item.payload, "readOnlyHint"),
            })]
        }
        "webSearch" => string(item, "query")
            .filter(|query| !query.trim().is_empty())
            .map_or_else(Vec::new, |query| {
                vec![WorkRowV2::WebSearch(WebSearchRowV2 {
                    id: id.to_owned(),
                    query,
                    status,
                })]
            }),
        "collabAgentToolCall" => collab_tool_rows(item, &status)
            .into_iter()
            .map(WorkRowV2::Collaboration)
            .collect(),
        "subAgentActivity" => subagent_activity_row(item)
            .map(WorkRowV2::Collaboration)
            .into_iter()
            .collect(),
        "imageGeneration" => vec![WorkRowV2::Other(OtherWorkRowV2 {
            id: id.to_owned(),
            label: "Generating an image".to_owned(),
            status,
        })],
        _ => Vec::new(),
    }
}

#[derive(Clone)]
struct CommandAction {
    command: String,
    kind: CommandActionKind,
}

#[derive(Clone)]
enum CommandActionKind {
    Read {
        target: String,
        is_tool: bool,
    },
    List {
        path: Option<String>,
    },
    Search {
        query: Option<String>,
        path: Option<String>,
    },
    Run,
}

fn command_actions(item: &CanonicalItem, fallback: &str) -> Vec<CommandAction> {
    let Some(actions) = item
        .payload
        .get("commandActions")
        .and_then(Value::as_array)
        .filter(|actions| !actions.is_empty())
    else {
        return fallback_command_action(fallback);
    };

    let projected = actions
        .iter()
        .map(|value| value.as_object())
        .map(|action| {
            let action = action?;
            let command = string_in(action, "command").unwrap_or_else(|| fallback.to_owned());
            let kind = match string_in(action, "type")
                .unwrap_or_default()
                .to_ascii_lowercase()
                .as_str()
            {
                "read" | "fileread" => {
                    let path = string_in(action, "path");
                    let name = string_in(action, "name")
                        .or_else(|| {
                            path.as_deref()
                                .and_then(last_path_component)
                                .map(str::to_owned)
                        })
                        .unwrap_or_else(|| "a file".to_owned());
                    let tool = skill_display_name(&name, path.as_deref());
                    CommandActionKind::Read {
                        target: tool.clone().unwrap_or(name),
                        is_tool: tool.is_some(),
                    }
                }
                "listfiles" | "list" => CommandActionKind::List {
                    path: string_in(action, "path"),
                },
                "search" | "searchfiles" => CommandActionKind::Search {
                    query: string_in(action, "query"),
                    path: string_in(action, "path"),
                },
                _ => CommandActionKind::Run,
            };
            Some(CommandAction { command, kind })
        })
        .collect::<Option<Vec<_>>>();

    projected
        .filter(|actions| !actions.is_empty())
        .unwrap_or_else(|| fallback_command_action(fallback))
}

fn fallback_command_action(command: &str) -> Vec<CommandAction> {
    vec![CommandAction {
        command: command.to_owned(),
        kind: CommandActionKind::Run,
    }]
}

fn command_action_category(kind: &CommandActionKind) -> WorkCategoryV2 {
    match kind {
        CommandActionKind::Read { is_tool: true, .. } => WorkCategoryV2::LoadedTool,
        CommandActionKind::Read { .. } => WorkCategoryV2::Read,
        CommandActionKind::List { .. } => WorkCategoryV2::List,
        CommandActionKind::Search { .. } => WorkCategoryV2::Search,
        CommandActionKind::Run => WorkCategoryV2::Run,
    }
}

fn command_action_label(action: &CommandAction, in_progress: bool) -> String {
    match &action.kind {
        CommandActionKind::Read { target, .. } => {
            format!("{} {target}", if in_progress { "Reading" } else { "Read" })
        }
        CommandActionKind::List { path } => trimmed(path.as_deref()).map_or_else(
            || {
                if in_progress {
                    "Listing files".to_owned()
                } else {
                    "Listed files".to_owned()
                }
            },
            |path| {
                format!(
                    "{} files in {path}",
                    if in_progress { "Listing" } else { "Listed" }
                )
            },
        ),
        CommandActionKind::Search { query, path } => {
            match (trimmed(query.as_deref()), trimmed(path.as_deref())) {
                (Some(query), Some(path)) => format!(
                    "{} for {query} in {path}",
                    if in_progress { "Searching" } else { "Searched" }
                ),
                (Some(query), None) => format!(
                    "{} for {query}",
                    if in_progress { "Searching" } else { "Searched" }
                ),
                _ if in_progress => "Searching for files".to_owned(),
                _ => "Searched for files".to_owned(),
            }
        }
        CommandActionKind::Run => {
            let command = short_command(&action.command);
            if in_progress {
                format!("Running {command}")
            } else {
                format!("Ran {command}")
            }
        }
    }
}

fn short_command(command: &str) -> String {
    const MAXIMUM_COMMAND_LABEL_CHARS: usize = 120;
    let command = command.find("-lc ").map_or(command, |index| {
        command[index + 4..].trim_matches([' ', '\'', '"'])
    });
    let Some((end, _)) = command
        .char_indices()
        .nth(MAXIMUM_COMMAND_LABEL_CHARS)
    else {
        return command.to_owned();
    };
    format!("{}…", &command[..end])
}

fn skill_display_name(name: &str, path: Option<&str>) -> Option<String> {
    if !name.eq_ignore_ascii_case("skill.md")
        && !path.is_some_and(|path| path.to_ascii_lowercase().ends_with("/skill.md"))
    {
        return None;
    }
    let parent = path?
        .trim_end_matches("/SKILL.md")
        .trim_end_matches("/skill.md");
    let skill = last_path_component(parent)?.replace('-', " ");
    if skill.is_empty() {
        return None;
    }
    let display = if skill.eq_ignore_ascii_case("github") {
        "GitHub".to_owned()
    } else {
        skill
    };
    Some(format!("{display} skill"))
}

fn trimmed(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|value| !value.is_empty())
}

fn mcp_error(item: &CanonicalItem) -> Option<String> {
    let error = item.error.as_ref().or_else(|| item.payload.get("error"));
    if let Some(message) = error
        .and_then(Value::as_str)
        .or_else(|| error.and_then(Value::as_object)?.get("message")?.as_str())
    {
        return Some(first_line(message));
    }
    let result = item.payload.get("result")?.as_object()?;
    if let Some(message) = result
        .get("structuredContent")
        .and_then(Value::as_object)
        .and_then(|content| content.get("error"))
        .and_then(Value::as_str)
    {
        return Some(first_line(message));
    }
    result
        .get("content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .find_map(|content| content.get("text").and_then(Value::as_str))
        .map(first_line)
}

fn first_line(value: &str) -> String {
    value.lines().next().unwrap_or(value).to_owned()
}

fn collab_tool_rows(
    item: &CanonicalItem,
    fallback_status: &WorkItemStatusV2,
) -> Vec<CollaborationRowV2> {
    let action = match string(item, "tool").as_deref() {
        Some("spawnAgent") => CollaborationActionV2::Created,
        Some("sendInput" | "resumeAgent") => CollaborationActionV2::SentInput,
        Some("closeAgent") => CollaborationActionV2::Closed,
        _ => CollaborationActionV2::Waited,
    };
    let states = item.payload.get("agentsStates").and_then(Value::as_object);
    let mut receiver_ids = item
        .payload
        .get("receiverThreadIds")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect::<Vec<_>>();
    if let Some(states) = states {
        let mut state_ids = states.keys().cloned().collect::<Vec<_>>();
        state_ids.sort();
        ordered_extend(&mut receiver_ids, state_ids);
    }
    if receiver_ids.is_empty() {
        return vec![CollaborationRowV2 {
            id: item.key.item_id.as_str().to_owned(),
            action,
            agent_names: Vec::new(),
            agent_thread_ids: Vec::new(),
            instructions: string(item, "prompt"),
            agent_messages: Vec::new(),
            timeline: vec![action],
            status: fallback_status.clone(),
            display_status: if action == CollaborationActionV2::Closed {
                AgentDisplayStatusV2::Closed
            } else {
                agent_display_status(None, fallback_status)
            },
        }];
    }
    receiver_ids
        .into_iter()
        .map(|thread_id| {
            let name = short_agent_name(&thread_id);
            let raw = states
                .and_then(|states| states.get(&thread_id))
                .and_then(Value::as_object);
            let status_text = raw
                .and_then(|raw| raw.get("status"))
                .and_then(Value::as_str);
            let agent_messages = raw
                .and_then(|raw| raw.get("message"))
                .and_then(Value::as_str)
                .filter(|message| !message.is_empty())
                .map_or_else(Vec::new, |message| vec![(name.clone(), message.to_owned())]);
            CollaborationRowV2 {
                id: format!("agent:{thread_id}"),
                action,
                agent_names: vec![name],
                agent_thread_ids: vec![thread_id],
                instructions: string(item, "prompt"),
                agent_messages,
                timeline: vec![action],
                status: agent_work_status(status_text, fallback_status),
                display_status: if action == CollaborationActionV2::Closed {
                    AgentDisplayStatusV2::Closed
                } else {
                    agent_display_status(status_text, fallback_status)
                },
            }
        })
        .collect()
}

fn subagent_activity_row(item: &CanonicalItem) -> Option<CollaborationRowV2> {
    let action = match string(item, "kind").as_deref() {
        Some("started") => CollaborationActionV2::Started,
        Some("interacted") => CollaborationActionV2::Interacted,
        Some("interrupted") => CollaborationActionV2::Interrupted,
        _ => return None,
    };
    let thread_id = string(item, "agentThreadId");
    let name = display_agent_name(
        string(item, "agentPath")
            .as_deref()
            .or(thread_id.as_deref())
            .unwrap_or("agent"),
    );
    let is_interrupted = action == CollaborationActionV2::Interrupted;
    Some(CollaborationRowV2 {
        id: thread_id.as_ref().map_or_else(
            || item.key.item_id.as_str().to_owned(),
            |thread_id| format!("agent:{thread_id}"),
        ),
        action,
        agent_names: vec![name],
        agent_thread_ids: thread_id.into_iter().collect(),
        instructions: None,
        agent_messages: Vec::new(),
        timeline: vec![action],
        status: if is_interrupted {
            WorkItemStatusV2::Completed
        } else {
            WorkItemStatusV2::InProgress
        },
        display_status: if is_interrupted {
            AgentDisplayStatusV2::Done
        } else {
            AgentDisplayStatusV2::Working
        },
    })
}

fn reconcile_agent_wait(
    item: &CanonicalItem,
    fallback: &WorkItemStatusV2,
    narrative: &mut [NarrativeEntryV2],
) {
    let states = item.payload.get("agentsStates").and_then(Value::as_object);
    let mut receiver_ids = item
        .payload
        .get("receiverThreadIds")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect::<Vec<_>>();
    if let Some(states) = states {
        let mut keys = states.keys().cloned().collect::<Vec<_>>();
        keys.sort();
        ordered_extend(&mut receiver_ids, keys);
    }
    let wait_completed = string(item, "status").as_deref() == Some("completed")
        || *fallback == WorkItemStatusV2::Completed;
    for entry in narrative {
        let NarrativeEntryV2::WorkGroup(group) = entry else {
            continue;
        };
        let mut changed = false;
        for row in &mut group.rows {
            let WorkRowV2::Collaboration(agent) = row else {
                continue;
            };
            let matching = agent
                .agent_thread_ids
                .iter()
                .filter(|thread_id| receiver_ids.contains(thread_id))
                .collect::<Vec<_>>();
            let mut resolved_status = None;
            let mut resolved_display = None;
            for thread_id in matching {
                let Some(raw) = states
                    .and_then(|states| states.get(thread_id))
                    .and_then(Value::as_object)
                else {
                    continue;
                };
                let raw_status = raw.get("status").and_then(Value::as_str);
                resolved_status = Some(agent_work_status(raw_status, fallback));
                resolved_display = Some(agent_display_status(raw_status, fallback));
                if let Some(message) = raw
                    .get("message")
                    .and_then(Value::as_str)
                    .filter(|message| !message.is_empty())
                {
                    let name = agent
                        .agent_names
                        .first()
                        .cloned()
                        .unwrap_or_else(|| short_agent_name(thread_id));
                    upsert_agent_message(&mut agent.agent_messages, name, message.to_owned());
                }
            }
            let effective = resolved_display.unwrap_or(agent.display_status);
            if wait_completed
                && matches!(
                    effective,
                    AgentDisplayStatusV2::Starting | AgentDisplayStatusV2::Working
                )
            {
                resolved_status = Some(WorkItemStatusV2::Completed);
                resolved_display = Some(AgentDisplayStatusV2::Done);
            }
            if let (Some(status), Some(display)) = (resolved_status, resolved_display) {
                agent.status = status;
                agent.display_status = display;
                changed = true;
            }
        }
        if changed {
            refresh_group(group);
        }
    }
}

fn append_work_row(row: WorkRowV2, turn: &mut TurnV2Presentation) {
    if let WorkRowV2::Collaboration(incoming) = &row
        && merge_collaboration(incoming, &mut turn.narrative)
    {
        return;
    }
    if let Some(NarrativeEntryV2::WorkGroup(group)) = turn.narrative.last_mut()
        && can_append_to_group(&row, group)
    {
        group.rows.push(row);
        refresh_group(group);
        return;
    }
    let header = synthesize_work_group_header(std::slice::from_ref(&row));
    if header.is_empty() {
        return;
    }
    let is_live = row.is_in_progress();
    let active_header = is_live.then(|| active_work_label(&row));
    let status = work_group_status(std::slice::from_ref(&row), is_live);
    turn.narrative
        .push(NarrativeEntryV2::WorkGroup(WorkGroupV2 {
            id: format!("group-{}", row.id()),
            header,
            active_header,
            rows: vec![row],
            is_live,
            status,
            is_expanded_by_default: false,
        }));
}

fn can_append_to_group(row: &WorkRowV2, group: &WorkGroupV2) -> bool {
    match (row, group.rows.last()) {
        (WorkRowV2::Collaboration(incoming), Some(WorkRowV2::Collaboration(previous))) => {
            (incoming.action == CollaborationActionV2::Waited)
                == (previous.action == CollaborationActionV2::Waited)
        }
        _ => true,
    }
}

fn close_work_group(turn: &mut TurnV2Presentation) {
    if let Some(NarrativeEntryV2::WorkGroup(group)) = turn.narrative.last_mut() {
        group.is_live = false;
        group.active_header = None;
        group.status = work_group_status(&group.rows, false);
    }
}

fn refresh_group(group: &mut WorkGroupV2) {
    group.header = synthesize_work_group_header(&group.rows);
    group.is_live = group.rows.iter().any(WorkRowV2::is_in_progress);
    group.active_header = group
        .rows
        .iter()
        .rev()
        .find(|row| row.is_in_progress())
        .map(active_work_label);
    group.status = work_group_status(&group.rows, group.is_live);
}

fn merge_collaboration(incoming: &CollaborationRowV2, narrative: &mut [NarrativeEntryV2]) -> bool {
    let incoming_ids = incoming.agent_thread_ids.iter().collect::<BTreeSet<_>>();
    let incoming_names = incoming.agent_names.iter().collect::<BTreeSet<_>>();
    let mut match_location = None;
    let mut sole_live = None;
    let mut live_count = 0;
    for (entry_index, entry) in narrative.iter().enumerate() {
        let NarrativeEntryV2::WorkGroup(group) = entry else {
            continue;
        };
        for (row_index, row) in group.rows.iter().enumerate() {
            let WorkRowV2::Collaboration(existing) = row else {
                continue;
            };
            if existing.status == WorkItemStatusV2::InProgress {
                live_count += 1;
                sole_live = Some((entry_index, row_index));
            }
            let existing_ids = existing.agent_thread_ids.iter().collect::<BTreeSet<_>>();
            let ids_intersect = !incoming_ids.is_empty()
                && !existing_ids.is_empty()
                && !incoming_ids.is_disjoint(&existing_ids);
            let existing_names = existing.agent_names.iter().collect::<BTreeSet<_>>();
            let names_intersect = !incoming_names.is_disjoint(&existing_names);
            if ids_intersect
                || (incoming_ids.is_empty() && existing_ids.is_empty() && names_intersect)
            {
                match_location = Some((entry_index, row_index));
                break;
            }
        }
        if match_location.is_some() {
            break;
        }
    }
    let location = match_location.or_else(|| {
        (!matches!(
            incoming.action,
            CollaborationActionV2::Created | CollaborationActionV2::Started
        ) && live_count == 1)
            .then_some(sole_live)
            .flatten()
    });
    let Some((entry_index, row_index)) = location else {
        return false;
    };
    let NarrativeEntryV2::WorkGroup(group) = &mut narrative[entry_index] else {
        return false;
    };
    let WorkRowV2::Collaboration(existing) = &mut group.rows[row_index] else {
        return false;
    };
    update_collaboration(existing, incoming);
    refresh_group(group);
    true
}

fn update_collaboration(existing: &mut CollaborationRowV2, incoming: &CollaborationRowV2) {
    existing.action = incoming.action;
    existing.status = incoming.status.clone();
    existing.display_status = incoming.display_status;
    existing.agent_names = preferred_agent_names(&existing.agent_names, &incoming.agent_names);
    ordered_extend(
        &mut existing.agent_thread_ids,
        incoming.agent_thread_ids.clone(),
    );
    if incoming.instructions.is_some() {
        existing.instructions.clone_from(&incoming.instructions);
    }
    for (name, message) in &incoming.agent_messages {
        upsert_agent_message(&mut existing.agent_messages, name.clone(), message.clone());
    }
    if existing.timeline.last() != Some(&incoming.action) {
        existing.timeline.push(incoming.action);
    }
}

fn preferred_agent_names(existing: &[String], incoming: &[String]) -> Vec<String> {
    let existing_named = existing
        .iter()
        .filter(|name| !name.starts_with("agent-"))
        .cloned()
        .collect::<Vec<_>>();
    let incoming_named = incoming
        .iter()
        .filter(|name| !name.starts_with("agent-"))
        .cloned()
        .collect::<Vec<_>>();
    if !incoming_named.is_empty() {
        let mut result = existing_named;
        ordered_extend(&mut result, incoming_named);
        result
    } else if !existing_named.is_empty() {
        existing_named
    } else {
        let mut result = existing.to_vec();
        ordered_extend(&mut result, incoming.to_vec());
        result
    }
}

fn ordered_extend(values: &mut Vec<String>, incoming: impl IntoIterator<Item = String>) {
    for value in incoming {
        if !values.contains(&value) {
            values.push(value);
        }
    }
}

fn upsert_agent_message(messages: &mut Vec<(String, String)>, name: String, message: String) {
    if let Some(existing) = messages
        .iter_mut()
        .find(|(existing_name, _)| existing_name == &name)
    {
        existing.1 = message;
    } else {
        messages.push((name, message));
    }
}

fn short_agent_name(thread_id: &str) -> String {
    let suffix = thread_id.rsplit('-').next().unwrap_or(thread_id);
    format!("agent-{}", suffix.chars().take(6).collect::<String>())
}

fn display_agent_name(value: &str) -> String {
    let leaf = value.rsplit('/').next().unwrap_or(value).replace('_', " ");
    leaf.split_whitespace()
        .map(|word| {
            let mut characters = word.chars();
            characters.next().map_or_else(String::new, |first| {
                first.to_uppercase().collect::<String>() + characters.as_str()
            })
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn agent_work_status(raw: Option<&str>, fallback: &WorkItemStatusV2) -> WorkItemStatusV2 {
    match raw.map(str::to_ascii_lowercase).as_deref() {
        Some("completed" | "done" | "shutdown" | "closed" | "interrupted") => {
            WorkItemStatusV2::Completed
        }
        Some("errored" | "error" | "failed") => WorkItemStatusV2::Failed,
        Some("declined") => WorkItemStatusV2::Declined,
        Some("pendinginit" | "pending_init" | "running" | "working") => {
            WorkItemStatusV2::InProgress
        }
        Some(value) => WorkItemStatusV2::Unknown(value.to_owned()),
        None => fallback.clone(),
    }
}

fn agent_display_status(raw: Option<&str>, fallback: &WorkItemStatusV2) -> AgentDisplayStatusV2 {
    match raw.map(str::to_ascii_lowercase).as_deref() {
        Some("pendinginit" | "pending_init" | "pending") => AgentDisplayStatusV2::Starting,
        Some("running" | "working") => AgentDisplayStatusV2::Working,
        Some("completed" | "done" | "interrupted") => AgentDisplayStatusV2::Done,
        Some("shutdown" | "closed" | "cancelled" | "canceled") => AgentDisplayStatusV2::Closed,
        Some(_) => AgentDisplayStatusV2::Failed,
        None => match fallback {
            WorkItemStatusV2::InProgress => AgentDisplayStatusV2::Working,
            WorkItemStatusV2::Completed => AgentDisplayStatusV2::Done,
            WorkItemStatusV2::Failed
            | WorkItemStatusV2::Declined
            | WorkItemStatusV2::Unknown(_) => AgentDisplayStatusV2::Failed,
        },
    }
}

fn work_status(item: &CanonicalItem, completed: bool) -> WorkItemStatusV2 {
    if integer(&item.payload, "exitCode").is_some_and(|code| code != 0) {
        return WorkItemStatusV2::Failed;
    }
    if let Some(status) = string(item, "status") {
        return match status.as_str() {
            "inProgress" => WorkItemStatusV2::InProgress,
            "completed" => WorkItemStatusV2::Completed,
            "failed" => WorkItemStatusV2::Failed,
            "declined" => WorkItemStatusV2::Declined,
            _ => WorkItemStatusV2::Unknown(status),
        };
    }
    match &item.status {
        LifecycleStatus::InProgress => WorkItemStatusV2::InProgress,
        LifecycleStatus::Interrupted | LifecycleStatus::Failed => WorkItemStatusV2::Failed,
        LifecycleStatus::Declined => WorkItemStatusV2::Declined,
        LifecycleStatus::Unknown(value) if !completed => WorkItemStatusV2::Unknown(value.clone()),
        LifecycleStatus::Completed | LifecycleStatus::Unknown(_) => WorkItemStatusV2::Completed,
    }
}

fn finish_turn(turn: &mut TurnV2Presentation) {
    turn.live_tail = None;
    if let Some(answer) = &mut turn.final_answer {
        answer.is_streaming = false;
    }
    finish_narrative(&mut turn.narrative);
    for segment in &mut turn.conversation_segments {
        finish_narrative(&mut segment.narrative);
    }
}

fn finish_narrative(narrative: &mut [NarrativeEntryV2]) {
    for entry in narrative {
        match entry {
            NarrativeEntryV2::Prose(prose) => prose.is_streaming = false,
            NarrativeEntryV2::WorkGroup(group) => {
                group.is_live = false;
                group.active_header = None;
                for row in &mut group.rows {
                    if let WorkRowV2::Collaboration(agent) = row
                        && matches!(
                            agent.display_status,
                            AgentDisplayStatusV2::Starting | AgentDisplayStatusV2::Working
                        )
                    {
                        agent.status = WorkItemStatusV2::Completed;
                        agent.display_status = AgentDisplayStatusV2::Done;
                    }
                }
                group.header = synthesize_work_group_header(&group.rows);
                group.status = work_group_status(&group.rows, false);
            }
            NarrativeEntryV2::InlineActivity(activity)
                if activity.status == WorkItemStatusV2::InProgress =>
            {
                activity.status = WorkItemStatusV2::Completed;
            }
            NarrativeEntryV2::ProductToolCall(_)
            | NarrativeEntryV2::InlineActivity(_)
            | NarrativeEntryV2::Notice(_) => {}
        }
    }
}

fn work_disclosure(turn: &TurnV2Presentation) -> TurnWorkDisclosureV2 {
    let final_is_visible = turn
        .final_answer
        .as_ref()
        .is_some_and(|answer| !answer.text.trim().is_empty());
    let has_in_progress = turn.narrative.iter().any(|entry| match entry {
        NarrativeEntryV2::WorkGroup(group) => group.rows.iter().any(WorkRowV2::is_in_progress),
        NarrativeEntryV2::ProductToolCall(call) => call.status == WorkItemStatusV2::InProgress,
        NarrativeEntryV2::InlineActivity(activity) => {
            activity.status == WorkItemStatusV2::InProgress
        }
        NarrativeEntryV2::Prose(_) | NarrativeEntryV2::Notice(_) => false,
    });
    match turn.status {
        TurnStatusV2::Working { .. } => TurnWorkDisclosureV2 {
            is_visible: !final_is_visible || has_in_progress,
            is_expanded_by_default: true,
            is_tail_mode: final_is_visible,
        },
        TurnStatusV2::Done { .. }
        | TurnStatusV2::Interrupted { .. }
        | TurnStatusV2::Failed { .. } => TurnWorkDisclosureV2 {
            is_visible: !turn.narrative.is_empty() || turn.live_tail.is_some(),
            is_expanded_by_default: false,
            is_tail_mode: false,
        },
    }
}

fn turn_duration_ms(turn: &CanonicalTurn) -> Option<u64> {
    nonnegative_u64(integer(&turn.metadata, "durationMs")).or_else(|| {
        let start = canonical_started_at(turn)?;
        let end = canonical_completed_at(turn)?;
        let seconds = end.checked_sub(start)?;
        nonnegative_u64(seconds.checked_mul(1_000))
    })
}

fn item_duration_ms(item: &CanonicalItem) -> Option<u64> {
    nonnegative_u64(item.duration_ms)
        .or_else(|| nonnegative_u64(integer(&item.payload, "durationMs")))
        .or_else(|| {
            let start = item_timestamp(item, "startedAtMs")?;
            let end = item_timestamp(item, "completedAtMs")?;
            nonnegative_u64(end.checked_sub(start))
        })
}

fn canonical_started_at(turn: &CanonicalTurn) -> Option<i64> {
    integer(&turn.metadata, "startedAt")
}

fn canonical_completed_at(turn: &CanonicalTurn) -> Option<i64> {
    integer(&turn.metadata, "completedAt")
}

fn item_timestamp(item: &CanonicalItem, key: &str) -> Option<i64> {
    integer(&item.payload, key)
}

fn turn_error_message(turn: &CanonicalTurn) -> Option<String> {
    let error = turn.metadata.get("error")?;
    error.as_str().map(str::to_owned).or_else(|| {
        error
            .get("message")
            .and_then(Value::as_str)
            .map(str::to_owned)
    })
}

fn nonnegative_u64(value: Option<i64>) -> Option<u64> {
    value.map(|value| u64::try_from(value.max(0)).unwrap_or(u64::MAX))
}

fn string(item: &CanonicalItem, key: &str) -> Option<String> {
    item.payload
        .get(key)
        .and_then(Value::as_str)
        .map(str::to_owned)
}

fn string_in(object: &Map<String, Value>, key: &str) -> Option<String> {
    object.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn integer(values: &BTreeMap<String, Value>, key: &str) -> Option<i64> {
    values.get(key).and_then(Value::as_i64)
}

fn bool_value(values: &BTreeMap<String, Value>, key: &str) -> Option<bool> {
    values.get(key).and_then(Value::as_bool)
}
