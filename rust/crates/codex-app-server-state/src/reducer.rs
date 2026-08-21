use std::collections::{BTreeSet, HashMap, VecDeque};

use serde_json::Value;
use thiserror::Error;

use crate::{
    CanonicalChange, CanonicalChangeBatch, CanonicalItem, CanonicalPlanStep, CanonicalState,
    CanonicalThread, CanonicalThreadGoal, CanonicalTurn, ItemDelta, ItemKey, ItemLiveOverlay,
    LifecycleStatus, ThreadId, TurnKey,
};

/// Bounded orphan-delta retention policy.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ReducerConfiguration {
    /// Maximum deltas retained before their items start.
    pub maximum_orphan_delta_count: usize,
    /// Maximum UTF-8 bytes retained across orphan deltas.
    pub maximum_orphan_utf8_bytes: usize,
    /// Maximum deltas retained for one missing item.
    pub maximum_orphan_deltas_per_item: usize,
}

impl Default for ReducerConfiguration {
    fn default() -> Self {
        Self {
            maximum_orphan_delta_count: 2_048,
            maximum_orphan_utf8_bytes: 2 * 1_024 * 1_024,
            maximum_orphan_deltas_per_item: 256,
        }
    }
}

/// Typed operation accepted by the deterministic reducer.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CanonicalMutation {
    /// Merge a thread snapshot/summary.
    ThreadUpsert(CanonicalThread),
    /// Remove a thread and every normalized descendant.
    ThreadRemove(ThreadId),
    /// Replace or clear the authoritative goal for one thread.
    ThreadGoalReplace {
        thread_id: ThreadId,
        goal: Option<CanonicalThreadGoal>,
    },
    /// Merge a turn and establish its thread relationship.
    TurnUpsert(CanonicalTurn),
    /// Replace the authoritative plan for one turn.
    TurnPlanReplace {
        key: TurnKey,
        steps: Vec<CanonicalPlanStep>,
        explanation: Option<String>,
    },
    /// Merge an item and replay retained orphan deltas.
    ItemUpsert(CanonicalItem),
    /// Append text or retain it until the item starts.
    ItemDelta { key: ItemKey, delta: ItemDelta },
    /// Replace one live-only item field while the item is nonterminal.
    ItemLiveFieldReplace {
        key: ItemKey,
        field: String,
        value: Option<Value>,
    },
}

/// Rejected mutation transaction.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum ReducerError {
    /// A required protocol identity, kind, or delta field was empty.
    #[error("canonical mutation contains an empty {0}")]
    EmptyField(&'static str),
    /// Local revision cannot advance without wrapping.
    #[error("canonical state revision exhausted")]
    RevisionExhausted,
    /// Item content revision cannot advance without wrapping.
    #[error("item content revision exhausted")]
    ContentRevisionExhausted,
    /// A goal payload named a different owner from its mutation.
    #[error("canonical thread goal identity does not match its mutation thread")]
    GoalThreadMismatch,
}

#[derive(Clone, Debug)]
struct BufferedDelta {
    sequence: u64,
    delta: ItemDelta,
    utf8_bytes: usize,
}

/// Synchronous reducer owned by the sole ordered session actor.
#[derive(Clone, Debug)]
pub struct CanonicalStateReducer {
    state: CanonicalState,
    configuration: ReducerConfiguration,
    orphan_by_item: HashMap<ItemKey, VecDeque<BufferedDelta>>,
    orphan_order: VecDeque<(ItemKey, u64)>,
    orphan_delta_count: usize,
    orphan_utf8_bytes: usize,
    next_orphan_sequence: u64,
}

impl Default for CanonicalStateReducer {
    fn default() -> Self {
        Self::new(ReducerConfiguration::default())
    }
}

impl CanonicalStateReducer {
    /// Create an empty reducer with explicit bounds.
    #[must_use]
    pub fn new(configuration: ReducerConfiguration) -> Self {
        Self {
            state: CanonicalState::default(),
            configuration,
            orphan_by_item: HashMap::new(),
            orphan_order: VecDeque::new(),
            orphan_delta_count: 0,
            orphan_utf8_bytes: 0,
            next_orphan_sequence: 0,
        }
    }

    /// Immutable current replica.
    #[must_use]
    pub fn snapshot(&self) -> &CanonicalState {
        &self.state
    }

    /// Number of retained pre-start deltas.
    #[must_use]
    pub const fn buffered_orphan_delta_count(&self) -> usize {
        self.orphan_delta_count
    }

    /// Retained UTF-8 delta bytes.
    #[must_use]
    pub const fn buffered_orphan_utf8_bytes(&self) -> usize {
        self.orphan_utf8_bytes
    }

    /// Atomically apply well-formed mutations at one successor revision.
    ///
    /// Validation or reduction failure leaves the current graph unchanged.
    ///
    /// # Errors
    ///
    /// Returns [`ReducerError`] for malformed identities/fields or exhausted
    /// monotonic counters.
    pub fn apply(
        &mut self,
        mutations: &[CanonicalMutation],
    ) -> Result<Option<CanonicalChangeBatch>, ReducerError> {
        if mutations.is_empty() {
            return Ok(None);
        }
        for mutation in mutations {
            validate(mutation)?;
        }

        let mut working = self.clone();
        let base_revision = working.state.revision;
        let revision = base_revision
            .successor()
            .ok_or(ReducerError::RevisionExhausted)?;
        let mut changes = BTreeSet::new();
        for mutation in mutations {
            working.apply_one(mutation.clone(), &mut changes)?;
        }
        if changes.is_empty() {
            return Ok(None);
        }
        working.state.revision = revision;
        *self = working;
        Ok(Some(CanonicalChangeBatch {
            base_revision,
            revision,
            changes: changes.into_iter().collect(),
        }))
    }

    fn apply_one(
        &mut self,
        mutation: CanonicalMutation,
        changes: &mut BTreeSet<CanonicalChange>,
    ) -> Result<(), ReducerError> {
        match mutation {
            CanonicalMutation::ThreadUpsert(thread) => self.upsert_thread(thread, changes),
            CanonicalMutation::ThreadRemove(thread_id) => self.remove_thread(&thread_id, changes),
            CanonicalMutation::ThreadGoalReplace { thread_id, goal } => {
                self.replace_thread_goal(thread_id, goal, changes);
            }
            CanonicalMutation::TurnUpsert(turn) => self.upsert_turn(turn, changes),
            CanonicalMutation::TurnPlanReplace {
                key,
                steps,
                explanation,
            } => self.replace_plan(key, steps, explanation, changes),
            CanonicalMutation::ItemUpsert(item) => self.upsert_item(item, changes)?,
            CanonicalMutation::ItemDelta { key, delta } => {
                self.apply_or_buffer_delta(key, delta, changes)?;
            }
            CanonicalMutation::ItemLiveFieldReplace { key, field, value } => {
                self.replace_live_field(key, field, value, changes)?;
            }
        }
        Ok(())
    }

    fn upsert_thread(
        &mut self,
        incoming: CanonicalThread,
        changes: &mut BTreeSet<CanonicalChange>,
    ) {
        let id = incoming.id.clone();
        match self.state.threads.get_mut(&id) {
            None => {
                if incoming.goal.is_some() {
                    changes.insert(CanonicalChange::ThreadGoalUpdated(id.clone()));
                }
                self.state.thread_order.push(id.clone());
                self.state.threads.insert(id.clone(), incoming);
                changes.insert(CanonicalChange::ThreadInserted(id));
            }
            Some(existing) => {
                let before = existing.clone();
                existing.status = incoming.status;
                existing.coverage = existing.coverage.merged(incoming.coverage);
                append_unique(&mut existing.turn_ids, incoming.turn_ids);
                if incoming.goal.is_some() && existing.goal != incoming.goal {
                    existing.goal = incoming.goal;
                    changes.insert(CanonicalChange::ThreadGoalUpdated(id.clone()));
                }
                existing.metadata.extend(incoming.metadata);
                if *existing != before {
                    changes.insert(CanonicalChange::ThreadUpdated(id));
                }
            }
        }
    }

    fn replace_thread_goal(
        &mut self,
        thread_id: ThreadId,
        goal: Option<CanonicalThreadGoal>,
        changes: &mut BTreeSet<CanonicalChange>,
    ) {
        let inserted = !self.state.threads.contains_key(&thread_id);
        self.ensure_thread(&thread_id, changes);
        let thread = self
            .state
            .threads
            .get_mut(&thread_id)
            .expect("thread established above");
        if thread.goal != goal {
            thread.goal = goal;
            changes.insert(CanonicalChange::ThreadGoalUpdated(thread_id));
        } else if inserted {
            // An authoritative empty get/clear still resolves previously
            // unknown goal state for a newly materialized thread.
            changes.insert(CanonicalChange::ThreadGoalUpdated(thread_id));
        }
    }

    fn ensure_thread(&mut self, id: &ThreadId, changes: &mut BTreeSet<CanonicalChange>) {
        if !self.state.threads.contains_key(id) {
            self.state.thread_order.push(id.clone());
            self.state
                .threads
                .insert(id.clone(), CanonicalThread::partial(id.clone()));
            changes.insert(CanonicalChange::ThreadInserted(id.clone()));
        }
    }

    fn upsert_turn(&mut self, incoming: CanonicalTurn, changes: &mut BTreeSet<CanonicalChange>) {
        self.ensure_thread(&incoming.key.thread_id, changes);
        let key = incoming.key.clone();
        let thread = self
            .state
            .threads
            .get_mut(&key.thread_id)
            .expect("thread established above");
        if !thread.turn_ids.contains(&key.turn_id) {
            thread.turn_ids.push(key.turn_id.clone());
            changes.insert(CanonicalChange::ThreadUpdated(key.thread_id.clone()));
        }
        match self.state.turns.get_mut(&key) {
            None => {
                self.state.turns.insert(key.clone(), incoming);
                changes.insert(CanonicalChange::TurnInserted(key));
            }
            Some(existing) => {
                let before = existing.clone();
                existing.status = merge_lifecycle(&existing.status, incoming.status);
                existing.coverage = existing.coverage.merged(incoming.coverage);
                append_unique(&mut existing.item_ids, incoming.item_ids);
                if let Some(plan) = incoming.plan {
                    existing.plan = Some(plan);
                    existing.plan_explanation = incoming.plan_explanation;
                }
                existing.metadata.extend(incoming.metadata);
                if *existing != before {
                    changes.insert(CanonicalChange::TurnUpdated(key));
                }
            }
        }
    }

    fn ensure_turn(&mut self, key: &TurnKey, changes: &mut BTreeSet<CanonicalChange>) {
        if !self.state.turns.contains_key(key) {
            self.upsert_turn(CanonicalTurn::partial(key.clone()), changes);
        }
    }

    fn replace_plan(
        &mut self,
        key: TurnKey,
        steps: Vec<CanonicalPlanStep>,
        explanation: Option<String>,
        changes: &mut BTreeSet<CanonicalChange>,
    ) {
        self.ensure_turn(&key, changes);
        let turn = self
            .state
            .turns
            .get_mut(&key)
            .expect("turn established above");
        if turn.plan.as_ref() != Some(&steps) || turn.plan_explanation != explanation {
            turn.plan = Some(steps);
            turn.plan_explanation = explanation;
            changes.insert(CanonicalChange::PlanUpdated(key));
        }
    }

    fn upsert_item(
        &mut self,
        mut incoming: CanonicalItem,
        changes: &mut BTreeSet<CanonicalChange>,
    ) -> Result<(), ReducerError> {
        let turn_key = incoming.key.turn_key();
        self.ensure_turn(&turn_key, changes);
        let key = incoming.key.clone();
        let turn = self
            .state
            .turns
            .get_mut(&turn_key)
            .expect("turn established above");
        if !turn.item_ids.contains(&key.item_id) {
            turn.item_ids.push(key.item_id.clone());
            changes.insert(CanonicalChange::TurnUpdated(turn_key));
        }

        let incoming_is_terminal = incoming.status.is_terminal();
        if incoming_is_terminal {
            incoming.live_overlay = ItemLiveOverlay::default();
            incoming.live_fields.clear();
        }
        match self.state.items.get_mut(&key) {
            None => {
                self.state.items.insert(key.clone(), incoming);
                changes.insert(CanonicalChange::ItemInserted(key.clone()));
            }
            Some(existing) => {
                let before = existing.clone();
                let existing_is_terminal = existing.status.is_terminal();
                existing.coverage = existing.coverage.merged(incoming.coverage);
                if incoming_is_terminal {
                    existing.kind = incoming.kind;
                    existing.status = merge_lifecycle(&existing.status, incoming.status);
                    existing.payload = incoming.payload;
                    existing.duration_ms = incoming.duration_ms;
                    existing.error = incoming.error;
                    if incoming.started_at_ms.is_some() {
                        existing.started_at_ms = incoming.started_at_ms;
                    }
                    if incoming.completed_at_ms.is_some() {
                        existing.completed_at_ms = incoming.completed_at_ms;
                    }
                    existing.live_overlay = ItemLiveOverlay::default();
                    existing.live_fields.clear();
                } else if !existing_is_terminal {
                    existing.kind = incoming.kind;
                    existing.status = incoming.status;
                    existing.payload.append(&mut incoming.payload);
                    if incoming.started_at_ms.is_some() {
                        existing.started_at_ms = incoming.started_at_ms;
                    }
                    if incoming.completed_at_ms.is_some() {
                        existing.completed_at_ms = incoming.completed_at_ms;
                    }
                    if incoming.duration_ms.is_some() {
                        existing.duration_ms = incoming.duration_ms;
                    }
                    if incoming.error.is_some() {
                        existing.error = incoming.error;
                    }
                    existing.live_fields.extend(incoming.live_fields);
                } else if existing.started_at_ms.is_none() && incoming.started_at_ms.is_some() {
                    // A late start notification may fill timing metadata but
                    // must never regress an already-authoritative terminal item.
                    existing.started_at_ms = incoming.started_at_ms;
                }
                if *existing != before {
                    existing.content_revision = existing
                        .content_revision
                        .checked_add(1)
                        .ok_or(ReducerError::ContentRevisionExhausted)?;
                    changes.insert(CanonicalChange::ItemUpdated(key.clone()));
                }
            }
        }
        if incoming_is_terminal {
            self.discard_orphans(&key);
            Ok(())
        } else {
            self.replay_orphans(&key, changes)
        }
    }

    fn apply_or_buffer_delta(
        &mut self,
        key: ItemKey,
        delta: ItemDelta,
        changes: &mut BTreeSet<CanonicalChange>,
    ) -> Result<(), ReducerError> {
        if self.state.items.contains_key(&key) {
            return self.append_delta(&key, delta, changes);
        }
        self.buffer_orphan(key, delta, changes)
    }

    fn append_delta(
        &mut self,
        key: &ItemKey,
        delta: ItemDelta,
        changes: &mut BTreeSet<CanonicalChange>,
    ) -> Result<(), ReducerError> {
        let item = self
            .state
            .items
            .get_mut(key)
            .expect("delta target checked by caller");
        if item.status.is_terminal() {
            return Ok(());
        }
        item.live_overlay.append(delta);
        item.content_revision = item
            .content_revision
            .checked_add(1)
            .ok_or(ReducerError::ContentRevisionExhausted)?;
        changes.insert(CanonicalChange::ItemDeltaAppended(key.clone()));
        Ok(())
    }

    fn buffer_orphan(
        &mut self,
        key: ItemKey,
        delta: ItemDelta,
        changes: &mut BTreeSet<CanonicalChange>,
    ) -> Result<(), ReducerError> {
        let bytes = delta.utf8_bytes();
        if self.configuration.maximum_orphan_delta_count == 0
            || self.configuration.maximum_orphan_deltas_per_item == 0
            || bytes > self.configuration.maximum_orphan_utf8_bytes
        {
            changes.insert(CanonicalChange::OrphanDeltaDropped(key));
            return Ok(());
        }

        while self
            .orphan_by_item
            .get(&key)
            .is_some_and(|queue| queue.len() >= self.configuration.maximum_orphan_deltas_per_item)
        {
            self.evict_item_front(&key, changes);
        }
        while self.orphan_delta_count >= self.configuration.maximum_orphan_delta_count
            || self.orphan_utf8_bytes.saturating_add(bytes)
                > self.configuration.maximum_orphan_utf8_bytes
        {
            if !self.evict_global_front(changes) {
                break;
            }
        }

        let sequence = self.next_orphan_sequence;
        self.next_orphan_sequence = self
            .next_orphan_sequence
            .checked_add(1)
            .ok_or(ReducerError::ContentRevisionExhausted)?;
        self.orphan_by_item
            .entry(key.clone())
            .or_default()
            .push_back(BufferedDelta {
                sequence,
                delta,
                utf8_bytes: bytes,
            });
        self.orphan_order.push_back((key.clone(), sequence));
        self.orphan_delta_count += 1;
        self.orphan_utf8_bytes += bytes;
        changes.insert(CanonicalChange::OrphanDeltaBuffered(key));
        Ok(())
    }

    fn replay_orphans(
        &mut self,
        key: &ItemKey,
        changes: &mut BTreeSet<CanonicalChange>,
    ) -> Result<(), ReducerError> {
        let Some(queue) = self.orphan_by_item.remove(key) else {
            return Ok(());
        };
        for buffered in queue {
            self.orphan_delta_count -= 1;
            self.orphan_utf8_bytes -= buffered.utf8_bytes;
            self.append_delta(key, buffered.delta, changes)?;
        }
        Ok(())
    }

    fn discard_orphans(&mut self, key: &ItemKey) {
        let Some(queue) = self.orphan_by_item.remove(key) else {
            return;
        };
        for buffered in queue {
            self.orphan_delta_count -= 1;
            self.orphan_utf8_bytes -= buffered.utf8_bytes;
        }
    }

    fn replace_live_field(
        &mut self,
        key: ItemKey,
        field: String,
        value: Option<Value>,
        changes: &mut BTreeSet<CanonicalChange>,
    ) -> Result<(), ReducerError> {
        let Some(item) = self.state.items.get_mut(&key) else {
            return Ok(());
        };
        if item.status.is_terminal() {
            return Ok(());
        }
        let previous = item.live_fields.get(&field);
        if previous == value.as_ref() {
            return Ok(());
        }
        if let Some(value) = value {
            item.live_fields.insert(field, value);
        } else {
            item.live_fields.remove(&field);
        }
        item.content_revision = item
            .content_revision
            .checked_add(1)
            .ok_or(ReducerError::ContentRevisionExhausted)?;
        changes.insert(CanonicalChange::ItemLiveFieldReplaced(key));
        Ok(())
    }

    fn evict_item_front(&mut self, key: &ItemKey, changes: &mut BTreeSet<CanonicalChange>) {
        let mut remove_queue = false;
        if let Some(queue) = self.orphan_by_item.get_mut(key)
            && let Some(buffered) = queue.pop_front()
        {
            self.orphan_delta_count -= 1;
            self.orphan_utf8_bytes -= buffered.utf8_bytes;
            remove_queue = queue.is_empty();
            changes.insert(CanonicalChange::OrphanDeltaDropped(key.clone()));
        }
        if remove_queue {
            self.orphan_by_item.remove(key);
        }
    }

    fn evict_global_front(&mut self, changes: &mut BTreeSet<CanonicalChange>) -> bool {
        while let Some((key, sequence)) = self.orphan_order.pop_front() {
            let matches_front = self
                .orphan_by_item
                .get(&key)
                .and_then(VecDeque::front)
                .is_some_and(|entry| entry.sequence == sequence);
            if matches_front {
                self.evict_item_front(&key, changes);
                return true;
            }
        }
        false
    }

    fn remove_thread(&mut self, thread_id: &ThreadId, changes: &mut BTreeSet<CanonicalChange>) {
        if self.state.threads.remove(thread_id).is_none() {
            return;
        }
        self.state.thread_order.retain(|id| id != thread_id);
        self.state
            .turns
            .retain(|key, _| &key.thread_id != thread_id);
        self.state
            .items
            .retain(|key, _| &key.thread_id != thread_id);
        let orphan_keys: Vec<_> = self
            .orphan_by_item
            .keys()
            .filter(|key| &key.thread_id == thread_id)
            .cloned()
            .collect();
        for key in orphan_keys {
            while self.orphan_by_item.contains_key(&key) {
                self.evict_item_front(&key, changes);
            }
        }
        changes.insert(CanonicalChange::ThreadRemoved(thread_id.clone()));
    }
}

fn validate(mutation: &CanonicalMutation) -> Result<(), ReducerError> {
    let check_thread = |id: &ThreadId| {
        if id.as_str().is_empty() {
            Err(ReducerError::EmptyField("thread id"))
        } else {
            Ok(())
        }
    };
    match mutation {
        CanonicalMutation::ThreadUpsert(thread) => {
            check_thread(&thread.id)?;
            if let Some(goal) = &thread.goal {
                check_thread(&goal.thread_id)?;
                if goal.thread_id != thread.id {
                    return Err(ReducerError::GoalThreadMismatch);
                }
            }
            Ok(())
        }
        CanonicalMutation::ThreadRemove(id) => check_thread(id),
        CanonicalMutation::ThreadGoalReplace { thread_id, goal } => {
            check_thread(thread_id)?;
            if let Some(goal) = goal {
                check_thread(&goal.thread_id)?;
                if &goal.thread_id != thread_id {
                    return Err(ReducerError::GoalThreadMismatch);
                }
            }
            Ok(())
        }
        CanonicalMutation::TurnUpsert(turn) => {
            check_thread(&turn.key.thread_id)?;
            if turn.key.turn_id.as_str().is_empty() {
                Err(ReducerError::EmptyField("turn id"))
            } else {
                Ok(())
            }
        }
        CanonicalMutation::TurnPlanReplace { key, steps, .. } => {
            check_thread(&key.thread_id)?;
            if key.turn_id.as_str().is_empty() {
                return Err(ReducerError::EmptyField("turn id"));
            }
            if steps.iter().any(|step| step.step.is_empty()) {
                Err(ReducerError::EmptyField("plan step"))
            } else {
                Ok(())
            }
        }
        CanonicalMutation::ItemUpsert(item) => {
            check_item_key(&item.key)?;
            if item.kind.is_empty() {
                Err(ReducerError::EmptyField("item kind"))
            } else {
                Ok(())
            }
        }
        CanonicalMutation::ItemDelta { key, .. } => check_item_key(key),
        CanonicalMutation::ItemLiveFieldReplace { key, field, .. } => {
            check_item_key(key)?;
            if field.is_empty() {
                Err(ReducerError::EmptyField("delta field"))
            } else {
                Ok(())
            }
        }
    }
}

fn check_item_key(key: &ItemKey) -> Result<(), ReducerError> {
    if key.thread_id.as_str().is_empty() {
        return Err(ReducerError::EmptyField("thread id"));
    }
    if key.turn_id.as_str().is_empty() {
        return Err(ReducerError::EmptyField("turn id"));
    }
    if key.item_id.as_str().is_empty() {
        return Err(ReducerError::EmptyField("item id"));
    }
    Ok(())
}

fn merge_lifecycle(existing: &LifecycleStatus, incoming: LifecycleStatus) -> LifecycleStatus {
    if existing.is_terminal() {
        existing.clone()
    } else {
        incoming
    }
}

fn append_unique<T: Eq>(destination: &mut Vec<T>, incoming: Vec<T>) {
    for value in incoming {
        if !destination.contains(&value) {
            destination.push(value);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;
    use crate::{
        CanonicalTerminalInteraction, ItemId, PlanStepStatus, StateCoverage, StateEntityScope,
        StateFieldMask, StateInvalidation, StateObservationScope, ThreadGoalStatus, ThreadStatus,
        TurnId,
    };
    use serde_json::json;

    fn item_key(item: &str) -> ItemKey {
        ItemKey {
            thread_id: ThreadId::from("thread"),
            turn_id: TurnId::from("turn"),
            item_id: ItemId::from(item),
        }
    }

    fn item(key: ItemKey, status: LifecycleStatus) -> CanonicalItem {
        CanonicalItem {
            key,
            kind: "agentMessage".to_owned(),
            status,
            coverage: StateCoverage::Full,
            payload: BTreeMap::from([("text".to_owned(), json!("hello"))]),
            duration_ms: None,
            error: None,
            started_at_ms: None,
            completed_at_ms: None,
            live_overlay: ItemLiveOverlay::default(),
            live_fields: BTreeMap::new(),
            content_revision: 0,
        }
    }

    #[test]
    fn batch_commits_relationships_at_one_revision() {
        let mut reducer = CanonicalStateReducer::default();
        let key = item_key("item");
        let batch = reducer
            .apply(&[CanonicalMutation::ItemUpsert(item(
                key.clone(),
                LifecycleStatus::InProgress,
            ))])
            .expect("valid batch")
            .expect("changed batch");
        assert_eq!(batch.base_revision.get(), 0);
        assert_eq!(batch.revision.get(), 1);
        assert!(reducer.snapshot().threads.contains_key(&key.thread_id));
        assert!(reducer.snapshot().turns.contains_key(&key.turn_key()));
        assert!(reducer.snapshot().items.contains_key(&key));
    }

    #[test]
    fn terminal_item_does_not_regress() {
        let mut reducer = CanonicalStateReducer::default();
        let key = item_key("item");
        reducer
            .apply(&[CanonicalMutation::ItemUpsert(item(
                key.clone(),
                LifecycleStatus::Completed,
            ))])
            .expect("insert");
        reducer
            .apply(&[CanonicalMutation::ItemUpsert(item(
                key.clone(),
                LifecycleStatus::InProgress,
            ))])
            .expect("merge");
        assert_eq!(
            reducer.snapshot().items[&key].status,
            LifecycleStatus::Completed
        );
    }

    #[test]
    fn terminal_interactions_and_item_timing_follow_lifecycle_authority() {
        let mut reducer = CanonicalStateReducer::default();
        let key = item_key("item");
        let mut started = item(key.clone(), LifecycleStatus::InProgress);
        started.started_at_ms = Some(100);
        reducer
            .apply(&[CanonicalMutation::ItemUpsert(started)])
            .expect("start item");
        reducer
            .apply(&[CanonicalMutation::ItemDelta {
                key: key.clone(),
                delta: ItemDelta::TerminalInteraction {
                    process_id: "process".to_owned(),
                    stdin: "yes\n".to_owned(),
                },
            }])
            .expect("terminal input");
        assert_eq!(
            reducer.snapshot().items[&key]
                .live_overlay
                .terminal_interactions,
            [CanonicalTerminalInteraction {
                process_id: "process".to_owned(),
                stdin: "yes\n".to_owned(),
            }]
        );

        let mut completed = item(key.clone(), LifecycleStatus::Completed);
        completed.completed_at_ms = Some(250);
        reducer
            .apply(&[CanonicalMutation::ItemUpsert(completed)])
            .expect("complete item");
        let completed_item = &reducer.snapshot().items[&key];
        assert_eq!(completed_item.started_at_ms, Some(100));
        assert_eq!(completed_item.completed_at_ms, Some(250));
        assert!(completed_item.live_overlay.is_empty());

        let mut late_start = item(key.clone(), LifecycleStatus::InProgress);
        late_start.started_at_ms = Some(90);
        reducer
            .apply(&[CanonicalMutation::ItemUpsert(late_start)])
            .expect("late start metadata");
        let completed_item = &reducer.snapshot().items[&key];
        assert_eq!(completed_item.status, LifecycleStatus::Completed);
        assert_eq!(completed_item.started_at_ms, Some(100));
    }

    #[test]
    fn orphan_deltas_replay_in_wire_order() {
        let mut reducer = CanonicalStateReducer::default();
        let key = item_key("late");
        for text in [" one", " two"] {
            reducer
                .apply(&[CanonicalMutation::ItemDelta {
                    key: key.clone(),
                    delta: ItemDelta::AgentMessage(text.to_owned()),
                }])
                .expect("buffer delta");
        }
        assert_eq!(reducer.buffered_orphan_delta_count(), 2);
        reducer
            .apply(&[CanonicalMutation::ItemUpsert(item(
                key.clone(),
                LifecycleStatus::InProgress,
            ))])
            .expect("insert item");
        assert_eq!(
            reducer.snapshot().items[&key]
                .live_overlay
                .agent_message
                .joined(),
            " one two"
        );
        assert_eq!(reducer.buffered_orphan_delta_count(), 0);
    }

    #[test]
    fn orphan_budget_evicts_oldest_delta() {
        let mut reducer = CanonicalStateReducer::new(ReducerConfiguration {
            maximum_orphan_delta_count: 2,
            maximum_orphan_utf8_bytes: 32,
            maximum_orphan_deltas_per_item: 2,
        });
        for (item, text) in [("a", "a"), ("b", "b"), ("c", "c")] {
            reducer
                .apply(&[CanonicalMutation::ItemDelta {
                    key: item_key(item),
                    delta: ItemDelta::AgentMessage(text.to_owned()),
                }])
                .expect("bounded buffer");
        }
        assert_eq!(reducer.buffered_orphan_delta_count(), 2);
        reducer
            .apply(&[CanonicalMutation::ItemUpsert(item(
                item_key("a"),
                LifecycleStatus::InProgress,
            ))])
            .expect("materialize evicted item");
        assert_eq!(
            reducer.snapshot().items[&item_key("a")].payload["text"],
            "hello"
        );
    }

    #[test]
    fn malformed_batch_is_atomic() {
        let mut reducer = CanonicalStateReducer::default();
        let before = reducer.snapshot().clone();
        let error = reducer
            .apply(&[
                CanonicalMutation::ItemDelta {
                    key: item_key("valid"),
                    delta: ItemDelta::AgentMessage("value".to_owned()),
                },
                CanonicalMutation::ItemLiveFieldReplace {
                    key: item_key("invalid"),
                    field: String::new(),
                    value: Some(json!(true)),
                },
            ])
            .expect_err("invalid field rejects transaction");
        assert_eq!(error, ReducerError::EmptyField("delta field"));
        assert_eq!(reducer.snapshot(), &before);
        assert_eq!(reducer.buffered_orphan_delta_count(), 0);
    }

    #[test]
    fn unknown_lifecycle_round_trips_losslessly() {
        let status = LifecycleStatus::from_raw("futureStatus");
        let encoded = serde_json::to_string(&status).expect("encode");
        let decoded: LifecycleStatus = serde_json::from_str(&encoded).expect("decode");
        assert_eq!(decoded, status);
    }

    #[test]
    fn thread_upsert_never_decreases_coverage() {
        let mut reducer = CanonicalStateReducer::default();
        let make = |coverage| CanonicalThread {
            id: ThreadId::from("thread"),
            status: ThreadStatus::Idle,
            coverage,
            turn_ids: Vec::new(),
            goal: None,
            metadata: BTreeMap::new(),
        };
        reducer
            .apply(&[CanonicalMutation::ThreadUpsert(make(StateCoverage::Full))])
            .expect("insert");
        reducer
            .apply(&[CanonicalMutation::ThreadUpsert(make(
                StateCoverage::Summary,
            ))])
            .expect("merge");
        assert_eq!(
            reducer.snapshot().threads[&ThreadId::from("thread")].coverage,
            StateCoverage::Full
        );
    }

    #[test]
    fn unrelated_thread_upsert_does_not_clear_goal() {
        let mut reducer = CanonicalStateReducer::default();
        let thread_id = ThreadId::from("thread");
        let goal = goal("thread", ThreadGoalStatus::Active);
        reducer
            .apply(&[CanonicalMutation::ThreadGoalReplace {
                thread_id: thread_id.clone(),
                goal: Some(goal.clone()),
            }])
            .expect("set goal");
        reducer
            .apply(&[CanonicalMutation::ThreadUpsert(CanonicalThread {
                id: thread_id.clone(),
                status: ThreadStatus::Idle,
                coverage: StateCoverage::Full,
                turn_ids: Vec::new(),
                goal: None,
                metadata: BTreeMap::new(),
            })])
            .expect("unrelated thread update");
        assert_eq!(
            reducer.snapshot().threads[&thread_id].goal.as_ref(),
            Some(&goal)
        );
    }

    #[test]
    fn plan_replace_is_typed_atomic_and_idempotent() {
        let mut reducer = CanonicalStateReducer::default();
        let key = TurnKey {
            thread_id: ThreadId::from("thread"),
            turn_id: TurnId::from("turn"),
        };
        let mutation = CanonicalMutation::TurnPlanReplace {
            key: key.clone(),
            steps: vec![CanonicalPlanStep {
                step: "Build".to_owned(),
                status: PlanStepStatus::InProgress,
            }],
            explanation: Some("Plan".to_owned()),
        };
        let batch = reducer
            .apply(std::slice::from_ref(&mutation))
            .expect("plan transaction")
            .expect("plan changed");
        assert!(
            batch
                .changes
                .contains(&CanonicalChange::PlanUpdated(key.clone()))
        );
        assert_eq!(
            reducer.snapshot().turns[&key].plan_explanation.as_deref(),
            Some("Plan")
        );
        assert!(
            reducer
                .apply(&[mutation])
                .expect("idempotent plan transaction")
                .is_none()
        );
    }

    fn goal(thread_id: &str, status: ThreadGoalStatus) -> CanonicalThreadGoal {
        CanonicalThreadGoal {
            thread_id: ThreadId::from(thread_id),
            objective: "Ship parity".to_owned(),
            status,
            token_budget: Some(4_096),
            tokens_used: 512,
            time_used_seconds: 45,
            created_at: 10,
            updated_at: 20,
            extensions: BTreeMap::from([("futureField".to_owned(), json!(true))]),
        }
    }

    #[test]
    fn goal_replace_is_atomic_idempotent_and_lossless() {
        let mut reducer = CanonicalStateReducer::default();
        let thread_id = ThreadId::from("thread");
        let goal = goal(
            thread_id.as_str(),
            ThreadGoalStatus::Unknown("futureStatus".to_owned()),
        );
        let mutation = CanonicalMutation::ThreadGoalReplace {
            thread_id: thread_id.clone(),
            goal: Some(goal.clone()),
        };
        let batch = reducer
            .apply(std::slice::from_ref(&mutation))
            .expect("goal transaction")
            .expect("goal changed");
        assert!(
            batch
                .changes
                .contains(&CanonicalChange::ThreadGoalUpdated(thread_id.clone()))
        );
        assert_eq!(reducer.snapshot().threads[&thread_id].goal, Some(goal));
        assert!(
            reducer
                .apply(std::slice::from_ref(&mutation))
                .expect("idempotent goal transaction")
                .is_none()
        );

        reducer
            .apply(&[CanonicalMutation::ThreadGoalReplace {
                thread_id: thread_id.clone(),
                goal: None,
            }])
            .expect("clear goal");
        assert_eq!(reducer.snapshot().threads[&thread_id].goal, None);
    }

    #[test]
    fn authoritative_empty_goal_materializes_one_goal_invalidation() {
        let mut reducer = CanonicalStateReducer::default();
        let thread_id = ThreadId::from("thread");
        let mutation = CanonicalMutation::ThreadGoalReplace {
            thread_id: thread_id.clone(),
            goal: None,
        };
        let batch = reducer
            .apply(std::slice::from_ref(&mutation))
            .expect("empty goal transaction")
            .expect("unknown goal became authoritatively empty");
        assert!(
            batch
                .changes
                .contains(&CanonicalChange::ThreadGoalUpdated(thread_id))
        );
        assert!(
            reducer
                .apply(&[mutation])
                .expect("second empty goal is idempotent")
                .is_none()
        );
    }

    #[test]
    fn goal_invalidation_is_field_and_thread_scoped() {
        let observed_id = ThreadId::from("observed");
        let sibling_id = ThreadId::from("sibling");
        let batch = CanonicalChangeBatch {
            base_revision: crate::StateRevision::ZERO,
            revision: crate::StateRevision::new(1),
            changes: vec![CanonicalChange::ThreadGoalUpdated(observed_id.clone())],
        };
        let invalidation = StateInvalidation::from_batch(&batch);
        assert!(invalidation.affects(
            &StateObservationScope::thread(observed_id).with_fields(StateFieldMask::THREAD_GOAL)
        ));
        assert!(!invalidation.affects(
            &StateObservationScope::thread(sibling_id).with_fields(StateFieldMask::THREAD_GOAL)
        ));
        assert!(!invalidation.affects(&StateObservationScope {
            entities: StateEntityScope::All,
            fields: StateFieldMask::PLAN,
        }));
    }

    #[test]
    fn mismatched_goal_owner_rejects_the_whole_batch() {
        let mut reducer = CanonicalStateReducer::default();
        let before = reducer.snapshot().clone();
        let error = reducer
            .apply(&[CanonicalMutation::ThreadGoalReplace {
                thread_id: ThreadId::from("thread"),
                goal: Some(goal("other", ThreadGoalStatus::Active)),
            }])
            .expect_err("mismatched owner must fail");
        assert_eq!(error, ReducerError::GoalThreadMismatch);
        assert_eq!(reducer.snapshot(), &before);
    }

    #[test]
    fn unknown_goal_status_round_trips_losslessly() {
        let status = ThreadGoalStatus::from_raw("futureStatus");
        let encoded = serde_json::to_string(&status).expect("encode");
        let decoded: ThreadGoalStatus = serde_json::from_str(&encoded).expect("decode");
        assert_eq!(decoded, status);
        assert_eq!(decoded.as_raw(), "futureStatus");
    }
}
