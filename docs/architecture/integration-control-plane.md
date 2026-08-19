# Integration control-plane seams

The reference host routes Plugins, Skills, Apps, MCP, hooks, marketplace, and
sharing operations through `CodexIntegrationControlPlaneRequest`. UI code must
not call `Codex.perform` or construct JSON-RPC methods directly.

## Host contract

- `CodexAppServerIntegrationControlPlaneProvider` is the production adapter.
- `CodexIntegrationControlPlaneProvider` is the test seam. Mocks receive the
  typed request and return the encoded app-server response.
- `CodexIntegrationControlPlaneSession` records per-surface loading/error state
  and retains successful responses by exact method name. Apps list and
  installed-app responses therefore remain distinct.
- `CodexCoreAppModel.performIntegrationControlPlaneRequest(_:)` is the app-level
  entry point for detail panes and confirmed mutations.
- `CodexAppServerPluginCatalogActionProvider` wires the existing install,
  uninstall, plugin-enable, skill-enable, and personal-skill removal controls
  directly to `Codex`. `CodexIntegrationControlPlanePluginCatalogActionProvider`
  exposes the same catalog action seam through a host-supplied control-plane
  provider. The richer plugin UI can use the general app-model entry point for
  marketplace and sharing flows.

Catalog refresh also hydrates `app/list`, `app/installed`, `plugin/installed`,
`hooks/list`, and layered `config/read` state. The existing plugin, skill, and
MCP summary projections remain presentation models; they are not protocol
owners.

`CodexPluginRouteView` and `CodexMCPStatusSheet` accept an optional
`CodexIntegrationControlPlaneProvider`. Hosts supply the connected
`CodexAppServerIntegrationControlPlaneProvider` to enable direct marketplace,
skill-read, MCP mutation, and MCP authentication controls. Omitting it leaves
mutation controls disabled while previews and disconnected gallery fixtures
remain usable.

## Permission and loading boundaries

Every request declares its surface and, where relevant, a
`CodexIntegrationPermissionBoundary`. OAuth login, MCP resource reads and tool
calls, configuration writes, plugin/marketplace/share mutations, and skill
configuration writes must pass through host confirmation or permission UI
before execution. App-server policy remains authoritative and may still reject
an allowed request.

Use `CodexIntegrationControlPlanePhase` to render idle, loading, loaded, failed,
and permission-required states. Do not infer permission denial from an empty
response, and do not clear a previous successful response merely because a
later refresh failed.

## Configuration-backed operations

Hooks configuration and other control-plane settings use generated
`config/read`, `config/value/write`, and `config/batchWrite` parameters. Plugin
enabled state is written at `plugins.<plugin-name>.enabled`; skill enabled state
uses `skills/config/write`, while removal of a personal skill uses `fs/remove`
behind the skill-configuration permission boundary. MCP configuration changes
should be followed by `config/mcpServer/reload` only after the write succeeds.

Generated protocol files are pinned to the runtime in `Tools/UPSTREAM_VERSION`.
If a future runtime lacks one of these methods, follow
`docs/contributing/protocol-upgrades.md`; never edit generated requests or
schema types by hand.

## MCP management contract

`CodexMCPServerConfiguration` is the UI-owned lossless configuration model for
both stdio and streamable HTTP transports. It includes environment passthrough,
HTTP authentication/header sources, startup and tool timeouts, allow/deny tool
lists, server-default approval, and per-tool approval. Mutations target
`mcp_servers.<name>` through generated `config/value/write` requests. A
successful write, enable toggle, or removal is immediately followed by
`config/mcpServer/reload`; a failed write must never trigger reload.

Status and configuration are separate dimensions. `enabled` comes from config;
`CodexSchemaMCPServerStartupState` comes from the canonical
`mcpServer/startupStatus/updated` stream. Unknown startup states are rendered as
unknown, never as success, and notification `failureReason` remains typed.
OAuth UI registers `observeMCPServerOAuthLogin` before issuing
`mcpServer/oauth/login`, opens the returned authorization URL, and waits for the
bounded completion observer rather than polling.

`McpServerStatus.pluginId` is authoritative ownership. A plugin-owned server may
authenticate and expose runtime inventory, but generic MCP configuration UI must
not write, toggle, or remove its `mcp_servers.<name>` entry. OAuth login exposes
the 0.148 per-attempt registration strategy: automatic discovery by default,
or explicit CIMD/DCR when troubleshooting a server's discovery behavior.

The generated `CodexSchemaConfig` currently omits `mcp_servers`, even though the
runtime accepts these keys. Therefore the host must retain the
`CodexMCPServerConfiguration` values it supplies to the sheet (including values
written during the current session); generated files are not patched locally.

## Marketplace, skill, and hook projections

Marketplace management calls `marketplace/add`, `marketplace/remove`, and
`marketplace/upgrade` directly. Installed and available versions remain
separate so the UI can label known updates while still allowing an explicit
update check when version metadata is absent.

Skill detail registers a `plugin/skill/read` request on presentation and renders
the returned body. `allowed-tools` and `disable-model-invocation` are security
metadata, not decoration: they are shown alongside the body, and skill icons use
the schema-provided small/large URLs. Personal-skill removal stays behind an
explicit destructive confirmation.

`CodexHooksCatalog` projects the resolved `hooks/list` response.
`CodexHooksListView` displays event, matcher, source attribution, trust,
handler, and blocking status. In 0.148, `HookMetadata` flattens a heterogeneous
`handlerType` union: command handlers carry `command` plus `async`, while MCP
handlers carry `server` and `tool`. Do not infer one from the other.

Resolved state writes only `hooks.state` using one upserted object keyed by the
exact protocol hook key, with `reloadUserConfig: true`. Source hook definitions
remain owned by their reported config or plugin path and are never reconstructed
from list output.
