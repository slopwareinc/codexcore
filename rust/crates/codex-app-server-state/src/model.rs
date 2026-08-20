use std::{
    collections::{BTreeMap, BTreeSet},
    ops::{BitOr, BitOrAssign},
};

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::Value;

use crate::{ItemId, ItemKey, StateCoverage, StateRevision, ThreadId, TurnId, TurnKey};

/// Lossless item/turn lifecycle value.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum LifecycleStatus {
    /// Work is currently running.
    InProgress,
    /// Work completed successfully.
    Completed,
    /// Work was interrupted.
    Interrupted,
    /// Work failed.
    Failed,
    /// Requested work was declined.
    Declined,
    /// Future protocol value retained exactly.
    Unknown(String),
}

impl LifecycleStatus {
    /// Decode without discarding future values.
    #[must_use]
    pub fn from_raw(value: impl Into<String>) -> Self {
        let value = value.into();
        match value.as_str() {
            "inProgress" => Self::InProgress,
            "completed" => Self::Completed,
            "interrupted" => Self::Interrupted,
            "failed" => Self::Failed,
            "declined" => Self::Declined,
            _ => Self::Unknown(value),
        }
    }

    /// Exact protocol spelling.
    #[must_use]
    pub fn as_raw(&self) -> &str {
        match self {
            Self::InProgress => "inProgress",
            Self::Completed => "completed",
            Self::Interrupted => "interrupted",
            Self::Failed => "failed",
            Self::Declined => "declined",
            Self::Unknown(value) => value,
        }
    }

    /// Whether a later nonterminal event must not regress this value.
    #[must_use]
    pub const fn is_terminal(&self) -> bool {
        matches!(
            self,
            Self::Completed | Self::Interrupted | Self::Failed | Self::Declined
        )
    }
}

impl Serialize for LifecycleStatus {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(self.as_raw())
    }
}

impl<'de> Deserialize<'de> for LifecycleStatus {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        String::deserialize(deserializer).map(Self::from_raw)
    }
}

/// Lossless canonical thread lifecycle.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum ThreadStatus {
    /// Detail has not been loaded in this session.
    NotLoaded,
    /// Loaded with no active turn.
    Idle,
    /// Active with exact protocol flags.
    Active {
        /// Flags such as waiting on approval or user input.
        flags: BTreeSet<String>,
    },
    /// Structured server failure retained for presentation.
    SystemError(Value),
    /// Future tagged union retained losslessly.
    Unknown(Value),
}

/// One normalized thread record.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct CanonicalThread {
    /// Stable thread identity.
    pub id: ThreadId,
    /// Current lifecycle.
    pub status: ThreadStatus,
    /// Known detail coverage.
    pub coverage: StateCoverage,
    /// Stable turn display order.
    pub turn_ids: Vec<TurnId>,
    /// Current server-owned thread goal, when one exists.
    #[serde(default)]
    pub goal: Option<CanonicalThreadGoal>,
    /// Lossless metadata not yet promoted to stable fields.
    pub metadata: BTreeMap<String, Value>,
}

impl CanonicalThread {
    pub(crate) fn partial(id: ThreadId) -> Self {
        Self {
            id,
            status: ThreadStatus::NotLoaded,
            coverage: StateCoverage::NotLoaded,
            turn_ids: Vec::new(),
            goal: None,
            metadata: BTreeMap::new(),
        }
    }
}

/// Lossless thread-goal lifecycle value.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum ThreadGoalStatus {
    Active,
    Paused,
    Blocked,
    UsageLimited,
    BudgetLimited,
    Complete,
    /// Future protocol value retained exactly.
    Unknown(String),
}

impl ThreadGoalStatus {
    /// Decode without discarding future values.
    #[must_use]
    pub fn from_raw(value: impl Into<String>) -> Self {
        let value = value.into();
        match value.as_str() {
            "active" => Self::Active,
            "paused" => Self::Paused,
            "blocked" => Self::Blocked,
            "usageLimited" => Self::UsageLimited,
            "budgetLimited" => Self::BudgetLimited,
            "complete" => Self::Complete,
            _ => Self::Unknown(value),
        }
    }

    /// Exact protocol spelling.
    #[must_use]
    pub fn as_raw(&self) -> &str {
        match self {
            Self::Active => "active",
            Self::Paused => "paused",
            Self::Blocked => "blocked",
            Self::UsageLimited => "usageLimited",
            Self::BudgetLimited => "budgetLimited",
            Self::Complete => "complete",
            Self::Unknown(value) => value,
        }
    }
}

impl Serialize for ThreadGoalStatus {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(self.as_raw())
    }
}

impl<'de> Deserialize<'de> for ThreadGoalStatus {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        String::deserialize(deserializer).map(Self::from_raw)
    }
}

/// One authoritative goal attached to a thread.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct CanonicalThreadGoal {
    /// Owning thread identity.
    pub thread_id: ThreadId,
    /// User-authored objective.
    pub objective: String,
    /// Current server lifecycle, including future values.
    pub status: ThreadGoalStatus,
    /// Optional token limit selected for this goal.
    pub token_budget: Option<i64>,
    /// Server-reported tokens consumed so far.
    pub tokens_used: i64,
    /// Server-reported wall-clock seconds consumed so far.
    pub time_used_seconds: i64,
    /// Protocol Unix timestamp in seconds.
    pub created_at: i64,
    /// Protocol Unix timestamp in seconds.
    pub updated_at: i64,
    /// Future goal fields retained without interpretation.
    pub extensions: BTreeMap<String, Value>,
}

/// One normalized turn record.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct CanonicalTurn {
    /// Composite thread/turn identity.
    pub key: TurnKey,
    /// Current lifecycle.
    pub status: LifecycleStatus,
    /// Known detail coverage.
    pub coverage: StateCoverage,
    /// Stable item display order.
    pub item_ids: Vec<ItemId>,
    pub plan: Option<Vec<CanonicalPlanStep>>,
    pub plan_explanation: Option<String>,
    /// Lossless metadata not yet promoted to stable fields.
    pub metadata: BTreeMap<String, Value>,
}

impl CanonicalTurn {
    pub(crate) fn partial(key: TurnKey) -> Self {
        Self {
            key,
            status: LifecycleStatus::Unknown("notLoaded".to_owned()),
            coverage: StateCoverage::NotLoaded,
            item_ids: Vec::new(),
            plan: None,
            plan_explanation: None,
            metadata: BTreeMap::new(),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct CanonicalPlanStep {
    pub step: String,
    pub status: PlanStepStatus,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub enum PlanStepStatus {
    Pending,
    InProgress,
    Completed,
    Unknown(String),
}

impl PlanStepStatus {
    #[must_use]
    pub fn from_raw(value: impl Into<String>) -> Self {
        let value = value.into();
        match value.as_str() {
            "pending" => Self::Pending,
            "inProgress" => Self::InProgress,
            "completed" => Self::Completed,
            _ => Self::Unknown(value),
        }
    }
}

/// Typed content carried by one live item delta.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ItemDelta {
    /// Assistant message markdown.
    AgentMessage(String),
    /// Experimental plan item text.
    Plan(String),
    /// One indexed reasoning summary part.
    ReasoningSummary { index: i64, text: String },
    /// One indexed reasoning content part.
    ReasoningContent { index: i64, text: String },
    /// Interleaved command stdout/stderr.
    CommandOutput(String),
    /// Deprecated textual `apply_patch` output.
    FileChangeOutput(String),
    /// Human-readable MCP tool progress.
    McpProgress(String),
}

impl ItemDelta {
    pub(crate) fn utf8_bytes(&self) -> usize {
        match self {
            Self::AgentMessage(value)
            | Self::Plan(value)
            | Self::CommandOutput(value)
            | Self::FileChangeOutput(value)
            | Self::McpProgress(value)
            | Self::ReasoningSummary { text: value, .. }
            | Self::ReasoningContent { text: value, .. } => value.len(),
        }
    }
}

/// Ordered chunks from one live protocol text stream.
///
/// Keeping chunks separate avoids rebuilding a cumulative string for every
/// hot delta while still preserving repeated and empty chunks exactly.
#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(transparent)]
pub struct TextChunkBuffer(Vec<String>);

impl TextChunkBuffer {
    pub(crate) fn append(&mut self, value: String) {
        self.0.push(value);
    }

    /// Borrow retained chunks in wire order.
    #[must_use]
    pub fn chunks(&self) -> &[String] {
        &self.0
    }

    /// Materialize the complete stream text.
    #[must_use]
    pub fn joined(&self) -> String {
        self.0.concat()
    }

    /// Whether the stream has no retained chunks.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

/// Live-only item content discarded by an authoritative terminal item.
#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct ItemLiveOverlay {
    pub agent_message: TextChunkBuffer,
    pub plan: TextChunkBuffer,
    pub reasoning_summary: BTreeMap<i64, TextChunkBuffer>,
    pub reasoning_content: BTreeMap<i64, TextChunkBuffer>,
    pub command_output: TextChunkBuffer,
    pub file_change_output: TextChunkBuffer,
    pub mcp_progress: TextChunkBuffer,
}

impl ItemLiveOverlay {
    pub(crate) fn append(&mut self, delta: ItemDelta) {
        match delta {
            ItemDelta::AgentMessage(text) => self.agent_message.append(text),
            ItemDelta::Plan(text) => self.plan.append(text),
            ItemDelta::ReasoningSummary { index, text } => self
                .reasoning_summary
                .entry(index)
                .or_default()
                .append(text),
            ItemDelta::ReasoningContent { index, text } => self
                .reasoning_content
                .entry(index)
                .or_default()
                .append(text),
            ItemDelta::CommandOutput(text) => self.command_output.append(text),
            ItemDelta::FileChangeOutput(text) => self.file_change_output.append(text),
            ItemDelta::McpProgress(text) => self.mcp_progress.append(text),
        }
    }

    /// Whether no live delta content is retained.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.agent_message.is_empty()
            && self.plan.is_empty()
            && self
                .reasoning_summary
                .values()
                .all(TextChunkBuffer::is_empty)
            && self
                .reasoning_content
                .values()
                .all(TextChunkBuffer::is_empty)
            && self.command_output.is_empty()
            && self.file_change_output.is_empty()
            && self.mcp_progress.is_empty()
    }
}

/// One normalized transcript item.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct CanonicalItem {
    /// Composite thread/turn/item identity.
    pub key: ItemKey,
    /// Exact protocol item kind.
    pub kind: String,
    /// Current lifecycle.
    pub status: LifecycleStatus,
    /// Known detail coverage.
    pub coverage: StateCoverage,
    /// Lossless typed/open item payload.
    pub payload: BTreeMap<String, Value>,
    /// Protocol duration promoted for framework-neutral lifecycle consumers.
    #[serde(default)]
    pub duration_ms: Option<i64>,
    /// Structured item error promoted without narrowing future fields.
    #[serde(default)]
    pub error: Option<Value>,
    /// Ordered live delta content separate from authoritative payload fields.
    #[serde(default)]
    pub live_overlay: ItemLiveOverlay,
    /// Replacement-style live values such as current file changes.
    #[serde(default)]
    pub live_fields: BTreeMap<String, Value>,
    /// Monotonic content update revision for projection caches.
    pub content_revision: u64,
}

/// Immutable normalized replica.
#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct CanonicalState {
    /// Atomic local commit revision.
    pub revision: StateRevision,
    /// Stable thread display order.
    pub thread_order: Vec<ThreadId>,
    /// Thread records by scalar identity.
    pub threads: BTreeMap<ThreadId, CanonicalThread>,
    /// Turn records by composite identity.
    pub turns: BTreeMap<TurnKey, CanonicalTurn>,
    /// Item records by composite identity.
    pub items: BTreeMap<ItemKey, CanonicalItem>,
}

/// Small invalidation fact emitted by one atomic commit.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum CanonicalChange {
    /// Thread first appeared.
    ThreadInserted(ThreadId),
    /// Existing thread facts changed.
    ThreadUpdated(ThreadId),
    /// A thread goal was replaced or cleared.
    ThreadGoalUpdated(ThreadId),
    /// Thread and all descendants were removed.
    ThreadRemoved(ThreadId),
    /// Turn first appeared.
    TurnInserted(TurnKey),
    /// Existing turn facts changed.
    TurnUpdated(TurnKey),
    PlanUpdated(TurnKey),
    /// Item first appeared.
    ItemInserted(ItemKey),
    /// Existing item facts changed.
    ItemUpdated(ItemKey),
    /// Text delta was appended to a materialized item.
    ItemDeltaAppended(ItemKey),
    /// A replacement-style live item field changed.
    ItemLiveFieldReplaced(ItemKey),
    /// Delta was retained until its item materializes.
    OrphanDeltaBuffered(ItemKey),
    /// A bounded orphan delta was evicted or refused.
    OrphanDeltaDropped(ItemKey),
}

/// Every accepted mutation batch commits at one successor revision.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CanonicalChangeBatch {
    /// Revision before the transaction.
    pub base_revision: StateRevision,
    /// One successor revision shared by every change.
    pub revision: StateRevision,
    /// Deduplicated invalidations in deterministic order.
    pub changes: Vec<CanonicalChange>,
}

/// Coarse canonical fields used only to filter observation wake-ups.
#[derive(Clone, Copy, Debug, Default, Eq, Hash, PartialEq)]
pub struct StateFieldMask(u32);

impl StateFieldMask {
    pub const THREAD: Self = Self(1 << 0);
    pub const TURN: Self = Self(1 << 1);
    pub const ITEM_STRUCTURE: Self = Self(1 << 2);
    pub const ITEM_LIFECYCLE: Self = Self(1 << 3);
    pub const ITEM_CONTENT: Self = Self(1 << 4);
    pub const DIAGNOSTICS: Self = Self(1 << 5);
    pub const PLAN: Self = Self(1 << 6);
    pub const THREAD_GOAL: Self = Self(1 << 7);
    pub const ALL: Self = Self(u32::MAX);

    #[must_use]
    pub const fn intersects(self, other: Self) -> bool {
        self.0 & other.0 != 0
    }
}

impl BitOr for StateFieldMask {
    type Output = Self;

    fn bitor(self, rhs: Self) -> Self::Output {
        Self(self.0 | rhs.0)
    }
}

impl BitOrAssign for StateFieldMask {
    fn bitor_assign(&mut self, rhs: Self) {
        self.0 |= rhs.0;
    }
}

/// Canonical entity selection. Thread and turn scopes include descendants.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum StateEntityScope {
    All,
    Global,
    Threads(BTreeSet<ThreadId>),
    Turns(BTreeSet<TurnKey>),
    Items(BTreeSet<ItemKey>),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StateObservationScope {
    pub entities: StateEntityScope,
    pub fields: StateFieldMask,
}

impl Default for StateObservationScope {
    fn default() -> Self {
        Self {
            entities: StateEntityScope::All,
            fields: StateFieldMask::ALL,
        }
    }
}

impl StateObservationScope {
    #[must_use]
    pub fn thread(thread_id: ThreadId) -> Self {
        Self {
            entities: StateEntityScope::Threads(BTreeSet::from([thread_id])),
            fields: StateFieldMask::ALL,
        }
    }

    #[must_use]
    pub fn with_fields(mut self, fields: StateFieldMask) -> Self {
        self.fields = fields;
        self
    }
}

/// Ephemeral normalized invalidation derived from one canonical transaction.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StateInvalidation {
    pub revision: StateRevision,
    pub fields: StateFieldMask,
    pub thread_ids: BTreeSet<ThreadId>,
    pub turn_keys: BTreeSet<TurnKey>,
    pub item_keys: BTreeSet<ItemKey>,
}

impl StateInvalidation {
    #[must_use]
    pub fn from_batch(batch: &CanonicalChangeBatch) -> Self {
        let mut invalidation = Self {
            revision: batch.revision,
            fields: StateFieldMask::default(),
            thread_ids: BTreeSet::new(),
            turn_keys: BTreeSet::new(),
            item_keys: BTreeSet::new(),
        };
        for change in &batch.changes {
            invalidation.record(change);
        }
        invalidation
    }

    fn record(&mut self, change: &CanonicalChange) {
        match change {
            CanonicalChange::ThreadInserted(id) | CanonicalChange::ThreadUpdated(id) => {
                self.fields |= StateFieldMask::THREAD;
                self.thread_ids.insert(id.clone());
            }
            CanonicalChange::ThreadGoalUpdated(id) => {
                self.fields |= StateFieldMask::THREAD_GOAL;
                self.thread_ids.insert(id.clone());
            }
            CanonicalChange::ThreadRemoved(id) => {
                self.fields |= StateFieldMask::THREAD | StateFieldMask::THREAD_GOAL;
                self.thread_ids.insert(id.clone());
            }
            CanonicalChange::TurnInserted(key) | CanonicalChange::TurnUpdated(key) => {
                self.fields |= StateFieldMask::TURN;
                self.thread_ids.insert(key.thread_id.clone());
                self.turn_keys.insert(key.clone());
            }
            CanonicalChange::PlanUpdated(key) => {
                self.fields |= StateFieldMask::PLAN;
                self.thread_ids.insert(key.thread_id.clone());
                self.turn_keys.insert(key.clone());
            }
            CanonicalChange::ItemInserted(key) => {
                self.fields |= StateFieldMask::ITEM_STRUCTURE | StateFieldMask::ITEM_CONTENT;
                self.record_item(key);
            }
            CanonicalChange::ItemUpdated(key) => {
                self.fields |= StateFieldMask::ITEM_LIFECYCLE | StateFieldMask::ITEM_CONTENT;
                self.record_item(key);
            }
            CanonicalChange::ItemDeltaAppended(key)
            | CanonicalChange::ItemLiveFieldReplaced(key) => {
                self.fields |= StateFieldMask::ITEM_CONTENT;
                self.record_item(key);
            }
            CanonicalChange::OrphanDeltaBuffered(key)
            | CanonicalChange::OrphanDeltaDropped(key) => {
                self.fields |= StateFieldMask::ITEM_CONTENT | StateFieldMask::DIAGNOSTICS;
                self.record_item(key);
            }
        }
    }

    fn record_item(&mut self, key: &ItemKey) {
        self.thread_ids.insert(key.thread_id.clone());
        self.turn_keys.insert(key.turn_key());
        self.item_keys.insert(key.clone());
    }

    #[must_use]
    pub fn affects(&self, scope: &StateObservationScope) -> bool {
        if !self.fields.intersects(scope.fields) {
            return false;
        }
        match &scope.entities {
            StateEntityScope::All => true,
            StateEntityScope::Global => {
                self.thread_ids.is_empty() && self.turn_keys.is_empty() && self.item_keys.is_empty()
            }
            StateEntityScope::Threads(observed) => !self.thread_ids.is_disjoint(observed),
            StateEntityScope::Turns(observed) => !self.turn_keys.is_disjoint(observed),
            StateEntityScope::Items(observed) => !self.item_keys.is_disjoint(observed),
        }
    }
}
