# CodexCore Session Engine Architecture

## Status

This document defines the post-legacy CodexCore runtime. The app-server protocol is
currently pinned to `codex-cli 0.145.0-alpha.20`. Protocol evolution is handled by
regenerating the wire layer and its drift tests, not by adding a second runtime path.

CodexCore uses an isolated `CODEX_HOME` at `~/.codexcore` by default. The normal Codex
app's `~/.codex` state is not selected implicitly.

## Non-negotiable invariants

1. `CodexSession` is the sole owner of ordered connection and protocol state.
2. Every inbound JSON-RPC frame is decoded once and assigned one local wire cursor.
3. A state-bearing frame is adapted and reduced exactly once.
4. All mutations derived from one frame commit at one canonical state revision.
5. A response's state is committed before its caller continuation resumes.
6. JSON-RPC integer and string identifiers remain distinct and are scoped by connection
   epoch.
7. Thread, turn, and item identity is always composite: thread, `(thread, turn)`, and
   `(thread, turn, item)`.
8. History and live traffic converge through the same protocol adapter and canonical
   reducer.
9. Server-originated requests are registered before application code is invoked, and
   exactly one terminal outcome wins.
10. UI state is a disposable projection plus local interaction state. It never reduces
    protocol notifications.
11. Auxiliary operation streams are explicitly keyed and bounded. There is no global
    raw-notification replay stream.
12. Reconnect never replays a mutation whose write was attempted on an earlier physical
    connection.

## Module boundaries

### Generated protocol

`Generated/AppServerProtocolMethods.swift` and
`Generated/AppServerSchemaTypes.swift` are the complete pinned wire vocabulary. Request
descriptors pair each post-handshake method with its generated parameter and response
types, including the protocol distinction between omitted parameters, JSON `null`, and
an empty object.

This layer knows wire spelling and Codable shapes. It does not own connection state,
retry policy, canonical state, or UI behavior.

### Frame transport

`CodexFrameTransport` opens one physical connection and yields complete frames once, in
order. It performs a single write attempt and never retains outbound mutations for
replay. Buffer overflow is an explicit connection failure rather than silent frame
loss.

Transport implementations do not decode JSON-RPC or infer application lifecycle.

### Ordered session

`CodexSession` owns:

- the active connection epoch and wire ordinal;
- initialization buffering and handshake state;
- request/response correlation and one-attempt outbound writes;
- protocol adaptation and canonical reduction;
- the state change journal;
- server-request, operation, history, and retention registries;
- reconnect and terminal waiters.

Actor isolation is the serialization mechanism. Registries and reducers are synchronous
values owned by the actor; they do not introduce hidden executors or competing stores.

### Protocol adapter

`ProtocolStateAdapter` is a stateless, exhaustive translation from generated wire values
to typed canonical mutations and non-state dispositions. It preserves unknown alpha
variants and additive fields instead of coercing them into lossy UI strings.

The adapter does not mutate state. This keeps protocol evolution mechanically testable:
the generated notification inventory must have an explicit disposition, and every
state-bearing method has a valid fixture.

### Canonical reducer

The canonical graph is a normalized materialized view:

```text
CanonicalStateGraph
|- account/session facts
|- threads[ThreadID]
|  `- turnOrder
|- turns[TurnKey]
|  `- itemOrder
|- items[ItemKey]
`- submissionIntents[SubmissionIntentID]
```

The reducer applies typed mutations synchronously and emits small invalidation facts. It
never emits cumulative transcript copies.

Coverage records how authoritative a snapshot is (`notLoaded < summary < full`). A
lower-coverage history page cannot erase richer live state. Streaming deltas accumulate
in typed live overlays; an authoritative completion replaces the corresponding
speculative content. Explicit rollback is the only general destructive thread/turn/item
replacement path.

Local user input is represented as a submission intent until the server echoes its
`clientUserMessageId`. Optimism therefore does not fabricate protocol turns or items.

### State change journal

Every accepted transaction advances a monotonic `StateRevision` and records bounded,
field-aware change metadata. Observation returns an atomic seed plus a signal stream.
Consumers catch up by revision; if relevant retained history has been evicted, they
receive an explicit reset and rebuild from a scoped snapshot.

The journal is a change index, not an event-sourcing log. Canonical state is the current
truth and raw protocol frames are not replayed into reducers.

### Server-request inbox

Server-originated JSON-RPC requests use exact `(connectionEpoch, requestID)` identity.
The request ledger owns pending/terminal arbitration across application response,
timeout, cancellation, `serverRequest/resolved`, and disconnect. First terminal outcome
wins.

Canonical/session observations expose sanitized, continuation-free request summaries.
The interactive prompt layer uses a dedicated typed inbox snapshot containing only the
pending request body required for presentation and validation. Secret-bearing results
are neither journaled nor retained in presentation state.

### Auxiliary operations

Notifications such as command/process output, fuzzy search, realtime audio, MCP startup,
and import progress are not canonical transcript state. Consumers register an exact
operation key before the initiating request is written. The operation registry decodes
one typed event at its wire cursor and publishes only to matching channels.

Channels are bounded and terminate explicitly on protocol completion, response-side
completion, cancellation, disconnect, or overflow. Warnings, unknown methods, and
unmatched operation metadata use a small bounded diagnostic journal; raw parameters are
not retained globally.

### Retention leases and history

A `CodexThreadLease` is a truthless capability that keeps one thread subscribed and its
detail retained. Multiple consumers share one subscription. Release/reacquire and
unsubscribe/reconnect races are resolved by operation identities in
`ThreadLeaseRegistry`.

History reconciliation uses the alpha protocol's resume cut:

1. send `thread/resume` with `excludeTurns`;
2. capture both backward cursors and the response wire cursor;
3. page turns in descending order;
4. page per-turn items with bounded concurrency;
5. install durable records oldest-first;
6. replay only live frames newer than the resume response cursor.

Live frames received during paging are bounded. Cursor cycles, wrong-turn entries,
empty pages with continuation, overflow, and stale epochs fail explicitly. A paging
failure marks coverage incomplete but must not suppress current-epoch live traffic.

### Presentation

`CodexPresentationStore` observes scoped canonical revisions and projects them off the
main actor into the TranscriptV2 grammar consumed by the AppKit renderer. Dirty turn
metadata permits incremental projection and terminal changes flush immediately.

The presentation layer owns only interaction state such as selection, scroll position,
bottom pin, expansion, display timestamps, and last-seen attention revision. This state
is bounded per thread. Sidebar status uses a lightweight thread-index projection rather
than copying all turn and item state.

AppKit remains the rendering implementation. It performs layout, reuse, selection, and
scrolling downstream of the canonical projection; it is not another reducer.

## End-to-end flow

```text
app-server frame
  -> CodexFrameTransport
  -> JSON-RPC envelope + wire cursor
  -> CodexSession
     |- response correlation
     |- server-request ledger
     |- keyed operation registry
     `- ProtocolStateAdapter
         -> CanonicalStateReducer
         -> StateChangeJournal
             |- SDK scoped snapshots / leases
             |- typed request inbox
             |- sidebar thread index
             `- CodexPresentationStore
                 -> TranscriptV2 presentation
                 -> AppKit collection renderer
```

There is no legacy Store dispatch, notification router fan-out, content-fingerprint
deduplication, or second transcript reducer in this flow.

## Reconnect and failure semantics

- A connection epoch seals all request IDs, operation channels, and wire cursors from
  that physical connection.
- A request cancelled before its write is removed. If the write was attempted, caller
  cancellation detaches the waiter but a later response is still reduced.
- A written mutation is never automatically resent after disconnect. Submission intent
  becomes indeterminate when the outcome cannot be known.
- The last yielded frame is reduced before disconnect lifecycle is published.
- Leased threads reconcile on a new epoch; active turns with an unprovable gap remain
  explicitly uncertain until authoritative state arrives.
- Protocol violations close the epoch rather than continuing with possibly divergent
  state.

## Testing gates

The architecture is protected by:

- generated inventory and pinned-schema drift tests;
- exact JSON-RPC envelope and identifier tests;
- reducer authority, coverage, rollback, and duplicate-delta tests;
- session ordering, cancellation, handshake, reconnect, and final-frame tests;
- request-ledger race and validation tests;
- paginated-history cursor/gap/parallelism tests;
- canonical-to-TranscriptV2 parity and incremental projection tests;
- production target builds and the full Swift test suite.

New protocol features deepen one of these modules. They must not add another state owner,
raw global stream, compatibility reducer, or presentation-specific branch to transport.
