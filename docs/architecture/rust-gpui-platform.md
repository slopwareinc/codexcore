# Rust SDK and GPUI platform

The Rust platform adds a portable Codex App Server SDK, a framework-neutral
presentation layer, reusable GPUI components, and a native reference host. It
does not replace the Swift products while parity is being established.

## Product stack

```text
codex app-server
  -> codex-app-server-wire
  -> codex-app-server-transport
  -> ordered session engine
  -> codex-app-server-state
  -> Rust SDK facade and leases
  -> framework-neutral presentation
  -> codex-gpui
  -> GPUI reference host
```

The supported backend is the documented App Server process boundary. A future
direct dependency on upstream internal Rust core crates, if explored, remains
an experimental backend behind the same SDK facade.

## Runtime invariants

The Rust implementation preserves the production Swift runtime semantics:

1. One session task owns ingress ordering, request correlation, leases,
   history hydration, server requests, reconnect state, and canonical commits.
2. A response is adapted and committed before its caller resumes.
3. Correlation identity is `(connection epoch, JSON-RPC id)`; integer and
   string identifiers never alias.
4. A mutation whose write attempt began is never blindly replayed after loss.
5. Canonical state contains server facts and explicit local submission intent,
   never drafts, scroll position, selection, routes, or expansion.
6. Observations provide an atomic seed plus coalesced revision invalidations.
   Consumers reread current state instead of treating signals as an event log.
7. Thread leases own subscription/retention reasons. Explicit asynchronous
   close is deterministic; `Drop` is only a best-effort fallback.
8. Server-declared history mode controls hydration. Paginated resume establishes
   a cut, buffers live events, and marks gaps uncertain rather than guessing.
9. Unknown protocol values remain lossless where the wire contract permits.

Paginated history is a separate pure coordinator. It treats nullable resume
cursors as opaque persistence anchors, rejects cursor loops and empty
continuation pages, bounds concurrent per-turn item requests, stages durable
pages until complete, installs oldest-first, and marks prior coverage stale
after a physical connection gap. The ordered actor alone executes its effects.

## Crate boundaries

| Layer | Responsibility |
| --- | --- |
| Wire | Generated protocol types, lossless JSON-RPC framing, runtime compatibility. |
| Transport | Bounded stdio, WebSocket, and Unix-socket physical connections. |
| Adapter | Generated-validation-first mapping from protocol methods to canonical mutations. |
| State | Pure canonical models, reducer, scopes, revisions, and diagnostics. |
| Engine | Ordered actor, handshake, correlation, reconnect, leases, history, inboxes. |
| SDK | Typed configuration, threads, turns, inputs, approvals, tools, operations. |
| Presentation | Transcript, activity, diff, prompt, composer, and panel projections. |
| GPUI | Controlled native components and host capability interfaces. |
| Platform adapters | Optional terminal, browser, Git, audio, notifications, and updater. |
| Reference app | Executable documentation for complete host integration. |

GPUI entities receive bounded/coalesced presentation changes. They never read
global runtime singletons or reduce raw protocol notifications.

WebSocket transport accepts `ws://`/`wss://` with an optional upgrade-only
bearer credential, plus WebSocket-over-Unix-socket endpoints. It enforces text
messages and frame bounds and never logs the credential. Remote exposure still
inherits App Server's experimental-support and TLS/auth requirements.

## Compatibility and generation

`Tools/UPSTREAM_VERSION` remains the repository authority for the Codex CLI
runtime. Rust protocol artifacts are generated from that exact binary using
`codex app-server generate-json-schema --experimental`. Drift verification must
fail when the schema or the compiled runtime constant differs. Upstream
workspace crates are not exposed as the SDK contract: the 0.148.0 protocol
crate depends on workspace-root patches that downstream Cargo dependencies do
not inherit.

The Rust toolchain is pinned in `rust-toolchain.toml`. `gpui` and
`gpui_platform` are pinned to Zed revision
`8bbbeb3d15a7b08c852d6c941cefdbbbaeab82fe`; the public
`codex_gpui::GPUI_REVISION` constant and Cargo lockfile make that compatibility
choice inspectable. macOS development without the full Xcode Metal toolchain
uses GPUI's runtime-shader feature. Linux enables the tested Wayland and X11
backends.

## Embedding the first GPUI surface

`codex-gpui` exposes `CodexTranscript`, `CodexPrompt`, and `CodexComposer` as
reusable GPUI entities. The host passes disposable presentation models and
later updates them from a GPUI context. The components own only presentation,
draft, focus, and viewport state: they do not start App Server, create a Tokio
runtime, or open a window.

The transcript uses GPUI's bottom-aligned variable-height list, stable
composite row identities, tail following, identity splices, and targeted
remeasurement for streaming content. Unknown canonical items render as visible
fallback cards rather than disappearing.

File-change projection decodes stable path, move destination, kind, and diff
semantics while retaining malformed raw values. GPUI renders a bounded native
preview (12 files and 16 lines per file) with add/delete colors and explicit
overflow counts; full review-grade expansion remains a host workbench concern.

Prompt projections preserve the exact connection-epoch/request-ID identity and
declare semantic host actions. `CodexPrompt` emits `PromptIntent`; the host
still maps that intent to a generated-schema-validated reply or opens the
required user/MCP form. It never infers approval policy in the render path.
Transcript rows, prompt dialogs, headings, and controls carry stable AccessKit
roles and bounded labels.

Typed user-input prompts preserve every question, choice, secret marker, and
custom-response capability. The GPUI card retains one advertised choice per
question and enables Respond only when every question is answered; the emitted
intent carries the exact answer map. Questions requiring free-form/custom text
remain visibly pending until the dedicated form editor lands.

The composer uses GPUI's native input-handler contract for IME composition,
UTF-16 platform ranges, grapheme navigation, selection, and clipboard actions.
Drafts are single-line and bounded to 256 KiB. Hosts install its scoped key
bindings once with `init_composer` and subscribe to `ComposerEvent`; sending,
steering, queueing, and persistence remain host policy.

Stored task navigation follows the same boundary. `Codex::list_threads`
validates the complete response against generated bindings and projects stable
`ThreadSummary` pages with opaque cursors and a lossless raw field.
`project_thread_list` supplies compact titles and attention states;
`CodexThreadList` virtualizes uniform rows and emits only a stable `ThreadId`.
The host owns resume, lease transfer, pagination, search, and selection races.
The reference host implements that ownership: task selection is deferred while
a turn is active, then `resume_thread_hydrated` reads the declared history mode,
installs its canonical snapshot, transfers the selected lease, and republishes
the sidebar selection. The old lease remains live until the replacement resume
succeeds.

Run the executable embedding example on a graphical machine:

```sh
cargo run -p codex-gpui --example transcript
```

`codex-gpui-app` is the first opinionated host slice. It pins the GPUI/Tokio
bridge to the same Zed revision, retains both executor tasks, drives an actual
SDK thread, coalesces canonical snapshots into transcript updates, and exposes
typed pending prompts. Only safe non-user request families use the built-in
default policy. Approval and decline require an explicit click and are resolved
against the exact epoch-qualified identity. Composer submissions start another
turn while idle and steer the exact active turn while running. The same driver
has a headless mode for authenticated Linux verification and an explicit quit
command for deterministic App Server and lease teardown.

## Verification strategy

- Pure Rust envelope, reducer, state-machine, and projection tests.
- Cross-language fixtures replayed into Swift and Rust with normalized snapshot
  comparison.
- Controllable in-memory transport tests for response/notification ordering,
  disconnect epochs, cancellation, and no-replay behavior.
- Live integration tests against the exact pinned App Server.
- GPUI interaction, accessibility, visual, virtualization, and streaming stress
  tests.
- A requirement-by-requirement parity audit against
  `docs/reference/support-status.md` before a stable release.
