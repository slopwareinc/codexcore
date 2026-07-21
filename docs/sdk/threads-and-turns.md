# Threads and turns

CodexCore exposes lifecycle-sensitive operations through leases instead of free-floating identifiers.

## Start or resume a thread

```swift
let thread = try await codex.startThread(.init(cwd: workspacePath))

let resumed = try await codex.resumeThread(.init(
    threadID: existingThreadID
))
```

Keep the lease alive while the thread is selected, observed, running, awaiting input, or otherwise required by the host. Call `close()` when that reason ends.

## Start and await a turn

```swift
let turn = try await thread.startTurn(.init(
    input: [CodexSchemaUserInput(.dictionary([
        "type": .string("text"),
        "text": .string(prompt),
    ]))],
    threadID: thread.id.rawValue
))

let terminal = try await turn.awaitTerminal(timeout: .seconds(600))
```

`runTurn` combines these steps. The returned `CodexTerminalTurn` is one atomic canonical projection containing the terminal turn and its items.

## Control an active turn

- `interrupt()` requests termination.
- `steer(...)` adds instruction to the exact active turn.
- `attachTurn(...)` creates a truthless handle backed by the existing thread lease for a known canonical turn; it is not an additional retention lease.
- `snapshot(...)` reads current canonical state.
- `observe(...)` returns an atomic seed followed by coalesced invalidation signals.

Lease methods validate composite identities. A turn ID cannot be accidentally used with another thread.

## History modes

The server owns each thread's declared `legacy` or `paginated` history mode; a new thread with no requested mode uses the server declaration. Resume supports both modes and paginated resume backfills history. Paginated fork is explicitly unsupported. A missing or unknown declared mode is a protocol violation—never infer it from cursors or migrate an existing thread from a new-chat preference.
