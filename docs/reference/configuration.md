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

## Task model settings

Model identity, service tier, and reasoning effort are independent app-server settings. Build model and tier choices from `model/list`: only send an advertised tier ID, omit `serviceTier` for Standard, and preserve the model ID when changing speed. `ReasoningEffort.max` encodes the server value `max`.

## Composer permission profiles

The reference app sends the selected app-server permission profile through the
generated `permissions` field when starting a thread, forking, or starting a
turn. Read only, workspace, and full access use the corresponding built-in
profile IDs and the official approval-policy/reviewer tuple. Sandbox fields stay
unset because the profile remains authoritative.

Resuming an existing thread does not send ambient composer permissions. The
resume response hydrates the composer from that thread’s active profile without
replacing the safe new-thread selection. Leaving the thread restores that
selection, and Voice-created threads use it rather than inheriting the active
thread’s profile.
Custom omits profile, approval, reviewer, and sandbox overrides so the
authoritative `config.toml` values apply for a new or config-backed thread. Once
an active thread has an explicit profile, Custom is unavailable because omitting
`permissions` does not reset the thread to config defaults. Preparing a turn or
fork does not change this UI state; a successful main-thread turn or an
authoritative fork response performs the transition.

Selecting Full access from either the composer or Settings requires an explicit
destructive confirmation. Follow-up issue #175 tracks richer persistent warning
and lifecycle affordances. Fresh and reset configuration sessions default to Ask
for approval and catalog reconciliation never promotes them to Full access.

Permission profile selection is resolved from in-memory composer state with a
fixed constant-time mapping. Submitting a prompt does not refresh or decode the
profile catalog and does not add an app-server request.
