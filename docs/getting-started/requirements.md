# Requirements

## Supported toolchain

- macOS 26 or newer
- Xcode toolchain with Swift 6.2
- Git
- Python 3 (generator tests)
- Bash and `curl`/`tar` (runtime regeneration and drift tooling)
- SDK core lifecycle: `codex-cli 0.148.x` through `0.160.x`; full reference app: `0.160.x` (types generated from stable `0.160.0`)
- `just` is optional

The package declares the authoritative platform and language versions in `Package.swift`. Runtime identity is pinned in `Tools/UPSTREAM_VERSION` and validated before the SDK launches app-server.

## Verify your environment

```bash
swift --version
codex --version
```

The second command checks only the `codex` executable selected by `PATH`. The recommended exact runtime prints:

```text
codex-cli 0.160.0
```

CodexCore rejects anything below the `0.148.0` floor, any different major version, or a minor version above `0.160`. Accepted versions that differ from `0.160.0` produce a warning. New generated features require a runtime that serves them. An explicit SDK or home-config pin can select a different binary than `codex --version`; check the discovery order below when a mismatch reports another path.

The reference app additionally requires the generated `0.160.x` feature line.
An older SDK-compatible binary produces an upgrade message before runtime
feature initialization.

## Reproducible local setup

```bash
Tools/install_runtime.sh
swift build
Tools/check_pinned_drift.sh
scripts/smoke-runtime.sh
```

The installer downloads the release in `Tools/UPSTREAM_VERSION`, checks its
SHA-256 against the official GitHub release asset digest, and stores the binary
under `.build/codexcore-tools`. It leaves installed CLI binaries and credentials
alone. Set `CODEXCORE_TOOL_CACHE` to relocate the cache. The smoke test uses a
temporary isolated home, checks the handshake, catalog, and thread lifecycle,
and starts no inference. `just setup`, `just drift`, and `just smoke` provide
shortcuts. A first installation needs network access to GitHub.

## Runtime discovery order

1. `CodexConfig.codexBinaryPath`
2. `[codexcore].codex_binary_path` in the selected CodexCore home
3. `CODEX_BINARY`
4. `CODEX_BIN`
5. `codex` on `PATH`
6. app bundles from `CODEX_APP_BUNDLE` or `CODEX_APP_BUNDLE_PATH`
7. installed Codex application candidates

Prefer an explicit `codexBinaryPath` in tests and reproducible development environments.
