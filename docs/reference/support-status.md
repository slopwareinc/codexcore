# Support status

This is the authoritative user-facing capability matrix for CodexCore `0.7.0` with `codex-cli 0.145.0`. “Visible in the app” does not necessarily mean “wired to production behavior.”

| Status | Meaning |
| --- | --- |
| Supported | Implemented end to end in the reference app or public SDK surface. |
| Conditional | Works only when the server emits the required data or the host supplies policy/actions. |
| Presentation only | UI exists, but its primary mutation or lifecycle provider is not implemented. |
| Unsupported | Deliberately unavailable or known not to work. |

## SDK and reusable UI

| Capability | Status | Boundary |
| --- | --- | --- |
| Exact app-server launch and version validation | Supported | Default facade uses the pinned CLI over stdio; custom transports are possible. |
| Start/resume threads; turns, steering, interruption | Supported | Both server-declared history modes can resume. |
| Paginated backfill | Supported | Uses a canonical cut and buffered live events. |
| Paginated fork/rollback/full `thread/read` turns | Unsupported | Upstream/raw protocol limitations; known facade paths reject unsafe operations. |
| Canonical state, snapshots, scoped observations | Supported | Observation signals are coalesced invalidations; consumers reread state. |
| Approvals, user input, MCP elicitation, dynamic-tool requests | Supported | The host must provide policy/UI or resolve pending inbox requests. |
| Dynamic-tool declaration | Conditional | Public thread-start seam currently accepts a raw generated schema wrapper, not the handwritten typed helper. |
| Product-specific transcript cards | Conditional | Custom renderer supports dynamic-tool calls in `CodexTranscriptViewV2`; MCP uses generic rendering. |
| `CodexChatWorkspaceView` defaults | Conditional | Several bindings/actions are constants or no-ops until the host wires them. |

## Reference app

| Capability | Status | Notes |
| --- | --- | --- |
| ChatGPT/API-key authentication and isolated home | Supported | Uses `~/.codexcore` by default. |
| Workspace selection; new/resume/search chat | Supported | Starting in a project scopes the working directory. |
| Chat pin, archive, rename, fork, copy | Supported | Chat reorder/hide/reveal is not supported. |
| Project group, pin, reorder, alias, remove, reveal | Supported | Projects can also archive their chats. |
| Model, reasoning, approval, Plan and Goal controls | Supported | Availability still depends on server/model capabilities. |
| Attachments, mentions, slash commands, send/steer/interrupt | Supported | Standard composer workflow. |
| Approval and input prompts | Supported | Decisions happen before the requested operation. |
| Transcript, plans, goals, subagents, side chat | Supported | Presentation follows canonical session state. |
| Files and syntax-highlighted previews | Supported | Filesystem authority remains governed by the host/runtime. |
| Workspace terminal | Supported | Interactive Ghostty terminal in the workspace side panel. |
| Embedded browser | Supported (manual) | WKWebView navigation only; not agent browser-tool integration. |
| Plugin, skill, and MCP inventory | Supported (read-only) | Inspect and refresh work; install/uninstall/enable/disable actions are presentation only. |
| Current-turn diff preview | Conditional | Appears only for a parseable unified diff; shows summary/counts, not repository review. |
| Branch/review/jump/commit/push/pull request | Unsupported | Controls are disabled or no-op. Use Git tooling outside the app. |
| Automations | Presentation only | Can draft a supported chat prompt (Daily Brief); no scheduler, persistence, run list, or history. |
| Mobile remote control | Presentation only | Status/environment can render; allow/pair/revoke provider is unsupported. |
| Plugin mutation | Presentation only | “Try in Chat” prepares a draft; lifecycle mutation provider is unsupported. |
| Environment/worktree handoff | Presentation only | Provider is unsupported and permanent worktree creation is disabled. |
| Git settings | Presentation only | Preferences persist but have no production consumers. |
| Bottom terminal | Presentation only | Runs a hard-coded demo command; use the workspace terminal instead. |

When source and this page disagree, treat production source and tests as authoritative and update this matrix in the same change.
