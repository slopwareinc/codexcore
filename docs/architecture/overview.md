# Architecture overview

CodexCore has one ordered runtime owner and many disposable readers.

```text
Codex facade
  → CodexFrameTransport
  → CodexSession actor
       ├─ request correlation
       ├─ server-request inbox
       ├─ thread runtime and lease reconciliation
       ├─ protocol adaptation
       └─ canonical reduction
            → canonical replica
            → scoped observations
            → presentation projections
                 → CodexCoreUI / host UI
```

The default `Codex` facade launches the exact pinned app-server over stdio. `CodexSession` itself is transport-agnostic and can use custom transports, including WebSocket implementations.

## Invariants

1. `CodexSession` is the sole ordered runtime coordinator.
2. Generated app-server models are the production wire representation.
3. Canonical state contains server facts and explicit local submission intent, not UI choices.
4. Observations deliver a snapshot seed plus invalidation signals, not an event journal.
5. Thread IDs are scalar; turn and item identities are composite. Leases control thread subscription and retention.
6. Ambiguous mutations are not blindly replayed after connection loss.
7. Projections may be dropped and rebuilt from canonical state.

## Read next

- `Sources/CodexCore/Client/CodexSession.swift` for production coordination.
- `Sources/CodexCore/Session/ThreadLeaseRegistry.swift` for lease reconciliation.
- `Sources/CodexCore/Session/PaginatedHistoryCoordinator.swift` for cut-and-buffer history hydration.
- `Tests/CodexCoreTests/` for executable behavior.

Historical design notes may describe target or superseded states. Production source and tests win when they disagree.
