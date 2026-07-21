# Authentication and isolated state

CodexCore defaults to `~/.codexcore`, not `~/.codex`.

This boundary isolates:

- `auth.json`
- `config.toml`
- threads and app-server state
- plugins and skills
- profiles and transient runtime artifacts

It also forces `cli_auth_credentials_store="file"`, keeping credentials inside the selected CodexCore home.

## Reference app login

The app supports ChatGPT device-code login and API-key login. Complete login inside the reference app; do not copy credential files between Codex homes.

## Custom home

```swift
let home = CodexHome(path: "/absolute/path/to/isolated-home")
let codex = try await Codex(config: .init(codexHome: home))
```

The path is normalized and must not resolve to `~/.codex` or any of its descendants.

## Pin a runtime in config

Inside the selected home's `config.toml`:

```toml
[codexcore]
codex_binary_path = "/absolute/path/to/codex"
```

The value must be a double-quoted absolute path. An explicit `CodexConfig.codexBinaryPath` still takes precedence.
