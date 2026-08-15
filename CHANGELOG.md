# Changelog

## 0.10.0 — 2026-08-15

Tag: `v0.147.0+codexcore.0.10.0`

### Highlights

- Upgraded the generated protocol and runtime contract to stable `codex-cli 0.147.0`, including typed plugin search, thread sections and ordering, current plugin metadata, MCP status/auth updates, and the remaining upstream schema changes.
- Rebuilt plugin management around server-authoritative Browse and Manage surfaces for plugins, skills, apps, MCP servers, and marketplaces. Catalogs load independently, protocol artwork is preserved, and enable, disable, install, uninstall, upgrade, and OAuth actions use the integration control plane.
- Expanded the native workspace with a Git review workbench, structured code review, worktree handoff, file previews, response annotations, voice dictation and realtime Voice tasks, and local automations.
- Refined subagent presentation with eagerly hydrated names, live lifecycle state, terminal-status authority, focused read-only transcripts, and a simpler child panel without a redundant composer or parent-chat control.
- Added theme-aligned app icons, deeper dark palettes, a darker sidebar, and broader Liquid Glass token coverage.

### Reliability and performance

- Project and recent-chat discovery now hydrates the sidebar before slower plugin, app, MCP, skill, configuration, account, and rate-limit inventories finish in the background.
- Fixed transcript diffable-update synchronization so width reflow cannot be mistaken for a broad streaming reload.
- Fixed transport shutdown hangs, stale subagent state regressions, optimistic-message ordering, and integration mutation pending-state behavior.
- Removed repository-level SwiftPM job caps; local builds and tests use SwiftPM's normal concurrency unless the caller explicitly chooses otherwise.

### Compatibility and distribution

- Requires `codex-cli 0.147.0` or a newer patch on the `0.147` protocol line. Protocol bindings were generated from exact stable `0.147.0`.
- Full reads and forks support paginated threads. Paginated rollback remains unsupported by the upstream runtime.
- Removed Sparkle and the in-app updater completely. This release is published as source and an annotated tag only; no prebuilt app binary is attached.

