//! Swift-shaped collaboration rows for Transcript V2.
//!
//! Collaboration activity is intentionally projected separately from the
//! canonical thread graph.  A transcript row can show the compact agent
//! chips, an action/status summary, and bounded messages while retaining the
//! exact `CollaborationRowV2` fields supplied by the presentation layer.

use codex_presentation::transcript_v2::{
    AgentDisplayStatusV2, CollaborationActionV2, CollaborationRowV2, WorkItemStatusV2,
};
use gpui::{AnyElement, KeyDownEvent, Role, WeakEntity, div, prelude::*, px};

use crate::{
    CodexTheme, TranscriptLayoutMetrics, transcript::is_activation_key,
    transcript_v2::CodexTranscriptV2,
};

/// Maximum agent chips retained in a compact collaboration row.
pub const MAX_AGENT_CHIPS: usize = 8;
/// Maximum messages retained in an expanded collaboration row.
pub const MAX_AGENT_MESSAGES: usize = 32;
/// Maximum visible characters for an instruction or agent message.
pub const MAX_COLLAB_TEXT_CHARS: usize = 4_096;
/// Maximum height of the expanded message region.
pub const MAX_MESSAGE_HEIGHT: f32 = 180.;

/// A compact, status-bearing chip for one collaborating agent.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentChipProjection {
    pub name: String,
    pub thread_id: Option<String>,
    pub status: AgentDisplayStatusV2,
    pub status_label: &'static str,
}

/// One bounded agent-authored message shown when the row expands.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentMessageProjection {
    pub agent: String,
    pub text: String,
}

/// Pure projection consumed by the collaboration renderer and host tests.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CollaborationProjection {
    pub action: CollaborationActionV2,
    pub summary: String,
    pub status_summary: &'static str,
    pub chips: Vec<AgentChipProjection>,
    pub hidden_agent_count: usize,
    pub instructions: Option<String>,
    pub messages: Vec<AgentMessageProjection>,
    pub hidden_message_count: usize,
    pub status: WorkItemStatusV2,
    pub display_status: AgentDisplayStatusV2,
}

impl CollaborationProjection {
    /// Project all user-facing collaboration fields with bounded text/list
    /// sizes.  Missing names/thread ids receive stable human-readable labels.
    #[must_use]
    pub fn from_row(row: &CollaborationRowV2) -> Self {
        let count = row.agent_names.len().max(row.agent_thread_ids.len()).max(1);
        let chips = (0..count.min(MAX_AGENT_CHIPS))
            .map(|index| AgentChipProjection {
                name: row
                    .agent_names
                    .get(index)
                    .filter(|name| !name.trim().is_empty())
                    .map_or_else(|| format!("Agent {}", index + 1), |name| bounded_text(name)),
                thread_id: row.agent_thread_ids.get(index).cloned(),
                status: row.display_status,
                status_label: display_status_label(row.display_status),
            })
            .collect::<Vec<_>>();
        let messages = row
            .agent_messages
            .iter()
            .take(MAX_AGENT_MESSAGES)
            .map(|(agent, message)| AgentMessageProjection {
                agent: if agent.trim().is_empty() {
                    "Agent".to_owned()
                } else {
                    bounded_text(agent)
                },
                text: bounded_text(message),
            })
            .collect::<Vec<_>>();
        Self {
            action: row.action,
            summary: action_summary(row.action, count),
            status_summary: display_status_label(row.display_status),
            chips,
            hidden_agent_count: count.saturating_sub(MAX_AGENT_CHIPS),
            instructions: row
                .instructions
                .as_deref()
                .filter(|value| !value.trim().is_empty())
                .map(bounded_text),
            hidden_message_count: row.agent_messages.len().saturating_sub(MAX_AGENT_MESSAGES),
            messages,
            status: row.status.clone(),
            display_status: row.display_status,
        }
    }

    #[must_use]
    pub fn has_details(&self) -> bool {
        self.instructions.is_some() || !self.messages.is_empty() || self.hidden_message_count > 0
    }
}

/// Build a concise action summary such as `Created 2 agents`.
#[must_use]
pub fn action_summary(action: CollaborationActionV2, count: usize) -> String {
    let count = count.max(1);
    let noun = if count == 1 { "agent" } else { "agents" };
    match action {
        CollaborationActionV2::Created => format!("Created {count} {noun}"),
        CollaborationActionV2::SentInput => format!("Messaged {count} {noun}"),
        CollaborationActionV2::Waited => format!("Waiting for {count} {noun}"),
        CollaborationActionV2::Closed => format!("Closed {count} {noun}"),
        CollaborationActionV2::Started => format!("Started {count} {noun}"),
        CollaborationActionV2::Interacted => format!("Interacted with {count} {noun}"),
        CollaborationActionV2::Interrupted => format!("Interrupted {count} {noun}"),
    }
}

/// Human-readable lifecycle text for an agent chip/status summary.
#[must_use]
pub const fn display_status_label(status: AgentDisplayStatusV2) -> &'static str {
    match status {
        AgentDisplayStatusV2::Starting => "Starting",
        AgentDisplayStatusV2::Working => "Working",
        AgentDisplayStatusV2::Done => "Done",
        AgentDisplayStatusV2::Failed => "Failed",
        AgentDisplayStatusV2::Closed => "Closed",
    }
}

fn bounded_text(text: &str) -> String {
    let mut value = text
        .trim()
        .chars()
        .take(MAX_COLLAB_TEXT_CHARS)
        .collect::<String>();
    if text.trim().chars().count() > MAX_COLLAB_TEXT_CHARS {
        value.push('…');
    }
    value
}

/// Render an expandable collaboration row with status-bearing agent chips.
#[allow(clippy::too_many_arguments)]
pub(crate) fn render_collaboration_row(
    id: &str,
    group_key: &str,
    row: &CollaborationRowV2,
    theme: CodexTheme,
    emitter: &WeakEntity<CodexTranscriptV2>,
    expanded: bool,
) -> AnyElement {
    let projection = CollaborationProjection::from_row(row);
    let row_key = id.to_owned();
    let group_key = group_key.to_owned();
    let click_emitter = emitter.clone();
    let keyboard_emitter = emitter.clone();
    let keyboard_row_key = row_key.clone();
    let keyboard_group_key = group_key.clone();
    let has_details = projection.has_details();
    let chips = projection
        .chips
        .iter()
        .enumerate()
        .map(|(index, chip)| render_agent_chip(index, chip, theme))
        .collect::<Vec<_>>();
    let label = format!("{} · {}", projection.summary, projection.status_summary);
    let header = div()
        .id(format!("{id}:disclosure"))
        .role(if has_details {
            Role::Button
        } else {
            Role::Status
        })
        .aria_label(format!(
            "{label}{}",
            if has_details {
                format!(", {}", if expanded { "expanded" } else { "collapsed" })
            } else {
                String::new()
            }
        ))
        .when(has_details, |view| {
            view.aria_expanded(expanded)
                .focusable()
                .tab_stop(true)
                .cursor_pointer()
                .on_click(move |_, _, cx| {
                    click_emitter
                        .update(cx, |transcript, cx| {
                            transcript.toggle_work_row(row_key.clone(), &group_key, cx);
                        })
                        .ok();
                })
                .on_key_down(move |event: &KeyDownEvent, window, cx| {
                    if is_activation_key(&event.keystroke.key) {
                        window.prevent_default();
                        keyboard_emitter
                            .update(cx, |transcript, cx| {
                                transcript.toggle_work_row(
                                    keyboard_row_key.clone(),
                                    &keyboard_group_key,
                                    cx,
                                );
                            })
                            .ok();
                    }
                })
        })
        .h(px(TranscriptLayoutMetrics::WORK_ROW_HEIGHT))
        .w_full()
        .pr_2()
        .flex()
        .items_center()
        .gap_2()
        .text_size(px(TranscriptLayoutMetrics::CAPTION_TEXT_SIZE))
        .text_color(theme.tertiary_text)
        .child(status_glyph(&projection.status, theme))
        .child(div().min_w_0().truncate().child(projection.summary.clone()))
        .children(chips)
        .when(projection.hidden_agent_count > 0, |view| {
            view.child(
                div()
                    .rounded_full()
                    .px_2()
                    .text_size(px(10.))
                    .text_color(theme.muted_text)
                    .child(format!("+{} more", projection.hidden_agent_count)),
            )
        })
        .when(has_details, |view| {
            view.child(div().child(if expanded { "⌄" } else { "›" }))
        });
    div()
        .id(format!("work-row:{id}"))
        .role(Role::ListItem)
        .aria_label(format!("Collaboration: {label}"))
        .w_full()
        .flex()
        .flex_col()
        .child(header)
        .when(expanded && has_details, |view| {
            view.child(render_collaboration_details(id, &projection, theme))
        })
        .into_any()
}

fn render_agent_chip(index: usize, chip: &AgentChipProjection, theme: CodexTheme) -> AnyElement {
    let color = chip_status_color(chip.status, theme);
    div()
        .id(format!("agent-chip:{index}:{}", chip.name))
        .role(Role::ListItem)
        .aria_label(format!("{}: {}", chip.name, chip.status_label))
        .max_w(px(130.))
        .rounded_full()
        .border_1()
        .border_color(color)
        .px_2()
        .text_size(px(10.))
        .text_color(color)
        .child(format!("{} · {}", chip.name, chip.status_label))
        .into_any()
}

fn render_collaboration_details(
    id: &str,
    projection: &CollaborationProjection,
    theme: CodexTheme,
) -> AnyElement {
    let instructions = projection.instructions.clone();
    let messages = projection
        .messages
        .iter()
        .enumerate()
        .map(|(index, message)| {
            div()
                .id(format!("{id}:message:{index}"))
                .role(Role::ListItem)
                .aria_label(format!("Message from {}: {}", message.agent, message.text))
                .w_full()
                .rounded_md()
                .bg(theme.surface)
                .border_1()
                .border_color(theme.border)
                .px_2()
                .py_1()
                .text_size(px(TranscriptLayoutMetrics::CAPTION_TEXT_SIZE))
                .child(div().text_color(theme.text).child(message.agent.clone()))
                .child(
                    div()
                        .mt_1()
                        .text_color(theme.muted_text)
                        .whitespace_normal()
                        .child(message.text.clone()),
                )
        });
    div()
        .id(format!("{id}:details"))
        .role(Role::Region)
        .aria_label("Collaboration details")
        .ml(px(38.))
        .mb_2()
        .w_full()
        .max_w(px(TranscriptLayoutMetrics::CARD_MAX_WIDTH))
        .rounded_md()
        .border_1()
        .border_color(theme.border)
        .bg(theme.elevated_surface)
        .px_2()
        .py_1()
        .when_some(instructions, |view, instructions| {
            view.child(
                div()
                    .text_size(px(TranscriptLayoutMetrics::CAPTION_TEXT_SIZE))
                    .text_color(theme.muted_text)
                    .whitespace_normal()
                    .child(format!("Instructions: {instructions}")),
            )
        })
        .when(!projection.messages.is_empty(), |view| {
            view.child(
                div()
                    .id(format!("{id}:messages"))
                    .role(Role::List)
                    .aria_label("Agent messages")
                    .mt_1()
                    .max_h(px(MAX_MESSAGE_HEIGHT))
                    .overflow_y_scroll()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .children(messages),
            )
        })
        .when(projection.hidden_message_count > 0, |view| {
            view.child(
                div()
                    .text_size(px(TranscriptLayoutMetrics::CAPTION_TEXT_SIZE))
                    .text_color(theme.muted_text)
                    .child(format!(
                        "+{} more message(s)",
                        projection.hidden_message_count
                    )),
            )
        })
        .into_any()
}

fn chip_status_color(status: AgentDisplayStatusV2, theme: CodexTheme) -> gpui::Rgba {
    match status {
        AgentDisplayStatusV2::Starting => theme.warning,
        AgentDisplayStatusV2::Working => theme.running,
        AgentDisplayStatusV2::Done | AgentDisplayStatusV2::Closed => theme.success,
        AgentDisplayStatusV2::Failed => theme.danger,
    }
}

fn status_glyph(status: &WorkItemStatusV2, theme: CodexTheme) -> gpui::Div {
    let (glyph, color) = match status {
        WorkItemStatusV2::InProgress => ("◌", theme.running),
        WorkItemStatusV2::Completed => ("✓", theme.success),
        WorkItemStatusV2::Failed => ("×", theme.danger),
        WorkItemStatusV2::Declined => ("—", theme.warning),
        WorkItemStatusV2::Unknown(_) => ("?", theme.warning),
    };
    div().w(px(14.)).text_color(color).child(glyph)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row() -> CollaborationRowV2 {
        CollaborationRowV2 {
            id: "collab".to_owned(),
            action: CollaborationActionV2::Created,
            agent_names: vec!["Kepler".to_owned(), "Luna".to_owned()],
            agent_thread_ids: vec!["thread-kepler".to_owned(), "thread-luna".to_owned()],
            instructions: Some("Inspect the renderer".to_owned()),
            agent_messages: vec![("Kepler".to_owned(), "Found the diff panel".to_owned())],
            timeline: vec![CollaborationActionV2::Created],
            status: WorkItemStatusV2::InProgress,
            display_status: AgentDisplayStatusV2::Working,
        }
    }

    #[test]
    fn projection_exposes_chips_status_summary_and_messages() {
        let projection = CollaborationProjection::from_row(&row());
        assert_eq!(projection.summary, "Created 2 agents");
        assert_eq!(projection.status_summary, "Working");
        assert_eq!(projection.chips[0].name, "Kepler");
        assert_eq!(
            projection.chips[0].thread_id.as_deref(),
            Some("thread-kepler")
        );
        assert_eq!(projection.messages[0].agent, "Kepler");
        assert!(projection.has_details());
    }

    #[test]
    fn projection_bounds_chips_messages_and_text() {
        let mut row = row();
        row.agent_names = (0..(MAX_AGENT_CHIPS + 2))
            .map(|index| format!("agent-{index}"))
            .collect();
        row.agent_messages = (0..(MAX_AGENT_MESSAGES + 2))
            .map(|index| {
                (
                    format!("agent-{index}"),
                    "x".repeat(MAX_COLLAB_TEXT_CHARS + 20),
                )
            })
            .collect();
        row.instructions = Some("y".repeat(MAX_COLLAB_TEXT_CHARS + 20));
        let projection = CollaborationProjection::from_row(&row);
        assert_eq!(projection.chips.len(), MAX_AGENT_CHIPS);
        assert_eq!(projection.hidden_agent_count, 2);
        assert_eq!(projection.messages.len(), MAX_AGENT_MESSAGES);
        assert_eq!(projection.hidden_message_count, 2);
        assert!(projection.messages[0].text.chars().count() <= MAX_COLLAB_TEXT_CHARS + 1);
        assert!(
            projection
                .instructions
                .as_deref()
                .is_some_and(|text| text.ends_with('…'))
        );
    }

    #[test]
    fn action_summary_uses_stable_singular_and_plural_grammar() {
        assert_eq!(
            action_summary(CollaborationActionV2::Closed, 1),
            "Closed 1 agent"
        );
        assert_eq!(
            action_summary(CollaborationActionV2::Interacted, 2),
            "Interacted with 2 agents"
        );
        assert_eq!(display_status_label(AgentDisplayStatusV2::Failed), "Failed");
    }
}
