# CodexCore Session Engine Architecture

> **Historical target design:** This document mixes target and transitional states and is not an inventory of the current engine. Production uses `ThreadLeaseRegistry` and `PaginatedHistoryCoordinator`; source and tests are authoritative.

## Status

This document defines the server-informed target runtime for the protocol pinned to
`codex-cli 0.145.0`. CodexCore opts into the app-server's experimental API surface, so
protocol evolution is handled by regenerating the wire layer and updating its drift
tests, not by preserving a second compatibility runtime.

The implementation is currently transitioning toward this shape. Separate history and
lease coordinators remain migration artifacts rather than target module boundaries.

Codex 0.145.0 exposes both `legacy` and `paginated` thread-history modes, and they are active
protocol contracts rather than a source-compatibility concern. CodexCore cannot yet make
`paginated` the universal product default while preserving the pinned server's features:
0.145.0 rejects `thread/rollback` and `thread/read(includeTurns: true)` for paginated
threads. GA adds compatibility hydration for older clients that resume paginated threads
with full turns, but it does not close those remaining operation gaps. Until the server
reaches full parity, CodexCore creates legacy threads by
default and treats paginated history as an explicit per-thread experiment. The session
selects behavior from the thread's declared history mode. It must never send a paginated
resume to an unknown or legacy thread and infer that null cursors mean empty history.
Configuration therefore exposes a persisted new-chat history preference, defaults it
to `legacy`, and sends the selection explicitly on `thread/start`. Changing the
preference never migrates existing threads; their server-declared mode remains the
source of truth for resume and operation policy.

CodexCore launches a pinned app-server over stdio and uses an isolated `CODEX_HOME` at
`~/.codexcore` by default. The normal Codex app's `~/.codex` state is not selected
implicitly.

### Alpha.24 protocol additions

Compared with alpha.20, the pinned schema adds `thread/searchOccurrences` for paginated
message search and `app/installed` for the committed connector runtime snapshot. Thread
payloads now advertise `canAcceptDirectInput`; CodexCore retains this capability in
canonical metadata instead of inferring it from thread ancestry. The server reports
`false` for multi-agent-v2 thread-spawned subagents and rejects direct turns to them.

Alpha.24 also adds audio input vocabulary, session-end hooks, listed plugin
discoverability, plugin installation-interstitial metadata, and realtime-v3 initial
items plus typed response-handoff modes. These remain generated wire capabilities until
a product surface explicitly adopts them. The existing paginated-history restrictions
on fork, rollback, full thread reads, and full items in `thread/turns/list` remain.

## What the server actually guarantees

The architecture deliberately relies only on behavior provided by app-server:

- stdio frames are delivered in transport order and outbound writes are backpressured;
- JSON-RPC responses correlate by their exact integer-or-string request ID, but
  unrelated requests may complete in a different order;
- a thread listener serializes that thread's notifications while it exists;
- `thread/resume` both returns thread state and establishes a live subscription, but it
  does not create one atomic history/live cut;
- history cursors are opaque pagination tokens, not event sequence numbers;
- resume responses, history pages, and live notifications may overlap;
- the server exposes neither a durable event sequence nor a replayable connection
  incarnation; and
- a written mutation may have succeeded even when the client loses its response.

A local frame ordinal is therefore useful for diagnostics and same-connection ordering
only. It must never be interpreted as the server's resume point, history cut, or proof
that state is complete.

## Non-negotiable invariants

1. `CodexSession` is the sole ordered owner of app-server client state.
2. Every inbound JSON-RPC frame is decoded once; state-bearing facts are adapted and
   reduced once when accepted.
3. Canonical mutations owned by one frame commit at one monotonically increasing state
   revision.
4. A response's state is committed before its caller continuation resumes.
5. JSON-RPC integer and string identifiers remain distinct. Pending identities also
   carry the physical connection epoch.
6. Thread, turn, and item identity is composite: thread, `(thread, turn)`, and
   `(thread, turn, item)`.
7. History and live facts merge into the same canonical replica. Their overlap is
   expected and reduction is idempotent and authority-aware.
8. Server-originated interaction requests exist locally only while pending. Resolution
   removes them; no terminal ledger is retained as application state.
9. UI state is a disposable projection plus local interaction state. It never reduces
   protocol notifications.
10. Observation is snapshot plus coalesced revision signal, not raw event replay.
11. Reconnect never blindly replays a mutation whose write may have reached an earlier
    physical connection.
12. The executable version and `CODEX_HOME` are controlled out of band. A reported
    `userAgent` is diagnostic metadata, not a runtime compatibility gate.

## Runtime shape

```text
Codex facade/runtime configuration
`- CodexSession actor
   |- AppServerConnection / frame transport
   |  |- pinned app-server child process
   |  `- ~/.codexcore environment + stdio framing
   |- ClientRequestBroker
   |- CanonicalReplica
   |- ThreadLeaseRegistry
   |- InteractionInbox
   |- operation-specific trackers
   `- ObservationHub
       `- CodexPresentationStore
           `- TranscriptV2 -> AppKit renderer
```

The values inside `CodexSession` are synchronous. They add domain structure without
introducing actors, executors, competing stores, or ordering seams of their own.

## Module boundaries

### Generated protocol

`Generated/AppServerProtocolMethods.swift` and
`Generated/AppServerSchemaTypes.swift` are the complete pinned wire vocabulary. Request
descriptors pair each post-handshake method with its generated parameter and response
types, including the distinction between omitted parameters, JSON `null`, and an empty
object.

This layer knows wire spelling and Codable shapes. It does not own connection state,
retry policy, canonical state, or UI behavior.

### Runtime and frame transport

`CodexRuntime` selects the pinned executable, supplies `CODEX_HOME=~/.codexcore`, and
owns the child-process lifetime. Version pinning is a deployment decision: initialization
metadata is recorded for diagnostics rather than parsed into a second compatibility
policy.

`CodexFrameTransport` opens one physical stdio connection and yields complete frames in
order. It performs a single write attempt and never queues a mutation for replay after
failure. Transport code frames bytes; it does not decode JSON-RPC or infer thread or
operation lifecycle.

### Ordered session

`CodexSession` is one actor and one ordering boundary. It owns:

- connection epoch, local diagnostic ordinal, initialization, and shutdown;
- request/response correlation through `ClientRequestBroker`;
- protocol adaptation and `CanonicalReplica` reduction;
- thread subscription and hydration intent through `ThreadLeaseRegistry`;
- currently pending server interactions through `InteractionInbox`;
- the few operation-specific trackers whose protocols have real multi-message
  lifecycles; and
- scoped observation through `ObservationHub`.

An unknown late response or already-resolved server request is a bounded diagnostic,
not evidence that canonical state is corrupt. A malformed known state-bearing payload
can still fail the connection when continuing would make the replica ambiguous.

### Client request broker

`ClientRequestBroker` is a synchronous table of requests pending on the current physical
connection. Its job is deliberately narrow:

1. allocate and preserve an exact JSON-RPC ID;
2. register the response decoder and continuation before writing;
3. match one response or error to that ID; and
4. fail remaining waiters when the connection closes.

It does not infer domain operations, retain completed requests, replay writes, or decide
whether a response is the end of a notification stream. Those semantics belong to the
specific command using the broker.

### Protocol adapter and canonical replica

`ProtocolStateAdapter` translates generated wire values into typed canonical mutations
and explicit non-state dispositions. It preserves unknown alpha variants and additive
fields rather than coercing them into lossy UI strings.

`CanonicalReplica` hides adaptation, mutation application, coverage rules, and revision
assignment behind one deep session-owned interface. Its normalized graph is:

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

Coverage records how authoritative an entity is (`notLoaded < summary < full`). History
merges cannot erase richer live or terminal facts. Streaming deltas accumulate in typed
live overlays; an authoritative completion replaces speculative content. Local user
input remains a submission intent until the server echoes its `clientUserMessageId`, so
optimism never fabricates protocol turns or items.

Each changed entity records its latest revision. A turn's aggregate revision advances
when its own fields, its item order, an item, or a submission intent affecting that turn
changes. This gives projectors a cheap invalidation key without retaining a journal of
past change sets.

### Thread lease registry

`ThreadLeaseRegistry` owns retention and subscription leases for each locally interesting thread;
the canonical graph remains the data-plane truth. Each lease record tracks:

```text
retainers          why local consumers still need the thread
desired            whether a live server subscription is wanted
actual             the best-known subscription state on this connection
phase              idle / resuming / subscribed / unsubscribing
generation         local token used to reject stale async completions
hydration          opaque turn and item pagination state
```

Multiple UI or SDK consumers add retainers, but the registry drives at most one desired
subscription. Connection replacement clears `actual`; it does not invent a server
incarnation or erase canonical facts. The generation is only local concurrency control.

History and live reconciliation follows these rules:

1. reserve the transition and its owner before sending `thread/resume`, so an inverse
   unsubscribe cannot overtake or follow it unnoticed;
2. select the request and hydration strategy from the server-declared history mode;
3. for legacy history, reduce the authoritative turns returned by resume without
   manufacturing pagination cursors;
4. for paginated history, reduce live notifications immediately while paging, treat
   turn and item cursors as independent opaque tokens, and merge overlapping pages
   idempotently;
5. make a resume usable as soon as its response is reduced, while exposing paginated
   loading state separately for callers that care about full hydration;
6. reject results from an obsolete connection epoch or thread generation; and
7. retry safe subscription transitions with bounded per-thread backoff while desire and
   connection epoch still match.

There is no response-ordinal cut, live-frame buffer, or replay-after-history phase.
Resume failure is not treated as proof that the server performed no subscription side
effect; desired/actual reconciliation remains explicit.

History mode is a strategy inside this registry, not a second store or reducer:

| Declared mode | Resume and hydration | Alpha.20 feature policy |
| --- | --- | --- |
| Unknown | Read metadata without turns before reserving resume | Do not guess from cursor absence |
| Legacy | Resume with turns and reduce the authoritative response directly | Fork, rollback, and full reads remain available |
| Paginated | Resume without turns, then follow opaque turn/item anchors | Reject alpha.20 operations the server declares unsupported |

An explicit resume first reserves its owner and generation in the same state machine used
by background reconciliation. Unsubscribe, reconnect, and resume therefore cannot pass
one another on the wire while leaving `actual` inverted. Safe resume/unsubscribe failures
retry with bounded per-thread backoff; cancellation or a connection-generation change
invalidates the retry. Subscription readiness and complete-history hydration are distinct
awaitable conditions.

### Interaction inbox

`InteractionInbox` contains only pending server-originated requests keyed by exact
`(connectionEpoch, requestID)` identity. It validates a proposed response against the
typed request and allows one local resolver to win. A server
`serverRequest/resolved`, a locally queued response, or disconnect removes the entry.
It does not invent client-side timeout or cancellation semantics that the protocol does
not define.

Presentation observes sanitized request bodies needed to render approval, tool-input,
or other interaction cards. Continuations and secret-bearing results never enter
canonical or presentation state. Late duplicate resolutions are harmless diagnostics;
there is no retained terminal request ledger.

### Operation-specific trackers

App-server does not give all commands one lifecycle shape, so CodexCore does not impose
one universal operation registry. A command with response-only semantics simply awaits
the broker. A command whose protocol explicitly includes follow-up notifications owns a
small tracker named for that operation—for example login completion or a keyed streaming
search/audio session.

Each tracker defines its actual key, completion event, cancellation behavior, and
buffering policy. Unrelated warnings, process output, import progress, MCP status, and
unknown notifications are routed through narrow typed observers or a bounded diagnostic
sink; they are not forced through a fabricated common state machine and raw parameters
are not retained globally.

### Observation hub

`ObservationHub` registers scoped observers and publishes coalesced revision signals.
Registration returns an atomic seed snapshot and a stream. On a relevant signal, a
consumer reads a fresh scoped snapshot; if intermediate signals coalesce, the latest
canonical state is still complete.

The hub may carry compact invalidation hints such as changed thread or aggregate turn
IDs, but it retains no historical change journal and promises no event replay. Slow
consumers do not require the session to retain every revision. Canonical state is the
truth; projections are cheap to rebuild.

### Presentation

`CodexPresentationStore` observes scoped canonical revisions and projects them off the
main actor into the TranscriptV2 grammar consumed by the AppKit renderer. Aggregate turn
revisions permit incremental projection, and terminal changes flush promptly.

Presentation owns only interaction state such as selection, scroll position, bottom
pin, expansion, drafts, display timestamps, and last-seen attention revision. Sidebar
status uses a lightweight thread-index projection instead of copying complete thread
detail. AppKit performs layout, reuse, selection, and scrolling downstream of the
canonical projection; it is not another reducer.

## End-to-end state flow

```text
stdio frame
  -> CodexFrameTransport
  -> generated JSON-RPC envelope
  -> CodexSession actor
     |- ClientRequestBroker (exact response correlation)
     |- InteractionInbox (pending server requests only)
     |- operation-specific tracker, when the method defines one
     `- CanonicalReplica
         -> normalized state + entity revisions
         -> ObservationHub signal
             |- SDK scoped snapshot
             |- sidebar thread-index snapshot
             `- CodexPresentationStore
                 -> TranscriptV2 presentation
                 -> AppKit collection renderer
```

There is no legacy Store dispatch, notification-router fan-out, raw global replay
stream, history response cut, universal operation registry, terminal request ledger, or
second transcript reducer in this flow.

## Reconnect and failure semantics

- A connection epoch seals pending request and interaction identities from that
  physical connection. Local ordinals have no meaning in the next epoch.
- A request cancelled before its write is removed. If the write was attempted, caller
  cancellation may detach its waiter, but CodexCore does not assume the server skipped
  the work.
- A written mutation is never automatically resent after disconnect. A submission
  intent becomes indeterminate when its outcome cannot be known.
- The last yielded frame is reduced before disconnect lifecycle is published.
- Desired thread subscriptions are reconciled on the new connection. Canonical facts
  remain available at their recorded coverage while fresh resume/history facts merge.
- Pending interactions and operation-specific trackers from the old connection are
  failed or removed; terminal tombstones are not carried forward.
- Malformed known protocol state fails the epoch only when continuing would make the
  canonical replica ambiguous. Benign late or duplicate completion frames are ignored
  with bounded diagnostics.

## Testing gates

The architecture is protected by:

- generated inventory and pinned-schema drift tests;
- exact JSON-RPC envelope and integer/string identifier tests;
- request-broker ordering, cancellation, disconnect, and late-response tests;
- reducer authority, overlap, coverage, rollback, and duplicate-delta tests;
- thread-runtime generation, resume/unsubscribe race, and reconnect tests;
- history tests that deliberately interleave live notifications, resume responses, and
  overlapping pages;
- pending-interaction validation and duplicate-resolution tests;
- operation-specific completion tests rather than a universal lifecycle matrix;
- observation coalescing and canonical-to-TranscriptV2 projection tests; and
- production target builds and the full Swift test suite.

New protocol features must deepen one of these modules. They must not add another state
owner, compatibility reducer, raw event replay path, or presentation-specific branch to
transport.
