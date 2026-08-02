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
  uninstall, plugin-enable, and skill-enable controls. The richer plugin UI can
  use the general app-model entry point for marketplace and sharing flows.

Catalog refresh also hydrates `app/list`, `app/installed`, `plugin/installed`,
`hooks/list`, and layered `config/read` state. The existing plugin, skill, and
MCP summary projections remain presentation models; they are not protocol
owners.

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
uses `skills/config/write`. MCP configuration changes should be followed by
`config/mcpServer/reload` only after the write succeeds.

Generated protocol files are pinned to the runtime in `Tools/UPSTREAM_VERSION`.
If a future runtime lacks one of these methods, follow
`docs/contributing/protocol-upgrades.md`; never edit generated requests or
schema types by hand.
