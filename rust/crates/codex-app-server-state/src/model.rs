use std::collections::{BTreeMap, BTreeSet};

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
