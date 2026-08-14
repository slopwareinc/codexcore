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

The composer exposes the same three choices as Codex Desktop: Ask for approval,
Approve for me, and Full access. The reference app sends the selected app-server
permission profile through the generated `permissions` field when starting a
thread, forking, or starting a turn. Sandbox fields stay unset because the
profile remains authoritative. The legacy `guardian_subagent` reviewer hydrates
as Approve for me.

Resuming an existing thread does not send ambient composer permissions. The
resume response hydrates the composer from that thread’s active profile without
replacing the safe new-thread selection. Leaving the thread restores that
selection, and Voice-created threads use it rather than inheriting the active
thread’s profile.
Read-only and custom profiles remain representable when an existing task or
managed installation reports them, but they are not selectable composer modes.
Preparing a turn or fork does not change the active UI state; a successful
main-thread turn or an authoritative fork response performs the transition.

Selecting Full access from either the composer or Settings requires an explicit
destructive confirmation. Follow-up issue #175 tracks richer persistent warning
and lifecycle affordances. Fresh and reset configuration sessions default to Ask
for approval and catalog reconciliation never promotes them to Full access.

Permission profile selection is resolved from in-memory composer state with a
fixed constant-time mapping. Submitting a prompt does not refresh or decode the
profile catalog and does not add an app-server request.

## Trusted agent instructions

The `CodexCoreUI` settings routes include an Agent instructions inspector for
the `AGENTS.md` files trusted by the current workspace. Resolution starts with
`$CODEX_HOME/AGENTS.md`, then applies project documents from the repository root
toward the working directory; later rows have higher precedence. Each row shows
the server-side path, original byte size, and whether the shared project byte
budget truncated its content.

Hosts inject `CodexAgentsDocumentStore`, the selected Codex home, and the active
working directory into `CodexSettingsAboutRouteView`. The store uses app-server
filesystem requests, so paths remain in the connected host's namespace. The
global editor also saves through `fs/writeFile` rather than local
`FileManager` access.

`CodexAgentsDocumentPolicy` models the upstream `project_doc_max_bytes`,
`project_doc_fallback_filenames`, and `project_root_markers` settings. Until a
host projects those config values into the UI, defaults are a 32 KiB shared
project-document budget, no fallback filenames, and `.git` as the root marker.

## Prompt library and slash commands

`CodexPromptLibrary` reads Markdown files from `$CODEX_HOME/prompts` through the
app-server filesystem. It recognizes `description` and `argument-hint` YAML
front matter and bounds discovery to 256 files and 256 KiB per file. User and
MCP prompt entries can be converted to palette items with
`CodexSlashCommand.promptCommands(from:)`, or merged with built-ins and skills
using `mergedCommands(prompts:skillsResponse:)`.

The built-in palette includes `/init`, `/review`, `/new`, and `/feedback` in
addition to the previously observed commands. Skills marked
`disable-model-invocation` are excluded from generated slash commands.
