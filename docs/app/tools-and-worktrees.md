# Tools, diff previews, and worktrees

## Workspace tools

The app can present:

- syntax-highlighted file previews;
- command output and interactive terminal sessions;
- a manual embedded WKWebView browser (not agent browser-tool integration);
- turn diff previews and file-change summaries;
- environment and workspace context;
- subagent activity and side chat.

These surfaces visualize app-server or host state. They do not expand filesystem or network authority by themselves.

### Files

Open **Files** to browse the active workspace and preview text files without leaving the task.

![Workspace file browser showing the README preview](../assets/screenshots/files-preview.png)

### Terminal

Open **Terminal** for a real interactive shell rooted in the workspace. Terminal tabs live in the shared right/bottom workspace topology: moving or hiding a tab preserves its PTY, while hidden terminals suspend their display link. Server-owned background processes are shown from canonical thread facts in the overview; selecting one opens a metadata/detail tab with its command, working directory, process and item IDs, and the supported **Terminate** action. The protocol has no stream-attachment endpoint, so background facts never fabricate a second Ghostty shell. Interactive Terminal identity is scoped to the chat thread and checkout. Terminal commands use the permissions of the host process; opening the panel does not grant an agent permission to run them.

![Interactive workspace terminal beside a completed task](../assets/screenshots/workspace-terminal.png)

### Browser

Open **Browser** for manually navigated documentation and local previews. It is an embedded WKWebView for the user, not an agent-controlled browser tool.

![Embedded browser showing Swift documentation](../assets/screenshots/browser-panel.png)

## Review workbench

The task summary's Environment section hosts the local project environment panel. It shows the current local or worktree mode and branch, lists local branches, and refuses branch switching while the checkout is dirty. The section menu retains Reveal in Finder, Copy path, and Open Review when Review is available. Remote-branch listing is not offered — the environment snapshot enumerates `refs/heads` only.

Open **Changes** from the shared task summary or select the Review side-panel tab. Review is available in any Git checkout, not only after the current turn has produced edits: with no turn diff it opens on its Last Turn empty state and offers the repository sources from there, so Changes, Commit or push, and Create pull request stay live in a normal repository. Completed plans appear as a separate Plan section in that same summary and open a Plan tab; diffs never appear inside Plan. Review offers Last Turn, Uncommitted, Unstaged, Staged, Committed, and Branch sources. Last Turn uses the immutable diff already projected for the current conversation; repository sources are refreshed explicitly from Git. Committed accepts a recent commit or explicit ref. Branch requires an explicit or safely discovered base and uses merge-base comparison; it never silently substitutes the previous commit.

The changed-file navigator is a directory tree on the trailing edge, with the unified diff leading. Single-child directory chains collapse into one row, and each row carries its status colour, line statistics, staging tag, and viewed toggle. It supports filtering, keyboard movement, rename metadata, and a draggable divider; below 560 points it collapses to a compact picker above the diff.

The unified diff carries a single line-number gutter, matching bundle `26.727.40816`, whose unified renderer emits one gutter cell per row holding the new-side number and falling back to the old side for removed lines. A whole-file addition is therefore numbered once, from line 1, instead of repeating the same numbers in two columns. Change bars mark added and removed rows (the bundle's default `diffIndicators: "bars"`), markers live in their own column so added, removed, and unchanged lines share one indentation origin, and file headers are dropped in favour of the pane's own file header. The bundle's collapsed "N unmodified lines" expanders are not reproduced: CodexCore loads bounded per-file patches with Git's default context rather than whole files. Patches load only for the selected file and are byte-bounded. Untracked trees are capped at 5,000 visible paths/512 KiB and Review discloses when additional paths were omitted.

Per-file and bulk stage, unstage, and tracked-file revert actions are explicit. Branch create/checkout, commit, commit-and-push, push, and draft-PR actions share the same mutation boundary. Rendering never mutates Git. Each mutation validates paths and rejects a stale repository revision. Mutations refuse index locks and active merge, rebase, cherry-pick, revert, bisect, or sequencer operations. Tracked revert requires confirmation, clears staged and unstaged content together, and refuses untracked deletion. Commit-and-push reports partial success if the commit succeeds but the network step fails, so recovery never suggests duplicating the commit.

Choose **Create environment** to hand the current chat off to a local Git
worktree. The confirmation sheet shows the editable branch name and destination
path, then reports capture, worktree creation, branch creation, tracked-change
application, untracked-file copying, and finalization as distinct stages. The
source checkout is left untouched, tracked diffs are applied with Git's
three-way machinery, and untracked files are transferred individually. Success
and failure results report each captured path as applied, skipped, or
conflicted; failures explicitly confirm that the source tree was not changed.
The destination uses a short machine-identifiable bucket and preserves the
chat's repository-relative working directory. Worktree-backed chats are marked
in the project sidebar using Git metadata, with a path fallback for unavailable
checkouts. Cloud environments are not offered.

Worktree handoff and Review require a Git-backed workspace. Projectless chats
show the Review empty state instead. Use the workspace side panel for the real
interactive Ghostty terminal.
