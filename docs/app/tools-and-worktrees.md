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

Open **Terminal** for a real interactive shell rooted in the workspace. Terminal commands use the permissions of the host process; opening the panel does not grant an agent permission to run them.

![Interactive workspace terminal beside a completed task](../assets/screenshots/workspace-terminal.png)

### Browser

Open **Browser** for manually navigated documentation and local previews. It is an embedded WKWebView for the user, not an agent-controlled browser tool.

![Embedded browser showing Swift documentation](../assets/screenshots/browser-panel.png)

## Review workbench

Open **Changes** from the shared task summary or select the Review side-panel tab. Completed plans appear as a separate Plan section in that same summary and open a Plan tab; diffs never appear inside Plan. Review offers Last Turn, Uncommitted, Unstaged, Staged, Committed, and Branch sources. Last Turn uses the immutable diff already projected for the current conversation; repository sources are refreshed explicitly from Git. Committed accepts a recent commit or explicit ref. Branch requires an explicit or safely discovered base and uses merge-base comparison; it never silently substitutes the previous commit.

The changed-file navigator supports filtering, keyboard movement, rename metadata, line statistics, and per-file viewed state. It remains beside the unified diff at normal widths and collapses to a compact picker below 520 points. Patches load only for the selected file and are byte-bounded.

Stage, unstage, tracked-file revert, branch create/checkout, commit, push, and draft-PR actions are explicit. Rendering never mutates Git. Each mutation validates paths and rejects a stale repository revision; tracked revert requires confirmation and refuses untracked deletion.

The reference app still omits worktree handoff and the old demo bottom terminal. Use external Git tooling for worktrees and the workspace side panel for the real interactive Ghostty terminal.
