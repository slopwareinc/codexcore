# Troubleshooting

## Runtime not found or version mismatch

CodexCore resolves the runtime in this order: `CodexConfig.codexBinaryPath`, the selected home's `[codexcore].codex_binary_path`, `CODEX_BINARY`, `CODEX_BIN`, `codex` on `PATH`, then Codex app bundles. `codex --version` checks only the PATH candidate, so inspect `~/.codexcore/config.toml` when the error names another path. The current SDK accepts `codex-cli` 0.148.x through 0.149.x; exact 0.149.0 matches the generated types, while other accepted versions produce a warning. Generated project and Bedrock request factories require 0.149.0 or newer. Do not suppress the check.

## The app asks me to sign in again

Expected. `~/.codexcore` is isolated from `~/.codex`. Authenticate within the reference app or selected custom home.

## A turn waits forever

Inspect the server-request inbox. The app-server may be waiting for command approval, file approval, permissions, user input, MCP elicitation, or a dynamic-tool result. A host that returns `.pending` must later resolve the exact request key.

## Voice starts but no audio plays

The reference app writes detailed Voice diagnostics to
`~/Library/Logs/CodexCore/voice.jsonl`. The log includes session lifecycle, complete
SDP offers and answers, WebRTC state, remote-track and audio-element events,
inbound RTP statistics, protocol errors, and the complete transcript text.
If macOS denies direct Library log creation, the app falls back to
`$TMPDIR/CodexCore/voice.jsonl`; `session.start.requested` records the resolved
`logFile` path in unified logging.

```bash
tail -f ~/Library/Logs/CodexCore/voice.jsonl
```

The same records are available through unified logging under subsystem
`com.slopware.codexcore` and category `voice`. Voice logs rotate at 25 MiB to
`voice.jsonl.previous`. Because transcript and SDP fields are intentionally
unredacted, review the file before sharing it.

## Paginated thread operations fail

In Codex `0.148.0`, paginated threads support fork, `thread/read(includeTurns: true)`, and durable history replacement through `thread/revert`. The legacy `thread/rollback` method remains a separate full-history operation. Existing threads retain their server-declared history mode.

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
