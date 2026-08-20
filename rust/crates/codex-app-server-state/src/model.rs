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
            metadata: BTreeMap::new(),
        }
    }
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
            metadata: BTreeMap::new(),
        }
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
    /// Thread and all descendants were removed.
    ThreadRemoved(ThreadId),
    /// Turn first appeared.
    TurnInserted(TurnKey),
    /// Existing turn facts changed.
    TurnUpdated(TurnKey),
    /// Item first appeared.
    ItemInserted(ItemKey),
    /// Existing item facts changed.
    ItemUpdated(ItemKey),
    /// Text delta was appended to a materialized item.
    ItemDeltaAppended(ItemKey),
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
            CanonicalChange::ThreadInserted(id)
            | CanonicalChange::ThreadUpdated(id)
            | CanonicalChange::ThreadRemoved(id) => {
                self.fields |= StateFieldMask::THREAD;
                self.thread_ids.insert(id.clone());
            }
            CanonicalChange::TurnInserted(key) | CanonicalChange::TurnUpdated(key) => {
                self.fields |= StateFieldMask::TURN;
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
            CanonicalChange::ItemDeltaAppended(key) => {
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
