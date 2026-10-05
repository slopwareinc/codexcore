# App-server feature coverage

The [machine-readable ledger](app-server-feature-coverage.json) assigns every
entry in the pinned `codex-cli 0.160.0` protocol to one primary workflow. It
records explicit method arrays, notifications, server requests, production
source symbols, and behavioral test files. Generated factories alone do not
establish an app workflow.

| Ownership | Client methods | Notifications | Server requests |
| --- | ---: | ---: | ---: |
| Reference-app workflows | 161 | 80 | 10 |
| SDK host workflows | 3 | 1 | 0 |
| Windows-only capabilities | 2 | 2 | 0 |
| External authentication host extension | 0 | 0 | 1 |
| Upstream internal mock | 1 | 0 | 0 |
| Total pinned inventory | 167 | 83 | 11 |

The ownership counts describe implemented seams and entrypoints. They do not
claim that every provider enables every capability, that a test file exercises
every variant, or that static source evidence replaces live UI validation.

## Find a workflow

Use [Runtime features](../app/runtime-features.md) for the app controls and
[the app tour](../app/using-the-app.md) for ordinary chat workflows. The ledger's
workflow IDs provide stable lookup keys:

| Workflow IDs | Product owner |
| --- | --- |
| `connection`, `authentication`, `gateway`, `bedrock`, `native-verification`, `account-usage` | App connection/login and **Runtime features → Account**. Gateway readiness is checked before authenticated catalogs or inference. Native verification proofs stay scoped to the initiating approval. |
| `models-and-permissions`, `turns-and-review` | Composer model/reasoning/tier/permission controls, live turn settings, code review, and confirmed Guardian retry. |
| `thread-lifecycle`, `thread-history`, `thread-resources`, `thread-goals`, `thread-queue` | Sidebar chat actions and **Runtime features → Chat**. Selected history and resource controls use authoritative thread IDs and paginated responses. |
| `projects-and-sections` | Sidebar projects/sections/search and **Runtime features → Projects**. Project identity and ordered source folders remain distinct. |
| `canonical-transcript`, `runtime-notices`, `diagnostics` | Canonical transcript projection, the scoped conversation notice panel, and runtime diagnostics in Settings. Typed warnings retain bounded actionable text; opaque provider/native payloads are not rendered. |
| `realtime-voice` | Voice entrypoints and **Runtime features → Voice**. Voice/model/output selections configure the next session; V3 uses the upstream v1 voice catalog. |
| `remote-control`, `environments` | **Runtime features → Remote control / Environments**. Observation does not enable remote access; pairing and executor recovery are explicit actions. |
| `files-and-search`, `processes`, `background-terminals` | **Runtime features → Files / Processes**, composer file mentions, and background terminal tabs. Start observers are registered before dispatch and cleanup remains attached to the accepting provider. |
| `imports`, `experiments`, `feedback` | **Runtime features → Imports / Experiments / Feedback**. Imports preserve early completion; feedback sends the reviewed request once with explicit log consent. |
| `integration-catalog`, `plugin-sharing`, `configuration`, `mcp-management`, `mcp-inspection` | Plugin route and skill/app/plugin/MCP sheets. Versioned configuration edits retain unknown fields; widgets use scoped resources/tools and an isolated MCP Apps bridge. |
| `side-conversation-boundary` | The app's ephemeral side-chat fork clears inherited goals and injects an instruction boundary before new inference. |
| `approvals`, `interactive-input`, `host-dynamic-tools`, `host-attestation`, `host-current-time` | Typed server-request inbox, approval/input panels, exact pending MCP verification bridge, registered thread tools, and local automatic host responses. |

## SDK and platform boundaries

`realtime-pcm` owns `thread/realtime/appendAudio` and typed output-audio events.
SDK hosts provide PCM frames and consume those events; the reference app's
microphone transport is WebRTC. See the typed APIs in
`Codex+Realtime.swift` and `RealtimeObserverHub.swift`.

`out-of-band-elicitation` owns `thread/increment_elicitation` and
`thread/decrement_elicitation`. `CodexThreadLease.withOutOfBandElicitation(_:)`
balances host-owned interactions with connection-scoped cleanup. The app's
MCP approval path uses the server-owned elicitation lifecycle. Lease-scoped
`injectItems` also supports SDK hosts. See
[approvals and input](../sdk/approvals-and-input.md).

`external-token-refresh` owns `account/chatgptAuthTokens/refresh`. SDK hosts
using external ChatGPT tokens supply the `Codex` initializer's `serverRequestHandler` and
own token rotation. The reference app instantiates managed login, API-key or
Bedrock authentication, so it does not create this external-token mode. An
unconfigured handler reports an unavailable capability instead of supplying
stale credentials.

`windows-sandbox` separates typed Windows setup/readiness and its completion
or world-writable warning events from the macOS reference app. There is no
Windows setup UI in that app. `mock-internal` records the generated upstream
test method solely as protocol inventory; it has no product workflow.

## Runtime compatibility

`Tools/UPSTREAM_VERSION` and generated bindings pin `0.160.0`. The reference
app requires the `0.160.x` feature line and checks that boundary after the wire
handshake and before feature startup. Its explicit gateway readiness probe does not treat a failed
or unsupported read as authenticated readiness.

The SDK's accepted core lifecycle floor remains `0.148.0`. Acceptance of an
older SDK runtime does not imply support for newer methods: hosts must use a
runtime implementing the workflows they invoke. See
[runtime compatibility](runtime-compatibility.md) and the app's
`CodexAppRuntimeCompatibility` guard.

## Maintain the ledger

Run `python3 -m unittest Tools.tests.test_app_server_feature_coverage` after
changing workflow owners or regenerating protocol bindings. The check enforces
the exact committed client/event/server-request inventories, one primary owner
per entry, the upstream pin, existing source symbols/test paths, and the
platform/internal/host-extension boundaries.

When adding a protocol feature, implement its typed workflow and lifecycle
tests first, then update its ledger entry with source evidence. Follow
[protocol upgrades](../contributing/protocol-upgrades.md) for generated files.
