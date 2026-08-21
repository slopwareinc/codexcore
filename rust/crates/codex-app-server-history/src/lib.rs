//! Pure paginated history reconciliation state machine.

use std::collections::{BTreeMap, BTreeSet, VecDeque};

use codex_app_server_state::{ItemId, ThreadId, TurnId};
use serde_json::Value;
use thiserror::Error;

/// Page sizing and item request concurrency.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct HistoryPolicy {
    /// Turns requested per page.
    pub turn_page_limit: u32,
    /// Items requested per page.
    pub item_page_limit: u32,
    /// Simultaneous per-turn item chains.
    pub maximum_concurrent_item_pages: usize,
}

impl Default for HistoryPolicy {
    fn default() -> Self {
        Self {
            turn_page_limit: 50,
            item_page_limit: 100,
            maximum_concurrent_item_pages: 4,
        }
    }
}

/// Coordinator-local request identity.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct HistoryRequestId(u64);

impl HistoryRequestId {
    /// Stored numeric identity.
    #[must_use]
    pub const fn get(self) -> u64 {
        self.0
    }
}

/// Durable resume cut anchors.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HistoryCut {
    /// Physical connection generation.
    pub connection_epoch: u64,
    /// Lease/reconciliation generation.
    pub resume_generation: u64,
    /// Descending turns anchor.
    pub turns_backwards_cursor: Option<String>,
    /// Descending items anchor.
    pub items_backwards_cursor: Option<String>,
}

/// Lossless turn page record.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TurnRecord {
    pub turn_id: TurnId,
    pub value: Value,
}

/// Lossless item page record.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ItemRecord {
    pub turn_id: TurnId,
    pub item_id: ItemId,
    pub value: Value,
}

/// Optional descending page embedded in `thread/resume`.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct InitialTurnsPage {
    /// Newest-first records.
    pub data: Vec<TurnRecord>,
    /// Reverse-direction anchor for the page.
    pub backwards_cursor: Option<String>,
    /// Next descending cursor.
    pub next_cursor: Option<String>,
}

/// I/O requested from the ordered actor.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum HistoryEffect {
    /// Resume metadata-only and establish a cut.
    RequestResume {
        request_id: HistoryRequestId,
        thread_id: ThreadId,
    },
    /// Fetch another descending turn page with summary items.
    RequestTurns {
        request_id: HistoryRequestId,
        thread_id: ThreadId,
        cursor: String,
        limit: u32,
    },
    /// Fetch another descending item page for one turn.
    RequestItems {
        request_id: HistoryRequestId,
        thread_id: ThreadId,
        turn_id: TurnId,
        cursor: String,
        limit: u32,
    },
    /// Install complete durable history at the cut.
    Install(HistoryInstallation),
    /// Mark installed coverage uncertain after connection loss.
    MarkStale {
        thread_id: ThreadId,
        previous_cut: Option<HistoryCut>,
    },
    /// Stop reconciliation without partial installation.
    Failed(HistoryFailure),
}

/// Complete durable installation, ordered oldest-first.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HistoryInstallation {
    /// Thread being installed.
    pub thread_id: ThreadId,
    /// Durable cut.
    pub cut: HistoryCut,
    /// Complete turns oldest-first.
    pub turns: Vec<TurnRecord>,
    /// Complete items grouped by turn order, each oldest-first.
    pub items: Vec<ItemRecord>,
    /// Whether a prior installed cut crossed a connection gap.
    pub crossed_connection_gap: bool,
}

/// Request family for diagnostics.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum HistoryRequestKind {
    Resume,
    Turns,
    Items(TurnId),
}

/// Fail-closed reconciliation reason.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum HistoryFailureReason {
    /// Request failed.
    #[error("{kind:?} request failed: {message}")]
    RequestFailed {
        kind: HistoryRequestKind,
        message: String,
    },
    /// Continuation repeated an already-seen cursor.
    #[error("{kind:?} repeated cursor {cursor}")]
    RepeatedCursor {
        kind: HistoryRequestKind,
        cursor: String,
    },
    /// Empty page claimed another continuation.
    #[error("{0:?} returned an empty page with continuation")]
    EmptyPageWithContinuation(HistoryRequestKind),
    /// Item page violated its requested turn filter.
    #[error("item returned for {actual} while requesting {expected}")]
    WrongTurn { expected: TurnId, actual: TurnId },
    /// Items cursor exists while no turn can own it.
    #[error("items cursor exists without any turns")]
    ItemsWithoutTurns,
    /// Monotonic request identity exhausted.
    #[error("history request identity exhausted")]
    RequestIdentityExhausted,
    /// Page or concurrency policy is zero.
    #[error("history policy {0} must be positive")]
    InvalidPolicy(&'static str),
}

/// Thread-qualified failure.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HistoryFailure {
    pub thread_id: ThreadId,
    pub reason: HistoryFailureReason,
}

/// Observable coordinator phase.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum HistoryPhase {
    AwaitingResume {
        connection_epoch: u64,
        resume_generation: u64,
    },
    Paging(HistoryCut),
    Live(HistoryCut),
    Stale(Option<HistoryCut>),
    Failed(HistoryFailure),
}

#[derive(Clone, Debug)]
struct ItemChain {
    records: BTreeMap<ItemId, ItemRecord>,
    newest_first: Vec<ItemId>,
    seen_cursors: BTreeSet<String>,
    next_cursor: Option<String>,
    active_request: Option<HistoryRequestId>,
}

#[derive(Clone, Debug)]
struct Paging {
    cut: HistoryCut,
    previous_cut: Option<HistoryCut>,
    turns: BTreeMap<TurnId, TurnRecord>,
    newest_first_turns: Vec<TurnId>,
    seen_turn_cursors: BTreeSet<String>,
    next_turn_cursor: Option<String>,
    active_turn_request: Option<HistoryRequestId>,
    item_chains: BTreeMap<TurnId, ItemChain>,
    pending_item_turns: VecDeque<TurnId>,
    active_item_requests: BTreeMap<HistoryRequestId, TurnId>,
}

#[derive(Clone, Debug)]
enum Scope {
    Awaiting {
        request_id: HistoryRequestId,
        epoch: u64,
        generation: u64,
        previous_cut: Option<HistoryCut>,
    },
    Paging(Box<Paging>),
    Live(HistoryCut),
    Stale(Option<HistoryCut>),
    Failed(HistoryFailure),
}

/// Synchronous coordinator owned by the ordered session actor.
#[derive(Clone, Debug)]
pub struct PaginatedHistoryCoordinator {
    policy: HistoryPolicy,
    scopes: BTreeMap<ThreadId, Scope>,
    next_request: u64,
}

impl Default for PaginatedHistoryCoordinator {
    fn default() -> Self {
        Self {
            policy: HistoryPolicy::default(),
            scopes: BTreeMap::new(),
            next_request: 1,
        }
    }
}

impl PaginatedHistoryCoordinator {
    /// Create a coordinator with explicit positive bounds.
    ///
    /// # Errors
    ///
    /// Returns [`HistoryFailureReason::InvalidPolicy`] for any zero bound.
    pub fn new(policy: HistoryPolicy) -> Result<Self, HistoryFailureReason> {
        if policy.turn_page_limit == 0 {
            return Err(HistoryFailureReason::InvalidPolicy("turn_page_limit"));
        }
        if policy.item_page_limit == 0 {
            return Err(HistoryFailureReason::InvalidPolicy("item_page_limit"));
        }
        if policy.maximum_concurrent_item_pages == 0 {
            return Err(HistoryFailureReason::InvalidPolicy(
                "maximum_concurrent_item_pages",
            ));
        }
        Ok(Self {
            policy,
            scopes: BTreeMap::new(),
            next_request: 1,
        })
    }

    /// Current phase for one thread.
    #[must_use]
    pub fn phase(&self, thread: &ThreadId) -> Option<HistoryPhase> {
        self.scopes.get(thread).map(|scope| match scope {
            Scope::Awaiting {
                epoch, generation, ..
            } => HistoryPhase::AwaitingResume {
                connection_epoch: *epoch,
                resume_generation: *generation,
            },
            Scope::Paging(paging) => HistoryPhase::Paging(paging.cut.clone()),
            Scope::Live(cut) => HistoryPhase::Live(cut.clone()),
            Scope::Stale(cut) => HistoryPhase::Stale(cut.clone()),
            Scope::Failed(failure) => HistoryPhase::Failed(failure.clone()),
        })
    }

    /// Begin a new reconciliation generation.
    ///
    /// # Errors
    ///
    /// Returns [`HistoryFailureReason::RequestIdentityExhausted`] before aliasing.
    pub fn begin(
        &mut self,
        thread_id: ThreadId,
        connection_epoch: u64,
        resume_generation: u64,
    ) -> Result<Vec<HistoryEffect>, HistoryFailureReason> {
        let previous_cut = cut(self.scopes.get(&thread_id));
        let request_id = self.allocate_request()?;
        self.scopes.insert(
            thread_id.clone(),
            Scope::Awaiting {
                request_id,
                epoch: connection_epoch,
                generation: resume_generation,
                previous_cut,
            },
        );
        Ok(vec![HistoryEffect::RequestResume {
            request_id,
            thread_id,
        }])
    }

    /// Install the resume cut and start turn paging.
    pub fn receive_resume_cut(
        &mut self,
        thread_id: &ThreadId,
        request_id: HistoryRequestId,
        turns_cursor: Option<String>,
        items_cursor: Option<String>,
        initial: Option<InitialTurnsPage>,
    ) -> Vec<HistoryEffect> {
        let Some(Scope::Awaiting {
            request_id: expected,
            epoch,
            generation,
            previous_cut,
        }) = self.scopes.get(thread_id).cloned()
        else {
            return Vec::new();
        };
        if expected != request_id {
            return Vec::new();
        }
        let cut = HistoryCut {
            connection_epoch: epoch,
            resume_generation: generation,
            turns_backwards_cursor: turns_cursor.clone(),
            items_backwards_cursor: items_cursor,
        };
        let mut paging = Paging {
            cut,
            previous_cut,
            turns: BTreeMap::new(),
            newest_first_turns: Vec::new(),
            seen_turn_cursors: BTreeSet::new(),
            next_turn_cursor: turns_cursor,
            active_turn_request: None,
            item_chains: BTreeMap::new(),
            pending_item_turns: VecDeque::new(),
            active_item_requests: BTreeMap::new(),
        };
        if let Some(initial) = initial {
            add_turns(&mut paging, initial.data);
            if initial.next_cursor.is_some() && paging.newest_first_turns.is_empty() {
                return self.fail(
                    thread_id,
                    HistoryFailureReason::EmptyPageWithContinuation(HistoryRequestKind::Turns),
                );
            }
            paging.next_turn_cursor = initial.next_cursor;
        }
        self.scopes
            .insert(thread_id.clone(), Scope::Paging(Box::new(paging)));
        self.pump(thread_id)
    }

    /// Apply one descending turn page if its request is current.
    pub fn receive_turns_page(
        &mut self,
        thread_id: &ThreadId,
        request_id: HistoryRequestId,
        data: Vec<TurnRecord>,
        next_cursor: Option<String>,
    ) -> Vec<HistoryEffect> {
        let Some(Scope::Paging(mut paging)) = self.scopes.get(thread_id).cloned() else {
            return Vec::new();
        };
        if paging.active_turn_request != Some(request_id) {
            return Vec::new();
        }
        paging.active_turn_request = None;
        if data.is_empty() && next_cursor.is_some() {
            return self.fail(
                thread_id,
                HistoryFailureReason::EmptyPageWithContinuation(HistoryRequestKind::Turns),
            );
        }
        add_turns(&mut paging, data);
        if let Some(cursor) = &next_cursor
            && !paging.seen_turn_cursors.insert(cursor.clone())
        {
            return self.fail(
                thread_id,
                HistoryFailureReason::RepeatedCursor {
                    kind: HistoryRequestKind::Turns,
                    cursor: cursor.clone(),
                },
            );
        }
        paging.next_turn_cursor = next_cursor;
        self.scopes.insert(thread_id.clone(), Scope::Paging(paging));
        self.pump(thread_id)
    }

    /// Apply one descending item page if its request/turn pair is current.
    pub fn receive_items_page(
        &mut self,
        thread_id: &ThreadId,
        turn_id: &TurnId,
        request_id: HistoryRequestId,
        data: Vec<ItemRecord>,
        next_cursor: Option<String>,
    ) -> Vec<HistoryEffect> {
        let Some(Scope::Paging(mut paging)) = self.scopes.get(thread_id).cloned() else {
            return Vec::new();
        };
        if paging.active_item_requests.get(&request_id) != Some(turn_id) {
            return Vec::new();
        }
        paging.active_item_requests.remove(&request_id);
        let Some(chain) = paging.item_chains.get_mut(turn_id) else {
            return Vec::new();
        };
        chain.active_request = None;
        let page_was_empty = data.is_empty();
        for record in data {
            if &record.turn_id != turn_id {
                return self.fail(
                    thread_id,
                    HistoryFailureReason::WrongTurn {
                        expected: turn_id.clone(),
                        actual: record.turn_id,
                    },
                );
            }
            if !chain.records.contains_key(&record.item_id) {
                chain.newest_first.push(record.item_id.clone());
                chain.records.insert(record.item_id.clone(), record);
            }
        }
        if page_was_empty && next_cursor.is_some() {
            return self.fail(
                thread_id,
                HistoryFailureReason::EmptyPageWithContinuation(HistoryRequestKind::Items(
                    turn_id.clone(),
                )),
            );
        }
        if let Some(cursor) = &next_cursor
            && !chain.seen_cursors.insert(cursor.clone())
        {
            return self.fail(
                thread_id,
                HistoryFailureReason::RepeatedCursor {
                    kind: HistoryRequestKind::Items(turn_id.clone()),
                    cursor: cursor.clone(),
                },
            );
        }
        chain.next_cursor = next_cursor;
        self.scopes.insert(thread_id.clone(), Scope::Paging(paging));
        self.pump(thread_id)
    }

    /// Fail the scope only when the request identity is still current.
    #[must_use]
    pub fn request_failed(
        &mut self,
        thread_id: &ThreadId,
        request_id: HistoryRequestId,
        message: impl Into<String>,
    ) -> Vec<HistoryEffect> {
        let Some(scope) = self.scopes.get(thread_id) else {
            return Vec::new();
        };
        let kind = match scope {
            Scope::Awaiting {
                request_id: expected,
                ..
            } if *expected == request_id => Some(HistoryRequestKind::Resume),
            Scope::Paging(paging) if paging.active_turn_request == Some(request_id) => {
                Some(HistoryRequestKind::Turns)
            }
            Scope::Paging(paging) => paging
                .active_item_requests
                .get(&request_id)
                .cloned()
                .map(HistoryRequestKind::Items),
            Scope::Awaiting { .. } | Scope::Live(_) | Scope::Stale(_) | Scope::Failed(_) => None,
        };
        kind.map_or_else(Vec::new, |kind| {
            self.fail(
                thread_id,
                HistoryFailureReason::RequestFailed {
                    kind,
                    message: message.into(),
                },
            )
        })
    }

    /// Mark scopes from a sealed physical epoch stale.
    #[must_use]
    pub fn connection_lost(&mut self, epoch: u64) -> Vec<HistoryEffect> {
        let threads: Vec<_> = self.scopes.keys().cloned().collect();
        let mut effects = Vec::new();
        for thread in threads {
            let Some(scope) = self.scopes.get(&thread) else {
                continue;
            };
            if scope_epoch(scope) != Some(epoch) {
                continue;
            }
            let previous_cut = cut(Some(scope));
            self.scopes
                .insert(thread.clone(), Scope::Stale(previous_cut.clone()));
            effects.push(HistoryEffect::MarkStale {
                thread_id: thread,
                previous_cut,
            });
        }
        effects
    }

    fn pump(&mut self, thread_id: &ThreadId) -> Vec<HistoryEffect> {
        let Some(Scope::Paging(mut paging)) = self.scopes.get(thread_id).cloned() else {
            return Vec::new();
        };
        if paging.active_turn_request.is_none()
            && let Some(cursor) = paging.next_turn_cursor.take()
        {
            if !paging.seen_turn_cursors.insert(cursor.clone()) && paging.turns.is_empty() {
                return self.fail(
                    thread_id,
                    HistoryFailureReason::RepeatedCursor {
                        kind: HistoryRequestKind::Turns,
                        cursor,
                    },
                );
            }
            let Ok(request_id) = self.allocate_request() else {
                return self.fail(thread_id, HistoryFailureReason::RequestIdentityExhausted);
            };
            paging.active_turn_request = Some(request_id);
            self.scopes.insert(thread_id.clone(), Scope::Paging(paging));
            return vec![HistoryEffect::RequestTurns {
                request_id,
                thread_id: thread_id.clone(),
                cursor,
                limit: self.policy.turn_page_limit,
            }];
        }
        if paging.active_turn_request.is_some() {
            return Vec::new();
        }
        if paging.item_chains.is_empty() {
            if paging.newest_first_turns.is_empty() {
                if paging.cut.items_backwards_cursor.is_some() {
                    return self.fail(thread_id, HistoryFailureReason::ItemsWithoutTurns);
                }
                return self.install(thread_id, paging);
            }
            for turn in &paging.newest_first_turns {
                paging.pending_item_turns.push_back(turn.clone());
                paging.item_chains.insert(
                    turn.clone(),
                    ItemChain {
                        records: BTreeMap::new(),
                        newest_first: Vec::new(),
                        seen_cursors: paging.cut.items_backwards_cursor.iter().cloned().collect(),
                        next_cursor: paging.cut.items_backwards_cursor.clone(),
                        active_request: None,
                    },
                );
            }
        }
        let mut effects = Vec::new();
        while paging.active_item_requests.len() < self.policy.maximum_concurrent_item_pages {
            let Some(turn) = paging.pending_item_turns.pop_front() else {
                break;
            };
            let Some(chain) = paging.item_chains.get_mut(&turn) else {
                continue;
            };
            let Some(cursor) = chain.next_cursor.take() else {
                continue;
            };
            let Ok(request_id) = self.allocate_request() else {
                return self.fail(thread_id, HistoryFailureReason::RequestIdentityExhausted);
            };
            chain.active_request = Some(request_id);
            paging.active_item_requests.insert(request_id, turn.clone());
            effects.push(HistoryEffect::RequestItems {
                request_id,
                thread_id: thread_id.clone(),
                turn_id: turn,
                cursor,
                limit: self.policy.item_page_limit,
            });
        }
        let finished = paging.active_item_requests.is_empty()
            && paging.pending_item_turns.is_empty()
            && paging
                .item_chains
                .values()
                .all(|chain| chain.next_cursor.is_none() && chain.active_request.is_none());
        if finished {
            return self.install(thread_id, paging);
        }
        self.scopes.insert(thread_id.clone(), Scope::Paging(paging));
        effects
    }

    fn install(&mut self, thread_id: &ThreadId, paging: Box<Paging>) -> Vec<HistoryEffect> {
        let paging = *paging;
        let turn_ids: Vec<_> = paging.newest_first_turns.iter().rev().cloned().collect();
        let turns = turn_ids
            .iter()
            .filter_map(|id| paging.turns.get(id).cloned())
            .collect();
        let mut items = Vec::new();
        for turn in &turn_ids {
            if let Some(chain) = paging.item_chains.get(turn) {
                items.extend(
                    chain
                        .newest_first
                        .iter()
                        .rev()
                        .filter_map(|id| chain.records.get(id).cloned()),
                );
            }
        }
        let installation = HistoryInstallation {
            thread_id: thread_id.clone(),
            cut: paging.cut.clone(),
            turns,
            items,
            crossed_connection_gap: paging
                .previous_cut
                .is_some_and(|cut| cut.connection_epoch != paging.cut.connection_epoch),
        };
        self.scopes
            .insert(thread_id.clone(), Scope::Live(paging.cut));
        vec![HistoryEffect::Install(installation)]
    }

    fn fail(&mut self, thread_id: &ThreadId, reason: HistoryFailureReason) -> Vec<HistoryEffect> {
        let failure = HistoryFailure {
            thread_id: thread_id.clone(),
            reason,
        };
        self.scopes
            .insert(thread_id.clone(), Scope::Failed(failure.clone()));
        vec![HistoryEffect::Failed(failure)]
    }

    fn allocate_request(&mut self) -> Result<HistoryRequestId, HistoryFailureReason> {
        let id = HistoryRequestId(self.next_request);
        self.next_request = self
            .next_request
            .checked_add(1)
            .ok_or(HistoryFailureReason::RequestIdentityExhausted)?;
        Ok(id)
    }
}

fn add_turns(paging: &mut Paging, data: Vec<TurnRecord>) {
    for record in data {
        if !paging.turns.contains_key(&record.turn_id) {
            paging.newest_first_turns.push(record.turn_id.clone());
            paging.turns.insert(record.turn_id.clone(), record);
        }
    }
}

fn cut(scope: Option<&Scope>) -> Option<HistoryCut> {
    match scope? {
        Scope::Awaiting { previous_cut, .. } => previous_cut.clone(),
        Scope::Paging(paging) => Some(paging.cut.clone()),
        Scope::Live(cut) => Some(cut.clone()),
        Scope::Stale(cut) => cut.clone(),
        Scope::Failed(_) => None,
    }
}

fn scope_epoch(scope: &Scope) -> Option<u64> {
    match scope {
        Scope::Awaiting { epoch, .. } => Some(*epoch),
        Scope::Paging(paging) => Some(paging.cut.connection_epoch),
        Scope::Live(cut) => Some(cut.connection_epoch),
        Scope::Stale(_) | Scope::Failed(_) => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn turn(id: &str) -> TurnRecord {
        TurnRecord {
            turn_id: TurnId::from(id),
            value: json!({"id": id}),
        }
    }
    fn item(turn: &str, id: &str) -> ItemRecord {
        ItemRecord {
            turn_id: TurnId::from(turn),
            item_id: ItemId::from(id),
            value: json!({"id": id}),
        }
    }

    #[test]
    fn installs_turns_and_items_oldest_first() {
        let thread = ThreadId::from("thread");
        let mut coordinator = PaginatedHistoryCoordinator::new(HistoryPolicy {
            maximum_concurrent_item_pages: 2,
            ..HistoryPolicy::default()
        })
        .expect("valid policy");
        let resume = coordinator.begin(thread.clone(), 1, 7).expect("begin");
        let HistoryEffect::RequestResume { request_id, .. } = resume[0] else {
            panic!("resume")
        };
        let turns = coordinator.receive_resume_cut(
            &thread,
            request_id,
            Some("turns".into()),
            Some("items".into()),
            None,
        );
        let HistoryEffect::RequestTurns { request_id, .. } = turns[0] else {
            panic!("turn page")
        };
        let item_effects = coordinator.receive_turns_page(
            &thread,
            request_id,
            vec![turn("new"), turn("old")],
            None,
        );
        assert_eq!(item_effects.len(), 2);
        let mut install = Vec::new();
        for effect in item_effects {
            let HistoryEffect::RequestItems {
                request_id,
                turn_id,
                ..
            } = effect
            else {
                panic!("item page")
            };
            let data = if turn_id.as_str() == "new" {
                vec![item("new", "n2"), item("new", "n1")]
            } else {
                vec![item("old", "o2"), item("old", "o1")]
            };
            install = coordinator.receive_items_page(&thread, &turn_id, request_id, data, None);
        }
        let HistoryEffect::Install(installation) = &install[0] else {
            panic!("install")
        };
        assert_eq!(
            installation
                .turns
                .iter()
                .map(|record| record.turn_id.as_str())
                .collect::<Vec<_>>(),
            ["old", "new"]
        );
        assert_eq!(
            installation
                .items
                .iter()
                .map(|record| record.item_id.as_str())
                .collect::<Vec<_>>(),
            ["o1", "o2", "n1", "n2"]
        );
    }

    #[test]
    fn repeated_turn_cursor_fails_closed() {
        let thread = ThreadId::from("thread");
        let mut coordinator = PaginatedHistoryCoordinator::default();
        let effects = coordinator.begin(thread.clone(), 1, 1).expect("begin");
        let HistoryEffect::RequestResume { request_id, .. } = effects[0] else {
            panic!("resume")
        };
        let effects =
            coordinator.receive_resume_cut(&thread, request_id, Some("cursor".into()), None, None);
        let HistoryEffect::RequestTurns { request_id, .. } = effects[0] else {
            panic!("turns")
        };
        let effects = coordinator.receive_turns_page(
            &thread,
            request_id,
            vec![turn("turn")],
            Some("cursor".into()),
        );
        assert!(matches!(
            &effects[0],
            HistoryEffect::Failed(HistoryFailure {
                reason: HistoryFailureReason::RepeatedCursor { .. },
                ..
            })
        ));
    }

    #[test]
    fn connection_loss_marks_matching_cut_stale() {
        let thread = ThreadId::from("thread");
        let mut coordinator = PaginatedHistoryCoordinator::default();
        let effects = coordinator.begin(thread.clone(), 3, 1).expect("begin");
        let HistoryEffect::RequestResume { request_id, .. } = effects[0] else {
            panic!("resume")
        };
        let install = coordinator.receive_resume_cut(&thread, request_id, None, None, None);
        assert!(matches!(install[0], HistoryEffect::Install(_)));
        let stale = coordinator.connection_lost(3);
        assert!(matches!(stale[0], HistoryEffect::MarkStale { .. }));
        assert!(matches!(
            coordinator.phase(&thread),
            Some(HistoryPhase::Stale(_))
        ));
    }
}
