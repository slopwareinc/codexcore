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

## Run the GPUI reference host bootstrap

The native host currently runs one real prompt from start through terminal
canonical state, displays typed pending approval cards, and preserves exact
request identity when routing approve/decline intent:

```bash
CODEX_BINARY=/absolute/path/to/codex \
  cargo run -p codex-gpui-app -- \
  --cwd /path/to/workspace \
  --prompt "Summarize this project without changing files."
```

Use `--persist` to keep the thread; the safer default is ephemeral. A headless
mode exercises the same SDK/session/projection driver without a display:

```bash
CODEX_BINARY=/absolute/path/to/codex \
  cargo run -p codex-gpui-app -- --headless
```

User-input and MCP form editors are still pending. The host never synthesizes
answers for those requests; they remain visibly pending.

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
