use std::sync::Arc;

use codex_presentation::{
    CollabAgentLifecycle, ThreadGraphKey, ThreadGraphNode, ThreadGraphSnapshot,
};
use gpui::{
    AnyElement, Context, EventEmitter, Render, Rgba, Role, Window, div, prelude::*, px,
    uniform_list,
};

use crate::CodexTheme;

/// Stable child-thread selection routed to the host that owns thread leases.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SubagentSelectionEvent {
    pub key: ThreadGraphKey,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct SubagentRow {
    key: ThreadGraphKey,
    name: String,
    path: Option<String>,
    lifecycle: Option<CollabAgentLifecycle>,
    lifecycle_label: String,
    depth: usize,
    position_in_set: usize,
    set_size: usize,
    is_loaded: bool,
}

/// Controlled, recursively flattened navigation for one thread's child agents.
///
/// The host supplies disposable graph snapshots and retains all authority over
/// resume, hydration, lease transfer, and task switching. Clicking a row only
/// emits [`SubagentSelectionEvent`].
pub struct CodexSubagentNavigator {
    revision: codex_app_server_state::StateRevision,
    root: ThreadGraphKey,
    rows: Arc<[SubagentRow]>,
    theme: CodexTheme,
}

impl CodexSubagentNavigator {
    #[must_use]
    pub fn new(root: ThreadGraphKey, snapshot: &ThreadGraphSnapshot) -> Self {
        Self {
            revision: snapshot.revision,
            rows: subagent_rows(snapshot, &root).into(),
            root,
            theme: CodexTheme::default(),
        }
    }

    #[must_use]
    pub const fn with_theme(mut self, theme: CodexTheme) -> Self {
        self.theme = theme;
        self
    }

    /// Replace the controlled root and its disposable graph projection.
    pub fn set_snapshot(
        &mut self,
        root: ThreadGraphKey,
        snapshot: &ThreadGraphSnapshot,
        cx: &mut Context<Self>,
    ) {
        if self.replace_snapshot(root, snapshot) {
            cx.notify();
        }
    }

    fn replace_snapshot(&mut self, root: ThreadGraphKey, snapshot: &ThreadGraphSnapshot) -> bool {
        if root == self.root && snapshot.revision < self.revision {
            return false;
        }
        let next_rows: Arc<[SubagentRow]> = subagent_rows(snapshot, &root).into();
        let changed = root != self.root || next_rows.as_ref() != self.rows.as_ref();
        self.revision = snapshot.revision;
        if changed {
            self.rows = next_rows;
            self.root = root;
        }
        changed
    }

    fn select(&mut self, key: ThreadGraphKey, cx: &mut Context<Self>) {
        if self.rows.iter().any(|row| row.key == key) {
            cx.emit(SubagentSelectionEvent { key });
        }
    }
}

impl EventEmitter<SubagentSelectionEvent> for CodexSubagentNavigator {}

impl Render for CodexSubagentNavigator {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let count = self.rows.len();
        div()
            .id("codex-subagent-navigation")
            .role(Role::Navigation)
            .aria_label(format!("Child agents: {count}"))
            .size_full()
            .flex()
            .flex_col()
            .overflow_hidden()
            .bg(self.theme.surface)
            .child(
                div()
                    .flex_shrink_0()
                    .px_3()
                    .py_2()
                    .border_b_1()
                    .border_color(self.theme.border)
                    .flex()
                    .items_center()
                    .justify_between()
                    .child(
                        div()
                            .text_sm()
                            .text_color(self.theme.text)
                            .child("Subagents"),
                    )
                    .child(
                        div()
                            .text_xs()
                            .text_color(self.theme.muted_text)
                            .child(count.to_string()),
                    ),
            )
            .when(count == 0, |view| {
                view.child(
                    div()
                        .id("codex-subagent-empty")
                        .role(Role::Status)
                        .aria_label("No child agents")
                        .p_3()
                        .text_xs()
                        .text_color(self.theme.muted_text)
                        .child("No child agents"),
                )
            })
            .when(count > 0, |view| {
                view.child(
                    div()
                        .id("codex-subagent-tree")
                        .role(Role::Tree)
                        .aria_label("Recursive child agents")
                        .flex_1()
                        .min_h_0()
                        .overflow_hidden()
                        .child(
                            uniform_list(
                                "codex-subagent-list",
                                count,
                                cx.processor(|this, range: std::ops::Range<usize>, _window, cx| {
                                    range
                                        .filter_map(|index| {
                                            let row = this.rows.get(index)?.clone();
                                            let key = row.key.clone();
                                            Some(
                                                render_row(&row, this.theme)
                                                    .on_click(cx.listener(move |this, _, _, cx| {
                                                        this.select(key.clone(), cx);
                                                    }))
                                                    .into_any(),
                                            )
                                        })
                                        .collect::<Vec<AnyElement>>()
                                }),
                            )
                            .size_full(),
                        ),
                )
            })
    }
}

fn subagent_rows(snapshot: &ThreadGraphSnapshot, root: &ThreadGraphKey) -> Vec<SubagentRow> {
    let root_depth = snapshot.nodes.get(root).and_then(|node| node.depth);
    snapshot
        .descendants(root)
        .into_iter()
        .filter_map(|key| {
            let node = snapshot.nodes.get(&key)?;
            let depth = node.depth.zip(root_depth).map_or(0, |(depth, root_depth)| {
                depth.saturating_sub(root_depth.saturating_add(1))
            });
            let (position_in_set, set_size) = sibling_position(snapshot, node);
            Some(SubagentRow {
                key,
                name: display_name(node),
                path: node.agent_path.clone(),
                lifecycle: node.lifecycle.clone(),
                lifecycle_label: lifecycle_label(node),
                depth,
                position_in_set,
                set_size,
                is_loaded: node.is_loaded,
            })
        })
        .collect()
}

fn sibling_position(snapshot: &ThreadGraphSnapshot, node: &ThreadGraphNode) -> (usize, usize) {
    let siblings = node
        .parent
        .as_ref()
        .and_then(|parent| snapshot.nodes.get(parent))
        .map(|parent| parent.children.as_slice())
        .unwrap_or_default();
    let position = siblings
        .iter()
        .position(|key| key == &node.key)
        .map_or(1, |position| position.saturating_add(1));
    (position, siblings.len().max(1))
}

fn display_name(node: &ThreadGraphNode) -> String {
    node.agent_nickname
        .clone()
        .or_else(|| {
            node.agent_path
                .as_deref()
                .and_then(|path| path.rsplit('/').find(|component| !component.is_empty()))
                .map(str::to_owned)
        })
        .unwrap_or_else(|| node.key.thread_id.as_str().to_owned())
}

fn lifecycle_label(node: &ThreadGraphNode) -> String {
    match &node.lifecycle {
        Some(CollabAgentLifecycle::PendingInit) => "Starting".to_owned(),
        Some(CollabAgentLifecycle::Running) => "Running".to_owned(),
        Some(CollabAgentLifecycle::Interrupted) => "Interrupted".to_owned(),
        Some(CollabAgentLifecycle::Completed) => "Completed".to_owned(),
        Some(CollabAgentLifecycle::Errored) => "Failed".to_owned(),
        Some(CollabAgentLifecycle::Shutdown) => "Shutdown".to_owned(),
        Some(CollabAgentLifecycle::NotFound) => "Not found".to_owned(),
        Some(CollabAgentLifecycle::Unknown(value)) => format!("Unknown: {value}"),
        None if node.is_loaded => "Loaded".to_owned(),
        None => "Discovered".to_owned(),
    }
}

fn lifecycle_color(lifecycle: Option<&CollabAgentLifecycle>, theme: CodexTheme) -> Rgba {
    match lifecycle {
        Some(CollabAgentLifecycle::Running) => theme.accent,
        Some(CollabAgentLifecycle::PendingInit) => theme.warning,
        Some(CollabAgentLifecycle::Completed) => theme.success,
        Some(CollabAgentLifecycle::Errored | CollabAgentLifecycle::NotFound) => theme.danger,
        Some(
            CollabAgentLifecycle::Interrupted
            | CollabAgentLifecycle::Shutdown
            | CollabAgentLifecycle::Unknown(_),
        )
        | None => theme.muted_text,
    }
}

fn render_row(row: &SubagentRow, theme: CodexTheme) -> gpui::Stateful<gpui::Div> {
    let path = row.path.as_deref().unwrap_or("Path unavailable");
    let load_status = if row.is_loaded {
        "loaded"
    } else {
        "not loaded"
    };
    let color = lifecycle_color(row.lifecycle.as_ref(), theme);
    div()
        .id(format!(
            "subagent:{}:{}",
            row.key.host_id, row.key.thread_id
        ))
        .focusable()
        .tab_stop(true)
        .role(Role::TreeItem)
        .aria_label(format!(
            "{}. {}. Path: {path}. {load_status}.",
            row.name, row.lifecycle_label
        ))
        .aria_level(row.depth.saturating_add(1))
        .aria_position_in_set(row.position_in_set)
        .aria_size_of_set(row.set_size)
        .h(px(68.))
        .w_full()
        .pl(depth_padding(row.depth))
        .pr_3()
        .py_2()
        .flex()
        .flex_col()
        .justify_center()
        .border_b_1()
        .border_color(theme.border)
        .hover(move |style| style.bg(theme.elevated_surface))
        .cursor_pointer()
        .child(
            div()
                .flex()
                .items_center()
                .gap_2()
                .child(div().size(px(7.)).rounded_full().bg(color).flex_shrink_0())
                .child(
                    div()
                        .min_w_0()
                        .flex_1()
                        .text_sm()
                        .text_color(theme.text)
                        .truncate()
                        .child(row.name.clone()),
                )
                .child(
                    div()
                        .flex_shrink_0()
                        .text_xs()
                        .text_color(color)
                        .child(row.lifecycle_label.clone()),
                ),
        )
        .child(
            div()
                .mt_1()
                .text_xs()
                .text_color(theme.muted_text)
                .truncate()
                .child(path.to_owned()),
        )
}

fn depth_padding(depth: usize) -> gpui::Pixels {
    match depth.min(6) {
        0 => px(12.),
        1 => px(28.),
        2 => px(44.),
        3 => px(60.),
        4 => px(76.),
        5 => px(92.),
        _ => px(108.),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use codex_app_server_state::{StateRevision, ThreadId};
    use codex_presentation::{ThreadGraphKind, ThreadGraphNode};

    use super::*;

    #[test]
    fn rows_include_recursive_children_with_relative_depth() {
        let root = key("root");
        let child = key("child");
        let grandchild = key("grandchild");
        let snapshot = snapshot(vec![
            node(root.clone(), None, vec![child.clone()], 0, None),
            node(
                child.clone(),
                Some(root.clone()),
                vec![grandchild.clone()],
                1,
                Some("Galileo"),
            ),
            node(grandchild.clone(), Some(child), Vec::new(), 2, None),
        ]);

        let rows = subagent_rows(&snapshot, &root);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].name, "Galileo");
        assert_eq!(rows[0].depth, 0);
        assert_eq!(rows[1].name, "grandchild");
        assert_eq!(rows[1].depth, 1);
    }

    #[test]
    fn path_and_future_lifecycle_remain_visible() {
        let mut child = node(key("child"), Some(key("root")), Vec::new(), 1, None);
        child.agent_path = Some("/root/extra_subagent_4".to_owned());
        child.lifecycle = Some(CollabAgentLifecycle::Unknown("futureState".to_owned()));
        let snapshot = snapshot(vec![
            node(key("root"), None, vec![key("child")], 0, None),
            child,
        ]);

        let rows = subagent_rows(&snapshot, &key("root"));
        assert_eq!(rows[0].name, "extra_subagent_4");
        assert_eq!(rows[0].path.as_deref(), Some("/root/extra_subagent_4"));
        assert_eq!(rows[0].lifecycle_label, "Unknown: futureState");
    }

    #[test]
    fn selection_event_preserves_host_qualified_child_identity() {
        let event = SubagentSelectionEvent {
            key: ThreadGraphKey::new("remote", ThreadId::from("child")),
        };
        assert_eq!(event.key.host_id, "remote");
        assert_eq!(event.key.thread_id.as_str(), "child");
    }

    #[test]
    fn unchanged_rows_advance_revision_without_requesting_a_render() {
        let root = key("root");
        let first = snapshot(vec![node(root.clone(), None, Vec::new(), 0, None)]);
        let mut navigator = CodexSubagentNavigator::new(root.clone(), &first);
        let mut token_delta = first;
        token_delta.revision = StateRevision::new(8);

        assert!(!navigator.replace_snapshot(root, &token_delta));
        assert_eq!(navigator.revision, StateRevision::new(8));
    }

    fn key(thread_id: &str) -> ThreadGraphKey {
        ThreadGraphKey::new("local", ThreadId::from(thread_id))
    }

    fn snapshot(nodes: Vec<ThreadGraphNode>) -> ThreadGraphSnapshot {
        ThreadGraphSnapshot {
            revision: StateRevision::new(7),
            nodes: nodes
                .into_iter()
                .map(|node| (node.key.clone(), node))
                .collect::<BTreeMap<_, _>>(),
            edges: Vec::new(),
            actions: Vec::new(),
            roots: vec![key("root")],
            cycle_edges: Vec::new(),
        }
    }

    fn node(
        key: ThreadGraphKey,
        parent: Option<ThreadGraphKey>,
        children: Vec<ThreadGraphKey>,
        depth: usize,
        nickname: Option<&str>,
    ) -> ThreadGraphNode {
        ThreadGraphNode {
            key,
            parent,
            children,
            depth: Some(depth),
            kind: ThreadGraphKind::CollabChild,
            prompt: None,
            model: None,
            reasoning_effort: None,
            lifecycle: Some(CollabAgentLifecycle::Running),
            result_message: None,
            error_message: None,
            source_turn_id: None,
            source_item_id: None,
            agent_nickname: nickname.map(str::to_owned),
            agent_role: None,
            agent_path: None,
            cwd: None,
            ephemeral: None,
            archived: None,
            created_at: None,
            updated_at: None,
            is_loaded: true,
        }
    }
}
