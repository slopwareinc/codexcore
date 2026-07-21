# Troubleshooting

## Runtime not found or version mismatch

CodexCore resolves the runtime in this order: `CodexConfig.codexBinaryPath`, the selected home's `[codexcore].codex_binary_path`, `CODEX_BINARY`, `CODEX_BIN`, `codex` on `PATH`, then Codex app bundles. `codex --version` checks only the PATH candidate, so inspect `~/.codexcore/config.toml` for a stale pin when the error names another path. CodexCore requires exactly `codex-cli 0.145.0`; do not suppress the check.

## The app asks me to sign in again

Expected. `~/.codexcore` is isolated from `~/.codex`. Authenticate within the reference app or selected custom home.

## A turn waits forever

Inspect the server-request inbox. The app-server may be waiting for command approval, file approval, permissions, user input, MCP elicitation, or a dynamic-tool result. A host that returns `.pending` must later resolve the exact request key.

## Paginated thread operations fail

In Codex `0.145.0`, paginated threads still do not support rollback, fork, or `thread/read(includeTurns: true)`. These limitations come from the upstream protocol or raw request surface; CodexCore rejects known-unsafe facade operations where it can. Existing threads retain their server-declared history mode.

## Build fails in generated files

Confirm the pinned runtime, then run the generator drift check. Never patch generated files manually.

```bash
CODEX_BINARY=/absolute/path/to/codex Tools/check_drift.sh
```

## Report a bug

Include:

- CodexCore tag or commit
- `codex --version`
- macOS and Swift versions
- the smallest reproduction
- sanitized error output

Never attach `auth.json`, API keys, tokens, or unredacted app-server frames.
