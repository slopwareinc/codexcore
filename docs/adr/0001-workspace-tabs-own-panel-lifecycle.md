# Workspace tabs own panel lifecycle

CodexCoreUI will route Plan, Review, Files, Subagents, Terminal, Browser, artifacts,
Sources, MCP apps, and later workspace surfaces through one deep workspace-tab module.
The module owns identity, preview and pin behavior, ordering, selection, close fallback,
panel movement, durable routes, lazy restoration, per-tab state, and heavy-host retention;
feature adapters own only resource-specific behavior. This replaces feature-specific tab
arrays and magic IDs, keeps panel mutations out of transcript projection, and lets Summary
and New Tab open the same projected thread resources without duplicating lifecycle logic.

## Consequences

- Panel topology and tab routes are presentation state, never canonical protocol state.
- Heavy processes and views are retained by feature adapters according to explicit policy,
  not by transient SwiftUI view lifetime.
- A new workspace surface must register an adapter instead of extending a central content
  switch and fallback chain.
- Preview tabs are intentionally non-durable; restoration remains lazy and availability-
  checked.
