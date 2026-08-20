# Rust SDK quick start

The Rust SDK is experimental while it approaches the supported Swift SDK and
reference-app capability matrix. Its current public slice provides exact-runtime
initialize/initialized negotiation, bounded stdio transport, ordered request
correlation, revisioned snapshots, coalesced observations, and a pending
server-request inbox.

Use `codex-app-server-sdk` for the ergonomic facade and
`codex-app-server-client` when implementing lower-level hosts:

```rust
use codex_app_server_client::LocalSessionConfig;
use codex_app_server_sdk::{Codex, StartThreadOptions};

# async fn sdk() -> Result<(), Box<dyn std::error::Error>> {
let codex = Codex::connect_local(LocalSessionConfig::app_server(
    "/absolute/path/to/codex",
)).await?;
let thread = codex.start_thread(StartThreadOptions::default()).await?;

// Start turns through thread.start_turn(...).

thread.close().await?;
codex.close().await?;
# Ok(())
# }
```

Stored task navigation uses a generated-schema-validated stable page rather
than exposing generated protocol types:

```rust
use codex_app_server_sdk::ListThreadsOptions;

# async fn tasks(codex: &codex_app_server_sdk::Codex) -> Result<(), Box<dyn std::error::Error>> {
let page = codex
    .list_threads(ListThreadsOptions {
        limit: Some(50),
        ..ListThreadsOptions::default()
    })
    .await?;
for thread in page.data {
    println!("{}: {}", thread.id, thread.preview);
}
# Ok(())
# }
```

Pagination cursors stay opaque. `ThreadSummary::raw` preserves additional
schema-valid fields without making generated wire structs the SDK contract.

Stored-task lifecycle calls are generated-schema validated without exposing
generated protocol types. Root methods rename, archive, unarchive, or fork by
stable thread identity; a retained `CodexThread` provides the same rename,
archive, and fork operations plus history revert:

```rust
use codex_app_server_sdk::{ForkPoint, ForkThreadOptions};
use codex_app_server_state::{ThreadId, TurnId};

# async fn lifecycle(codex: &codex_app_server_sdk::Codex) -> Result<(), Box<dyn std::error::Error>> {
let source = ThreadId::from("source-thread");
codex.rename_thread(&source, "Stable title").await?;
let forked = codex
    .fork_thread(
        &source,
        ForkThreadOptions {
            point: Some(ForkPoint::Before(TurnId::from("turn-to-exclude"))),
            ..ForkThreadOptions::default()
        },
    )
    .await?;
let fork_id = forked.thread.id().clone();
forked.thread.archive().await?;
forked.thread.close().await?;
let restored = codex.unarchive_thread(&fork_id).await?;
assert_eq!(restored.thread_id, fork_id);
# Ok(())
# }
```

`ThreadLifecycleResult::raw` keeps the complete validated response. Revert
results also project the opaque turn/item backwards cursors. The pinned runtime
still exposes `thread/rollback`, but the SDK marks that wrapper deprecated and
requires a nonzero turn count; prefer `CodexThread::revert` for paginated
threads. Neither history operation reverts local file changes.

Server-persisted task sections are available through `list_sections`,
`create_section`, `update_section`, `delete_section`, and
`move_thread_to_section`. Appearance updates use an explicit
`SectionAppearanceUpdate::{Preserve, Clear, Set}` policy so omission never
accidentally clears synchronized metadata.

The model catalog follows the same stable-page boundary:

```rust
use codex_app_server_sdk::ListModelsOptions;

# async fn models(codex: &codex_app_server_sdk::Codex) -> Result<(), Box<dyn std::error::Error>> {
let models = codex
    .list_models(ListModelsOptions::default())
    .await?;
for model in models.data {
    println!("{} ({})", model.display_name, model.default_reasoning_effort);
}
# Ok(())
# }
```

```rust
use codex_app_server_client::{AppServerClient, LocalSessionConfig};
use serde_json::json;

# async fn example() -> Result<(), Box<dyn std::error::Error>> {
let client = AppServerClient::connect_local(
    LocalSessionConfig::app_server("/absolute/path/to/codex"),
).await?;

let models = client.request(
    "model/list",
    json!({ "limit": 20, "includeHidden": false }),
).await?;

println!("{}", models.value);
client.close().await?;
# Ok(())
# }
```

`request` is the raw escape hatch during typed facade construction. Its result
contains the local revision that was already committed before the awaiting
caller resumed. UI consumers should use `observe()` as an invalidation signal
and reread `snapshot()`; the signal stream is not an event journal.

Local sessions use a bounded `ReconnectPolicy`. Only physical transport loss
reconnects; malformed protocol/schema/canonical input seals the session. A
request whose write attempt began is completed locally with
`IndeterminateRequest` and is never replayed on the new physical connection.
The successful connection receives a new epoch, so old pending server-request
identities cannot be resolved against it.

Durable follow-ups use the typed thread queue instead of a client-only list:

```rust
# async fn queue(thread: &codex_app_server_sdk::CodexThread) -> Result<(), Box<dyn std::error::Error>> {
use codex_app_server_sdk::CodexInput;

let queued = thread
    .queue_add(
        vec![CodexInput::text("Run this after the active turn")],
        "stable-client-message-id".to_owned(),
    )
    .await?;
let page = thread.queue_list(None, Some(50)).await?;
thread
    .queue_update(&queued.id, vec![CodexInput::text("Updated follow-up")])
    .await?;
thread
    .queue_reorder(page.data.iter().map(|item| item.id.clone()).collect())
    .await?;
# Ok(())
# }
```

The SDK also exposes `queue_delete` and `queue_start`. Queue identities and
input arrays are generated-schema validated on every response.

Thread goals use stable SDK-owned types and are committed into canonical state
before the typed method returns. Future status strings and goal fields remain
available losslessly:

```rust
use codex_app_server_sdk::{CodexThread, SetGoalOptions, ThreadGoalStatus};

# async fn goals(thread: &CodexThread) -> Result<(), Box<dyn std::error::Error>> {
let goal = thread
    .set_goal(SetGoalOptions {
        objective: Some("Ship the Rust parity slice".to_owned()),
        status: Some(ThreadGoalStatus::Active),
        token_budget: Some(32_000),
    })
    .await?;
println!("{}: {}", goal.status.as_raw(), goal.objective);

let current = thread.get_goal().await?;
assert!(current.is_some());
thread.clear_goal().await?;
# Ok(())
# }
```

Every pending server request is keyed by `(connection epoch, JSON-RPC id)`.
Resolve that exact key once with `resolve_server_request`. Production hosts must
eventually provide explicit policy or UI for every request family documented in
[approvals and user input](../sdk/approvals-and-input.md).

Keep a semantic `ThreadLease` alive while a thread is selected, running,
hydrating history, awaiting interaction, or retained for a host operation:

```rust
use codex_app_server_lease::LeaseReason;
use codex_app_server_state::ThreadId;

# async fn retain(client: &codex_app_server_client::AppServerClient) -> Result<(), Box<dyn std::error::Error>> {
let lease = client
    .acquire_thread(ThreadId::from("thread-id"), LeaseReason::Selected)
    .await?;

// Observe or operate on the thread.

lease.close().await?;
# Ok(())
# }
```

The actor owns `thread/resume` and `thread/unsubscribe` control requests,
suppresses stale operation completions, and restores retained threads in
semantic priority order on a new connection epoch. Dropping a lease only
enqueues best-effort release; explicit `close()` is the deterministic path.

For a thread that declares `historyMode: "paginated"`, use
`resume_thread_paginated`. It validates the resume and page responses against
the generated schema, holds a history lease, rejects cursor loops and malformed
continuations, and submits one atomic canonical installation only after every
durable page completes:

```rust
use codex_app_server_sdk::PaginatedResumeOptions;
use codex_app_server_state::ThreadId;

# async fn history(codex: &codex_app_server_sdk::Codex) -> Result<(), Box<dyn std::error::Error>> {
let thread = codex
    .resume_thread_paginated(
        ThreadId::from("thread-id"),
        PaginatedResumeOptions::default(),
    )
    .await?;
thread.close().await?;
# Ok(())
# }
```

Navigation hosts that can encounter either history mode should call
`resume_thread_hydrated`. It performs a typed `thread/read`, follows the
server-declared mode, installs legacy resume history atomically, and delegates
paginated history to the cut/page coordinator:

```rust
use codex_app_server_sdk::PaginatedResumeOptions;
use codex_app_server_state::ThreadId;

# async fn open(codex: &codex_app_server_sdk::Codex) -> Result<(), Box<dyn std::error::Error>> {
let thread = codex
    .resume_thread_hydrated(
        ThreadId::from("thread-id"),
        PaginatedResumeOptions::default(),
    )
    .await?;
# thread.close().await?;
# Ok(())
# }
```

Run the live authenticated smoke test on the GCP host with:

```bash
CODEX_BINARY=/usr/local/bin/codex \
  cargo test -p codex-app-server-client --test live_client -- --ignored
```

The exact runtime remains `Tools/UPSTREAM_VERSION`; Rust schema drift is checked
by the same protocol workflow as Swift.

The ordered client validates the runtime version reported by `initialize`.
Official App Server user agents must remain on the generated major/minor line
and meet its patch floor; for this tree that means `0.148.0` or a newer
`0.148.x` patch.

Authentication is an App Server lifecycle, not an SDK-owned credential file
policy. Read account state with `Codex::account`; start API-key, browser OAuth,
or device-code login with `Codex::login`; cancel with `cancel_login`; and remove
credentials with `logout`. Browser/device challenges preserve the exact
`login_id` required by later completion/cancellation notifications.

## Run the GPUI reference host bootstrap

The native host runs real multi-turn prompts through terminal canonical state,
supports native composer submissions, active-turn steering, and exact-turn
interruption, displays typed
pending approval cards, and preserves exact request identity when routing
approve/decline intent:

```bash
CODEX_BINARY=/absolute/path/to/codex \
  cargo run -p codex-gpui-app -- \
  --cwd /path/to/workspace \
  --prompt "Summarize this project without changing files."
```

Reference-host threads are persisted by default so durable follow-ups and task
navigation work. Use `--ephemeral` for a disposable thread. A headless mode
exercises the same SDK/session/projection driver without a display:

```bash
CODEX_BINARY=/absolute/path/to/codex \
  cargo run -p codex-gpui-app -- --headless
```

Add `--queue "follow-up"` in headless mode to inject a durable active-turn
follow-up and verify automatic one-at-a-time queue draining.

Advertised-choice, free-form, custom, and secret user questions can be answered
inline. MCP primitive schema forms and URL-mode opening are supported; nested
or compound schemas remain visibly blocked rather than receiving synthesized
answers.

## Remote and Unix-socket sessions

Use the same SDK over an authenticated WebSocket by selecting the transport in
`SessionConfig`; the bearer value is used only for the HTTP upgrade and is
redacted from `Debug` output:

```rust
use codex_app_server_client::SessionConfig;
use codex_app_server_transport::{
    FrameConnectionConfig, TransportLimits, WebSocketConnectConfig,
};

# async fn remote() -> Result<(), Box<dyn std::error::Error>> {
let config = SessionConfig::for_transport(FrameConnectionConfig::WebSocket(
    WebSocketConnectConfig {
        url: "wss://codex-host.example/app-server".to_owned(),
        bearer_token: Some("secret-from-keychain".to_owned()),
        limits: TransportLimits::default(),
    },
));
let codex = codex_app_server_sdk::Codex::connect(config).await?;
codex.close().await?;
# Ok(())
# }
```

On Unix, `FrameConnectionConfig::UnixWebSocket` uses the same WebSocket message
contract over a domain socket. App Server remote transport remains experimental;
use TLS and authentication for every non-loopback endpoint.
