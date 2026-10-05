# Observe canonical state

CodexCore maintains a normalized local replica of app-server facts. UI state does not belong in that replica.

## Snapshot

```swift
let snapshot = try await turn.snapshot(fields: [
    .turnStatus,
    .itemStructure,
    .itemLifecycle,
    .itemContent,
])
```

Select fields to filter which revisions wake the observer. Field masks do not produce partial snapshots or reduce projection work; entity scope narrows collections.

## Observe

```swift
let observation = try await turn.observe(fields: [
    .turnStatus,
    .itemStructure,
    .itemContent,
])

render(observation.seed)

for await _ in observation.signals {
    let current = try await turn.snapshot(fields: [
        .turnStatus,
        .itemStructure,
        .itemContent,
    ])
    render(current)
}

await turn.cancel(observation)
```

Signals are coalesced with newest-one buffering and carry the latest revision. They mean “re-read current state,” not “replay this event”; slow observers do not receive an event journal.

## Ownership model

```text
app-server frames
  → protocol adapter
  → canonical reducer
  → revisioned canonical replica
  → scoped observations
  → disposable projections
  → host presentation state
```

Keep scroll position, drafts, selection, expansion, and other UI choices in MainActor-owned presentation state.

## Ordered operation streams

Realtime audio and transcript events are ordered data rather than snapshot invalidations. Each realtime observation buffers up to 2,048 events. If a consumer falls behind that bound, the stream throws and ends; restart the operation instead of continuing with missing deltas. Command output and filesystem change streams likewise report overflow rather than silently losing ordered data.

External-agent imports receive their ID from the server. Register
`observeExternalAgentConfigImport(importID: nil)` before the import request,
retain early events, then match the response's import ID. This connection-wide
stream remains open across completed imports and buffers 256 events. Overflow
throws `CodexExternalAgentConfigImportObserverError.bufferOverflow`; reconcile
with import history instead of assuming success. Disconnect seals the original
epoch. An observer for a known import ID finishes after that import completes.
