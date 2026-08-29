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

Server-owned background processes are available through the same lease-scoped
session: `listBackgroundTerminals(threadID:)` refreshes the canonical process
rows, while `terminateBackgroundTerminal` and `cleanBackgroundTerminals` issue
explicit mutations. A background-terminal list page never overwrites older
pages unless it is the first page of a refresh.

For convenience builders, `CodexInput` covers text (including
`text_elements`), URL/local images with optional `CodexSchemaImageDetail`,
URL/local audio, skills, mentions, and a lossless `raw` escape hatch.

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

try await codex.threadRealtimeStart(.codexVoiceWebRTC(
    threadID: thread.id.rawValue,
    offerSDP: offer.sdp
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

Codex 0.150 also emits item-scoped `.itemStarted`, `.itemTranscriptDelta`, and
`.itemCompleted` events. Use them when reconstructing the realtime session's
typed item timeline; the older session-level transcript events remain available.

Desktop clients authenticated with ChatGPT use WebRTC: create the browser or
webview offer first, send it with `codexVoiceWebRTC`, and apply the later
`thread/realtime/sdp` event as the remote answer. Websocket clients may omit
`transport` and exchange base64 PCM16 chunks, but that transport requires its
own supported API authentication. The stream ends when its connection is sealed
or its consumer is cancelled. Enable the app-server
`features.realtime_conversation` feature in the thread's `config` overrides.
`codexVoiceWebRTC` selects the current Frameless Bidi v3 session,
`gpt-live-1-codex`, and the `sol` voice. ChatGPT-authenticated app hosts must
also initialize with `requestAttestation` and answer
`attestation/generate` with their cached DeviceCheck client attestation.

Interactive clients should serialize steer submissions. Send one `turn/steer` with the cached active turn ID and no read or polling call. If `classifyCodexTurnSteerRace(_:)` returns `.expectedTurnMismatch`, retry `steerTurn(...)` once with the server-reported ID. If it returns `.noActiveTurn`, immediately send the same input with `turn/start`. Other failures remain ordinary failures.

CodexCore registers the submission intent before writing either request. The echoed user item can therefore reconcile by `clientUserMessageId` even if its notification arrives before the RPC response. A successful steer stays inside the existing turn and does not produce another `turn/started` event.

## Durable queued turns

Stable 0.148 owns queued follow-ups through `thread/queue/*`. Add a submission
with its stable `clientUserMessageId`; app-server persists FIFO order and starts
queued turns automatically whenever the loaded thread becomes idle. Do not run
a competing client-side drain loop.

`thread/queue/changed` is a lightweight invalidation. Register the coalescing
thread-scoped stream, then reread one authoritative page (the queue is capped at
100 entries):

```swift
let changes = try await codex.session.observeThreadQueueChanges(
    threadID: thread.id.rawValue
)
for try await _ in changes {
    let queue = try await codex.perform(CodexRequest.threadQueueList(.init(
        cursor: nil,
        limit: 100,
        threadID: thread.id.rawValue
    )))
    render(queue.data)
}
```

Queue input is projected through `CodexInput(jsonValue:)`; unknown future arms
remain lossless as `.raw`.

## Thread section appearance

Section updates preserve all three wire states for appearance:

- `.omitted` preserves the current appearance;
- `.null` clears it;
- `.value(...)` replaces it.

`CodexSchemaThreadSectionUpdateParams.appearance` uses
`CodexAppServerOptionalField` so Swift callers cannot accidentally collapse
omit and null. The generator owns this type; regenerate rather than patching
the emitted schema file.

## Operation notifications

Register an operation stream before starting its request so early frames cannot
race the subscription. Streams are scoped to the current connection epoch and
terminate when their keyed operation completes or the connection is lost:

```swift
let events = try await codex.observeProcessEvents(processHandle: "shell-1")
_ = try await codex.processSpawn(.init(
    command: ["swift", "--version"],
    cwd: .string(workspacePath),
    processHandle: "shell-1"
))

for try await event in events {
    switch event {
    case .output(let delta): print(delta.stream.rawValue, delta.deltaBase64)
    case .exited(let result): print("exit", result.exitCode)
    }
}
```

The same session exposes durable queue invalidations, filesystem watch changes, fuzzy-search updates,
external-agent import progress, MCP OAuth completion, app-list invalidation,
remote-control status changes, and Windows sandbox setup completion through
their corresponding `observe…` methods.

## History modes

The server owns each thread's declared `legacy` or `paginated` history mode; a new thread with no requested mode uses the server declaration. Resume supports both modes and paginated resume backfills history. Paginated threads support fork and durable `thread/revert`; legacy `thread/rollback` remains separate. A missing or unknown declared mode is a protocol violation—never infer it from cursors or migrate an existing thread from a new-chat preference.
