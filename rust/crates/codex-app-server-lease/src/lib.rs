//! Pure thread lease/subscription reconciliation.
//!
//! The ordered actor executes returned actions. Exact operation identities make
//! late completions harmless across release races and physical reconnects.

use std::collections::BTreeMap;

use codex_app_server_state::ThreadId;
use thiserror::Error;

/// Exact local lease identity.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct LeaseId(u64);

impl LeaseId {
    /// Stored numeric identity.
    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }
}

/// Exact reconciliation operation identity.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct LeaseOperationId(u64);

impl LeaseOperationId {
    /// Stored numeric identity.
    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }
}

/// Semantic reason a thread must remain subscribed.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum LeaseReason {
    /// Visible primary conversation.
    Selected,
    /// Turn is running or may still emit events.
    ActiveTurn,
    /// Approval, question, or other server request is pending.
    PendingInteraction,
    /// History hydration requires a stable cut.
    History,
    /// Explicit host operation such as review or fork.
    Operation,
    /// Background presentation or automation retention.
    Background,
}

impl LeaseReason {
    const fn reconnect_priority(self) -> u8 {
        match self {
            Self::PendingInteraction => 0,
            Self::ActiveTurn => 1,
            Self::Selected => 2,
            Self::Operation => 3,
            Self::History => 4,
            Self::Background => 5,
        }
    }
}

/// External action for the ordered actor to execute once.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LeaseAction {
    /// Resume/subscribe on the current physical connection.
    Subscribe {
        thread_id: ThreadId,
        operation_id: LeaseOperationId,
    },
    /// Unsubscribe after the final reason ends.
    Unsubscribe {
        thread_id: ThreadId,
        operation_id: LeaseOperationId,
    },
}

/// Observable reconciliation phase.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LeasePhase {
    /// Desired locally but not live on the current connection.
    Stale,
    /// Subscribe/resume request is in flight.
    Subscribing(LeaseOperationId),
    /// Subscription is live.
    Live,
    /// Final unsubscribe is in flight.
    Unsubscribing(LeaseOperationId),
}

/// Monotonic identity exhaustion.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum LeaseRegistryError {
    /// Allocating another identity would alias an older one.
    #[error("{0} identity exhausted")]
    IdentityExhausted(&'static str),
}

#[derive(Clone, Debug)]
struct Entry {
    reasons: BTreeMap<LeaseId, LeaseReason>,
    phase: LeasePhase,
}

/// Deterministic lease registry with no I/O or executor dependency.
#[derive(Clone, Debug)]
pub struct ThreadLeaseRegistry {
    connected: bool,
    entries: BTreeMap<ThreadId, Entry>,
    lease_threads: BTreeMap<LeaseId, ThreadId>,
    next_lease: u64,
    next_operation: u64,
}

impl Default for ThreadLeaseRegistry {
    fn default() -> Self {
        Self::new(false)
    }
}

impl ThreadLeaseRegistry {
    /// Create a registry in connected or disconnected state.
    #[must_use]
    pub fn new(connected: bool) -> Self {
        Self {
            connected,
            entries: BTreeMap::new(),
            lease_threads: BTreeMap::new(),
            next_lease: 1,
            next_operation: 1,
        }
    }

    /// Acquire one semantic reason and return any required subscribe action.
    ///
    /// # Errors
    ///
    /// Returns [`LeaseRegistryError`] before an identity could alias.
    pub fn acquire(
        &mut self,
        thread_id: ThreadId,
        reason: LeaseReason,
    ) -> Result<(LeaseId, Vec<LeaseAction>), LeaseRegistryError> {
        let lease = self.allocate_lease()?;
        self.lease_threads.insert(lease, thread_id.clone());
        self.entries
            .entry(thread_id.clone())
            .or_insert_with(|| Entry {
                reasons: BTreeMap::new(),
                phase: LeasePhase::Stale,
            })
            .reasons
            .insert(lease, reason);
        let should_subscribe = self.connected
            && self.entries.get(&thread_id).is_some_and(|entry| {
                matches!(
                    entry.phase,
                    LeasePhase::Stale | LeasePhase::Unsubscribing(_)
                )
            });
        if !should_subscribe {
            return Ok((lease, Vec::new()));
        }
        let operation = self.allocate_operation()?;
        if let Some(entry) = self.entries.get_mut(&thread_id) {
            entry.phase = LeasePhase::Subscribing(operation);
        }
        Ok((
            lease,
            vec![LeaseAction::Subscribe {
                thread_id,
                operation_id: operation,
            }],
        ))
    }

    /// Release one exact lease; unknown/already-released identities are no-ops.
    ///
    /// # Errors
    ///
    /// Returns [`LeaseRegistryError`] before an operation identity could alias.
    pub fn release(&mut self, lease: LeaseId) -> Result<Vec<LeaseAction>, LeaseRegistryError> {
        let Some(thread_id) = self.lease_threads.remove(&lease) else {
            return Ok(Vec::new());
        };
        let Some(entry) = self.entries.get_mut(&thread_id) else {
            return Ok(Vec::new());
        };
        entry.reasons.remove(&lease);
        if !entry.reasons.is_empty() {
            return Ok(Vec::new());
        }
        let phase = entry.phase;
        match phase {
            LeasePhase::Live if self.connected => {
                let operation = self.allocate_operation()?;
                if let Some(entry) = self.entries.get_mut(&thread_id) {
                    entry.phase = LeasePhase::Unsubscribing(operation);
                }
                Ok(vec![LeaseAction::Unsubscribe {
                    thread_id,
                    operation_id: operation,
                }])
            }
            LeasePhase::Stale => {
                self.entries.remove(&thread_id);
                Ok(Vec::new())
            }
            LeasePhase::Subscribing(_) | LeasePhase::Unsubscribing(_) | LeasePhase::Live => {
                Ok(Vec::new())
            }
        }
    }

    /// Invalidate in-flight operations after physical connection loss.
    pub fn connection_lost(&mut self) {
        self.connected = false;
        self.entries.retain(|_, entry| {
            if entry.reasons.is_empty() {
                false
            } else {
                entry.phase = LeasePhase::Stale;
                true
            }
        });
    }

    /// Reconcile retained threads on a new connection in semantic priority order.
    ///
    /// # Errors
    ///
    /// Returns [`LeaseRegistryError`] before an operation identity could alias.
    pub fn connection_restored(&mut self) -> Result<Vec<LeaseAction>, LeaseRegistryError> {
        self.connected = true;
        let mut ordered: Vec<_> = self
            .entries
            .iter()
            .filter(|(_, entry)| !entry.reasons.is_empty())
            .map(|(thread, entry)| {
                let priority = entry
                    .reasons
                    .values()
                    .map(|reason| reason.reconnect_priority())
                    .min()
                    .unwrap_or(u8::MAX);
                (priority, thread.clone())
            })
            .collect();
        ordered.sort();
        let mut actions = Vec::with_capacity(ordered.len());
        for (_, thread_id) in ordered {
            let operation = self.allocate_operation()?;
            if let Some(entry) = self.entries.get_mut(&thread_id) {
                entry.phase = LeasePhase::Subscribing(operation);
            }
            actions.push(LeaseAction::Subscribe {
                thread_id,
                operation_id: operation,
            });
        }
        Ok(actions)
    }

    /// Apply a subscribe completion only if its operation is still current.
    ///
    /// # Errors
    ///
    /// Returns [`LeaseRegistryError`] before a compensating operation could alias.
    pub fn complete_subscribe(
        &mut self,
        thread_id: &ThreadId,
        operation: LeaseOperationId,
        succeeded: bool,
    ) -> Result<Vec<LeaseAction>, LeaseRegistryError> {
        let Some(entry) = self.entries.get(thread_id) else {
            return Ok(Vec::new());
        };
        if entry.phase != LeasePhase::Subscribing(operation) {
            return Ok(Vec::new());
        }
        let retained = !entry.reasons.is_empty();
        if !succeeded {
            if retained {
                if let Some(entry) = self.entries.get_mut(thread_id) {
                    entry.phase = LeasePhase::Stale;
                }
            } else {
                self.entries.remove(thread_id);
            }
            return Ok(Vec::new());
        }
        if retained {
            if let Some(entry) = self.entries.get_mut(thread_id) {
                entry.phase = LeasePhase::Live;
            }
            return Ok(Vec::new());
        }
        let unsubscribe = self.allocate_operation()?;
        if let Some(entry) = self.entries.get_mut(thread_id) {
            entry.phase = LeasePhase::Unsubscribing(unsubscribe);
        }
        Ok(vec![LeaseAction::Unsubscribe {
            thread_id: thread_id.clone(),
            operation_id: unsubscribe,
        }])
    }

    /// Apply an unsubscribe completion only if its operation is still current.
    ///
    /// # Errors
    ///
    /// Returns [`LeaseRegistryError`] before a compensating operation could alias.
    pub fn complete_unsubscribe(
        &mut self,
        thread_id: &ThreadId,
        operation: LeaseOperationId,
        succeeded: bool,
    ) -> Result<Vec<LeaseAction>, LeaseRegistryError> {
        let Some(entry) = self.entries.get(thread_id) else {
            return Ok(Vec::new());
        };
        if entry.phase != LeasePhase::Unsubscribing(operation) {
            return Ok(Vec::new());
        }
        let retained = !entry.reasons.is_empty();
        if succeeded && !retained {
            self.entries.remove(thread_id);
            return Ok(Vec::new());
        }
        if retained && self.connected {
            let subscribe = self.allocate_operation()?;
            if let Some(entry) = self.entries.get_mut(thread_id) {
                entry.phase = LeasePhase::Subscribing(subscribe);
            }
            return Ok(vec![LeaseAction::Subscribe {
                thread_id: thread_id.clone(),
                operation_id: subscribe,
            }]);
        }
        if let Some(entry) = self.entries.get_mut(thread_id) {
            entry.phase = if self.connected {
                LeasePhase::Live
            } else {
                LeasePhase::Stale
            };
        }
        Ok(Vec::new())
    }

    /// Current phase for diagnostics.
    #[must_use]
    pub fn phase(&self, thread: &ThreadId) -> Option<LeasePhase> {
        self.entries.get(thread).map(|entry| entry.phase)
    }

    /// Number of active semantic reasons for one thread.
    #[must_use]
    pub fn reason_count(&self, thread: &ThreadId) -> usize {
        self.entries
            .get(thread)
            .map_or(0, |entry| entry.reasons.len())
    }

    /// Number of threads with at least one semantic retention reason.
    #[must_use]
    pub fn retained_thread_count(&self) -> usize {
        self.entries
            .values()
            .filter(|entry| !entry.reasons.is_empty())
            .count()
    }

    fn allocate_lease(&mut self) -> Result<LeaseId, LeaseRegistryError> {
        let id = LeaseId(self.next_lease);
        self.next_lease = self
            .next_lease
            .checked_add(1)
            .ok_or(LeaseRegistryError::IdentityExhausted("lease"))?;
        Ok(id)
    }

    fn allocate_operation(&mut self) -> Result<LeaseOperationId, LeaseRegistryError> {
        let id = LeaseOperationId(self.next_operation);
        self.next_operation = self
            .next_operation
            .checked_add(1)
            .ok_or(LeaseRegistryError::IdentityExhausted("operation"))?;
        Ok(id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn subscribe(action: &LeaseAction) -> LeaseOperationId {
        match action {
            LeaseAction::Subscribe { operation_id, .. } => *operation_id,
            LeaseAction::Unsubscribe { .. } => panic!("expected subscribe"),
        }
    }
    fn unsubscribe(action: &LeaseAction) -> LeaseOperationId {
        match action {
            LeaseAction::Unsubscribe { operation_id, .. } => *operation_id,
            LeaseAction::Subscribe { .. } => panic!("expected unsubscribe"),
        }
    }

    #[test]
    fn only_final_release_unsubscribes() {
        let thread = ThreadId::from("thread");
        let mut registry = ThreadLeaseRegistry::new(true);
        let (selected, first) = registry
            .acquire(thread.clone(), LeaseReason::Selected)
            .expect("selected");
        assert!(
            registry
                .complete_subscribe(&thread, subscribe(&first[0]), true)
                .expect("subscribe")
                .is_empty()
        );
        let (turn, actions) = registry
            .acquire(thread.clone(), LeaseReason::ActiveTurn)
            .expect("turn");
        assert!(actions.is_empty());
        assert!(
            registry
                .release(selected)
                .expect("release selected")
                .is_empty()
        );
        assert!(matches!(
            registry.release(turn).expect("release turn")[0],
            LeaseAction::Unsubscribe { .. }
        ));
    }

    #[test]
    fn released_while_subscribing_compensates_after_success() {
        let thread = ThreadId::from("thread");
        let mut registry = ThreadLeaseRegistry::new(true);
        let (lease, actions) = registry
            .acquire(thread.clone(), LeaseReason::Selected)
            .expect("acquire");
        let operation = subscribe(&actions[0]);
        assert!(registry.release(lease).expect("release").is_empty());
        assert!(matches!(
            registry
                .complete_subscribe(&thread, operation, true)
                .expect("complete")[0],
            LeaseAction::Unsubscribe { .. }
        ));
    }

    #[test]
    fn reacquire_supersedes_late_unsubscribe_completion() {
        let thread = ThreadId::from("thread");
        let mut registry = ThreadLeaseRegistry::new(true);
        let (lease, actions) = registry
            .acquire(thread.clone(), LeaseReason::Selected)
            .expect("acquire");
        registry
            .complete_subscribe(&thread, subscribe(&actions[0]), true)
            .expect("live");
        let old = unsubscribe(&registry.release(lease).expect("release")[0]);
        let (_, actions) = registry
            .acquire(thread.clone(), LeaseReason::PendingInteraction)
            .expect("reacquire");
        let new = subscribe(&actions[0]);
        assert!(
            registry
                .complete_unsubscribe(&thread, old, true)
                .expect("stale")
                .is_empty()
        );
        assert_eq!(registry.phase(&thread), Some(LeasePhase::Subscribing(new)));
    }

    #[test]
    fn reconnect_prioritizes_interaction_over_background() {
        let mut registry = ThreadLeaseRegistry::new(true);
        let background = ThreadId::from("background");
        let approval = ThreadId::from("approval");
        let (_, bg) = registry
            .acquire(background.clone(), LeaseReason::Background)
            .expect("background");
        let (_, urgent) = registry
            .acquire(approval.clone(), LeaseReason::PendingInteraction)
            .expect("approval");
        let old_bg = subscribe(&bg[0]);
        let old_urgent = subscribe(&urgent[0]);
        registry.connection_lost();
        assert!(
            registry
                .complete_subscribe(&background, old_bg, true)
                .expect("stale")
                .is_empty()
        );
        assert!(
            registry
                .complete_subscribe(&approval, old_urgent, true)
                .expect("stale")
                .is_empty()
        );
        let actions = registry.connection_restored().expect("restore");
        assert!(
            matches!(&actions[0], LeaseAction::Subscribe { thread_id, .. } if thread_id == &approval)
        );
        assert!(
            matches!(&actions[1], LeaseAction::Subscribe { thread_id, .. } if thread_id == &background)
        );
    }

    #[test]
    fn disconnected_final_release_needs_no_rpc() {
        let thread = ThreadId::from("thread");
        let mut registry = ThreadLeaseRegistry::new(false);
        let (lease, actions) = registry
            .acquire(thread.clone(), LeaseReason::History)
            .expect("acquire");
        assert!(actions.is_empty());
        assert!(registry.release(lease).expect("release").is_empty());
        assert_eq!(registry.phase(&thread), None);
    }
}
