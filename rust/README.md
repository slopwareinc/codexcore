# CodexCore for Rust

The Rust workspace is the portable foundation for a Codex App Server SDK and
the GPUI component framework/reference client tracked by issue #224.

The workspace follows the same ownership rule as the Swift runtime: one
ordered session owner reduces app-server frames into canonical state, while
UI projections are disposable readers. GPUI does not own protocol truth.

Initial crates:

- `codex-app-server-adapter`: generated-validation-first mapping into canonical
  mutations with lossless unknown notification fallback.
- `codex-app-server-client`: single-owner handshake, correlation, observations,
  and server-request inbox.
- `codex-app-server-lease`: semantic thread retention and reconnect
  reconciliation state machine.
- `codex-app-server-sdk`: ergonomic input, thread, turn, steer, interrupt, and
  owned-lease facade.
- `codex-app-server-history`: cut-based, cursor-guarded paginated history
  reconciliation with bounded item-page concurrency.
- `codex-app-server-interaction`: typed approvals, questions, MCP elicitation,
  dynamic-tool, auth, attestation, time, and legacy request models.
- `codex-app-server-wire`: lossless JSON-RPC envelopes and runtime pin.
- `codex-app-server-transport`: bounded stdio, TCP/TLS WebSocket, and
  WebSocket-over-Unix-socket primitives.
- `codex-app-server-types`: generated v2 request, response, notification, and
  item types from the exact CLI schema.
- `codex-app-server-state`: framework-neutral canonical identities.

Run the foundation checks with:

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace --locked
```

See [the architecture guide](../docs/architecture/rust-gpui-platform.md) for
the planned crate graph and host boundaries.
