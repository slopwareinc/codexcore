# CodexCore for Rust

The Rust workspace is the portable foundation for a Codex App Server SDK and
the GPUI component framework/reference client tracked by issue #224.

The workspace follows the same ownership rule as the Swift runtime: one
ordered session owner reduces app-server frames into canonical state, while
UI projections are disposable readers. GPUI does not own protocol truth.

Initial crates:

- `codex-app-server-wire`: lossless JSON-RPC envelopes and runtime pin.
- `codex-app-server-transport`: bounded frame transport primitives.
- `codex-app-server-state`: framework-neutral canonical identities.

Run the foundation checks with:

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace --locked
```

See [the architecture guide](../docs/architecture/rust-gpui-platform.md) for
the planned crate graph and host boundaries.
