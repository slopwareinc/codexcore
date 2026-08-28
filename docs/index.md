# CodexCore documentation

Use this page as the stable router. Pages are organized by task, not by source directory.

## Start

- [Requirements](getting-started/requirements.md)
- [Run the reference app](getting-started/run-the-app.md)
- [SDK quick start](getting-started/sdk-quickstart.md)
- [Authentication and isolated state](getting-started/authentication.md)
- [Troubleshooting](getting-started/troubleshooting.md)

## Build with CodexCore

- [Threads and turns](sdk/threads-and-turns.md)
- [Recursive thread graphs](sdk/thread-graphs.md)
- [Observe canonical state](sdk/observing-state.md)
- [Approvals and user input](sdk/approvals-and-input.md)
- [Dynamic tools](sdk/dynamic-tools.md)

## Embed CodexCoreUI

- [Embedding guide](ui/embedding.md)
- [Activity presentation](ui/live-activity.md)
- [Custom tool cards](ui/custom-tool-cards.md)
- [Theming and host boundaries](ui/theming-and-hosts.md)
- [Design tokens and Liquid Glass](ui/design-tokens.md)

## Use the app

- [App tour and workflows](app/using-the-app.md)
- [Tools, diff previews, and worktrees](app/tools-and-worktrees.md)

## Understand and contribute

- [Architecture overview](architecture/overview.md)
- [Workspace tabs own panel lifecycle](adr/0001-workspace-tabs-own-panel-lifecycle.md)
- [Integration control-plane seams](architecture/integration-control-plane.md)
- [Configuration reference](reference/configuration.md)
- [Runtime compatibility](reference/runtime-compatibility.md)
- [Products and module boundaries](reference/products.md)
- [Support status](reference/support-status.md)
- [Development](contributing/development.md)
- [Protocol upgrades](contributing/protocol-upgrades.md)
- [Documentation conventions](contributing/documentation.md)

## Internal research

Files marked **Historical engineering note** are evidence or superseded design proposals, not stable product documentation. They are intentionally excluded from the primary reading path.

- [Workspace tab and panel oracle](performance/workspace-panel-oracle.md)

## For agents

Read only the pages needed for the task. Source-of-truth routing:

| Question | Read |
| --- | --- |
| Supported runtime | `Tools/UPSTREAM_VERSION` |
| Package/platform requirements | `Package.swift` |
| Public SDK lifecycle | `Sources/CodexCore/Client/Codex.swift`, `CodexTurnLease.swift` |
| Canonical state | `Sources/CodexCore/StateEngine/` |
| UI composition | `Sources/CodexCoreUI/CodexChatWorkspace.swift` |
| Reference host wiring | `Sources/CodexCoreApp/CodexCoreAppModel.swift` |
| Generated methods and types | `Sources/CodexCore/Generated/`, `CodexSessionCommands.swift` |
| Build/test commands | `justfile`, `CONTRIBUTING.md` |
| Design tokens, glass, themes | `docs/ui/design-tokens.md`, `Sources/CodexCoreUI/CodexTheme.swift`, `CodexGlass.swift`, `CodexThemePresets.swift` |

Do not infer current API shape from historical plans when production source or tests disagree.
