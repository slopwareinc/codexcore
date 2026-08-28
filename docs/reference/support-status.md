# Support status

This is the authoritative user-facing capability matrix for CodexCore `0.13.0` with `codex-cli 0.148.0` or newer and types generated from `0.150.1`. “Visible in the app” does not necessarily mean “wired to production behavior.”

| Status | Meaning |
| --- | --- |
| Supported | Implemented end to end in the reference app or public SDK surface. |
| Conditional | Works only when the server emits the required data or the host supplies policy/actions. |
| Presentation only | UI exists, but its primary mutation or lifecycle provider is not implemented. |
| Unsupported | Deliberately unavailable or known not to work. |
| Deferred | Product surface is intentionally removed pending a tracked reintroduction. |

## SDK and reusable UI

| Capability | Status | Boundary |
| --- | --- | --- |
| Exact app-server launch and version validation | Supported | Default facade uses the pinned CLI over stdio; custom transports are possible. |
| On-demand app-server diagnostics | Supported | Settings → About displays process memory and gauges from one explicit snapshot; there is no background polling. |
| Thread credit and cost estimates | Conditional | `/status` fetches the selected thread estimate on demand; availability depends on the authenticated workspace billing route. |
| Model multi-agent and retirement metadata | Supported | Model catalog projection preserves runtime generation and preformats retirement/replacement detail for the picker. |
| MCP plugin ownership and OAuth registration selection | Supported | Plugin-owned servers are configuration read-only; login supports automatic, CIMD, and DCR registration strategies. |
| MCP event streams | Supported | Public start/stop wrappers and a connection-scoped observer expose lossless subscription notifications; callers filter concurrent streams by subscription ID. |
| Async command and MCP-tool hooks | Supported | Settings shows the heterogeneous handler metadata and configures resolved enable/trust state without rewriting hook definitions. |
| Structured image-generation failures | Supported | Usage-limit metadata is typed and rendered persistently in both transcript implementations, including after resume. |
| Start/resume threads; turns, steering, interruption | Supported | Both server-declared history modes can resume. |
| Thread sections, appearance, and server-persisted ordering | Supported | Public SDK wrappers cover list/create/update/delete/move; Settings edits synchronized icons/colors and sidebar rows render them without extra requests. |
| Paginated backfill | Supported | Uses a canonical cut and buffered live events. |
| Paginated fork, full `thread/read`, and durable revert | Supported | Stable 0.148.0 exposes `thread/revert`; CodexCore invalidates stale detail and retains replacement cursors. |
| Paginated legacy rollback | Unsupported | `thread/rollback` remains the separate legacy full-history operation. |
| Canonical state, snapshots, scoped observations | Supported | Observation signals are coalesced invalidations; consumers reread state. |
| Approvals, user input, MCP elicitation, dynamic-tool requests | Supported | The host must provide policy/UI or resolve pending inbox requests. |
| Dynamic-tool declaration | Conditional | Public thread-start seam currently accepts a raw generated schema wrapper, not the handwritten typed helper. |
| Realtime Voice requests and event stream | Supported | `CodexRealtimeEvent` routes ephemeral thread-scoped transcript, item lifecycle, PCM audio, session lifecycle, and SDP notifications. |
| Product-specific transcript cards | Conditional | Custom renderer supports dynamic-tool calls in `CodexTranscriptViewV2`; MCP uses generic rendering. |
| `CodexChatWorkspaceView` defaults | Conditional | Several bindings/actions are constants or no-ops until the host wires them. |

## Reference app

| Capability | Status | Notes |
| --- | --- | --- |
| ChatGPT/API-key authentication and isolated home | Supported | Uses `~/.codexcore` by default. |
| Projectless chats; multi-folder projects; new/resume/search chat | Supported | Projectless tasks live in a separate Chats section and generated Documents/Codex workspaces, but have no Git-backed Review workbench. For projects, Primary is `cwd` and all ordered source folders are runtime workspace roots. |
| Chat pin, archive, rename, fork, copy | Supported | Chat reorder/hide/reveal is not supported. |
| Project group, pin, reorder, alias, remove, reveal | Supported | Projects can also archive their chats. |
| Model, reasoning, approval, Plan and Goal controls | Supported | Availability still depends on server/model capabilities. |
| Attachments, mentions, slash commands, durable queued follow-ups, steer, interrupt | Supported | App-server persists FIFO follow-ups and auto-dispatches them while CodexCore provides steer, edit, and remove actions. Steering appends a distinct in-turn user bubble and preserves the original prompt. |
| Approval and input prompts | Supported | Decisions happen before the requested operation. |
| Transcript, plans, goals, subagents, side chat | Supported | Presentation follows canonical session state. |
| Global realtime Voice task | Supported | One active top-level V3 Voice task with microphone capture, audio playback, live transcript, orb UI, background mini-control, and list/read/message access to other tasks. |
| Files and syntax-highlighted previews | Supported | Filesystem authority remains governed by the host/runtime. |
| Workspace terminal | Supported | Interactive Ghostty terminal in the workspace side panel. |
| Embedded browser | Supported (manual) | WKWebView navigation only; not agent browser-tool integration. |
| Plugin, skill, app, and MCP management | Supported | Browse and detail views use app-server inventory; install/uninstall, enable/disable, marketplace add/upgrade, and MCP OAuth actions route through the integration control plane. The public SDK also exposes paginated server-side plugin search. |
| Review workbench | Conditional | Available for Git-backed project chats; projectless chats show an empty state. Includes Last Turn, Uncommitted, Unstaged, Staged, and Branch sources; filtered navigation, viewed state, lazy bounded unified patches, and adaptive layout. |
| Repository stage/unstage/revert/branch/commit/push/draft PR | Supported | Cancellable operations validate paths and reject stale revisions; tracked revert requires confirmation and untracked deletion is refused. Draft PR creation requires `gh` authentication. |
| Structured AI code review | Supported | Starts app-server review for uncommitted, base-branch, commit, or custom targets. |
| Automations | Supported | Local TOML-backed schedules run as independent chats while the app is open; native completion notifications require the packaged app and macOS permission. No first-class app-server automation API exists in the pinned protocol. |
| Mobile remote control | Deferred | Product UI and pairing flow are removed pending [#190](https://github.com/slopwareinc/CodexCore/issues/190); generated remote-control protocol wrappers remain available for a future reintroduction. |
| Environment/worktree handoff | Supported | Git-backed chats can create a local branch in a new worktree, transfer tracked and untracked changes without modifying the source checkout, and continue from the corresponding repository-relative directory. Cloud environments are not offered. |
| Git settings | Preview | Stored settings remain host-facing preferences; Review mutations use repository state directly. |
| Demo bottom terminal | Unsupported | Removed from the reference app; use the real workspace terminal. |

When source and this page disagree, treat production source and tests as authoritative and update this matrix in the same change.
