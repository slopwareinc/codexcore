//! Framework-neutral identities and monotonic metadata for canonical state.
//!
//! UI choices such as selection, scroll position, drafts, and expansion never
//! belong in these types.

use std::fmt::{self, Display};

use serde::{Deserialize, Serialize};

macro_rules! string_id {
    ($name:ident, $doc:literal) => {
        #[doc = $doc]
        #[derive(Clone, Debug, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
        #[serde(transparent)]
        pub struct $name(String);

        impl $name {
            /// Create an identity from its exact wire value.
            #[must_use]
            pub fn new(value: impl Into<String>) -> Self {
                Self(value.into())
            }

            /// Borrow the exact wire value.
            #[must_use]
            pub fn as_str(&self) -> &str {
                &self.0
            }

            /// Consume the wrapper and return its wire value.
            #[must_use]
            pub fn into_inner(self) -> String {
                self.0
            }
        }

        impl Display for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str(&self.0)
            }
        }

        impl From<&str> for $name {
            fn from(value: &str) -> Self {
                Self::new(value)
            }
        }

        impl From<String> for $name {
            fn from(value: String) -> Self {
                Self::new(value)
            }
        }
    };
}

string_id!(ThreadId, "Stable App Server thread identity.");
string_id!(TurnId, "Turn identity scoped to one thread.");
string_id!(ItemId, "Item identity scoped to one turn.");
string_id!(
    SubmissionIntentId,
    "Local submission identity used for echo reconciliation."
);

/// Composite identity for a turn in normalized state.
#[derive(Clone, Debug, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
pub struct TurnKey {
    /// Owning thread.
    pub thread_id: ThreadId,
    /// Thread-scoped turn identity.
    pub turn_id: TurnId,
}

/// Composite identity for an item in normalized state.
#[derive(Clone, Debug, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
pub struct ItemKey {
    /// Owning thread.
    pub thread_id: ThreadId,
    /// Owning turn.
    pub turn_id: TurnId,
    /// Turn-scoped item identity.
    pub item_id: ItemId,
}

impl ItemKey {
    /// Return the owning composite turn identity.
    #[must_use]
    pub fn turn_key(&self) -> TurnKey {
        TurnKey {
            thread_id: self.thread_id.clone(),
            turn_id: self.turn_id.clone(),
        }
    }
}

/// Monotonic local materialized-view revision, not a server replay cursor.
#[derive(
    Clone, Copy, Debug, Default, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize,
)]
#[serde(transparent)]
pub struct StateRevision(u64);

impl StateRevision {
    /// Zero revision before any canonical commit.
    pub const ZERO: Self = Self(0);

    /// Create a revision from its stored value.
    #[must_use]
    pub const fn new(value: u64) -> Self {
        Self(value)
    }

    /// Return the stored value.
    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }

    /// Advance without wrapping.
    #[must_use]
    pub const fn successor(self) -> Option<Self> {
        match self.0.checked_add(1) {
            Some(value) => Some(Self(value)),
            None => None,
        }
    }
}

/// Coverage lattice for partially hydrated canonical entities.
#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
pub enum StateCoverage {
    /// Entity has not been loaded.
    NotLoaded,
    /// Summary metadata is available.
    Summary,
    /// Full entity detail is available.
    Full,
}

impl StateCoverage {
    /// Merge coverage monotonically; information never moves downward.
    #[must_use]
    pub fn merged(self, other: Self) -> Self {
        self.max(other)
    }
}

/// Distinguishes an omitted field from an explicit protocol clear.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CanonicalFieldUpdate<T> {
    /// Protocol did not author this field.
    Unchanged,
    /// Protocol authored a concrete value.
    Set(T),
    /// Protocol explicitly cleared the value.
    Clear,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn composite_item_identity_preserves_scope() {
        let item = ItemKey {
            thread_id: ThreadId::from("thread-a"),
            turn_id: TurnId::from("turn-a"),
            item_id: ItemId::from("item-a"),
        };
        assert_eq!(
            item.turn_key(),
            TurnKey {
                thread_id: ThreadId::from("thread-a"),
                turn_id: TurnId::from("turn-a"),
            }
        );
    }

    #[test]
    fn coverage_only_moves_upward() {
        assert_eq!(
            StateCoverage::Summary.merged(StateCoverage::NotLoaded),
            StateCoverage::Summary
        );
        assert_eq!(
            StateCoverage::Summary.merged(StateCoverage::Full),
            StateCoverage::Full
        );
    }

    #[test]
    fn revision_never_wraps() {
        assert_eq!(StateRevision::ZERO.successor(), Some(StateRevision::new(1)));
        assert_eq!(StateRevision::new(u64::MAX).successor(), None);
    }
}
