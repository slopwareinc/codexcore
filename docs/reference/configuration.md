# Configuration reference

`CodexConfig` describes one app-server process/session boundary.

| Field | Purpose |
| --- | --- |
| `codexHome` | Isolated authentication, configuration, and runtime state root. |
| `codexBinaryPath` | Exact executable path; highest runtime precedence. |
| `launchArgumentsOverride` | Advanced replacement for normal app-server arguments. |
| `configOverrides` | `--config key=value` overrides; credential-store isolation remains enforced. |
| `cwd` | Default working directory. |
| `environment` | Additional child-process environment only. It is not consulted during runtime discovery; `CODEX_HOME` is overwritten from `codexHome`. |
| `clientName`, `clientTitle`, `clientVersion` | Initialize-time host identity. |
| `capabilities` | Initialize capabilities. Experimental API is always enabled. |
| `reconnectPolicy` | Bounded session reconnection behavior. |
| `maximumBufferedHandshakeFrames` | Defensive handshake buffer bound. |
| `maximumRetainedLoginCompletions` | Bound for login-operation completion retention. |

## Runtime discovery

Resolution order is explicit `codexBinaryPath`, `[codexcore].codex_binary_path` in the selected CodexCore home, process `CODEX_BINARY`, `CODEX_BIN`, PATH `codex`, explicit app-bundle variables, then installed app candidates. `CodexHome.default` is always `~/.codexcore`; a parent-process `CODEX_HOME` is ignored. Runtime identity is preflight checked with `--version`.

## SDK process environment variables

| Variable | Meaning |
| --- | --- |
| `CODEX_BINARY` | Preferred runtime override. |
| `CODEX_BIN` | Alternate runtime override. |
| `CODEX_APP_BUNDLE` | Candidate Codex application bundle. |
| `CODEX_APP_BUNDLE_PATH` | Alternate application bundle path. |

Do not set `CODEX_HOME` expecting it to replace `CodexConfig.codexHome`; the SDK injects the selected home deliberately.

`TRACE_DURATION` is a developer `just trace` option, not an SDK runtime-discovery variable. `launchArgumentsOverride` replaces normal app-server arguments but does not bypass the forced credential-store isolation override.
