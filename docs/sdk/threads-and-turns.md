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
- `steerTurn(...)` is the thread-scoped recovery form: it steers the supplied `expectedTurnID` and returns a lease for the server-confirmed turn.
- `attachTurn(...)` creates a truthless handle backed by the existing thread lease for a known canonical turn; it is not an additional retention lease.
- `snapshot(...)` reads current canonical state.
- `observe(...)` returns an atomic seed followed by coalesced invalidation signals.

Lease methods validate composite identities. A turn ID cannot be accidentally used with another thread.

## Observe realtime Voice events

Realtime transcript and audio notifications are ephemeral and intentionally do
not become canonical `ThreadItem`s. Register the thread-scoped stream before
starting realtime so the startup notification cannot race the observer:

```swift
let events = try await codex.session.observeRealtimeEvents(
    threadID: thread.id.rawValue
)

try await codex.threadRealtimeStart(.init(
    includeStartupContext: true,
    outputModality: .audio,
    threadID: thread.id.rawValue,
    version: .v3
))

for try await event in events {
    switch event {
    case .transcriptDone(let value):
        print(value.role, value.text)
    case .outputAudio(let value):
        playPCM16(value.audio)
    default:
        break
    }
}
```

Input and output chunks are base64-encoded PCM16 with explicit sample rate and
channel metadata. The stream ends when its connection is sealed or its consumer
is cancelled.

Interactive clients should serialize steer submissions. Send one `turn/steer` with the cached active turn ID and no read or polling call. If `classifyCodexTurnSteerRace(_:)` returns `.expectedTurnMismatch`, retry `steerTurn(...)` once with the server-reported ID. If it returns `.noActiveTurn`, immediately send the same input with `turn/start`. Other failures remain ordinary failures. Keep local queue draining blocked until that sequence resolves.

CodexCore registers the submission intent before writing either request. The echoed user item can therefore reconcile by `clientUserMessageId` even if its notification arrives before the RPC response. A successful steer stays inside the existing turn and does not produce another `turn/started` event.

## History modes

The server owns each thread's declared `legacy` or `paginated` history mode; a new thread with no requested mode uses the server declaration. Resume supports both modes and paginated resume backfills history. Paginated fork is explicitly unsupported. A missing or unknown declared mode is a protocol violation—never infer it from cursors or migrate an existing thread from a new-chat preference.
