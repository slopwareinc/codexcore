//! Native renderer for the Swift-parity Transcript V2 presentation grammar.

use std::{
    collections::{BTreeMap, BTreeSet},
    path::PathBuf,
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use codex_app_server_state::{StateRevision, TurnId};
use codex_presentation::{
    PlanPresentation,
    transcript_v2::{
        AssistantTextV2, CollaborationActionV2, CommandRowV2, ConversationSegmentV2,
        GeneratedImageV2, InlineActivityV2, NarrativeEntryV2, NoticeV2, ProductToolCallV2,
        TranscriptV2Presentation, TurnStatusV2, TurnV2Presentation, UserMessageV2, WorkCategoryV2,
        WorkGroupV2, WorkItemStatusV2, WorkRowV2,
    },
};
use gpui::{
    AnyElement, Context, EventEmitter, FollowMode, KeyDownEvent, ListAlignment, ListState,
    ObjectFit, Render, Role, Task, WeakEntity, Window, div, img, list, prelude::*, px,
};

use crate::{
    markdown::render_markdown,
    transcript::{CodexTheme, TranscriptEvent, TranscriptLayoutMetrics},
};

/// One independently virtualized V2 row in exact Swift display order.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TranscriptV2Row {
    OpeningUser {
        turn_id: TurnId,
        message: UserMessageV2,
    },
    WorkDisclosure {
        turn_id: TurnId,
        status: TurnStatusV2,
        expanded: bool,
        visible_entry_count: usize,
    },
    SteeredUser {
        turn_id: TurnId,
        segment_id: String,
        message: UserMessageV2,
    },
    Prose {
        turn_id: TurnId,
        segment_id: String,
        prose: AssistantTextV2,
    },
    WorkGroup {
        turn_id: TurnId,
        segment_id: String,
        group: WorkGroupV2,
    },
    ProductToolCall {
        turn_id: TurnId,
        segment_id: String,
        call: ProductToolCallV2,
    },
    InlineActivity {
        turn_id: TurnId,
        segment_id: String,
        activity: InlineActivityV2,
    },
    Notice {
        turn_id: TurnId,
        segment_id: String,
        notice: NoticeV2,
    },
    LiveTail {
        turn_id: TurnId,
        text: String,
    },
    Plan {
        turn_id: TurnId,
        plan: PlanPresentation,
    },
    FinalAnswer {
        turn_id: TurnId,
        answer: AssistantTextV2,
    },
    GeneratedImage {
        turn_id: TurnId,
        image: GeneratedImageV2,
    },
    Lifecycle {
        turn_id: TurnId,
        status: TurnStatusV2,
    },
}

impl TranscriptV2Row {
    /// Stable identity used by GPUI splices and expansion-state lookup.
    #[must_use]
    pub fn stable_id(&self) -> String {
        match self {
            Self::OpeningUser { turn_id, message } => {
                format!("turn:{turn_id}:opening-user:{}", message.id)
            }
            Self::WorkDisclosure { turn_id, .. } => format!("turn:{turn_id}:work-disclosure"),
            Self::SteeredUser {
                turn_id,
                segment_id,
                message,
            } => format!("turn:{turn_id}:segment:{segment_id}:steer:{}", message.id),
            Self::Prose {
                turn_id,
                segment_id,
                prose,
            } => format!("turn:{turn_id}:segment:{segment_id}:prose:{}", prose.id),
            Self::WorkGroup {
                turn_id,
                segment_id,
                group,
            } => work_group_stable_id(turn_id, segment_id, &group.id),
            Self::ProductToolCall {
                turn_id,
                segment_id,
                call,
            } => format!(
                "turn:{turn_id}:segment:{segment_id}:product-tool:{}",
                call.id
            ),
            Self::InlineActivity {
                turn_id,
                segment_id,
                activity,
            } => format!("turn:{turn_id}:segment:{segment_id}:inline:{}", activity.id),
            Self::Notice {
                turn_id,
                segment_id,
                notice,
            } => format!("turn:{turn_id}:segment:{segment_id}:notice:{}", notice.id),
            Self::LiveTail { turn_id, .. } => format!("turn:{turn_id}:live-tail"),
            Self::Plan { turn_id, .. } => format!("turn:{turn_id}:plan"),
            Self::FinalAnswer { turn_id, answer } => {
                format!("turn:{turn_id}:final-answer:{}", answer.id)
            }
            Self::GeneratedImage { turn_id, image } => {
                format!("turn:{turn_id}:generated-image:{}", image.id)
            }
            Self::Lifecycle { turn_id, .. } => format!("turn:{turn_id}:lifecycle"),
        }
    }
}

fn work_group_stable_id(turn_id: &TurnId, segment_id: &str, group_id: &str) -> String {
    format!("turn:{turn_id}:segment:{segment_id}:work-group:{group_id}")
}

/// Flatten a V2 projection using presentation-declared disclosure defaults.
#[must_use]
pub fn transcript_v2_rows(presentation: &TranscriptV2Presentation) -> Vec<TranscriptV2Row> {
    project_rows(presentation, &BTreeMap::new())
}

fn project_rows(
    presentation: &TranscriptV2Presentation,
    turn_expansion_overrides: &BTreeMap<String, bool>,
) -> Vec<TranscriptV2Row> {
    presentation
        .turns
        .iter()
        .flat_map(|turn| project_turn_rows(turn, turn_expansion_overrides))
        .collect()
}

fn working_client_starts(
    presentation: &TranscriptV2Presentation,
    now_unix_seconds: i64,
) -> BTreeMap<String, i64> {
    presentation
        .turns
        .iter()
        .filter_map(|turn| {
            matches!(turn.status, TurnStatusV2::Working { .. })
                .then_some((turn.turn_id.as_str().to_owned(), now_unix_seconds))
        })
        .collect()
}

fn project_turn_rows(
    turn: &TurnV2Presentation,
    turn_expansion_overrides: &BTreeMap<String, bool>,
) -> Vec<TranscriptV2Row> {
    let mut rows = Vec::new();
    if let Some(message) = &turn.opening_user_message {
        rows.push(TranscriptV2Row::OpeningUser {
            turn_id: turn.turn_id.clone(),
            message: message.clone(),
        });
    }

    let turn_key = turn.turn_id.as_str();
    let work_expanded = turn_expansion_overrides
        .get(turn_key)
        .copied()
        .unwrap_or(turn.work_disclosure.is_expanded_by_default);
    let visible_entry_count = visible_work_entry_count(turn);
    if turn.work_disclosure.is_visible {
        rows.push(TranscriptV2Row::WorkDisclosure {
            turn_id: turn.turn_id.clone(),
            status: turn.status.clone(),
            expanded: work_expanded,
            visible_entry_count,
        });
    }
    if work_expanded && turn.work_disclosure.is_visible {
        for segment in &turn.conversation_segments {
            project_segment_rows(turn, segment, &mut rows);
        }
        if let Some(text) = turn
            .live_tail
            .as_ref()
            .filter(|text| !text.trim().is_empty())
        {
            rows.push(TranscriptV2Row::LiveTail {
                turn_id: turn.turn_id.clone(),
                text: text.clone(),
            });
        }
    }
    if let Some(plan) = &turn.plan {
        rows.push(TranscriptV2Row::Plan {
            turn_id: turn.turn_id.clone(),
            plan: plan.clone(),
        });
    }
    if let Some(answer) = &turn.final_answer {
        rows.push(TranscriptV2Row::FinalAnswer {
            turn_id: turn.turn_id.clone(),
            answer: answer.clone(),
        });
    }
    rows.extend(turn.generated_images.iter().cloned().map(|image| {
        TranscriptV2Row::GeneratedImage {
            turn_id: turn.turn_id.clone(),
            image,
        }
    }));
    rows.push(TranscriptV2Row::Lifecycle {
        turn_id: turn.turn_id.clone(),
        status: turn.status.clone(),
    });
    rows
}

fn project_segment_rows(
    turn: &TurnV2Presentation,
    segment: &ConversationSegmentV2,
    rows: &mut Vec<TranscriptV2Row>,
) {
    if let Some(message) = &segment.steered_message {
        rows.push(TranscriptV2Row::SteeredUser {
            turn_id: turn.turn_id.clone(),
            segment_id: segment.id.clone(),
            message: message.clone(),
        });
    }
    for entry in &segment.narrative {
        if turn.work_disclosure.is_tail_mode && !narrative_is_live(entry) {
            continue;
        }
        let turn_id = turn.turn_id.clone();
        let segment_id = segment.id.clone();
        rows.push(match entry {
            NarrativeEntryV2::Prose(prose) => TranscriptV2Row::Prose {
                turn_id,
                segment_id,
                prose: prose.clone(),
            },
            NarrativeEntryV2::WorkGroup(group) => TranscriptV2Row::WorkGroup {
                turn_id,
                segment_id,
                group: group.clone(),
            },
            NarrativeEntryV2::ProductToolCall(call) => TranscriptV2Row::ProductToolCall {
                turn_id,
                segment_id,
                call: call.clone(),
            },
            NarrativeEntryV2::InlineActivity(activity) => TranscriptV2Row::InlineActivity {
                turn_id,
                segment_id,
                activity: activity.clone(),
            },
            NarrativeEntryV2::Notice(notice) => TranscriptV2Row::Notice {
                turn_id,
                segment_id,
                notice: notice.clone(),
            },
        });
    }
}

fn narrative_is_live(entry: &NarrativeEntryV2) -> bool {
    match entry {
        NarrativeEntryV2::WorkGroup(group) => {
            group.is_live
                || group.status.is_in_progress()
                || group.rows.iter().any(WorkRowV2::is_in_progress)
        }
        NarrativeEntryV2::ProductToolCall(call) => call.status.is_in_progress(),
        NarrativeEntryV2::InlineActivity(activity) => activity.status.is_in_progress(),
        NarrativeEntryV2::Prose(_) | NarrativeEntryV2::Notice(_) => false,
    }
}

fn visible_work_entry_count(turn: &TurnV2Presentation) -> usize {
    turn.conversation_segments
        .iter()
        .flat_map(|segment| &segment.narrative)
        .filter(|entry| !turn.work_disclosure.is_tail_mode || narrative_is_live(entry))
        .count()
        + usize::from(
            turn.live_tail
                .as_ref()
                .is_some_and(|tail| !tail.trim().is_empty()),
        )
}

/// Bottom-following, variable-height native Transcript V2 component.
pub struct CodexTranscriptV2 {
    presentation: TranscriptV2Presentation,
    rows: Arc<[TranscriptV2Row]>,
    list_state: ListState,
    theme: CodexTheme,
    /// Client fallback start, scoped to each working turn whose server
    /// timestamp is absent. A transcript may receive a later working turn.
    working_client_started_unix_seconds: BTreeMap<String, i64>,
    /// Wall-clock second used by the one active work-header tick.
    now_unix_seconds: i64,
    /// A single foreground-owned tick task refreshes active elapsed labels.
    work_tick_task: Option<Task<()>>,
    turn_expansion_overrides: BTreeMap<String, bool>,
    group_expansion_overrides: BTreeMap<String, bool>,
    expanded_work_rows: BTreeSet<String>,
}

impl CodexTranscriptV2 {
    #[must_use]
    pub fn new(presentation: &TranscriptV2Presentation) -> Self {
        let rows: Arc<[TranscriptV2Row]> = transcript_v2_rows(presentation).into();
        let list_state = ListState::new(rows.len(), ListAlignment::Bottom, px(800.));
        list_state.set_follow_mode(FollowMode::Tail);
        let now_unix_seconds = unix_seconds();
        Self {
            presentation: presentation.clone(),
            rows,
            list_state,
            theme: CodexTheme::default(),
            working_client_started_unix_seconds: working_client_starts(
                presentation,
                now_unix_seconds,
            ),
            now_unix_seconds,
            work_tick_task: None,
            turn_expansion_overrides: BTreeMap::new(),
            group_expansion_overrides: BTreeMap::new(),
            expanded_work_rows: BTreeSet::new(),
        }
    }

    #[must_use]
    pub fn with_theme(mut self, theme: CodexTheme) -> Self {
        self.theme = theme;
        self
    }

    #[must_use]
    pub const fn revision(&self) -> StateRevision {
        self.presentation.revision
    }

    #[must_use]
    pub fn list_state(&self) -> ListState {
        self.list_state.clone()
    }

    /// Replace the disposable projection while retaining viewport and explicit disclosure state.
    pub fn set_presentation(
        &mut self,
        presentation: &TranscriptV2Presentation,
        cx: &mut Context<Self>,
    ) {
        if presentation.revision < self.presentation.revision {
            return;
        }
        self.now_unix_seconds = unix_seconds();
        self.presentation = presentation.clone();
        self.sync_working_client_starts();
        self.prune_expansion_state();
        self.rebuild_rows();
        if !self.has_working_turn() {
            self.work_tick_task.take();
        }
        cx.notify();
    }

    fn has_working_turn(&self) -> bool {
        self.presentation
            .turns
            .iter()
            .any(|turn| matches!(turn.status, TurnStatusV2::Working { .. }))
    }

    fn sync_working_client_starts(&mut self) {
        let active_turns = self
            .presentation
            .turns
            .iter()
            .filter_map(|turn| {
                matches!(turn.status, TurnStatusV2::Working { .. })
                    .then_some(turn.turn_id.as_str().to_owned())
            })
            .collect::<BTreeSet<_>>();
        self.working_client_started_unix_seconds
            .retain(|turn_id, _| active_turns.contains(turn_id));
        for turn_id in active_turns {
            self.working_client_started_unix_seconds
                .entry(turn_id)
                .or_insert(self.now_unix_seconds);
        }
    }

    /// Start the one real GPUI timer used for active work headers. The task is
    /// deliberately lazy so an idle transcript does not wake once per second.
    fn ensure_work_tick(&mut self, cx: &Context<Self>) {
        if self.work_tick_task.is_some() || !self.has_working_turn() {
            return;
        }
        self.work_tick_task = Some(cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor().timer(Duration::from_secs(1)).await;
                let Ok(active) = this.update(cx, |transcript, cx| {
                    if !transcript.has_working_turn() {
                        transcript.work_tick_task.take();
                        return false;
                    }
                    transcript.now_unix_seconds = unix_seconds();
                    cx.notify();
                    true
                }) else {
                    break;
                };
                if !active {
                    break;
                }
            }
        }));
    }

    fn toggle_turn_work(&mut self, turn_id: String, cx: &mut Context<Self>) {
        let default = self
            .presentation
            .turns
            .iter()
            .find(|turn| turn.turn_id.as_str() == turn_id)
            .is_some_and(|turn| turn.work_disclosure.is_expanded_by_default);
        let next = !self
            .turn_expansion_overrides
            .get(&turn_id)
            .copied()
            .unwrap_or(default);
        self.turn_expansion_overrides.insert(turn_id, next);
        self.rebuild_rows();
        cx.notify();
    }

    fn toggle_group(&mut self, group_key: &str, cx: &mut Context<Self>) {
        let default = self
            .rows
            .iter()
            .find_map(|row| match row {
                TranscriptV2Row::WorkGroup { group, .. } if row.stable_id() == group_key => {
                    Some(group.is_expanded_by_default)
                }
                _ => None,
            })
            .unwrap_or(false);
        let next = !self
            .group_expansion_overrides
            .get(group_key)
            .copied()
            .unwrap_or(default);
        self.group_expansion_overrides
            .insert(group_key.to_owned(), next);
        self.remeasure_group(group_key);
        cx.notify();
    }

    fn toggle_work_row(&mut self, row_key: String, group_key: &str, cx: &mut Context<Self>) {
        if !self.expanded_work_rows.remove(&row_key) {
            self.expanded_work_rows.insert(row_key);
        }
        self.remeasure_group(group_key);
        cx.notify();
    }

    fn rebuild_rows(&mut self) {
        let next: Arc<[TranscriptV2Row]> =
            project_rows(&self.presentation, &self.turn_expansion_overrides).into();
        update_list_state(&self.list_state, &self.rows, &next);
        self.rows = next;
    }

    fn remeasure_group(&self, group_key: &str) {
        if let Some(index) = self
            .rows
            .iter()
            .position(|row| row.stable_id() == group_key)
        {
            self.list_state.remeasure_items(index..index + 1);
        }
    }

    fn prune_expansion_state(&mut self) {
        let turn_ids = self
            .presentation
            .turns
            .iter()
            .map(|turn| turn.turn_id.as_str())
            .collect::<BTreeSet<_>>();
        self.turn_expansion_overrides
            .retain(|turn_id, _| turn_ids.contains(turn_id.as_str()));
        let group_keys = self
            .presentation
            .turns
            .iter()
            .flat_map(|turn| {
                turn.conversation_segments.iter().flat_map(|segment| {
                    segment.narrative.iter().filter_map(|entry| match entry {
                        NarrativeEntryV2::WorkGroup(group) => {
                            Some(work_group_stable_id(&turn.turn_id, &segment.id, &group.id))
                        }
                        _ => None,
                    })
                })
            })
            .collect::<BTreeSet<_>>();
        self.group_expansion_overrides
            .retain(|group_key, _| group_keys.contains(group_key));
        self.expanded_work_rows.retain(|row_key| {
            group_keys
                .iter()
                .any(|group_key| row_key.starts_with(&format!("{group_key}:row:")))
        });
    }
}

impl EventEmitter<TranscriptEvent> for CodexTranscriptV2 {}

impl Render for CodexTranscriptV2 {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.ensure_work_tick(cx);
        let rows = Arc::clone(&self.rows);
        let state = self.list_state.clone();
        let theme = self.theme;
        let now_unix_seconds = self.now_unix_seconds;
        let working_client_started_unix_seconds = self.working_client_started_unix_seconds.clone();
        let emitter = cx.entity().downgrade();
        let group_expansion_overrides = self.group_expansion_overrides.clone();
        let expanded_work_rows = self.expanded_work_rows.clone();
        div()
            .id("codex-transcript-v2")
            .role(Role::Log)
            .aria_label("Codex transcript")
            .size_full()
            .overflow_hidden()
            .bg(theme.background)
            .text_color(theme.text)
            .text_size(px(TranscriptLayoutMetrics::CHAT_TEXT_SIZE))
            .child(
                div()
                    .flex()
                    .justify_center()
                    .size_full()
                    .px(px(TranscriptLayoutMetrics::HORIZONTAL_MARGIN))
                    .child(
                        div()
                            .w_full()
                            .max_w(px(TranscriptLayoutMetrics::OUTER_MAX_WIDTH))
                            .h_full()
                            .child(
                                list(state, move |index, _window, _cx| {
                                    rows.get(index).map_or_else(
                                        || div().into_any(),
                                        |row| {
                                            render_row(
                                                row,
                                                theme,
                                                &emitter,
                                                &group_expansion_overrides,
                                                &expanded_work_rows,
                                                now_unix_seconds,
                                                &working_client_started_unix_seconds,
                                            )
                                        },
                                    )
                                })
                                .size_full(),
                            ),
                    ),
            )
    }
}

fn update_list_state(state: &ListState, old: &[TranscriptV2Row], new: &[TranscriptV2Row]) {
    let prefix = old
        .iter()
        .zip(new)
        .take_while(|(left, right)| left.stable_id() == right.stable_id())
        .count();
    let suffix = old[prefix..]
        .iter()
        .rev()
        .zip(new[prefix..].iter().rev())
        .take_while(|(left, right)| left.stable_id() == right.stable_id())
        .count();
    let old_middle_end = old.len() - suffix;
    let new_middle_end = new.len() - suffix;
    if prefix != old_middle_end || prefix != new_middle_end {
        state.splice(prefix..old_middle_end, new_middle_end - prefix);
    }
    let mut changed = Vec::new();
    changed.extend((0..prefix).filter(|&index| old[index] != new[index]));
    changed.extend((0..suffix).filter_map(|offset| {
        let old_index = old.len() - suffix + offset;
        let new_index = new.len() - suffix + offset;
        (old[old_index] != new[new_index]).then_some(new_index)
    }));
    for range in contiguous_ranges(&changed) {
        state.remeasure_items(range);
    }
}

fn contiguous_ranges(indices: &[usize]) -> Vec<std::ops::Range<usize>> {
    let mut ranges: Vec<std::ops::Range<usize>> = Vec::new();
    for &index in indices {
        match ranges.last_mut() {
            Some(range) if range.end == index => range.end += 1,
            _ => ranges.push(index..index + 1),
        }
    }
    ranges
}

fn render_row(
    row: &TranscriptV2Row,
    theme: CodexTheme,
    emitter: &WeakEntity<CodexTranscriptV2>,
    group_expansion_overrides: &BTreeMap<String, bool>,
    expanded_work_rows: &BTreeSet<String>,
    now_unix_seconds: i64,
    working_client_started_unix_seconds: &BTreeMap<String, i64>,
) -> AnyElement {
    match row {
        TranscriptV2Row::OpeningUser { message, .. }
        | TranscriptV2Row::SteeredUser { message, .. } => {
            render_user(row.stable_id(), message, theme)
        }
        TranscriptV2Row::WorkDisclosure {
            turn_id,
            status,
            expanded,
            visible_entry_count,
        } => render_work_disclosure(
            row.stable_id(),
            turn_id,
            status,
            *expanded,
            *visible_entry_count,
            theme,
            emitter,
            now_unix_seconds,
            working_client_started_unix_seconds
                .get(turn_id.as_str())
                .copied(),
        ),
        TranscriptV2Row::Prose { prose, .. }
        | TranscriptV2Row::FinalAnswer { answer: prose, .. } => {
            render_assistant(row.stable_id(), prose, theme, emitter)
        }
        TranscriptV2Row::WorkGroup { group, .. } => {
            let group_key = row.stable_id();
            render_work_group(
                &group_key,
                group,
                theme,
                emitter,
                group_expansion_overrides
                    .get(&group_key)
                    .copied()
                    .unwrap_or(group.is_expanded_by_default),
                expanded_work_rows,
            )
        }
        TranscriptV2Row::ProductToolCall { call, .. } => {
            render_product_tool(row.stable_id(), call, theme)
        }
        TranscriptV2Row::InlineActivity { activity, .. } => {
            render_inline_activity(row.stable_id(), activity, theme)
        }
        TranscriptV2Row::Notice { notice, .. } => render_notice(row.stable_id(), notice, theme),
        TranscriptV2Row::LiveTail { text, .. } => render_live_tail(row.stable_id(), text, theme),
        TranscriptV2Row::Plan { plan, .. } => render_plan(row.stable_id(), plan, theme),
        TranscriptV2Row::GeneratedImage { image, .. } => {
            render_generated_image(row.stable_id(), image, theme)
        }
        TranscriptV2Row::Lifecycle { status, .. } => {
            render_lifecycle(row.stable_id(), status, theme)
        }
    }
}

fn render_user(id: String, message: &UserMessageV2, theme: CodexTheme) -> AnyElement {
    let text = message.display_text();
    div()
        .id(id)
        .role(Role::Article)
        .aria_label(bounded_label(format!("You: {text}")))
        .w_full()
        .mb(px(TranscriptLayoutMetrics::ITEM_GAP))
        .flex()
        .flex_col()
        .items_end()
        .child(
            div()
                .max_w(px(TranscriptLayoutMetrics::USER_MAX_WIDTH))
                .rounded(px(16.))
                .bg(theme.user_message)
                .border_1()
                .border_color(theme.user_message_stroke)
                .px_3()
                .py_2()
                .whitespace_normal()
                .child(text),
        )
        .into_any()
}

fn render_assistant(
    id: String,
    prose: &AssistantTextV2,
    theme: CodexTheme,
    emitter: &WeakEntity<CodexTranscriptV2>,
) -> AnyElement {
    div()
        .id(id)
        .role(Role::Article)
        .aria_label(bounded_label(format!("Codex: {}", prose.text)))
        .w_full()
        .mb(px(TranscriptLayoutMetrics::ITEM_GAP))
        .child(render_markdown(&prose.markdown, theme, emitter))
        .into_any()
}

#[allow(clippy::too_many_arguments)]
fn render_work_disclosure(
    id: String,
    turn_id: &TurnId,
    status: &TurnStatusV2,
    expanded: bool,
    visible_entry_count: usize,
    theme: CodexTheme,
    emitter: &WeakEntity<CodexTranscriptV2>,
    now_unix_seconds: i64,
    client_started_unix_seconds: Option<i64>,
) -> AnyElement {
    let label = work_disclosure_label(
        status,
        visible_entry_count,
        now_unix_seconds,
        client_started_unix_seconds.unwrap_or(now_unix_seconds),
    );
    let toggle_turn_id = turn_id.as_str().to_owned();
    let is_actionable = matches!(status, TurnStatusV2::Done { .. });
    div()
        .id(id)
        .aria_label(format!(
            "{label}, {visible_entry_count} item(s), {}",
            if expanded { "expanded" } else { "collapsed" }
        ))
        .w_full()
        .max_w(px(TranscriptLayoutMetrics::CARD_MAX_WIDTH))
        .h(px(TranscriptLayoutMetrics::WORK_HEADER_HEIGHT))
        .mb(px(TranscriptLayoutMetrics::ITEM_GAP))
        .flex()
        .items_center()
        .gap_1()
        .text_size(px(TranscriptLayoutMetrics::CAPTION_TEXT_SIZE))
        .text_color(theme.tertiary_text)
        .child(label)
        .when(is_actionable, |view| {
            view.child(div().child(if expanded { "⌄" } else { "›" }))
        })
        .when(is_actionable, |view| {
            let emitter = emitter.clone();
            let click_emitter = emitter.clone();
            let keyboard_turn_id = toggle_turn_id.clone();
            view.role(Role::Button)
                .aria_expanded(expanded)
                .focusable()
                .tab_stop(true)
                .cursor_pointer()
                .on_click(move |_, _, cx| {
                    click_emitter
                        .update(cx, |transcript, cx| {
                            transcript.toggle_turn_work(toggle_turn_id.clone(), cx);
                        })
                        .ok();
                })
                .on_key_down(move |event, window, cx| {
                    if is_disclosure_key(event) {
                        window.prevent_default();
                        emitter
                            .update(cx, |transcript, cx| {
                                transcript.toggle_turn_work(keyboard_turn_id.clone(), cx);
                            })
                            .ok();
                    }
                })
        })
        .when(!is_actionable, |view| view.role(Role::Status))
        .into_any()
}

fn work_disclosure_label(
    status: &TurnStatusV2,
    visible_entry_count: usize,
    now_unix_seconds: i64,
    client_started_unix_seconds: i64,
) -> String {
    match status {
        TurnStatusV2::Working { .. } if visible_entry_count == 0 => "Thinking".to_owned(),
        TurnStatusV2::Working { since_unix_seconds } => format!(
            "Working for {}s",
            working_elapsed_seconds(
                now_unix_seconds,
                *since_unix_seconds,
                client_started_unix_seconds,
            )
        ),
        TurnStatusV2::Done { duration_ms } => duration_ms.map_or_else(
            || "Worked".to_owned(),
            |duration| format!("Worked for {}", format_duration(duration)),
        ),
        TurnStatusV2::Interrupted {
            duration_ms,
            message,
        } => interrupted_work_label(*duration_ms, message),
        TurnStatusV2::Failed { message, .. } => {
            if message.trim().is_empty() {
                "Work failed".to_owned()
            } else {
                bounded_label(message.clone())
            }
        }
    }
}

fn render_work_group(
    id: &str,
    group: &WorkGroupV2,
    theme: CodexTheme,
    emitter: &WeakEntity<CodexTranscriptV2>,
    expanded: bool,
    expanded_work_rows: &BTreeSet<String>,
) -> AnyElement {
    let label = group.display_header().to_owned();
    let group_key = id.to_owned();
    div()
        .id(id.to_owned())
        .role(Role::Group)
        .aria_label(format!("{label}, {} activity row(s)", group.rows.len()))
        .w_full()
        .max_w(px(TranscriptLayoutMetrics::CARD_MAX_WIDTH))
        .mb(px(TranscriptLayoutMetrics::ITEM_GAP))
        .child({
            let emitter = emitter.clone();
            let click_emitter = emitter.clone();
            let keyboard_group_key = group_key.clone();
            div()
                .id(format!("{id}:disclosure"))
                .role(Role::Button)
                .aria_label(format!(
                    "{label}, {} activity row(s), {}",
                    group.rows.len(),
                    if expanded { "expanded" } else { "collapsed" }
                ))
                .aria_expanded(expanded)
                .focusable()
                .tab_stop(true)
                .h(px(TranscriptLayoutMetrics::WORK_ROW_HEIGHT))
                .w_full()
                .flex()
                .items_center()
                .gap_2()
                .text_size(px(TranscriptLayoutMetrics::CAPTION_TEXT_SIZE))
                .text_color(theme.tertiary_text)
                .cursor_pointer()
                .child(work_status_glyph(&group.status, theme))
                .child(div().min_w_0().truncate().child(label))
                .child(div().child(if expanded { "⌄" } else { "›" }))
                .on_click(move |_, _, cx| {
                    click_emitter
                        .update(cx, |transcript, cx| {
                            transcript.toggle_group(&group_key, cx);
                        })
                        .ok();
                })
                .on_key_down(move |event, window, cx| {
                    if is_disclosure_key(event) {
                        window.prevent_default();
                        emitter
                            .update(cx, |transcript, cx| {
                                transcript.toggle_group(&keyboard_group_key, cx);
                            })
                            .ok();
                    }
                })
        })
        .when(expanded, |view| {
            view.child(
                div()
                    .id(format!("{id}:rows"))
                    .role(Role::List)
                    .aria_label("Work group details")
                    .w_full()
                    .flex()
                    .flex_col()
                    .children(group.rows.iter().map(|row| {
                        let row_key = work_row_key(id, row.id());
                        render_work_row(
                            row,
                            id,
                            theme,
                            emitter,
                            expanded_work_rows.contains(&row_key),
                        )
                    })),
            )
        })
        .into_any()
}

#[allow(clippy::too_many_lines)]
fn render_work_row(
    row: &WorkRowV2,
    group_key: &str,
    theme: CodexTheme,
    emitter: &WeakEntity<CodexTranscriptV2>,
    expanded: bool,
) -> AnyElement {
    let row_key = work_row_key(group_key, row.id());
    let (label, detail) = work_row_content(row);
    let has_detail = detail.is_some();
    let status = row.status();
    let label_for_aria = label.clone();
    let (duration, execution_state, use_command_font) = match row {
        WorkRowV2::Command(command) => (
            command_duration_label(command),
            Some(command_execution_state_label(command)),
            command_row_is_monospaced(command),
        ),
        _ => (None, None, false),
    };
    let label_view = div()
        .min_w_0()
        .flex_1()
        .truncate()
        .when(use_command_font, |view| view.font_family("monospace"))
        .child(label);
    let status_color = work_status_color(status, theme);
    let header = div()
        .id(format!("work-row:{row_key}:disclosure"))
        .aria_label(if has_detail {
            format!(
                "{label_for_aria}, {}, {}",
                work_status_label(status),
                if expanded { "expanded" } else { "collapsed" }
            )
        } else {
            format!("{label_for_aria}, {}", work_status_label(status))
        })
        .when(has_detail, |view| {
            let emitter = emitter.clone();
            let click_emitter = emitter.clone();
            let toggle_key = row_key.clone();
            let toggle_group_key = group_key.to_owned();
            let keyboard_toggle_key = toggle_key.clone();
            let keyboard_group_key = toggle_group_key.clone();
            view.role(Role::Button)
                .aria_expanded(expanded)
                .focusable()
                .tab_stop(true)
                .cursor_pointer()
                .on_click(move |_, _, cx| {
                    click_emitter
                        .update(cx, |transcript, cx| {
                            transcript.toggle_work_row(toggle_key.clone(), &toggle_group_key, cx);
                        })
                        .ok();
                })
                .on_key_down(move |event, window, cx| {
                    if is_disclosure_key(event) {
                        window.prevent_default();
                        emitter
                            .update(cx, |transcript, cx| {
                                transcript.toggle_work_row(
                                    keyboard_toggle_key.clone(),
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
        .child(
            div()
                .w(px(14.))
                .text_color(theme.muted_text)
                .child(work_kind_glyph(row)),
        )
        .child(work_status_glyph(status, theme))
        .child(label_view)
        .when_some(duration, |view, duration| {
            view.child(
                div()
                    .text_size(px(TranscriptLayoutMetrics::CAPTION_TEXT_SIZE))
                    .text_color(theme.tertiary_text)
                    .child(duration),
            )
        })
        .when_some(execution_state, |view, state| {
            view.child(
                div()
                    .text_size(px(TranscriptLayoutMetrics::CAPTION_TEXT_SIZE))
                    .text_color(status_color)
                    .child(state),
            )
        })
        .when(has_detail, |view| {
            view.child(
                div()
                    .text_size(px(TranscriptLayoutMetrics::CAPTION_TEXT_SIZE))
                    .child(if expanded { "⌄" } else { "›" }),
            )
        });
    div()
        .id(format!("work-row:{row_key}"))
        .role(Role::ListItem)
        .aria_label("Work activity row")
        .w_full()
        .flex()
        .flex_col()
        .child(header)
        .when(expanded && has_detail, |view| {
            view.child(
                div()
                    .id(format!("work-row:{row_key}:detail"))
                    .role(Role::Region)
                    .aria_label("Work activity detail")
                    .ml(px(38.))
                    .mb_2()
                    .max_h(px(220.))
                    .overflow_y_scroll()
                    .rounded_md()
                    .border_1()
                    .border_color(theme.border)
                    .bg(theme.surface)
                    .p_2()
                    .font_family("monospace")
                    .text_size(px(TranscriptLayoutMetrics::CAPTION_TEXT_SIZE))
                    .text_color(theme.muted_text)
                    .whitespace_normal()
                    .when_some(detail, gpui::ParentElement::child),
            )
        })
        .into_any()
}

fn work_row_key(group_key: &str, row_id: &str) -> String {
    format!("{group_key}:row:{row_id}")
}

const COMMAND_LABEL_LIMIT: usize = 280;

/// The command text is the primary label. A semantic label alone can hide the
/// actual process while it is still running (for example, "Running command").
#[must_use]
fn command_row_label(command: &CommandRowV2) -> String {
    let command_text = command.command.trim();
    if !matches!(command.category, WorkCategoryV2::Run) {
        return if command.label.trim().is_empty() {
            truncate_middle(command_text, COMMAND_LABEL_LIMIT)
        } else {
            truncate_middle(command.label.trim(), COMMAND_LABEL_LIMIT)
        };
    }
    if command_text.is_empty() {
        return truncate_middle(command.label.trim(), COMMAND_LABEL_LIMIT);
    }
    truncate_middle(format!("$ {command_text}"), COMMAND_LABEL_LIMIT)
}

#[must_use]
fn command_row_is_monospaced(command: &CommandRowV2) -> bool {
    matches!(command.category, WorkCategoryV2::Run)
}

/// Explicit process outcome shown beside every command duration.
#[must_use]
fn command_execution_state_label(command: &CommandRowV2) -> String {
    match &command.status {
        WorkItemStatusV2::InProgress => "running".to_owned(),
        WorkItemStatusV2::Completed => match command.exit_code {
            Some(0) => "succeeded · exit 0".to_owned(),
            Some(code) => format!("failed · exit {code}"),
            None => "finished".to_owned(),
        },
        WorkItemStatusV2::Failed => command.exit_code.map_or_else(
            || "failed".to_owned(),
            |code| format!("failed · exit {code}"),
        ),
        WorkItemStatusV2::Declined => "stopped".to_owned(),
        WorkItemStatusV2::Unknown(_) => "status unknown".to_owned(),
    }
}

#[must_use]
fn command_duration_label(command: &CommandRowV2) -> Option<String> {
    command.duration_ms.map(format_duration)
}

#[allow(clippy::too_many_lines)]
fn work_row_content(row: &WorkRowV2) -> (String, Option<String>) {
    match row {
        WorkRowV2::Command(command) => {
            let mut detail = Vec::new();
            if !command.command.trim().is_empty() {
                detail.push(format!("Command\n{}", command.command.trim()));
            }
            if let Some(cwd) = &command.cwd {
                detail.push(format!("Working directory: {cwd}"));
            }
            if let Some(output) = &command.output {
                detail.push(output.text.to_string());
                if output.truncated {
                    detail.push(format!(
                        "{} output byte(s) omitted",
                        output.total_bytes.saturating_sub(output.text.len())
                    ));
                }
            }
            if let Some(exit_code) = command.exit_code {
                detail.push(format!("Exit code: {exit_code}"));
            }
            (command_row_label(command), nonempty_detail(detail))
        }
        WorkRowV2::FileChange(file_change) => {
            const MAXIMUM_FILES: usize = 12;
            const MAXIMUM_LINES_PER_FILE: usize = 16;
            let paths = file_change
                .changes
                .iter()
                .take(3)
                .map(|change| change.destination_path.as_deref().unwrap_or(&change.path))
                .collect::<Vec<_>>()
                .join(" · ");
            let hidden = file_change.changes.len().saturating_sub(3);
            let label = if hidden == 0 {
                format!("Edited {paths}")
            } else {
                format!("Edited {paths} · +{hidden} more")
            };
            let mut detail = file_change
                .changes
                .iter()
                .take(MAXIMUM_FILES)
                .flat_map(|change| {
                    std::iter::once(change.path.clone()).chain(
                        change
                            .diff
                            .lines()
                            .take(MAXIMUM_LINES_PER_FILE)
                            .map(str::to_owned),
                    )
                })
                .collect::<Vec<_>>();
            if file_change.changes.len() > MAXIMUM_FILES {
                detail.push(format!(
                    "{} additional file(s)",
                    file_change.changes.len() - MAXIMUM_FILES
                ));
            }
            (label, nonempty_detail(detail))
        }
        WorkRowV2::McpToolCall(call) => {
            let label = format!("Called {} · {}", call.app_name, call.tool);
            let mut detail = Vec::new();
            if let Some(progress) = &call.progress {
                detail.push(format!("Progress\n{}", bounded_label(progress.clone())));
            }
            if let Some(error) = &call.error_first_line {
                detail.push(format!("Error\n{error}"));
            }
            if let Some(arguments) = &call.arguments {
                detail.push(format!("Arguments\n{}", compact_json(arguments)));
            }
            if let Some(result) = &call.result {
                detail.push(format!("Result\n{}", compact_json(result)));
            }
            (
                call.progress.as_ref().map_or(label.clone(), |progress| {
                    format!("{label} · {}", bounded_label(progress.clone()))
                }),
                nonempty_detail(detail),
            )
        }
        WorkRowV2::WebSearch(search) => (format!("Searched for {}", search.query), None),
        WorkRowV2::Collaboration(collaboration) => {
            let agents = if collaboration.agent_names.is_empty() {
                "agent".to_owned()
            } else {
                collaboration.agent_names.join(", ")
            };
            let label = format!(
                "{} · {agents}",
                collaboration_action_label(collaboration.action)
            );
            let mut detail = Vec::new();
            if let Some(instructions) = &collaboration.instructions {
                detail.push(instructions.clone());
            }
            detail.extend(
                collaboration
                    .agent_messages
                    .iter()
                    .map(|(agent, message)| format!("{agent}: {message}")),
            );
            (label, nonempty_detail(detail))
        }
        WorkRowV2::Other(other) => (other.label.clone(), None),
    }
}

fn nonempty_detail(parts: Vec<String>) -> Option<String> {
    let detail = parts
        .into_iter()
        .filter(|part| !part.trim().is_empty())
        .collect::<Vec<_>>()
        .join("\n\n");
    (!detail.is_empty()).then_some(detail)
}

fn render_product_tool(id: String, call: &ProductToolCallV2, theme: CodexTheme) -> AnyElement {
    let title = call.namespace.as_ref().map_or_else(
        || call.tool.clone(),
        |namespace| format!("{namespace} · {}", call.tool),
    );
    let mut detail = Vec::new();
    if let Some(arguments) = &call.arguments {
        detail.push(format!("Arguments\n{}", compact_json(arguments)));
    }
    if !call.content_items.is_empty() {
        detail.push(format!(
            "Content\n{}",
            compact_json(&serde_json::Value::Array(call.content_items.clone()))
        ));
    }
    render_card(
        id,
        "Product tool call",
        title,
        nonempty_detail(detail).unwrap_or_else(|| work_status_label(&call.status).to_owned()),
        theme,
    )
}

fn render_inline_activity(
    id: String,
    activity: &InlineActivityV2,
    theme: CodexTheme,
) -> AnyElement {
    div()
        .id(id)
        .role(Role::Status)
        .aria_label(bounded_label(format!(
            "{}: {}",
            work_status_label(&activity.status),
            activity.label
        )))
        .w_full()
        .max_w(px(TranscriptLayoutMetrics::CARD_MAX_WIDTH))
        .min_h(px(TranscriptLayoutMetrics::WORK_ROW_HEIGHT))
        .mb(px(TranscriptLayoutMetrics::ITEM_GAP))
        .flex()
        .items_center()
        .gap_2()
        .text_sm()
        .text_color(theme.muted_text)
        .child(work_status_glyph(&activity.status, theme))
        .child(activity.label.clone())
        .when_some(activity.detail.clone(), |view, detail| {
            view.child(
                div()
                    .text_size(px(TranscriptLayoutMetrics::CAPTION_TEXT_SIZE))
                    .truncate()
                    .child(detail),
            )
        })
        .into_any()
}

fn render_notice(id: String, notice: &NoticeV2, theme: CodexTheme) -> AnyElement {
    render_card(
        id,
        "Notice",
        "Notice".to_owned(),
        notice.message.clone(),
        theme,
    )
}

fn render_live_tail(id: String, text: &str, theme: CodexTheme) -> AnyElement {
    div()
        .id(id)
        .role(Role::Status)
        .aria_label(bounded_label(format!("Current activity: {text}")))
        .w_full()
        .max_w(px(TranscriptLayoutMetrics::CARD_MAX_WIDTH))
        .mb(px(TranscriptLayoutMetrics::ITEM_GAP))
        .text_sm()
        .text_color(theme.muted_text)
        .whitespace_normal()
        .child(text.to_owned())
        .into_any()
}

fn render_plan(id: String, plan: &PlanPresentation, theme: CodexTheme) -> AnyElement {
    let steps = plan
        .steps
        .iter()
        .enumerate()
        .map(|(index, step)| {
            let (marker, color) = match &step.status {
                codex_app_server_state::PlanStepStatus::Pending => ("○", theme.muted_text),
                codex_app_server_state::PlanStepStatus::InProgress => ("◉", theme.accent),
                codex_app_server_state::PlanStepStatus::Completed => ("●", theme.success),
                codex_app_server_state::PlanStepStatus::Unknown(_) => ("?", theme.warning),
            };
            div()
                .id(("v2-plan-step", index))
                .role(Role::ListItem)
                .aria_label(step.step.clone())
                .flex()
                .gap_2()
                .child(div().text_color(color).child(marker))
                .child(div().flex_1().whitespace_normal().child(step.step.clone()))
        })
        .collect::<Vec<_>>();
    div()
        .id(id)
        .role(Role::Region)
        .aria_label("Turn plan")
        .w_full()
        .max_w(px(TranscriptLayoutMetrics::CARD_MAX_WIDTH))
        .mb(px(TranscriptLayoutMetrics::ITEM_GAP))
        .rounded_lg()
        .border_1()
        .border_color(theme.border)
        .bg(theme.surface)
        .p_3()
        .child(div().text_sm().child("Plan"))
        .when_some(plan.explanation.clone(), |view, explanation| {
            view.child(
                div()
                    .mt_1()
                    .text_size(px(TranscriptLayoutMetrics::CAPTION_TEXT_SIZE))
                    .text_color(theme.muted_text)
                    .whitespace_normal()
                    .child(explanation),
            )
        })
        .child(
            div()
                .id("v2-plan-steps")
                .role(Role::List)
                .aria_label("Plan steps")
                .mt_2()
                .flex()
                .flex_col()
                .gap_2()
                .children(steps),
        )
        .into_any()
}

fn render_generated_image(id: String, image: &GeneratedImageV2, theme: CodexTheme) -> AnyElement {
    let detail = image.revised_prompt.as_ref().map_or_else(
        || image.source.clone(),
        |prompt| format!("{}\n\n{prompt}", image.source),
    );
    let local_path = local_image_path(&image.source);
    div()
        .id(id)
        .role(Role::Article)
        .aria_label(bounded_label(format!("Generated image: {detail}")))
        .w_full()
        .max_w(px(TranscriptLayoutMetrics::CARD_MAX_WIDTH))
        .mb(px(TranscriptLayoutMetrics::ITEM_GAP))
        .rounded_lg()
        .border_1()
        .border_color(theme.border)
        .bg(theme.surface)
        .px_3()
        .py_2()
        .child(div().text_sm().child("Generated image"))
        .when_some(local_path, |view, path| {
            view.child(
                div()
                    .mt_2()
                    .w_full()
                    .h(px(240.))
                    .rounded_md()
                    .overflow_hidden()
                    .bg(theme.background)
                    .child(
                        img(path)
                            .size_full()
                            .object_fit(ObjectFit::Contain)
                            .with_fallback({
                                let source = image.source.clone();
                                move || {
                                    div()
                                        .size_full()
                                        .flex()
                                        .items_center()
                                        .justify_center()
                                        .text_color(theme.muted_text)
                                        .text_xs()
                                        .child(format!("Unable to load {source}"))
                                        .into_any()
                                }
                            }),
                    ),
            )
        })
        .child(
            div()
                .mt_1()
                .text_size(px(TranscriptLayoutMetrics::CAPTION_TEXT_SIZE))
                .text_color(theme.muted_text)
                .whitespace_normal()
                .child(detail),
        )
        .into_any()
}

/// GPUI can load local paths through its resource loader. Remote/data payloads
/// remain a textual fallback because the transcript renderer never fetches
/// media or interprets untrusted image data.
fn local_image_path(source: &str) -> Option<PathBuf> {
    let source = source.trim();
    let path = source
        .strip_prefix("file://")
        .map_or_else(|| PathBuf::from(source), PathBuf::from);
    path.is_absolute()
        .then_some(path)
        .filter(|path| path.is_file())
}

fn render_lifecycle(id: String, _status: &TurnStatusV2, _theme: CodexTheme) -> AnyElement {
    // Swift's AppKit transcript uses the work header and hover footer for turn
    // state. There is no visible standalone lifecycle badge between turns.
    div()
        .id(id)
        .w_full()
        .h(px(TranscriptLayoutMetrics::TURN_GAP))
        .into_any()
}

fn render_card(
    id: String,
    accessibility_prefix: &str,
    title: String,
    detail: String,
    theme: CodexTheme,
) -> AnyElement {
    div()
        .id(id)
        .role(Role::Article)
        .aria_label(bounded_label(format!(
            "{accessibility_prefix}: {title}. {detail}"
        )))
        .w_full()
        .max_w(px(TranscriptLayoutMetrics::CARD_MAX_WIDTH))
        .mb(px(TranscriptLayoutMetrics::ITEM_GAP))
        .rounded_lg()
        .border_1()
        .border_color(theme.border)
        .bg(theme.surface)
        .px_3()
        .py_2()
        .child(div().text_sm().child(title))
        .child(
            div()
                .mt_1()
                .text_size(px(TranscriptLayoutMetrics::CAPTION_TEXT_SIZE))
                .text_color(theme.muted_text)
                .whitespace_normal()
                .child(detail),
        )
        .into_any()
}

fn work_status_glyph(status: &WorkItemStatusV2, theme: CodexTheme) -> gpui::Div {
    let (glyph, color) = match status {
        WorkItemStatusV2::InProgress => ("◌", theme.running),
        WorkItemStatusV2::Completed => ("✓", theme.success),
        WorkItemStatusV2::Failed => ("×", theme.danger),
        WorkItemStatusV2::Declined => ("—", theme.warning),
        WorkItemStatusV2::Unknown(_) => ("?", theme.warning),
    };
    div().w(px(14.)).text_color(color).child(glyph)
}

fn work_status_color(status: &WorkItemStatusV2, theme: CodexTheme) -> gpui::Rgba {
    match status {
        WorkItemStatusV2::InProgress => theme.running,
        WorkItemStatusV2::Completed => theme.success,
        WorkItemStatusV2::Failed => theme.danger,
        WorkItemStatusV2::Declined | WorkItemStatusV2::Unknown(_) => theme.warning,
    }
}

/// Stable semantic kind glyphs keep command/file/tool rows distinguishable
/// even when a status glyph has the same shape for every row.
fn work_kind_glyph(row: &WorkRowV2) -> &'static str {
    match row {
        WorkRowV2::Command(_) => "⌘",
        WorkRowV2::FileChange(_) => "✎",
        WorkRowV2::McpToolCall(_) => "◈",
        WorkRowV2::WebSearch(_) => "⌕",
        WorkRowV2::Collaboration(_) => "◎",
        WorkRowV2::Other(_) => "·",
    }
}

fn is_disclosure_key(event: &KeyDownEvent) -> bool {
    is_disclosure_key_name(&event.keystroke.key)
}

#[must_use]
fn is_disclosure_key_name(key: &str) -> bool {
    matches!(key, "enter" | "return" | "space" | " ")
}

fn work_status_label(status: &WorkItemStatusV2) -> &str {
    match status {
        WorkItemStatusV2::InProgress => "In progress",
        WorkItemStatusV2::Completed => "Completed",
        WorkItemStatusV2::Failed => "Failed",
        WorkItemStatusV2::Declined => "Declined",
        WorkItemStatusV2::Unknown(_) => "Unknown",
    }
}

fn collaboration_action_label(action: CollaborationActionV2) -> &'static str {
    match action {
        CollaborationActionV2::Created => "Created agent",
        CollaborationActionV2::SentInput => "Messaged agent",
        CollaborationActionV2::Waited => "Waited for agent",
        CollaborationActionV2::Closed => "Closed agent",
        CollaborationActionV2::Started => "Agent started",
        CollaborationActionV2::Interacted => "Agent interacted",
        CollaborationActionV2::Interrupted => "Interrupted agent",
    }
}

fn compact_json(value: &serde_json::Value) -> String {
    let text = serde_json::to_string_pretty(value).unwrap_or_else(|_| "<invalid JSON>".to_owned());
    truncate_chars(text, 12_000)
}

fn bounded_label(label: String) -> String {
    truncate_chars(label, 512)
}

/// Bound a visible command/path while retaining both its beginning and its
/// useful trailing arguments or filename. The result is always UTF-8 safe.
fn truncate_middle(text: impl AsRef<str>, maximum_chars: usize) -> String {
    let text = text.as_ref();
    let count = text.chars().count();
    if count <= maximum_chars {
        return text.to_owned();
    }
    if maximum_chars <= 1 {
        return "…".chars().take(maximum_chars).collect();
    }
    let available = maximum_chars - 1;
    let left_count = available.div_ceil(2);
    let right_count = available / 2;
    let left = text.chars().take(left_count).collect::<String>();
    let right = text
        .chars()
        .skip(count.saturating_sub(right_count))
        .collect::<String>();
    format!("{left}…{right}")
}

fn truncate_chars(mut text: String, maximum_chars: usize) -> String {
    let Some(byte_index) = text
        .char_indices()
        .nth(maximum_chars)
        .map(|(index, _)| index)
    else {
        return text;
    };
    text.truncate(byte_index);
    text.push('…');
    text
}

fn unix_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| {
            i64::try_from(duration.as_secs()).unwrap_or(i64::MAX)
        })
}

/// Calculate active work elapsed time from the server timestamp, falling back
/// to the client-side start captured when the component was created.
#[must_use]
fn working_elapsed_seconds(
    now_unix_seconds: i64,
    since_unix_seconds: Option<i64>,
    client_started_unix_seconds: i64,
) -> u64 {
    u64::try_from(
        now_unix_seconds
            .saturating_sub(since_unix_seconds.unwrap_or(client_started_unix_seconds))
            .max(0),
    )
    .unwrap_or_default()
}

fn interrupted_work_label(duration_ms: Option<u64>, message: &str) -> String {
    let elapsed = duration_ms
        .map(|duration| format!(" after {}", format_duration(duration)))
        .unwrap_or_default();
    let message = message.trim();
    if message.is_empty() {
        format!("Interrupted{elapsed}")
    } else {
        bounded_label(format!("Interrupted{elapsed}: {message}"))
    }
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
    use codex_app_server_state::{LifecycleStatus, PlanStepStatus, ThreadId};
    use codex_presentation::{
        PlanStepPresentation,
        transcript_v2::{OtherWorkRowV2, TurnWorkDisclosureV2, UserAttachmentV2, WorkGroupV2},
    };

    fn user(id: &str, text: &str) -> UserMessageV2 {
        UserMessageV2 {
            id: id.to_owned(),
            client_id: None,
            text: text.to_owned(),
            raw_text: text.to_owned(),
            attachments: Vec::<UserAttachmentV2>::new(),
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
            markdown: codex_presentation::MarkdownDocument::parse(text),
        }
    }

    fn group(id: &str, status: WorkItemStatusV2, is_live: bool) -> WorkGroupV2 {
        WorkGroupV2 {
            id: id.to_owned(),
            header: "Worked".to_owned(),
            active_header: Some("Working".to_owned()),
            rows: vec![WorkRowV2::Other(OtherWorkRowV2 {
                id: format!("{id}-row"),
                label: "Read files".to_owned(),
                status: status.clone(),
            })],
            is_live,
            status,
            is_expanded_by_default: false,
        }
    }

    fn turn() -> TurnV2Presentation {
        let opening = user("opening", "Build this");
        let steer = user("steer", "Also test it");
        TurnV2Presentation {
            turn_id: TurnId::from("turn"),
            canonical_status: LifecycleStatus::InProgress,
            status: TurnStatusV2::Working {
                since_unix_seconds: None,
            },
            opening_user_message: Some(opening),
            steered_messages: vec![steer.clone()],
            conversation_segments: vec![
                ConversationSegmentV2 {
                    id: "turn:initial".to_owned(),
                    steered_message: None,
                    narrative: vec![
                        NarrativeEntryV2::Prose(prose("commentary", "Checking")),
                        NarrativeEntryV2::WorkGroup(group(
                            "group-first-row",
                            WorkItemStatusV2::Completed,
                            false,
                        )),
                    ],
                },
                ConversationSegmentV2 {
                    id: "turn:steer:steer".to_owned(),
                    steered_message: Some(steer),
                    narrative: vec![NarrativeEntryV2::Notice(NoticeV2 {
                        id: "notice".to_owned(),
                        message: "Review mode".to_owned(),
                    })],
                },
            ],
            narrative: vec![
                NarrativeEntryV2::Prose(prose("commentary", "Checking")),
                NarrativeEntryV2::WorkGroup(group(
                    "group-first-row",
                    WorkItemStatusV2::Completed,
                    false,
                )),
            ],
            final_answer: Some(prose("answer", "Done")),
            generated_images: vec![GeneratedImageV2 {
                id: "image".to_owned(),
                source: "/tmp/image.png".to_owned(),
                revised_prompt: None,
                has_transparent_background: None,
            }],
            live_tail: None,
            plan: Some(PlanPresentation {
                explanation: None,
                steps: vec![PlanStepPresentation {
                    step: "Build".to_owned(),
                    status: PlanStepStatus::Completed,
                }],
            }),
            work_disclosure: TurnWorkDisclosureV2 {
                is_visible: true,
                is_expanded_by_default: true,
                is_tail_mode: false,
            },
        }
    }

    fn presentation(turn: TurnV2Presentation) -> TranscriptV2Presentation {
        TranscriptV2Presentation {
            revision: StateRevision::new(1),
            thread_id: ThreadId::from("thread"),
            turns: vec![turn],
        }
    }

    fn row_kind(row: &TranscriptV2Row) -> &'static str {
        match row {
            TranscriptV2Row::OpeningUser { .. } => "opening-user",
            TranscriptV2Row::WorkDisclosure { .. } => "work-disclosure",
            TranscriptV2Row::SteeredUser { .. } => "steered-user",
            TranscriptV2Row::Prose { .. } => "prose",
            TranscriptV2Row::WorkGroup { .. } => "work-group",
            TranscriptV2Row::ProductToolCall { .. } => "product-tool",
            TranscriptV2Row::InlineActivity { .. } => "inline-activity",
            TranscriptV2Row::Notice { .. } => "notice",
            TranscriptV2Row::LiveTail { .. } => "live-tail",
            TranscriptV2Row::Plan { .. } => "plan",
            TranscriptV2Row::FinalAnswer { .. } => "final-answer",
            TranscriptV2Row::GeneratedImage { .. } => "generated-image",
            TranscriptV2Row::Lifecycle { .. } => "lifecycle",
        }
    }

    #[test]
    fn rows_follow_swift_v2_turn_grammar() {
        let rows = transcript_v2_rows(&presentation(turn()));
        assert_eq!(
            rows.iter().map(row_kind).collect::<Vec<_>>(),
            vec![
                "opening-user",
                "work-disclosure",
                "prose",
                "work-group",
                "steered-user",
                "notice",
                "plan",
                "final-answer",
                "generated-image",
                "lifecycle",
            ]
        );
        assert_eq!(
            rows[3].stable_id(),
            "turn:turn:segment:turn:initial:work-group:group-first-row"
        );
        assert!(matches!(
            &rows[3],
            TranscriptV2Row::WorkGroup { group, .. } if group.id == "group-first-row"
        ));
    }

    #[test]
    fn terminal_work_defaults_collapsed_without_hiding_answer_or_footer() {
        let mut turn = turn();
        turn.status = TurnStatusV2::Done {
            duration_ms: Some(1_250),
        };
        turn.canonical_status = LifecycleStatus::Completed;
        turn.work_disclosure.is_expanded_by_default = false;
        let rows = transcript_v2_rows(&presentation(turn));
        assert_eq!(
            rows.iter().map(row_kind).collect::<Vec<_>>(),
            vec![
                "opening-user",
                "work-disclosure",
                "plan",
                "final-answer",
                "generated-image",
                "lifecycle",
            ]
        );
    }

    #[test]
    fn tail_mode_keeps_only_live_work_and_preserves_steer_boundaries() {
        let mut turn = turn();
        turn.work_disclosure.is_tail_mode = true;
        turn.conversation_segments[0]
            .narrative
            .push(NarrativeEntryV2::WorkGroup(group(
                "group-live",
                WorkItemStatusV2::InProgress,
                true,
            )));
        let rows = transcript_v2_rows(&presentation(turn));
        assert_eq!(
            rows.iter().map(row_kind).collect::<Vec<_>>(),
            vec![
                "opening-user",
                "work-disclosure",
                "work-group",
                "steered-user",
                "plan",
                "final-answer",
                "generated-image",
                "lifecycle",
            ]
        );
        let TranscriptV2Row::WorkDisclosure {
            visible_entry_count,
            ..
        } = &rows[1]
        else {
            panic!("work disclosure expected");
        };
        assert_eq!(*visible_entry_count, 1);
    }

    #[test]
    fn list_starts_in_bottom_tail_follow_mode_without_uniform_row_assumptions() {
        let transcript = CodexTranscriptV2::new(&presentation(turn()));
        assert_eq!(transcript.list_state.item_count(), transcript.rows.len());
        assert!(transcript.list_state.is_following_tail());
    }

    #[test]
    fn work_group_expansion_keys_are_scoped_to_turn_and_segment() {
        let first = turn();
        let mut second = turn();
        second.turn_id = TurnId::from("turn-two");
        second.conversation_segments[0].id = "turn-two:initial".to_owned();
        let projection = TranscriptV2Presentation {
            revision: StateRevision::new(1),
            thread_id: ThreadId::from("thread"),
            turns: vec![first, second],
        };
        let mut transcript = CodexTranscriptV2::new(&projection);
        let group_keys = transcript
            .rows
            .iter()
            .filter(|row| matches!(row, TranscriptV2Row::WorkGroup { .. }))
            .map(TranscriptV2Row::stable_id)
            .collect::<Vec<_>>();
        assert_eq!(group_keys.len(), 2);
        assert_ne!(group_keys[0], group_keys[1]);
        transcript
            .group_expansion_overrides
            .insert(group_keys[0].clone(), true);
        assert_eq!(
            transcript.group_expansion_overrides.get(&group_keys[0]),
            Some(&true)
        );
        assert!(
            !transcript
                .group_expansion_overrides
                .contains_key(&group_keys[1])
        );
    }

    #[test]
    fn layout_metrics_match_swift_column_geometry() {
        let assert_close = |actual: f32, expected: f32| {
            assert!((actual - expected).abs() < 0.01, "{actual} != {expected}");
        };
        assert_close(TranscriptLayoutMetrics::outer_width(1_024.), 768.);
        assert_close(TranscriptLayoutMetrics::card_width(1_024.), 640.);
        assert_close(TranscriptLayoutMetrics::user_width(1_024.), 560.);
        assert_close(TranscriptLayoutMetrics::outer_width(600.), 552.);
        assert_close(TranscriptLayoutMetrics::card_width(600.), 552.);
        assert_close(TranscriptLayoutMetrics::user_width(600.), 425.04);
        assert_close(TranscriptLayoutMetrics::TURN_GAP, 16.);
        assert_close(TranscriptLayoutMetrics::ITEM_GAP, 4.);
        assert_close(TranscriptLayoutMetrics::CHAT_TEXT_SIZE, 14.);
        assert_close(TranscriptLayoutMetrics::CAPTION_TEXT_SIZE, 12.);
        assert_close(TranscriptLayoutMetrics::CHAT_LINE_HEIGHT, 20.);
    }

    #[test]
    fn work_header_titles_follow_swift_semantics() {
        assert_eq!(
            work_disclosure_label(
                &TurnStatusV2::Working {
                    since_unix_seconds: None
                },
                0,
                1_000,
                900,
            ),
            "Thinking"
        );
        assert_eq!(
            work_disclosure_label(
                &TurnStatusV2::Working {
                    since_unix_seconds: None
                },
                2,
                1_000,
                900,
            ),
            "Working for 100s"
        );
        assert_eq!(
            work_disclosure_label(
                &TurnStatusV2::Done {
                    duration_ms: Some(4_800)
                },
                2,
                1_000,
                900,
            ),
            "Worked for 4.8s"
        );
    }

    fn command_row(status: WorkItemStatusV2, exit_code: Option<i64>) -> CommandRowV2 {
        CommandRowV2 {
            id: "command".to_owned(),
            command: "cargo test --workspace --locked".to_owned(),
            label: "Running command".to_owned(),
            category: WorkCategoryV2::Run,
            status,
            cwd: None,
            exit_code,
            duration_ms: Some(1_240),
            output: None,
        }
    }

    fn mcp_row(progress: Option<&str>) -> WorkRowV2 {
        WorkRowV2::McpToolCall(codex_presentation::transcript_v2::McpToolCallRowV2 {
            id: "mcp".to_owned(),
            app_name: "GitHub".to_owned(),
            server: "github".to_owned(),
            tool: "search".to_owned(),
            status: WorkItemStatusV2::InProgress,
            progress: progress.map(str::to_owned),
            duration_ms: None,
            error_first_line: None,
            arguments: None,
            result: None,
            read_only_hint: Some(true),
        })
    }

    #[test]
    fn command_rows_surface_command_metadata_while_running_and_after_exit() {
        let running = command_row(WorkItemStatusV2::InProgress, None);
        assert_eq!(
            command_row_label(&running),
            "$ cargo test --workspace --locked"
        );
        assert!(command_row_is_monospaced(&running));
        assert_eq!(command_duration_label(&running).as_deref(), Some("1.2s"));
        assert_eq!(command_execution_state_label(&running), "running");

        let mut listed = running.clone();
        listed.category = WorkCategoryV2::List;
        listed.label = "Listed files".to_owned();
        assert_eq!(command_row_label(&listed), "Listed files");
        assert!(!command_row_is_monospaced(&listed));

        let succeeded = command_row(WorkItemStatusV2::Completed, Some(0));
        assert_eq!(
            command_execution_state_label(&succeeded),
            "succeeded · exit 0"
        );

        let failed = command_row(WorkItemStatusV2::Completed, Some(2));
        assert_eq!(command_execution_state_label(&failed), "failed · exit 2");
    }

    #[test]
    fn command_label_truncation_preserves_both_middle_sides() {
        let mut command = command_row(WorkItemStatusV2::InProgress, None);
        command.command = format!("cargo run -- {}", "x".repeat(COMMAND_LABEL_LIMIT));
        let label = command_row_label(&command);
        assert_eq!(label.chars().count(), COMMAND_LABEL_LIMIT);
        assert!(label.starts_with("$ cargo run"));
        assert!(label.ends_with('x'));
        assert!(label.contains('…'));
    }

    #[test]
    fn active_work_elapsed_label_is_monotonic_and_clamped() {
        assert_eq!(working_elapsed_seconds(1_050, Some(1_000), 900), 50);
        assert_eq!(working_elapsed_seconds(899, Some(1_000), 900), 0);
        assert_eq!(working_elapsed_seconds(1_050, None, 1_000), 50);
    }

    #[test]
    fn work_rows_keep_semantic_kind_glyphs_distinct_from_status_glyphs() {
        let command = command_row(WorkItemStatusV2::InProgress, None);
        assert_eq!(work_kind_glyph(&WorkRowV2::Command(command)), "⌘");
        assert_ne!(
            work_kind_glyph(&WorkRowV2::WebSearch(
                codex_presentation::transcript_v2::WebSearchRowV2 {
                    id: "search".to_owned(),
                    query: "gpui".to_owned(),
                    status: WorkItemStatusV2::Completed,
                }
            )),
            "⌘"
        );
    }

    #[test]
    fn disclosure_keyboard_activation_accepts_enter_and_space_only() {
        assert!(is_disclosure_key_name("enter"));
        assert!(is_disclosure_key_name("space"));
        assert!(is_disclosure_key_name(" "));
        assert!(!is_disclosure_key_name("escape"));
    }

    #[test]
    fn mcp_progress_is_visible_in_compact_and_expanded_content() {
        let (label, detail) = work_row_content(&mcp_row(Some("Fetching issue 42")));
        assert!(label.contains("Fetching issue 42"));
        assert!(
            detail
                .as_deref()
                .is_some_and(|detail| detail.contains("Progress\nFetching issue 42"))
        );
    }

    #[test]
    fn default_theme_uses_exact_swift_slate_translucencies() {
        let theme = CodexTheme::default();
        assert_eq!(theme.border, gpui::rgba(0xffff_ff16));
        assert_eq!(theme.user_message, gpui::rgba(0xffff_ff0f));
        assert_eq!(theme.user_message_stroke, gpui::rgba(0xffff_ff14));
        assert_eq!(theme.tertiary_text, gpui::rgb(0x0076_767e));
    }
}
