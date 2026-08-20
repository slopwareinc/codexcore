//! Pure presentation projection for recursive thread and collaboration graphs.

use std::collections::{BTreeMap, BTreeSet, VecDeque};

use codex_app_server_state::{
    CanonicalItem, CanonicalState, CanonicalThread, ItemId, ItemKey, StateCoverage, StateRevision,
    ThreadId, TurnId, TurnKey,
};
use serde_json::{Map, Value};

/// Stable identity for one thread across multiplexed App Server hosts.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct ThreadGraphKey {
    pub host_id: String,
    pub thread_id: ThreadId,
}

impl ThreadGraphKey {
    #[must_use]
    pub fn new(host_id: impl Into<String>, thread_id: ThreadId) -> Self {
        Self {
            host_id: host_id.into(),
            thread_id,
        }
    }
}

/// Inferred relationship of a graph node to the rest of the session.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum ThreadGraphKind {
    TopLevel,
    CollabChild,
    SideChat,
    Fork,
    Worktree,
    Cloud,
    Unknown,
}

/// Exact `CollabAgentStatus` value, including values added by future runtimes.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum CollabAgentLifecycle {
    PendingInit,
    Running,
    Interrupted,
    Completed,
    Errored,
    Shutdown,
    NotFound,
    Unknown(String),
}

impl CollabAgentLifecycle {
    #[must_use]
    pub fn from_raw(value: impl Into<String>) -> Self {
        let value = value.into();
        match value.as_str() {
            "pendingInit" => Self::PendingInit,
            "running" => Self::Running,
            "interrupted" => Self::Interrupted,
            "completed" => Self::Completed,
            "errored" => Self::Errored,
            "shutdown" => Self::Shutdown,
            "notFound" => Self::NotFound,
            _ => Self::Unknown(value),
        }
    }

    /// Return the exact protocol spelling.
    #[must_use]
    pub fn as_raw(&self) -> &str {
        match self {
            Self::PendingInit => "pendingInit",
            Self::Running => "running",
            Self::Interrupted => "interrupted",
            Self::Completed => "completed",
            Self::Errored => "errored",
            Self::Shutdown => "shutdown",
            Self::NotFound => "notFound",
            Self::Unknown(value) => value,
        }
    }

    #[must_use]
    pub const fn is_terminal(&self) -> bool {
        matches!(
            self,
            Self::Interrupted | Self::Completed | Self::Errored | Self::Shutdown | Self::NotFound
        )
    }
}

/// Exact model-internal collaboration tool.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum CollabAction {
    SpawnAgent,
    SendInput,
    ResumeAgent,
    Wait,
    CloseAgent,
    Unknown(String),
}

impl CollabAction {
    #[must_use]
    pub fn from_raw(value: impl Into<String>) -> Self {
        let value = value.into();
        match value.as_str() {
            "spawnAgent" => Self::SpawnAgent,
            "sendInput" => Self::SendInput,
            "resumeAgent" => Self::ResumeAgent,
            "wait" => Self::Wait,
            "closeAgent" => Self::CloseAgent,
            _ => Self::Unknown(value),
        }
    }

    /// Return the exact protocol spelling.
    #[must_use]
    pub fn as_raw(&self) -> &str {
        match self {
            Self::SpawnAgent => "spawnAgent",
            Self::SendInput => "sendInput",
            Self::ResumeAgent => "resumeAgent",
            Self::Wait => "wait",
            Self::CloseAgent => "closeAgent",
            Self::Unknown(value) => value,
        }
    }
}

/// Exact lifecycle of a collaboration tool call.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum CollabActionStatus {
    InProgress,
    Completed,
    Failed,
    Unknown(String),
}

impl CollabActionStatus {
    #[must_use]
    pub fn from_raw(value: impl Into<String>) -> Self {
        let value = value.into();
        match value.as_str() {
            "inProgress" => Self::InProgress,
            "completed" => Self::Completed,
            "failed" => Self::Failed,
            _ => Self::Unknown(value),
        }
    }

    /// Return the exact protocol spelling.
    #[must_use]
    pub fn as_raw(&self) -> &str {
        match self {
            Self::InProgress => "inProgress",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Unknown(value) => value,
        }
    }

    #[must_use]
    pub const fn is_terminal(&self) -> bool {
        matches!(self, Self::Completed | Self::Failed)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CollabAgentState {
    pub lifecycle: CollabAgentLifecycle,
    pub message: Option<String>,
}

/// One collaboration action keyed by its stable canonical item identity.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ThreadGraphAction {
    pub source_item: ItemKey,
    pub action: CollabAction,
    pub status: CollabActionStatus,
    pub sender: ThreadGraphKey,
    /// Exact receiver order from the protocol item. Duplicate IDs are retained.
    pub receivers: Vec<ThreadGraphKey>,
    pub prompt: Option<String>,
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub agent_states: BTreeMap<ThreadGraphKey, CollabAgentState>,
}

#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum ThreadGraphEdgeSource {
    Collaboration(ItemKey),
    ThreadMetadata,
    ForkMetadata,
}

#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct ThreadGraphEdge {
    pub parent: ThreadGraphKey,
    pub child: ThreadGraphKey,
    pub source: ThreadGraphEdgeSource,
}

/// One UI-independent node enriched from thread metadata and collaboration items.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ThreadGraphNode {
    pub key: ThreadGraphKey,
    pub parent: Option<ThreadGraphKey>,
    pub children: Vec<ThreadGraphKey>,
    pub depth: Option<usize>,
    pub kind: ThreadGraphKind,
    pub prompt: Option<String>,
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub lifecycle: Option<CollabAgentLifecycle>,
    pub result_message: Option<String>,
    pub error_message: Option<String>,
    pub source_turn_id: Option<TurnId>,
    pub source_item_id: Option<ItemId>,
    pub agent_nickname: Option<String>,
    pub agent_role: Option<String>,
    /// Logical collaboration path. This is never the persisted rollout path.
    pub agent_path: Option<String>,
    pub cwd: Option<Value>,
    pub ephemeral: Option<bool>,
    pub archived: Option<bool>,
    pub created_at: Option<i64>,
    pub updated_at: Option<i64>,
    pub is_loaded: bool,
}

impl ThreadGraphNode {
    fn partial(key: ThreadGraphKey) -> Self {
        Self {
            key,
            parent: None,
            children: Vec::new(),
            depth: None,
            kind: ThreadGraphKind::Unknown,
            prompt: None,
            model: None,
            reasoning_effort: None,
            lifecycle: None,
            result_message: None,
            error_message: None,
            source_turn_id: None,
            source_item_id: None,
            agent_nickname: None,
            agent_role: None,
            agent_path: None,
            cwd: None,
            ephemeral: None,
            archived: None,
            created_at: None,
            updated_at: None,
            is_loaded: false,
        }
    }
}

/// Immutable graph presentation at one canonical state revision.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ThreadGraphSnapshot {
    pub revision: StateRevision,
    pub nodes: BTreeMap<ThreadGraphKey, ThreadGraphNode>,
    pub edges: Vec<ThreadGraphEdge>,
    pub actions: Vec<ThreadGraphAction>,
    pub roots: Vec<ThreadGraphKey>,
    pub cycle_edges: Vec<ThreadGraphEdge>,
}

impl ThreadGraphSnapshot {
    #[must_use]
    pub fn node(&self, host_id: &str, thread_id: &ThreadId) -> Option<&ThreadGraphNode> {
        self.nodes
            .get(&ThreadGraphKey::new(host_id, thread_id.clone()))
    }

    /// Return every reachable descendant once in breadth-first order.
    #[must_use]
    pub fn descendants(&self, root: &ThreadGraphKey) -> Vec<ThreadGraphKey> {
        let mut seen = BTreeSet::from([root.clone()]);
        let mut queue = self.nodes.get(root).map_or_else(VecDeque::new, |node| {
            node.children.iter().cloned().collect()
        });
        let mut result = Vec::new();
        while let Some(next) = queue.pop_front() {
            if !seen.insert(next.clone()) {
                continue;
            }
            result.push(next.clone());
            if let Some(node) = self.nodes.get(&next) {
                queue.extend(node.children.iter().cloned());
            }
        }
        result
    }
}

/// Pure canonical-state to collaboration-graph projection.
pub struct ThreadGraphProjector;

impl ThreadGraphProjector {
    #[must_use]
    pub fn project(state: &CanonicalState, host_id: &str) -> ThreadGraphSnapshot {
        let ordered_thread_ids = canonical_thread_order(state);
        let ordered_items = canonical_item_order(state, &ordered_thread_ids);
        let mut context = ProjectionContext::new(host_id);
        context.project_threads(state, &ordered_thread_ids);
        context.project_collaboration_items(&ordered_items);
        context.project_activity_items(&ordered_items);
        context.finish(state.revision, &ordered_thread_ids)
    }
}

struct ProjectionContext<'a> {
    host_id: &'a str,
    nodes: BTreeMap<ThreadGraphKey, ThreadGraphNode>,
    edges: Vec<ThreadGraphEdge>,
    edge_set: BTreeSet<ThreadGraphEdge>,
    actions: Vec<ThreadGraphAction>,
}

impl<'a> ProjectionContext<'a> {
    fn new(host_id: &'a str) -> Self {
        Self {
            host_id,
            nodes: BTreeMap::new(),
            edges: Vec::new(),
            edge_set: BTreeSet::new(),
            actions: Vec::new(),
        }
    }

    fn key(&self, thread_id: &ThreadId) -> ThreadGraphKey {
        ThreadGraphKey::new(self.host_id, thread_id.clone())
    }

    fn ensure_node(&mut self, graph_key: ThreadGraphKey) {
        self.nodes
            .entry(graph_key.clone())
            .or_insert_with(|| ThreadGraphNode::partial(graph_key));
    }

    fn append_edge(&mut self, edge: ThreadGraphEdge) {
        if self.edge_set.insert(edge.clone()) {
            self.edges.push(edge);
        }
    }

    fn project_threads(&mut self, state: &CanonicalState, thread_ids: &[ThreadId]) {
        for thread_id in thread_ids {
            if let Some(thread) = state.threads.get(thread_id) {
                self.project_thread(thread);
            }
        }
    }

    fn project_thread(&mut self, thread: &CanonicalThread) {
        let graph_key = self.key(&thread.id);
        self.ensure_node(graph_key.clone());
        let parent_id = parent_thread_id(thread);
        let fork_id = metadata_string(thread, "forkedFromId").map(ThreadId::new);
        let source = collaboration_source(thread);
        if let Some(node) = self.nodes.get_mut(&graph_key) {
            node.agent_nickname = metadata_string(thread, "agentNickname")
                .or_else(|| {
                    source.and_then(|value| {
                        object_string(value, &["agent_nickname", "agentNickname"])
                    })
                })
                .map(str::to_owned);
            node.agent_role = metadata_string(thread, "agentRole")
                .or_else(|| {
                    source.and_then(|value| object_string(value, &["agent_role", "agentRole"]))
                })
                .map(str::to_owned);
            node.agent_path = source
                .and_then(|value| object_string(value, &["agent_path", "agentPath"]))
                .map(str::to_owned);
            node.cwd = thread.metadata.get("cwd").cloned();
            node.ephemeral = metadata_bool(thread, "ephemeral");
            node.archived = metadata_bool(thread, "archived");
            node.created_at = metadata_i64(thread, "createdAt");
            node.updated_at = metadata_i64(thread, "updatedAt");
            node.is_loaded = thread.coverage == StateCoverage::Full;
            node.kind = inferred_kind(thread, parent_id.as_ref(), fork_id.as_ref());
        }
        if let Some(parent_id) = parent_id {
            self.append_metadata_edge(
                &graph_key,
                &parent_id,
                ThreadGraphEdgeSource::ThreadMetadata,
            );
        }
        if let Some(fork_id) = fork_id {
            self.append_metadata_edge(&graph_key, &fork_id, ThreadGraphEdgeSource::ForkMetadata);
        }
    }

    fn append_metadata_edge(
        &mut self,
        child: &ThreadGraphKey,
        parent_id: &ThreadId,
        source: ThreadGraphEdgeSource,
    ) {
        let parent = self.key(parent_id);
        self.ensure_node(parent.clone());
        self.append_edge(ThreadGraphEdge {
            parent,
            child: child.clone(),
            source,
        });
    }

    fn project_collaboration_items(&mut self, items: &[&CanonicalItem]) {
        for item in items
            .iter()
            .copied()
            .filter(|item| item.kind == "collabAgentToolCall")
        {
            self.project_collaboration_item(item);
        }
    }

    fn project_collaboration_item(&mut self, item: &CanonicalItem) {
        let sender_id = item
            .payload
            .get("senderThreadId")
            .and_then(Value::as_str)
            .map_or_else(|| item.key.thread_id.clone(), ThreadId::new);
        let receiver_ids = collaboration_receivers(item);
        let sender = self.key(&sender_id);
        self.ensure_node(sender.clone());
        let receivers = receiver_ids
            .iter()
            .map(|thread_id| self.key(thread_id))
            .collect::<Vec<_>>();
        for receiver in &receivers {
            self.ensure_node(receiver.clone());
        }
        let graph_action = ThreadGraphAction {
            source_item: item.key.clone(),
            action: CollabAction::from_raw(
                item.payload
                    .get("tool")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown"),
            ),
            status: CollabActionStatus::from_raw(
                item.payload
                    .get("status")
                    .and_then(Value::as_str)
                    .unwrap_or_else(|| item.status.as_raw()),
            ),
            sender,
            receivers,
            prompt: payload_string(item, "prompt"),
            model: payload_string(item, "model"),
            reasoning_effort: payload_string(item, "reasoningEffort"),
            agent_states: self.project_agent_states(item),
        };
        self.apply_collaboration_action(&graph_action);
        self.actions.push(graph_action);
    }

    fn project_agent_states(
        &mut self,
        item: &CanonicalItem,
    ) -> BTreeMap<ThreadGraphKey, CollabAgentState> {
        let mut result = BTreeMap::new();
        let Some(states) = item.payload.get("agentsStates").and_then(Value::as_object) else {
            return result;
        };
        for (raw_id, raw_state) in states {
            let Some(object) = raw_state.as_object() else {
                continue;
            };
            let Some(raw_lifecycle) = object.get("status").and_then(Value::as_str) else {
                continue;
            };
            let agent_key = self.key(&ThreadId::new(raw_id));
            self.ensure_node(agent_key.clone());
            result.insert(
                agent_key,
                CollabAgentState {
                    lifecycle: CollabAgentLifecycle::from_raw(raw_lifecycle),
                    message: object
                        .get("message")
                        .and_then(Value::as_str)
                        .map(str::to_owned),
                },
            );
        }
        result
    }

    fn apply_collaboration_action(&mut self, action: &ThreadGraphAction) {
        for receiver in &action.receivers {
            self.append_edge(ThreadGraphEdge {
                parent: action.sender.clone(),
                child: receiver.clone(),
                source: ThreadGraphEdgeSource::Collaboration(action.source_item.clone()),
            });
            if let Some(node) = self.nodes.get_mut(receiver) {
                node.kind = ThreadGraphKind::CollabChild;
                node.prompt = action.prompt.clone().or_else(|| node.prompt.clone());
                node.model = action.model.clone().or_else(|| node.model.clone());
                node.reasoning_effort = action
                    .reasoning_effort
                    .clone()
                    .or_else(|| node.reasoning_effort.clone());
                node.source_turn_id = Some(action.source_item.turn_id.clone());
                node.source_item_id = Some(action.source_item.item_id.clone());
                project_agent_lifecycle(node, action.agent_states.get(receiver));
                if !action.agent_states.contains_key(receiver)
                    && action.action == CollabAction::CloseAgent
                    && action.status == CollabActionStatus::Completed
                {
                    node.lifecycle = Some(CollabAgentLifecycle::Shutdown);
                }
            }
        }
    }

    fn project_activity_items(&mut self, items: &[&CanonicalItem]) {
        // An activity may announce a child before either its spawn item or
        // thread metadata has hydrated. Preserve that partial relationship.
        for item in items
            .iter()
            .copied()
            .filter(|item| item.kind == "subAgentActivity")
        {
            self.project_activity_item(item);
        }
    }

    fn project_activity_item(&mut self, item: &CanonicalItem) {
        let Some(raw_child_id) = item.payload.get("agentThreadId").and_then(Value::as_str) else {
            return;
        };
        let parent = self.key(&item.key.thread_id);
        let child = self.key(&ThreadId::new(raw_child_id));
        self.ensure_node(parent.clone());
        self.ensure_node(child.clone());
        self.append_edge(ThreadGraphEdge {
            parent,
            child: child.clone(),
            source: ThreadGraphEdgeSource::Collaboration(item.key.clone()),
        });
        if let Some(node) = self.nodes.get_mut(&child) {
            node.kind = ThreadGraphKind::CollabChild;
            node.source_turn_id
                .get_or_insert_with(|| item.key.turn_id.clone());
            node.source_item_id
                .get_or_insert_with(|| item.key.item_id.clone());
            if let Some(agent_path) = item.payload.get("agentPath").and_then(Value::as_str) {
                node.agent_path = Some(agent_path.to_owned());
            }
            match item.payload.get("kind").and_then(Value::as_str) {
                Some("started" | "interacted") if node.lifecycle.is_none() => {
                    node.lifecycle = Some(CollabAgentLifecycle::Running);
                }
                Some("interrupted") => {
                    node.lifecycle = Some(CollabAgentLifecycle::Interrupted);
                }
                _ => {}
            }
        }
    }

    fn finish(
        mut self,
        revision: StateRevision,
        ordered_thread_ids: &[ThreadId],
    ) -> ThreadGraphSnapshot {
        order_edges(&mut self.edges, ordered_thread_ids);
        let reconciled = reconcile_edges(&self.edges);
        for (graph_key, node) in &mut self.nodes {
            node.parent = reconciled.primary_parent.get(graph_key).cloned();
            node.children = reconciled
                .children_by_parent
                .get(graph_key)
                .cloned()
                .unwrap_or_default();
        }
        let roots = ordered_roots(&self.nodes, &reconciled.primary_parent, ordered_thread_ids);
        assign_depths(&mut self.nodes, &roots, &reconciled.primary_parent);
        ThreadGraphSnapshot {
            revision,
            nodes: self.nodes,
            edges: self.edges,
            actions: self.actions,
            roots,
            cycle_edges: reconciled.cycle_edges,
        }
    }
}

fn collaboration_receivers(item: &CanonicalItem) -> Vec<ThreadId> {
    item.payload
        .get("receiverThreadIds")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(ThreadId::new)
        .collect()
}

fn project_agent_lifecycle(node: &mut ThreadGraphNode, state: Option<&CollabAgentState>) {
    let Some(state) = state else {
        return;
    };
    node.lifecycle = Some(state.lifecycle.clone());
    if matches!(
        state.lifecycle,
        CollabAgentLifecycle::Errored | CollabAgentLifecycle::NotFound
    ) {
        node.error_message.clone_from(&state.message);
    } else if state.lifecycle.is_terminal() {
        node.result_message.clone_from(&state.message);
    }
}

fn canonical_thread_order(state: &CanonicalState) -> Vec<ThreadId> {
    let mut seen = BTreeSet::new();
    state
        .thread_order
        .iter()
        .chain(state.threads.keys())
        .filter(|thread_id| seen.insert((*thread_id).clone()))
        .cloned()
        .collect()
}

fn canonical_item_order<'a>(
    state: &'a CanonicalState,
    thread_ids: &[ThreadId],
) -> Vec<&'a CanonicalItem> {
    let mut seen = BTreeSet::new();
    let mut result = Vec::new();
    for thread_id in thread_ids {
        let Some(thread) = state.threads.get(thread_id) else {
            continue;
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
                let item_key = ItemKey {
                    thread_id: thread_id.clone(),
                    turn_id: turn_id.clone(),
                    item_id: item_id.clone(),
                };
                if seen.insert(item_key.clone())
                    && let Some(item) = state.items.get(&item_key)
                {
                    result.push(item);
                }
            }
        }
    }
    for (item_key, item) in &state.items {
        if seen.insert(item_key.clone()) {
            result.push(item);
        }
    }
    result
}

fn payload_string(item: &CanonicalItem, field: &str) -> Option<String> {
    item.payload
        .get(field)
        .and_then(Value::as_str)
        .map(str::to_owned)
}

fn metadata_string<'a>(thread: &'a CanonicalThread, field: &str) -> Option<&'a str> {
    thread.metadata.get(field).and_then(Value::as_str)
}

fn metadata_bool(thread: &CanonicalThread, field: &str) -> Option<bool> {
    thread.metadata.get(field).and_then(Value::as_bool)
}

fn metadata_i64(thread: &CanonicalThread, field: &str) -> Option<i64> {
    thread.metadata.get(field).and_then(Value::as_i64)
}

fn collaboration_source(thread: &CanonicalThread) -> Option<&Map<String, Value>> {
    let source = thread.metadata.get("source")?.as_object()?;
    let subagent = source
        .get("subagent")
        .or_else(|| source.get("subAgent"))?
        .as_object()?;
    subagent
        .get("thread_spawn")
        .or_else(|| subagent.get("threadSpawn"))?
        .as_object()
}

fn object_string<'a>(object: &'a Map<String, Value>, fields: &[&str]) -> Option<&'a str> {
    fields
        .iter()
        .find_map(|field| object.get(*field).and_then(Value::as_str))
}

fn parent_thread_id(thread: &CanonicalThread) -> Option<ThreadId> {
    metadata_string(thread, "parentThreadId")
        .or_else(|| {
            collaboration_source(thread)
                .and_then(|value| object_string(value, &["parent_thread_id", "parentThreadId"]))
        })
        .map(ThreadId::new)
}

fn inferred_kind(
    thread: &CanonicalThread,
    parent_id: Option<&ThreadId>,
    fork_id: Option<&ThreadId>,
) -> ThreadGraphKind {
    if metadata_bool(thread, "ephemeral") == Some(true) && fork_id.is_some() {
        return ThreadGraphKind::SideChat;
    }
    if parent_id.is_some() {
        return ThreadGraphKind::CollabChild;
    }
    if fork_id.is_some() {
        return ThreadGraphKind::Fork;
    }
    let source = thread
        .metadata
        .get("threadSource")
        .or_else(|| thread.metadata.get("source"));
    if source.is_some_and(|value| value_mentions(value, "cloud")) {
        return ThreadGraphKind::Cloud;
    }
    if source.is_some_and(|value| value_mentions(value, "worktree")) {
        return ThreadGraphKind::Worktree;
    }
    if source.is_some_and(|value| {
        value_mentions(value, "subagent") || value_mentions(value, "sub_agent")
    }) {
        return ThreadGraphKind::CollabChild;
    }
    ThreadGraphKind::TopLevel
}

fn value_mentions(value: &Value, needle: &str) -> bool {
    match value {
        Value::String(value) => value.to_lowercase().contains(needle),
        Value::Array(values) => values.iter().any(|value| value_mentions(value, needle)),
        Value::Object(object) => object.iter().any(|(key, value)| {
            key.to_lowercase().contains(needle) || value_mentions(value, needle)
        }),
        Value::Null | Value::Bool(_) | Value::Number(_) => false,
    }
}

fn order_edges(edges: &mut [ThreadGraphEdge], thread_ids: &[ThreadId]) {
    let order = thread_ids
        .iter()
        .enumerate()
        .map(|(index, thread_id)| (thread_id.clone(), index))
        .collect::<BTreeMap<_, _>>();
    edges.sort_by_key(|edge| {
        (
            order
                .get(&edge.parent.thread_id)
                .copied()
                .unwrap_or(usize::MAX),
            order
                .get(&edge.child.thread_id)
                .copied()
                .unwrap_or(usize::MAX),
            edge.child.clone(),
        )
    });
}

struct ReconciledEdges {
    primary_parent: BTreeMap<ThreadGraphKey, ThreadGraphKey>,
    children_by_parent: BTreeMap<ThreadGraphKey, Vec<ThreadGraphKey>>,
    cycle_edges: Vec<ThreadGraphEdge>,
}

fn reconcile_edges(edges: &[ThreadGraphEdge]) -> ReconciledEdges {
    let mut primary_parent = BTreeMap::new();
    let mut children_by_parent: BTreeMap<ThreadGraphKey, Vec<ThreadGraphKey>> = BTreeMap::new();
    let mut cycle_edges = Vec::new();
    for edge in edges {
        if edge.parent == edge.child || path_exists(&edge.child, &edge.parent, &children_by_parent)
        {
            cycle_edges.push(edge.clone());
            continue;
        }
        primary_parent
            .entry(edge.child.clone())
            .or_insert_with(|| edge.parent.clone());
        let children = children_by_parent.entry(edge.parent.clone()).or_default();
        if !children.contains(&edge.child) {
            children.push(edge.child.clone());
        }
    }
    ReconciledEdges {
        primary_parent,
        children_by_parent,
        cycle_edges,
    }
}

fn path_exists(
    start: &ThreadGraphKey,
    target: &ThreadGraphKey,
    children_by_parent: &BTreeMap<ThreadGraphKey, Vec<ThreadGraphKey>>,
) -> bool {
    let mut seen = BTreeSet::new();
    let mut queue = VecDeque::from([start.clone()]);
    while let Some(next) = queue.pop_front() {
        if &next == target {
            return true;
        }
        if !seen.insert(next.clone()) {
            continue;
        }
        if let Some(children) = children_by_parent.get(&next) {
            queue.extend(children.iter().cloned());
        }
    }
    false
}

fn ordered_roots(
    nodes: &BTreeMap<ThreadGraphKey, ThreadGraphNode>,
    primary_parent: &BTreeMap<ThreadGraphKey, ThreadGraphKey>,
    thread_ids: &[ThreadId],
) -> Vec<ThreadGraphKey> {
    let order = thread_ids
        .iter()
        .enumerate()
        .map(|(index, thread_id)| (thread_id.clone(), index))
        .collect::<BTreeMap<_, _>>();
    let mut roots = nodes
        .keys()
        .filter(|graph_key| !primary_parent.contains_key(*graph_key))
        .cloned()
        .collect::<Vec<_>>();
    roots.sort_by_key(|graph_key| {
        (
            order
                .get(&graph_key.thread_id)
                .copied()
                .unwrap_or(usize::MAX),
            graph_key.clone(),
        )
    });
    roots
}

fn assign_depths(
    nodes: &mut BTreeMap<ThreadGraphKey, ThreadGraphNode>,
    roots: &[ThreadGraphKey],
    primary_parent: &BTreeMap<ThreadGraphKey, ThreadGraphKey>,
) {
    let mut primary_children: BTreeMap<ThreadGraphKey, Vec<ThreadGraphKey>> = BTreeMap::new();
    for (child, parent) in primary_parent {
        primary_children
            .entry(parent.clone())
            .or_default()
            .push(child.clone());
    }
    let mut queue = roots
        .iter()
        .cloned()
        .map(|root| (root, 0))
        .collect::<VecDeque<_>>();
    let mut seen = BTreeSet::new();
    while let Some((next, depth)) = queue.pop_front() {
        if !seen.insert(next.clone()) {
            continue;
        }
        if let Some(node) = nodes.get_mut(&next) {
            node.depth = Some(depth);
        }
        if let Some(children) = primary_children.get(&next) {
            queue.extend(children.iter().cloned().map(|child| (child, depth + 1)));
        }
    }
}
