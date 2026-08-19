# Protocol upgrades

Protocol upgrades are exact-runtime migrations, not dependency-range bumps.

## Procedure

1. Compare the old and new official `codex-rs` tags, especially `app-server-protocol`, `app-server`, `protocol`, and `core`.
2. Obtain the exact release binary for the target platform.
3. Regenerate:

   ```bash
   CODEX_BINARY=/absolute/path/to/codex Tools/regenerate.sh
   ```

4. Audit raw aliases and handwritten server-request types. Generator output alone may not expose every union ergonomically.
5. Update protocol fixtures and compatibility documentation.
6. Verify:

   ```bash
   CODEX_BINARY=/absolute/path/to/codex Tools/check_drift.sh
   python3 -m unittest discover Tools/tests
   swift build --target CodexCoreApp
   swift test
   ```

7. Release with a composite tag such as `v0.147.0+codexcore.0.10.0`.

The generated pin (`CodexPinnedRuntime`) records the runtime the schema was
dumped from and may be a prerelease. The oldest accepted runtime is
`CodexSupportedRuntime.minimum` in `Sources/CodexCore/Client/Codex.swift`; raise
it only when the SDK starts depending on a field or method the older runtime
does not serve.

Generated output must be reproducible. A clean drift check is required before merge.
