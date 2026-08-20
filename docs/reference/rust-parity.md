# Rust SDK and GPUI parity ledger

This ledger tracks the experimental Rust platform against the supported Swift
SDK, reusable UI, and reference app. It is intentionally stricter than a
roadmap: **Complete** requires compiling production code plus relevant tests;
**Partial** means important behavior or verification is still absent.

## SDK and runtime

| Capability | Rust status | Current evidence | Remaining proof/work |
| --- | --- | --- | --- |
| Runtime pin and initialize compatibility | Complete | `codex-app-server-wire`, initialize user-agent validation, GCP 0.148.0 live tests | Composite release packaging |
| Generated v2 protocol and drift | Complete | Exact 0.148.0 schemas, generated Typify bindings, drift scripts/tests | Repeat on every runtime upgrade |
| Stdio transport | Complete | Bounded frames/stderr, process-group cleanup, unit/live tests | Windows process-tree verification |
| TCP/TLS WebSocket and Unix WebSocket | Complete | Bounded text frames, credential redaction, actor round-trip tests | Remote deployment soak test |
| Ordered actor/correlation | Complete | Epoch-qualified IDs, handshake buffering, response-before-resume tests | Cross-language golden replay |
| Disconnect/no-replay semantics | Complete | Write-attempt tracking and reconnect tests | Larger permutation/property suite |
| Canonical reducer and adapter | Partial | Atomic batches, coverage/status monotonicity, orphan replay, unknown fallback | Full item/notification inventory and Swift-normalized fixtures |
| Coalesced observation | Complete | Atomic scoped seed, descendant matching, field filters, newest-one actor tests | Expand coarse Rust masks as canonical field inventory grows |
| Thread leases | Complete | Semantic priorities, stale completion suppression, reconnect tests | Turn-operation lease inventory audit |
| Legacy/paginated hydration | Complete | Mode-aware read, cut coordinator, live materialized legacy/paginated tests | Reconnect-during-page live stress |
| Approvals/questions/MCP/dynamic-tool/auth/time requests | Complete | All request schemas, typed inbox/replies, safe defaults, GPUI routing | Pluggable token/attestation providers |
| Thread/turn SDK facade | Partial | Start/resume, hydrated resume, turn start/steer/interrupt, input builders | Fork/revert/rollback, rename/archive/delete wrappers, operation streams |
| Stored threads and models | Complete | Generated validation, stable pages, GCP live catalog tests | Pagination/search UI and cache invalidation |
| Thread sections | Missing | Generated wire types only | Stable SDK wrappers and host navigation |
| Dynamic-tool declaration/handlers | Partial | Request/reply types and safe unknown failure | Typed declaration builder and handler registry |
| Authentication/config/home isolation | Partial | Existing credentials work; runtime compatibility enforced | Login flows, isolated-home hardening, API-key/device-code UI |
| Realtime Voice | Missing | Generated wire types only | SDK stream, audio platform adapter, host UI |

## Reusable presentation and GPUI

| Capability | Rust status | Current evidence | Remaining proof/work |
| --- | --- | --- | --- |
| Virtual transcript | Partial | Bottom-aligned variable-height list, stable IDs, tail following, targeted remeasurement | Markdown, selection/copy, turn minimap, visual/stress baselines |
| User/assistant/reasoning/activity rows | Partial | Semantic projection and accessible native rows | Full grouping/phase grammar and rich Markdown |
| Commands | Partial | Bounded UTF-8 output, exit state, monospace card | ANSI styling, expand/copy, internal scrolling |
| File changes | Partial | Stable semantic changes and bounded colored diff preview | Full unified parser, gutters/hunks, expansion/review actions |
| Tool calls/unknown items | Partial | Semantic cards, bounded JSON, visible unknown fallback | Product renderer registry and structured result views |
| Composer | Partial | Bounded native IME, grapheme/UTF-16 selection, clipboard, submit/steer/stop | Multiline layout, attachments, mentions, slash commands, queue editor |
| Approval and user-input prompts | Complete | Exact identity, approval decisions, choice/free-form/secret answers | Visual/accessibility interaction baselines |
| MCP elicitation | Partial | URL opening and primitive JSON Schema forms; unsupported fields block submit | Nested arrays/objects and external URL completion lifecycle |
| Task navigation | Partial | Virtual list, status attention, mode-aware host switching | Search/pagination, pin/archive/rename/fork/copy, project grouping |
| Model/reasoning controls | Complete | Validated catalog, accessible picker, safe turn-boundary host policy | Service-tier/permission/Plan/Goal controls |
| Plans/goals | Partial | Typed `turn/plan/updated` canonical replacement and accessible stable plan row | Goal state, completed-plan panel, typed Plan/Goal composer modes |
| Subagents/side chat | Partial | Collaboration activity row only | Child graph projection, leases, task navigation, side transcript |
| Theming/accessibility | Partial | Semantic dark theme and AccessKit roles/labels | Light/high-contrast themes, keyboard audit, VoiceOver/NVDA/Orca smoke |

## Reference host and platform ecosystem

| Capability | Rust status | Current evidence | Remaining proof/work |
| --- | --- | --- | --- |
| Live native host | Partial | Real authenticated multi-turn GPUI/Tokio host and headless GCP run | Packaged app, crash recovery, persistence and visual QA |
| Files/previews | Missing | None | Scoped filesystem adapter, tree, syntax preview |
| Review/Git/worktrees | Missing | None | Safe read/mutation controller and native workbench |
| Terminal | Missing | None | Optional PTY/terminal crate and accessibility policy |
| Embedded browser | Missing | None | Optional host-owned webview adapter and URL policy |
| Plugins/skills/apps/MCP management | Missing | Server request handling only | Inventory/search/control-plane SDK and GPUI routes |
| Automations | Missing | None | Local durable scheduler, task creation, notifications |
| Dictation/realtime Voice | Missing | None | Audio/speech/WebRTC platform adapters and controls |
| Native shell integration | Missing | Window creation only | Menus, shortcuts, notifications, file panels, updater, packaging |

## Verification gates before stable parity

- Cross-language JSONL fixtures must produce normalized equivalent Swift and
  Rust canonical snapshots, revisions, diagnostics, and pending interactions.
- GPUI tests must cover keyboard, IME, clipboard, approvals, forms, task/model
  controls, resize, tail-follow, and cancellation.
- Visual baselines require a DRI3-capable Linux runner plus macOS rendering;
  Xvfb alone creates the window but cannot paint the GPUI GPU surface.
- Stress gates must include a 10,000-row transcript, continuous streaming,
  huge command/diff payloads, reconnect during hydration, and prompt races.
- The reference app must be packaged and smoke-tested on every claimed
  platform before this ledger can call the host complete.
