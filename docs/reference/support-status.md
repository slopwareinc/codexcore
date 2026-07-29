# Support status

This is the authoritative user-facing capability matrix for CodexCore `0.9.0` with `codex-cli 0.145.0`. “Visible in the app” does not necessarily mean “wired to production behavior.”

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
| Realtime Voice requests and event stream | Supported | `CodexRealtimeEvent` routes ephemeral thread-scoped transcript, PCM audio, lifecycle, and SDP notifications. |
| Product-specific transcript cards | Conditional | Custom renderer supports dynamic-tool calls in `CodexTranscriptViewV2`; MCP uses generic rendering. |
| `CodexChatWorkspaceView` defaults | Conditional | Several bindings/actions are constants or no-ops until the host wires them. |

## Reference app

| Capability | Status | Notes |
| --- | --- | --- |
| ChatGPT/API-key authentication and isolated home | Supported | Uses `~/.codexcore` by default. |
| Projectless chats; multi-folder projects; new/resume/search chat | Supported | Projectless tasks live in a separate Chats section and generated Documents/Codex workspaces. For projects, Primary is `cwd` and all ordered source folders are runtime workspace roots. |
| Chat pin, archive, rename, fork, copy | Supported | Chat reorder/hide/reveal is not supported. |
| Project group, pin, reorder, alias, remove, reveal | Supported | Projects can also archive their chats. |
| Model, reasoning, approval, Plan and Goal controls | Supported | Availability still depends on server/model capabilities. |
| Attachments, mentions, slash commands, queued follow-ups, steer, interrupt | Supported | Active-turn follow-ups form a multi-message FIFO queue with explicit steer, edit, and remove actions; one queued message starts after each completed turn. Steering appends a distinct in-turn user bubble and preserves the original prompt. |
| Approval and input prompts | Supported | Decisions happen before the requested operation. |
| Transcript, plans, goals, subagents, side chat | Supported | Presentation follows canonical session state. |
| Global realtime Voice task | Supported | One active top-level V3 Voice task with microphone capture, audio playback, live transcript, orb UI, background mini-control, and list/read/message access to other tasks. |
| Files and syntax-highlighted previews | Supported | Filesystem authority remains governed by the host/runtime. |
| Workspace terminal | Supported | Interactive Ghostty terminal in the workspace side panel. |
| Embedded browser | Supported (manual) | WKWebView navigation only; not agent browser-tool integration. |
| Plugin, skill, and MCP inventory | Supported (read-only) | Inspect and refresh work; install/uninstall/enable/disable actions are presentation only. |
| Review workbench | Supported | Last Turn, Uncommitted, Unstaged, Staged, and Branch sources; filtered navigation, viewed state, lazy bounded unified patches, and adaptive layout. |
| Repository stage/unstage/revert/branch/commit/push/draft PR | Supported | Cancellable operations validate paths and reject stale revisions; tracked revert requires confirmation and untracked deletion is refused. Draft PR creation requires `gh` authentication. |
| Structured AI code review | Supported | Starts app-server review for uncommitted, base-branch, commit, or custom targets. |
| Automations | Unsupported | Not shown in the reference app because scheduling, persistence, runs, and history are not implemented. |
| Mobile remote control | Unsupported | Not shown in the reference app because allow/pair/revoke is not implemented. |
| Plugin mutation | Unsupported | Install/uninstall/enable/disable controls are omitted; inventory, refresh, and “Try in Chat” remain. |
| Environment/worktree handoff | Unsupported | Creation and handoff controls are omitted. Use external Git tooling. |
| Git settings | Preview | Stored settings remain host-facing preferences; Review mutations use repository state directly. |
| Demo bottom terminal | Unsupported | Removed from the reference app; use the real workspace terminal. |

When source and this page disagree, treat production source and tests as authoritative and update this matrix in the same change.
