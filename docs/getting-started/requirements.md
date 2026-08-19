# Requirements

## Supported toolchain

- macOS 26 or newer
- Xcode toolchain with Swift 6.2
- Git
- Python 3 (generator tests)
- Bash and `curl`/`tar` (runtime regeneration and drift tooling)
- `codex-cli 0.148.0` or a newer patch (types generated from stable `0.148.0`)
- `just` is optional

The package declares the authoritative platform and language versions in `Package.swift`. Runtime identity is pinned in `Tools/UPSTREAM_VERSION` and validated before the SDK launches app-server.

## Verify your environment

```bash
swift --version
codex --version
```

The second command checks only the `codex` executable selected by `PATH` and must print `codex-cli 0.148.0` or a newer patch:

```text
codex-cli 0.148.0
```

CodexCore rejects anything below the `0.148.0` floor or outside the generated major/minor line. A newer patch is accepted and reported as a warning. An explicit SDK or home-config pin can select a different binary than `codex --version`; check the discovery order below when a mismatch reports another path.

## Runtime discovery order

1. `CodexConfig.codexBinaryPath`
2. `[codexcore].codex_binary_path` in the selected CodexCore home
3. `CODEX_BINARY`
4. `CODEX_BIN`
5. `codex` on `PATH`
6. app bundles from `CODEX_APP_BUNDLE` or `CODEX_APP_BUNDLE_PATH`
7. installed Codex application candidates

Prefer an explicit `codexBinaryPath` in tests and reproducible development environments.
