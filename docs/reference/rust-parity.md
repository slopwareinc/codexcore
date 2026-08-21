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
| Canonical reducer and adapter | Partial | Atomic batches, coverage/status monotonicity, bounded ordered orphan replay, typed Plan/Goal replacements, pinned 0.148.0 command/reasoning/file/MCP streaming deltas, typed command `terminalInteraction`, direct item start/completion timestamps, and terminal-authority tests | Remaining non-transcript notification inventory |
| Coalesced observation | Complete | Atomic scoped seed, descendant matching, field filters, newest-one actor tests | Expand coarse Rust masks as canonical field inventory grows |
| Thread leases | Complete | Semantic priorities, stale completion suppression, reconnect tests | Turn-operation lease inventory audit |
| Legacy/paginated hydration | Complete | Mode-aware read, cut coordinator, live materialized legacy/paginated tests | Reconnect-during-page live stress |
| Approvals/questions/MCP/dynamic-tool/auth/time requests | Complete | All request schemas, typed inbox/replies, safe defaults, GPUI routing | Pluggable token/attestation providers |
| Thread/turn SDK facade | Partial | Start/resume/fork, hydrated resume, rename, archive/unarchive, revert and deprecated rollback, turn start/steer/interrupt, typed Goal set/get/clear, durable queue add/list/update/delete/reorder/start, input builders | Delete wrapper, operation streams |
| Stored threads and models | Complete | Generated validation, stable pages, GCP live catalog tests | Pagination/search UI and cache invalidation |
| Thread sections | Partial | Stable list/create/update/delete/move SDK with explicit appearance tri-state | Grouped GPUI navigation and section ordering controls |
| Dynamic-tool declaration/handlers | Complete | Exact function/namespace declarations, JSON Schema argument validation, deterministic async handler registry, generated result validation, and cancellation tests | Broader reference-host tool inventory |
| Authentication/config/home isolation | Partial | Stable account/login/cancel/logout SDK; native masked API-key, browser, device-code and cancellation UI; account read live-tested | Isolated-home hardening, logout/account menu, signed-out visual automation |
| Realtime Voice | Missing | Generated wire types only | SDK stream, audio platform adapter, host UI |

## Reusable presentation and GPUI

| Capability | Rust status | Current evidence | Remaining proof/work |
| --- | --- | --- | --- |
| Transcript V2 projection and grammar | Complete for the audited fixture set | `TranscriptV2Projector` preserves opening/steered messages, chronological segments, promoted final answers, generated images, live reasoning tails, work disclosure decisions, terminal duration/error metadata, optimistic submissions, and semantic work grouping; seven cross-language parity fixtures pass | Broaden corpus coverage as Swift adds protocol/item kinds |
| Virtual transcript | Partial | `CodexTranscriptV2` uses a bottom-aligned variable-height list, stable scoped IDs, tail following, exact 768/640/560 column geometry, targeted remeasurement, keyboard-focusable disclosures, native Markdown blocks, a Swift-parity turn-minimap rail with hover mount, click-to-jump, preview cards, and a runnable V2 example | Selection/copy, visual/stress baselines |
| User/assistant/reasoning/activity rows | Partial | Swift-style turn ordering with reasoning hidden from the narrative, collapsed work groups, compact expandable command/file/MCP/collaboration rows, generated-image and notice rows, accessible status glyphs, CommonMark/GFM headings, emphasis, code, quotes, lists/tasks, aligned tables, literal HTML fallback, image alt text, typed host-routed HTTP(S) link actions | Full AppKit card parity, syntax highlighting, selection/copy, directives, and broader incremental streaming-tail coverage |
| Commands | Partial | Bounded UTF-8 output, exit state, monospace card | ANSI styling, expand/copy, internal scrolling |
| File changes | Partial | Stable semantic changes and bounded colored diff preview | Full unified parser, gutters/hunks, expansion/review actions |
| Tool calls/unknown items | Partial | Semantic cards, bounded JSON, visible unknown fallback | Product renderer registry and structured result views |
| Composer | Partial | Bounded native IME, grapheme/UTF-16 selection, clipboard, submit, default durable queue, explicit steer, stop, ordered queue strip with move/remove | Multiline layout, attachments, mentions, slash commands, queued-text editing |
| Approval and user-input prompts | Complete | Exact identity, approval decisions, choice/free-form/secret answers | Visual/accessibility interaction baselines |
| MCP elicitation | Partial | URL opening and primitive JSON Schema forms; unsupported fields block submit | Nested arrays/objects and external URL completion lifecycle |
| Task navigation | Partial | Virtual list, status attention, mode-aware host switching | Search/pagination, pin/archive/rename/fork/copy, project grouping |
| Model/reasoning controls | Complete | Validated catalog, accessible picker, safe turn-boundary host policy | Service-tier/permission/Plan controls |
| Plans/goals | Partial | Typed `turn/plan/updated` replacement and V2 plan row; ordered, lossless canonical Goal lifecycle, SDK methods, controlled native Goal panel, and idle/active host observation | Completed-plan panels and typed Plan/Goal composer modes |
| Subagents/side chat | Partial | Framework-neutral child graph projection, accessible recursive virtual navigator, collaboration activity rows, and host-owned hydrated child lease transfer | Concurrent parent/child panes, side-chat creation, graph actions |
| Theming/accessibility | Partial | Semantic dark theme and AccessKit roles/labels | Light/high-contrast themes, keyboard audit, VoiceOver/NVDA/Orca smoke |

## Reference host and platform ecosystem

| Capability | Rust status | Current evidence | Remaining proof/work |
| --- | --- | --- | --- |
| Live native host | Partial | Real authenticated multi-turn GPUI/Tokio host, authenticated SDK smoke tests, and a compiling `CodexTranscriptV2` native example | Packaged app, crash recovery, persistence and visual QA |
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
