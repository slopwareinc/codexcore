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

## Experimental diff preview

When the current turn emits a parseable unified diff, the workspace can expose a Review tab with changed-file counts and a file summary. This is a conditional preview, not a repository-wide Git review workflow.

Branch selection, review options, commit, push, and pull-request controls are intentionally unwired in the current reference app. Treat the working tree and normal Git tooling as authoritative.

## Environment handoff

Environment/worktree handoff controls are present but use an unsupported provider in the reference app; permanent worktree creation is disabled. Use external Git tooling for worktrees.

## Bottom terminal

The workspace side panel provides the real interactive Ghostty terminal. The separate bottom terminal currently runs only a hard-coded demo command and should not be treated as a workspace shell.
