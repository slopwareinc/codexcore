# CodexCore performance nitpick audit

- Date: 2026-07-17
- Audited commit: e5d41c191e9e6ef7b43723abe304903140f6bdc5
- Scope: current origin/main, including the merged AppKit transcript and Fable work
- Change policy: diagnosis only; no production changes, issues, pull requests, or commits

## Executive summary

The audit accepted 46 concrete opportunities. The dominant result is not one isolated slow function; it is repeated work along the same notification path:

    stdio JSONL
      -> Connection parses the frame twice
      -> Client reduces it into the legacy MainActor Store
      -> Router serializes parsed params again
      -> global and turn streams both deliver it
      -> runtime serializes both copies again to deduplicate
      -> TranscriptV2 mutates value snapshots and status state
      -> the app root and AppKit transcript both observe publication
      -> AppKit projects the whole transcript and invalidates global layout

The highest-value fixes therefore reduce whole stages: one inbound envelope, one transcript ingress identity, one mutable truth representation with coalesced snapshots, dirty-turn projection, and lifecycle-scoped caches. The report also retains smaller measured wins in parsing, file tools, launch RPC concurrency, transport copies, and generated-code size.

The shipped AppKit performance test was rerun in isolation on this commit:

- Debug: 1,085 items, 120 frames, 33.115 ms average projection, 53.421 ms maximum.
- Release: 1,085 items, 120 frames, 23.966 ms average projection, 31.267 ms maximum.
- Both runs passed because the test checks changed-item/cache-miss counts, not elapsed time.
- The session publishes at a 17 ms cadence, so the release average is sufficient to exercise the coordinator's cancel-and-restart starvation mechanism.

Six checked-in UI fixtures contain 2,318 notifications, including 1,860 agent-message deltas. Another recorded inventory contains a 3.95 MB response. These make per-frame serialization and per-delta MainActor work real workloads rather than hypothetical micro-optimizations.

## Methodology and scope

I verified HEAD, origin/main, and FETCH_HEAD all resolved to e5d41c1 after fetching origin/main. The worktree is isolated from the source checkout and began clean.

I used 24 subagents across 14 reconciled audit slices:

1. stdio and WebSocket transport;
2. connection ordering and reconnection;
3. notification routing and runtime ingress;
4. protocol/Codable model shapes;
5. JSON bridging;
6. generated schema and build tooling;
7. legacy Store mutation/projection;
8. history hydration and caches;
9. TranscriptV2 reducer/session state;
10. AppKit projection, cells, and layout;
11. Markdown, GFM, directive, and diff parsing;
12. app shell, sidebar, startup, and session orchestration;
13. workspace tools, files, and previews;
14. tests plus cross-cutting allocation, concurrency, cache, and stale-claim review.

Findings were accepted only when an active call path was demonstrated, a complexity/allocation mechanism was mechanically clear, or an isolated fixture/microbenchmark showed a material effect. Replicated microbenchmarks are directional, not product SLAs. Expected value considers frequency, user-visible placement, payload scaling, risk, and fix size.

Evidence labels:

- **High:** direct control-flow/ownership proof, usually with fixture or isolated measurement.
- **Medium-high:** direct mechanism with workload-dependent magnitude.
- **Medium:** real work on a narrower or less frequent path.
- **Low:** measurable nitpick with limited aggregate effect; retained because this audit explicitly requested small opportunities.

## Ranked findings

| Rank | ID | Expected value | Subsystem | Finding |
|---:|:---:|:---:|---|---|
| 1 | A1 | Very high | AppKit transcript | Full projection is cancelled and restarted faster than it can finish |
| 2 | S1 | Very high | Legacy Store | Per-delta cumulative strings and nested value snapshots copy on MainActor |
| 3 | T1 | Very high | Runtime ingress | Global and scoped copies are deduplicated with two JSON/Base64 fingerprints |
| 4 | C1 | Very high | Connection | Notifications and responses are fully decoded twice |
| 5 | V1 | Very high | TranscriptV2 | Dictionary extraction forces nested copy-on-write on every event |
| 6 | V2 | Very high | App state | Token deltas rewrite observable thread status and invalidate the shell |
| 7 | A2 | Very high | Block projection | Streaming reuse remains quadratic in accumulated text |
| 8 | C2 | Very high | Router/protocol | Parsed notification params are encoded and decoded again |
| 9 | H1 | Very high | History | Whole histories and each item are repeatedly JSON-bridged |
| 10 | A3 | Very high | AppKit cache | Every streaming prefix can remain as a full attributed-string cache entry |
| 11 | V3 | High | TranscriptV2 | Delta application repeatedly scans turns and timestamps |
| 12 | V4 | High | TranscriptV2 | Command and reasoning output accumulation is quadratic |
| 13 | A4 | High | AppKit layout | Targeted reconfigure still requests global flow-layout metrics |
| 14 | P1 | High | Directive parser | A regular expression is compiled once per line per projection |
| 15 | P2 | High | GFM tables | Cells are Markdown-parsed twice and invalidate as one block |
| 16 | D1 | High | Diff rendering | Unchanged diffs are independently reparsed across renderer and shell |
| 17 | H2 | High | History | Child histories load serially before the ready parent is shown |
| 18 | O1 | High | Telemetry | Performance tracing synchronously opens and writes a file per event |
| 19 | H3 | High | Cache/memory | Protected history entries can exceed the declared capacity forever |
| 20 | S2 | High | Cache/memory | The legacy Store retains every hydrated thread with no eviction |
| 21 | H4 | High | App orchestration | Superseded chat loads continue doing full restore work |
| 22 | O2 | High | Startup | Nine to ten mostly independent RPC waits are serialized |
| 23 | V5 | High | TranscriptV2 | Growing work groups repeatedly rescan and copy all rows |
| 24 | C3 | Medium-high | Connection | Inbound frames create an unbounded Task/queue pipeline |
| 25 | C4 | Medium-high | stdio | Every line makes a redundant full-frame Data copy |
| 26 | U1 | Medium-high | Workspace tools | Hidden heavy tools from up to 20 chats are mounted together |
| 27 | U2 | Medium-high | File preview | Cancellation misses detached work and queries are rebuilt per load |
| 28 | U3 | Medium-high | File explorer | Directory enumeration and metadata sorting run on MainActor |
| 29 | U4 | Medium-high | File preview | Every representable update hashes up to 2 MiB before its no-op guard |
| 30 | S3 | Medium-high | Store/runtime | Every delta eagerly fetches a linearly searched turn snapshot |
| 31 | V6 | Medium-high | Observation | Root and transcript child observe the same presentation revision |
| 32 | O3 | Medium | Sidebar | The same sidebar projection is rebuilt up to three times per body |
| 33 | A5 | Medium | TextKit | Reused cells replace full text storage and code width is measured twice |
| 34 | A6 | Medium | AppKit cache | A to B to A switching discards the first thread's render warmth |
| 35 | V7 | Medium | TranscriptV2 | Pre-hydration event queues are unbounded and replay synchronously |
| 36 | V8 | Medium | Subagents | Sorting, descendant closure, and retained transcripts scale poorly |
| 37 | C5 | Medium | Typed APIs | General request bridges and turn input create discardable payload copies |
| 38 | C6 | Medium | Reconnection | Retry work survives stop and outbox replay uses removeFirst |
| 39 | G1 | Medium | Code generation | Unused generated conformances, inventory, and initializers inflate builds |
| 40 | Q1 | Medium | Performance tests | AppKit timing regressions are printed but never fail |
| 41 | S4 | Medium | Projection | Each item is parsed into two overlapping legacy representations |
| 42 | C7 | Medium | stdio output | Synchronous pipe writes can pin the transport actor under backpressure |
| 43 | C8 | Low-medium | Client routing | Unmapped notifications hop to MainActor only to print |
| 44 | U5 | Low-medium | Integration catalog | Selection detail performs a list scan for every rendered row |
| 45 | A7 | Low-medium | Product tools | Reconfigure destroys and recreates a hosting view |
| 46 | V9 | Low | Scheduling | Sustained streaming creates a new sleeping cadence Task each tick |

## Core SDK, protocol, transport, and routing

### 4 / C1 — Decode each incoming JSON-RPC frame once

- **Anchor:** [CodexConnection.handleIncomingMessage](../Sources/CodexCore/Client/Connection.swift#L305), especially lines 309, 340, and 354.
- **Behavior and context:** Connection first decodes the complete frame as a dictionary to discover method/id, then decodes the same bytes as JSONRPCNotification or JSONRPCResponse. Both recursive object graphs temporarily coexist on the connection actor.
- **Impact:** every notification and response pays two O(frame bytes) parses. Small deltas pay at high frequency; a multi-megabyte history/catalog response adds peak memory and head-of-line latency for unrelated replies.
- **Fix / risk:** decode one private envelope with method, dynamic id, params, result, and error, then route from that tree. Preserve absent versus null IDs, numeric-string failure behavior, server requests, and diagnostic prefixes.
- **Evidence / verify:** 11,590 optimized fixture frames measured 0.882 s current versus 0.407 s one-pass, about 2.2 times. Benchmark 100,000 200-byte deltas and 100 one-megabyte results with allocations, RSS, throughput, and interleaved reply latency.
- **Overlap:** C2 and C5 add later encode/decode passes; measure each layer independently.

### 8 / C2 — Stop byte-bridging known notification payloads

- **Anchor:** [NotificationRouter.payload](../Sources/CodexCore/Client/NotificationRouter.swift#L278) and [CodexJSONValue.decode](../Sources/CodexCore/Protocol/JSONBridge.swift#L20).
- **Behavior and context:** Router already owns raw parsed params, but JSON-encodes them to Data and JSON-decodes a typed payload for deltas, item events, and turn events. Client independently decodes several item payloads before Router does so again.
- **Impact:** agent-message deltas dominate fixture traffic, so a full serialization pass runs in the hot actor path while rawParams is retained anyway.
- **Fix / risk:** add strict tree-backed initializers for the hottest small payloads, then share one typed/raw item envelope. Also switch on the already-classified notification enum rather than dispatching on the raw method string twice. Preserve known-fallback behavior for malformed optional fields.
- **Evidence / verify:** direct extraction was 17–22 times faster in a 723-event fixture replay, about 0.3–0.4 ms versus 6–7 ms. Golden-test malformed fields and benchmark 100,000 realistic deltas.
- **Overlap:** C1 removes the first duplicate parse; this distinct bridge remains afterward.

### 24 / C3 — Bound and drain inbound work instead of spawning one Task per frame

- **Anchor:** [CodexConnection transport callback and enqueueIncomingMessage](../Sources/CodexCore/Client/Connection.swift#L56), especially lines 92–97, 135–141, and 181–187; downstream [CodexClient.handleNotification](../Sources/CodexCore/Client/Client.swift#L1145).
- **Behavior and context:** the transport callback assigns a sequence under a lock, creates an unstructured Task for each line, reorders on the actor, then yields into default-unbounded streams. Producers never await consumer progress.
- **Impact:** when parsing, legacy Store, or UI routing falls behind stdout, Tasks and queued Strings/Data grow without a high-water mark, increasing RSS, scheduler work, and p99 delivery latency.
- **Fix / risk:** use one ordered mailbox/drain task with explicit capacity and pause/resume reads; coalesce only adjacent compatible deltas. Responses, approvals, completions, and ordering must remain lossless, and pipe backpressure can stall the child.
- **Evidence / verify:** the queues have no bound and existing mocks inject only small sequential messages. Burst 10,000/100,000 fixture frames against 50–500 microsecond consumers and measure peak Tasks, RSS, ordering, drain time, and latency.
- **Overlap:** C1/C2/S1 reduce consumer time; a bound is still needed for overload.

### 25 / C4 — Remove the redundant stdio line copy

- **Anchor:** [CodexLineBuffer.append](../Sources/CodexCore/Client/Transport.swift#L43), especially lines 51–53, and [CodexConnection.handleIncomingMessage](../Sources/CodexCore/Client/Connection.swift#L305).
- **Behavior and context:** the line buffer creates subdata for each frame, converts that copy to String, and Connection converts the String back to Data for JSON decoding.
- **Impact:** every inbound byte is copied unnecessarily; large thread/read or tool-output frames amplify allocator and memory-bandwidth cost.
- **Fix / risk:** minimally construct String directly from the buffer slice; longer term make the transport callback byte-native and decode Data directly. Avoid retaining a large backing buffer through slices and preserve invalid-UTF8 rejection.
- **Evidence / verify:** 50 four-megabyte frames measured 72–89 ms with subdata versus 9.6–11.5 ms using the slice initializer. Replay 200-byte, 64 KiB, and 4 MiB JSONL frames while recording allocated/copied bytes.
- **Overlap:** the old quadratic newline rescan is not present; this is the remaining per-frame copy.

### 37 / C5 — Avoid general typed-to-dynamic bridge passes and discarded turn input

- **Anchor:** [JSON bridge primitives](../Sources/CodexCore/Protocol/JSONBridge.swift#L15), typed wrappers at [CodexClient request helpers](../Sources/CodexCore/Client/Client.swift#L113), and [CodexThread.turn](../Sources/CodexCore/Client/Codex.swift#L952).
- **Behavior and context:** typed requests become Data, then CodexJSONValue, then wire Data; responses traverse the reverse bridge. Turn builds metadata including the full input, bridges it, removes input/threadId, and maps the original input again.
- **Impact:** short prompts are negligible, but large text, raw values, or data-URL images create payload-sized temporary trees; raw-consuming history/catalog callers pay the general bridge needlessly.
- **Fix / risk:** encode typed params directly into the wire envelope with a type-erased response decoder, or first add raw-result overloads for raw consumers. Construct turn override metadata without input and map canonical input once. Preserve additionalParams precedence and public API behavior.
- **Evidence / verify:** representative 25.7 KiB typed requests were roughly four times the direct path; discarded-input bridge cost scaled from about 5 ms at 1 MB to about 46 ms at 10 MB. Benchmark text/image/raw input at 1/10/50 MB and compare exact wire JSON.
- **Overlap:** H1 is the highest-frequency cold-load instance of this systemic bridge.

### 38 / C6 — Stop reconnection work and use a linear outbox

- **Anchor:** [CodexReconnectionManager.handleDisconnect](../Sources/CodexCore/Client/ReconnectionManager.swift#L96), [flushOutbox](../Sources/CodexCore/Client/ReconnectionManager.swift#L167), and [CodexConnection.stop](../Sources/CodexCore/Client/Connection.swift#L189).
- **Behavior and context:** an untracked retry Task strongly retains manager state and stop bypasses it, so backoff can continue wakeups or reopen transport. Successful reconnect repeatedly removes the first Array element, shifting the rest.
- **Impact:** explicit shutdown may continue energy/process/network activity; a large outage outbox replays in quadratic element movement.
- **Fix / risk:** track retry generation/task, add idempotent shutdown with cancellation-aware sleep, and store the outbox in a deque/head-index buffer. Preserve ordering, partial failure, actor-reentrant appends, and stale-attempt rejection.
- **Evidence / verify:** control flow is mechanically direct; frequency is failure-dependent. Use a manual clock/failing transport to assert no starts after stop, weak-reference release, and linear 1k/2k/4k/8k replay scaling.
- **Overlap:** C3 concerns normal inbound overload; this concerns outage lifecycle.

### 42 / C7 — Move blocking pipe writes off the transport actor

- **Anchor:** [CodexStdioTransport.send](../Sources/CodexCore/Client/Transport.swift#L182).
- **Behavior and context:** every outbound request writes synchronously with FileHandle while holding the stdio transport actor. If the daemon pauses reads or pipe capacity is exhausted, stop cannot enter the actor to close the descriptor.
- **Impact:** normal small frames are cheap, but large turn payloads or a stalled child can pin a cooperative executor thread and create unbounded send/stop latency.
- **Fix / risk:** add an ordered DispatchIO or nonblocking write queue whose awaits permit actor reentrancy; stop must cancel and complete queued writes. Partial writes, ordering, and exactly-once continuation completion are the risks.
- **Evidence / verify:** synchronous semantics are explicit; magnitude depends on backpressure. Test a child that never reads stdin with 1–8 MiB sends and measure send/stop p99, blocked threads, scheduler jitter, and energy.
- **Overlap:** C5 makes very large outbound frames more likely; fixing copies alone does not solve blocking.

### 43 / C8 — Skip MainActor dispatch for unmapped events

- **Anchor:** [CodexClient.handleNotification](../Sources/CodexCore/Client/Client.swift#L1145), [storeEventBeforeRouting](../Sources/CodexCore/Client/Client.swift#L1201), and the default event mapping near line 1362.
- **Behavior and context:** notifications not represented in the legacy Store become unknown events, synchronously hop to MainActor, and print before Router receives them.
- **Impact:** captured traffic includes process output/exit, app-list, and metadata notifications that make this a no-op UI barrier plus console I/O in front of all consumers.
- **Fix / risk:** return nil for Store-unconsumed methods and retain optional rate-limited diagnostics off MainActor. The only risk is lost debugging visibility.
- **Evidence / verify:** captures contained at least 321 such notifications. Replay the recorded method mix under synthetic MainActor load and compare Router p99 plus log-write count.
- **Overlap:** S1 is the cost for mapped events; this is the cheap early exit for unmapped ones.

## Legacy Store, history, cache, and app orchestration

### 2 / S1 — Stop publishing cumulative streaming text through nested value snapshots per delta

- **Anchor:** [CodexClient.handleNotification](../Sources/CodexCore/Client/Client.swift#L1145), [CodexCoreStore.snapshotForMutation](../Sources/CodexCore/Store/Store.swift#L402), and [appendDelta](../Sources/CodexCore/Store/Store.swift#L665).
- **Behavior and context:** Client awaits a MainActor legacy Store reduction before Router delivery. Store copies a dictionary-held thread snapshot while activeThread retains another value owner, linearly finds turn/item, appends to streamingBuffers, embeds the complete accumulated String in a new timeline item, and republishes the nested turns/items arrays.
- **Impact:** the next tiny append can copy the retained prefix plus array buffers. Many token-sized deltas therefore approach quadratic text bytes and repeatedly clone long-thread value structure, while also delaying every Router consumer. The app then reduces the same event again into TranscriptV2.
- **Fix / risk:** keep reference-backed/chunked mutable truth with item indexes; materialize public snapshots at a 16–50 ms cadence and flush before completion. SDK observers may rely on every intermediate prefix, and activeThread/threadSnapshotsByID compatibility must be preserved.
- **Evidence / verify:** fixtures contain 1,860 deltas and an item with 201 deltas. Benchmark 1k/5k/10k one-byte deltas over 1/50/217/1,000-turn histories; record scaling, allocations, MainActor time, Router latency, and exact final snapshots.
- **Overlap:** V1/V3 repeat similar value/index costs in TranscriptV2; they are separate truth pipelines.

### 9 / H1 — Keep history raw instead of serializing whole responses and every item

- **Anchor:** [CodexThreadResumeResult.rawResponse](../Sources/CodexCore/Client/Codex.swift#L108), [ThreadHistoryHydrator.decodeThread](../Sources/CodexCore/Store/ThreadHistoryHydrator.swift#L121), item decode at line 140, and typed read bridge at line 187.
- **Behavior and context:** cold restore travels wire dynamic tree to typed response to a newly encoded dynamic tree; hydration then JSON-encodes and decodes each already-dictionary item into CodexServerItem. Parent and every child repeat the path.
- **Impact:** cost scales with both history bytes and item/child count; large command outputs and diffs create payload-sized temporaries and raise time-to-chat.
- **Fix / risk:** expose an internal raw read/resume result or hydrate typed data directly, plus strict CodexServerItem construction from the existing dictionary. Preserve schema validation, malformed-item skipping/fallback IDs, raw unknown fields, and public typed APIs.
- **Evidence / verify:** a roughly 4 MiB/1,000-item cycle measured 143–249 ms; 5,000 4 KiB per-item bridges measured 300–418 ms versus below 1 ms for direct construction. Benchmark bytes and item count with peak RSS and transcript equivalence.
- **Overlap:** C5 is the general bridge; this is the measured, user-visible cold-load amplification.

### 17 / H2 — Show the parent before bounded-parallel child hydration

- **Anchor:** [ThreadHistoryHydrator.hydrate](../Sources/CodexCore/Store/ThreadHistoryHydrator.swift#L63), child loop lines 82–107, and [CodexThreadHistorySession.load](../Sources/CodexCoreUI/CodexThreadHistorySession.swift#L177).
- **Behavior and context:** the parent transcript is decoded by line 69, but every unique historical child is awaited serially and nothing is applied until the entire graph is ready.
- **Impact:** an agent-heavy chat's time-to-first-parent becomes the sum of child RPC, bridge, and decode latencies; one slow child blocks content already available.
- **Fix / risk:** install the parent immediately, load children progressively with bounded concurrency, and reassemble indexed results in reference order. Risks are server burst pressure, Sendable closure changes, deterministic failure/trace order, and cache semantics.
- **Evidence / verify:** a 20 ms synthetic loader produced about 30/124/241 ms for 1/5/10 children. Add gated tests for parent-first display and bounded maxInFlight, then measure real multi-agent histories.
- **Overlap:** H1 and O1 multiply once per child; fix them independently.

### 18 / O1 — Buffer performance tracing instead of synchronously writing every event

- **Anchor:** [CodexPerformanceTrace.emit](../Sources/CodexCore/Telemetry/CodexPerformanceTrace.swift#L30), file append lines 66–87, and main-actor chat-load spans in [CodexCoreAppModel](../Sources/CodexCoreApp/CodexCoreAppModel.swift#L721).
- **Behavior and context:** each trace event prints, logs, enters a serial queue synchronously, creates/checks a directory, creates a formatter, opens, seeks, writes, and closes the trace file. Normal chat resume emits many events; each child adds more.
- **Impact:** diagnostics block the UI and contaminate the latency being measured. Filesystem wakeups and energy grow with child count.
- **Fix / risk:** use a bounded async writer with one formatter and persistent handle, batch flushes, or gate file tracing to diagnostics. Explicit close/flush is required; crash-tail loss and ordering are the tradeoffs.
- **Evidence / verify:** 50 begin/end pairs measured 31.9–49.6 ms in isolation. Emit 1,000/10,000 events from MainActor with a 60 Hz heartbeat and compare p99, missed beats, syscalls, ordering, and end-to-end restore.
- **Overlap:** benchmark H1/H2 after removing or separately accounting for tracing.

### 19 / H3 — Make history-cache capacity apply to protected entries

- **Anchor:** cache capacity in [CodexCoreAppModel](../Sources/CodexCoreApp/CodexCoreAppModel.swift#L68), [CodexThreadHistoryCache.protect](../Sources/CodexCoreUI/CodexThreadHistorySession.swift#L114), and eviction lines 136–147.
- **Behavior and context:** capacity is 20, but protected entries are excluded from overflow and there is no unprotect API. Sending, steering, queuing, goals, and side chat can protect new parent/child histories indefinitely; switching chat does not release them.
- **Impact:** a long-lived session retains the sum of complete histories, and cache touch/count work grows on MainActor despite the apparent cap.
- **Fix / risk:** model temporary active/running/dirty pins, unpin on completion/switch, and enforce an absolute cap plus bounded active allowance. Premature eviction can lose warm or locally mutated state.
- **Evidence / verify:** the lifecycle/control flow is direct and no capacity test exists. Protect 100–1,000 synthetic multi-megabyte histories, then mutate repeatedly; count and RSS should plateau and refresh p99 remain flat.
- **Overlap:** S2 retains another copy even after this cache evicts.

### 20 / S2 — Add lifecycle/eviction to the legacy Store's thread map

- **Anchor:** [CodexCoreStore.threadSnapshotsByID](../Sources/CodexCore/Store/Store.swift#L342).
- **Behavior and context:** hydration and live routing insert complete thread snapshots into the SDK Store, but there is no eviction/removal policy. The app's separate history-cache eviction cannot release this copy.
- **Impact:** loading many large chats grows RSS for the lifetime of the client; per-approval scans and some cache synchronization costs also grow with retained thread count.
- **Fix / risk:** add configurable LRU/explicit removal while pinning active, running, waiting, and required parent/child threads. This changes an implicit SDK lifetime promise: callers may expect threadSnapshot(id:) to remain available forever.
- **Evidence / verify:** no removal path exists. Load 100 multi-megabyte histories and assert bounded count/RSS under the proposed policy, plus correct active/background turn retention.
- **Overlap:** H3 and V8 are separate retained copies of history/subagent state.

### 21 / H4 — Cancel superseded chat restoration at the source

- **Anchor:** selection task in [CodexCoreAppShell](../Sources/CodexCoreApp/CodexCoreAppShell.swift#L37), generation check near [CodexCoreAppModel](../Sources/CodexCoreApp/CodexCoreAppModel.swift#L1170), and invalidation near line 1604.
- **Behavior and context:** each click launches an independent load. Selection generation is checked only after resume, pagination, child hydration, tracing, projections, and cache work; hydrator also turns child errors into results without a cancellation checkpoint.
- **Impact:** quickly selecting B while A loads lets stale A compete for RPC, CPU, memory, MainActor, and cache resources, delaying the requested chat.
- **Fix / risk:** retain/cancel the active load and check cancellation/generation before every page, child request, projection, and Store mutation; propagate CancellationError. Define partial-cache behavior and account for RPCs that cannot be cancelled after send.
- **Evidence / verify:** direct control flow gives high confidence, frequency is interaction-dependent. Use a delayed transport: select A then B and assert no further A child calls/projection/store mutation.
- **Overlap:** H2's serial work makes superseded loads last longer.

### 22 / O2 — Parallelize independent startup and refresh requests

- **Anchor:** [CodexCoreAppModel.connect](../Sources/CodexCoreApp/CodexCoreAppModel.swift#L134), refresh path near line 433, [CodexChatConfigurationSession.refreshStartupCatalogs](../Sources/CodexCoreUI/CodexChatConfigurationSession.swift#L110), and [CodexThreadListSession.refreshRecentChats](../Sources/CodexCoreUI/CodexThreadListSession.swift#L90).
- **Behavior and context:** after the account prerequisite, four catalog reads, two thread lists, remote status/environment, and rate limits largely await in sequence. Separate notification triggers can also launch duplicate untracked refreshes.
- **Impact:** complete ready-state latency approximates the sum of 9–10 service times, and repeated triggers can duplicate work. The shell may paint earlier, but models/sidebar/environment remain incomplete.
- **Fix / risk:** fetch independent immutable responses with bounded async-let/task groups, apply deterministically on MainActor, keep environment dependent on status, and use keyed single-flight/debounce. Preserve partial errors, activity ordering, workspace generation, and server load limits.
- **Evidence / verify:** the connection supports concurrent pending IDs. A delayed mock at 20/100/500 ms should show request overlap and latency near the longest branch rather than the sum, with identical final state/errors.
- **Overlap:** C5 reduces per-response bridge cost; concurrency removes network serialization.

### 30 / S3 — Avoid Store ID scans and eager snapshots on delta events

- **Anchor:** [CodexCoreStore.turnSnapshot](../Sources/CodexCore/Store/Store.swift#L374), turnIndex near line 408, item mutation near line 679, and [CodexChatNotificationPipeline.applyMainNotification](../Sources/CodexCoreUI/CodexChatNotificationPipeline.swift#L218).
- **Behavior and context:** turn/item mutations use linear firstIndex scans. Before payload dispatch, the main pipeline fetches a turn snapshot for every notification even though only boundary cases use it; side-chat fetches one even though its apply method ignores the parameter.
- **Impact:** D deltas over T historical turns add D times T MainActor ID comparisons before the actual reducer. Long histories and high-frequency tokens make the otherwise small scan visible.
- **Fix / risk:** gate snapshot access by notification case, remove the unused side-chat argument, and maintain turn/item indexes plus last-element fast paths. Rebuild indexes after hydration and handle duplicate/optimistic IDs.
- **Evidence / verify:** 5,000 deltas and 1,000 turns mechanically imply five million avoidable comparisons. Benchmark 10/1k/10k turns by 10k deltas and assert zero snapshot calls for pure deltas.
- **Overlap:** S1 and V3 have additional scans after this eager caller.

### 41 / S4 — Parse one item once for legacy timeline and detail projections

- **Anchor:** dual mapping around [CodexCoreStore item application](../Sources/CodexCore/Store/Store.swift#L489), hydration mapping near [ThreadHistoryHydrator](../Sources/CodexCore/Store/ThreadHistoryHydrator.swift#L154), and [TimelineItemMapper](../Sources/CodexCore/Store/TimelineItemMapper.swift#L61).
- **Behavior and context:** live and hydrated items are independently transformed into timelineItem and detail. Both parse command output, file changes/diffs, progress, and tool arguments; structured JSON can be deep-mapped and sorted-serialized more than once.
- **Impact:** item boundaries are less frequent than text deltas, but large tool/file payloads pay overlapping parse/allocation work in both live and cold paths.
- **Fix / risk:** build one normalized parsed intermediate that yields both public projections, or make unused detail projection lazy/configurable. Preserve fallback precedence and public detail compatibility.
- **Evidence / verify:** call paths are direct; magnitude is payload-dependent. Benchmark 10,000 command/tool/file items at 100 KiB and compare both output representations byte-for-byte.
- **Overlap:** H1 removes upstream item JSON bridging; this removes downstream duplicate domain parsing.

## TranscriptV2, observation, and subagent state

### 3 / T1 — Replace dual-stream content fingerprints with one ingress identity

- **Anchor:** Router delivery in [NotificationRouter.route](../Sources/CodexCore/Client/NotificationRouter.swift#L139), consumers in [CodexChatRuntimeSession](../Sources/CodexCoreUI/CodexChatRuntimeSession.swift#L358) and line 464, and [transcriptIngressFingerprint](../Sources/CodexCoreUI/CodexChatRuntimeSession.swift#L550).
- **Behavior and context:** Router yields an active-turn event to both global and scoped streams. Each MainActor path creates a sorted-key JSONEncoder, serializes the full params, Base64-encodes the Data, and consults pending maps to suppress the second delivery.
- **Impact:** every active delta incurs two actor deliveries and two O(payload bytes) encodes; completed items may contain large output/diffs. Base64 expands retained keys and identical-but-distinct deltas make content identity semantically fragile.
- **Fix / risk:** assign a monotonic connection/router delivery ID once and deduplicate by that small ID, or give transcript reduction one owner while scoped streams retain lifecycle completion. Reconnect ID domains and genuinely repeated identical wire events must remain distinct.
- **Evidence / verify:** the checked-in 723-event/209 KiB fixture cost 10–17 ms per stream for fingerprints, roughly 20–34 ms for both. Replay duplicate pairs plus consecutive identical deltas and measure MainActor time, encoded bytes, allocations, and exact reducer count.
- **Overlap:** C2 performs an earlier serialization of the same params; both are independently removable.

### 5 / V1 — Mutate session truth in place instead of forcing copy-on-write

- **Anchor:** [CodexThreadUISessionStore.apply](../Sources/CodexCoreUI/TranscriptV2/CodexThreadUISessionStore.swift#L139) and [CodexSubagentStoreV2.apply](../Sources/CodexCoreUI/TranscriptV2/CodexSubagentStoreV2.swift#L99).
- **Behavior and context:** both stores copy a Session/reducer value out of a dictionary while the dictionary retains the original, mutate nested transcript/turn/group/row arrays, then reinsert. Presented snapshots add another owner.
- **Impact:** every event starts from shared buffers, guaranteeing copy-on-write through increasingly large nested value state before any AppKit projection begins.
- **Fix / risk:** mutate through dictionary subscript/_modify or box reducer truth behind MainActor, while keeping presentation snapshots immutable between publish ticks. Swift exclusivity/reentrancy and snapshot isolation are the correctness constraints.
- **Evidence / verify:** ownership is mechanically guaranteed by dictionary extraction. Replay thousands of deltas over 10/100/217/1,000 turns under allocation profiling and assert identical truth/presentation outputs.
- **Overlap:** S1 is the legacy pipeline's analogous copy; both currently run for each event.

### 6 / V2 — Do not publish observable thread status for token deltas

- **Anchor:** [CodexThreadStatusStore.apply](../Sources/CodexCoreUI/TranscriptV2/CodexThreadUISessionStore.swift#L382), runtime call near [CodexChatRuntimeSession](../Sources/CodexCoreUI/CodexChatRuntimeSession.swift#L489), and shell consumer [sidebarSnapshot](../Sources/CodexCoreApp/CodexCoreAppModel+ViewState.swift#L58).
- **Behavior and context:** every accepted method updates lastEventAt and reassigns observable entries, even when status/unread are unchanged. lastEventAt has no source consumer, but the shell reads entries to build sidebar status.
- **Impact:** token deltas bypass transcript's 17 ms presentation coalescing and can invalidate the root/sidebar at wire rate, triggering grouping/sorting and unrelated view-state getters.
- **Fix / risk:** return early for non-lifecycle methods, make timestamps observation-ignored/coalesced, and assign only on semantic status/unread changes. Preserve inactive-thread unread, started/completed/failed, and waiting transitions.
- **Evidence / verify:** static reader search found no lastEventAt consumer. Add observation/body counters to a 250-delta test; expected status/sidebar changes are zero while lifecycle tests remain identical.
- **Overlap:** O3 multiplies the cost of each root invalidation; V6 removes another root observation source.

### 11 / V3 — Index turns/items and update only the affected timestamp

- **Anchor:** [CodexTranscriptReducerV2.turnIndex](../Sources/CodexCoreUI/TranscriptV2/CodexTranscriptReducerV2.swift#L402), delta handlers lines 358–375, and [ensureStableTimestamps](../Sources/CodexCoreUI/TranscriptV2/CodexThreadUISessionStore.swift#L275).
- **Behavior and context:** delta handlers linearly find the active turn; item events can scan twice. After every apply, the session loops over all turns to ensure timestamps even though only structural insertion can create a missing timestamp.
- **Impact:** per-token reducer work is O(history turns) before parsing/rendering. Active turns are normally last, which is the worst case for firstIndex.
- **Fix / risk:** maintain turnIndexByID/item locations with a last-element fast path and pass changed-turn metadata to timestamp insertion. Indexes must follow hydration, row moves, and optimistic local-ID replacement.
- **Evidence / verify:** direct loops provide high confidence. Benchmark fixed deltas at 10/100/1,000 turns and require near-flat apply time plus reducer fixture equality.
- **Overlap:** S3 removes the eager legacy snapshot scan; this removes the V2 scan.

### 12 / V4 — Accumulate command/reasoning chunks without rebuilding the prefix

- **Anchor:** [appendReasoningDelta and appendCommandOutput](../Sources/CodexCoreUI/TranscriptV2/CodexTranscriptReducerV2.swift#L366).
- **Behavior and context:** command output computes oldString plus delta, then copies the containing row/group. Reasoning trims the entire accumulated String and duplicates it into liveTail on every delta.
- **Impact:** many small chunks make cumulative work quadratic in final output bytes; large command output is also copied by V1's shared transcript buffers.
- **Fix / risk:** keep item-indexed chunk/reference-backed append buffers and materialize public Strings at presentation/completion, or guarantee unique in-place append storage. activeTruthTranscript currently promises immediate truth, so delayed materialization semantics need care.
- **Evidence / verify:** the string expressions mechanically allocate/copy prefixes under shared ownership. Append 1 MiB using 1/16/256-byte chunks and plot time/allocations; final output and intermediate publication order must match.
- **Overlap:** S1 has the same cumulative-string pattern in the legacy Store.

### 23 / V5 — Make growing work-group updates incremental

- **Anchor:** [CodexTranscriptReducerV2.applyWork](../Sources/CodexCoreUI/TranscriptV2/CodexTranscriptReducerV2.swift#L203), collaboration matching lines 233–253, and rowLocation near line 411.
- **Behavior and context:** each work event scans for a row, copies its group, synthesizes a header across all rows, scans all rows for liveness, and refreshes the tail by scanning narrative groups. Collaboration matching rebuilds sets inside nested scans.
- **Impact:** adding K tool/subagent rows to one group approaches quadratic work and allocations, especially in agent/tool-heavy turns.
- **Fix / risk:** keep row-location indexes, incremental category/live counts, stable header state, and precomputed incoming ID/name sets. Group merges and optimistic ID/name updates must maintain indexes.
- **Evidence / verify:** direct nested loops and value copies give high confidence. Replay 10/100/1,000 row starts/completions and wide/deep collaboration fixtures; require linear scaling and exact headers/order.
- **Overlap:** V1 amplifies copied group buffers; V8 covers separate panel/graph recomputation.

### 31 / V6 — Isolate presentation observation inside the transcript host

- **Anchor:** root read in [CodexCoreAppShell.chatWorkspace](../Sources/CodexCoreApp/CodexCoreAppShell.swift#L189), [CodexCoreAppModel.transcriptV2](../Sources/CodexCoreApp/CodexCoreAppModel+ViewState.swift#L23), and [CodexTranscriptViewV2.effectivePresentation](../Sources/CodexCoreUI/TranscriptV2/CodexTranscriptViewV2.swift#L106).
- **Behavior and context:** the shell passes both a transcript value and sessionStore. When the store has an active presentation, the transcript view ignores the passed value and observes the store itself; effectivePresentation is also evaluated twice in body.
- **Impact:** every 17 ms presentation revision can rebuild the whole workspace and the transcript child, even though only the latter needs the change.
- **Fix / risk:** when sessionStore is supplied, keep observation inside the transcript host and stop reading/passing the root snapshot; bind effectivePresentation once. Preserve standalone/fallback embedding, empty state, approvals, and thread switches.
- **Evidence / verify:** the dependency chain is explicit. Use SwiftUI change logging/signposts; root-body count should stop following presentation revisions while transcript updates remain identical.
- **Overlap:** V2 is a second per-token root invalidator; fix both before measuring shell work.

### 35 / V7 — Bound and coalesce pre-hydration event queues

- **Anchor:** Session.pendingEvents in [CodexThreadUISessionStore](../Sources/CodexCoreUI/TranscriptV2/CodexThreadUISessionStore.swift#L70), append near lines 143–145, and synchronous replay lines 191–196.
- **Behavior and context:** while history is loading, every full raw event is retained without a count/byte bound. A failed or slow load can accumulate indefinitely; successful restore replays the entire queue on MainActor.
- **Impact:** chatty live turns during cold load can spike memory and then produce a long synchronous catch-up stall.
- **Fix / risk:** coalesce consecutive pure deltas by item, use a sequence boundary around off-main history construction, and cap with authoritative resync/failure recovery. Ordering around item start/completion, approvals, and repeated identical deltas must be exact.
- **Evidence / verify:** storage/replay loops are direct; scale depends on server/load delay. Delay hydration while injecting 100,000 deltas, record RSS/replay latency, and compare final transcript byte-for-byte.
- **Overlap:** H2/H4 lengthen the period during which this queue grows.

### 36 / V8 — Cache subagent order/count and scope retained transcripts

- **Anchor:** [CodexSubagentStoreV2.agents](../Sources/CodexCoreUI/TranscriptV2/CodexSubagentStoreV2.swift#L51), workingCount lines 59–63, runtime descendant selection [CodexChatRuntimeSession](../Sources/CodexCoreUI/CodexChatRuntimeSession.swift#L557), and agentsByID near line 47.
- **Behavior and context:** every getter sorts/copies the dictionary; the panel asks for agents and workingCount separately. Descendant selection sorts then repeatedly scans to closure. agentsByID retains every child transcript across parent chats with only runtime-wide reset.
- **Impact:** normal counts are small, but large swarms make getters/closure approach O(A log A) to O(A squared), and old child transcripts accumulate memory.
- **Fix / risk:** cache ordered IDs and working count by revision, maintain parent-to-children adjacency, and apply a parent-scoped LRU aligned with warm transcript sessions. Metadata/path changes must invalidate ordering and active descendants cannot be evicted.
- **Evidence / verify:** static loops and retention are explicit. Benchmark 100/1,000 wide/deep agents, repeated panel bodies, closure queries, and 100 parent chats; assert count/RSS plateau and exact order.
- **Overlap:** H3/S2 are separate parent-history retention layers.

### 46 / V9 — Replace per-tick sleeping Tasks with one cadence scheduler

- **Anchor:** [CodexThreadUISessionStore.schedulePresentationIfActive](../Sources/CodexCoreUI/TranscriptV2/CodexThreadUISessionStore.swift#L283).
- **Behavior and context:** each event burst creates a Task that sleeps until the next 17 ms presentation boundary, publishes, then the next burst creates another. Sustained streaming produces roughly 60 short-lived Tasks per second.
- **Impact:** Task allocation/scheduling is small compared with projection, but it is guaranteed steady overhead and another cancellation/lifecycle surface.
- **Fix / risk:** keep one long-lived cadence loop/display-link-style scheduler per active session and signal dirty state. Activation, deactivation, immediate flush, and shutdown cancellation must remain deterministic.
- **Evidence / verify:** mechanism is direct; aggregate impact is low. Instrument task creation and scheduler wakeups during a five-minute stream and compare CPU/allocations plus publication timestamps.
- **Overlap:** A1 is the much larger downstream consequence of the same cadence.

## AppKit transcript, block projection, parsing, and layout

### 1 / A1 — Make projection incremental and non-starvable

- **Anchor:** [CodexTranscriptCollectionView.updateNSView](../Sources/CodexCoreUI/TranscriptV2/AppKit/CodexTranscriptCollectionView.swift#L43), coordinator update lines 131–169, requestProjection lines 242–262, and the full loop in [CodexTranscriptRenderProjector.project](../Sources/CodexCoreUI/TranscriptV2/AppKit/CodexTranscriptRenderProjection.swift#L291).
- **Behavior and context:** every representable update unconditionally cancels the current task and starts a new projection of every turn/item, rebuilding copy-turn text and derived drafts even when one tail item changed. Transcript presentation arrives every 17 ms; cancellation checks occur inside the full pass.
- **Impact:** when projection exceeds cadence, sustained streaming can cancel every pass before completion, freezing visible updates until a quiet gap while burning CPU on partial work. Unrelated parent updates can start the same work.
- **Fix / risk:** publish dirty-turn/item and structure generations from the reducer; retain per-turn render fragments; skip no-op updateNSView calls; run one projector that merges latest dirty state instead of cancel/restart. Theme/width changes still invalidate all, and deletions, approvals, final/work transitions, stable IDs, and ordering need exhaustive tests.
- **Evidence / verify:** isolated release harness on this commit measured 23.966 ms average and 31.267 ms max for 1,085 items/120 frames, above the 17 ms cadence; debug measured 33.115/53.421 ms. Run 1k/5k rich items for five seconds at 60 Hz and record scheduled/completed/cancelled projections, p95 publication-to-apply, CPU, and continued frame completion.
- **Overlap:** A2/P1/P2/D1 are costs inside each pass; V6 reduces unrelated pass triggers.

### 7 / A2 — Preserve exact source/tail offsets for streaming block reuse

- **Anchor:** [CodexBlockProjector.reusePrevious](../Sources/CodexCoreUI/CodexBlockProjection.swift#L297), previousText lines 341–364, production source cache in [CodexTranscriptRenderProjection](../Sources/CodexCoreUI/TranscriptV2/AppKit/CodexTranscriptRenderProjection.swift#L614), and CodexBlock.contentDigest near line 34.
- **Behavior and context:** each append reconstructs the entire prior Markdown source from rendered blocks, prefix-compares/counts/traverses it, copies the suffix, concatenates the tail, and reparses. Reconstruction is lossy for headings/lists/tables, causing reuse to fail. contentDigest also rescans immutable UTF-8 content repeatedly.
- **Impact:** a single growing answer performs O(total prior text) work per delta and approaches quadratic cumulative time. Formatting/table streams can rebuild completed blocks and attributed strings.
- **Fix / risk:** retain exact raw source, stable-boundary UTF-8 offset, and incremental tail state; compute immutable block digests once. Unicode boundaries and Markdown structures whose new suffix changes earlier interpretation are the correctness risk.
- **Evidence / verify:** a 200-row by 8-cell streaming table took 8.218 s cumulatively and grew from 0.536 ms to 78.7 ms per frame. Stream 100 KiB/1 MiB prose, headings, fences, and tables in small chunks and compare last/first-decile time, rebuild count, and render equivalence.
- **Overlap:** P2 adds duplicate cell parsing after reuse fails; A1 repeats the work across all items.

### 10 / A3 — Evict streaming prefixes by content cost and source identity

- **Anchor:** prepared-text cache fields and limits in [CodexTranscriptRenderProjection](../Sources/CodexCoreUI/TranscriptV2/AppKit/CodexTranscriptRenderProjection.swift#L263), use around lines 918–953, and eviction lines 1045–1066.
- **Behavior and context:** each answer prefix gets a unique prepared NSAttributedString; combined selection surfaces can contain the entire message. FIFO eviction starts only after 8,192 entries and is not byte/cost aware.
- **Impact:** streaming a long answer in small chunks can retain the sum of successively larger prefixes, approaching quadratic retained characters and causing RSS/allocator pressure across warm threads.
- **Fix / risk:** keep only the latest ephemeral prepared value per streaming source, promote final stable blocks into a weighted LRU/NSCache, and charge attributed/string bytes. Markdown tail edits can invalidate earlier styling, so only proven stable blocks may be shared.
- **Evidence / verify:** the existing harness confirms one new prepared miss per each of 120 frames. Stream 100 KiB in 1/8/32-byte chunks and measure cache entries, estimated/actual bytes, RSS after completion, and projection p95.
- **Overlap:** A2 reduces the number/size of new values; A6 defines thread-scoped eviction.

### 13 / A4 — Avoid global flow-layout invalidation for one changed item

- **Anchor:** [CodexTranscriptCollectionView.Coordinator.apply](../Sources/CodexCoreUI/TranscriptV2/AppKit/CodexTranscriptCollectionView.swift#L287), especially ID/set work lines 298–340 and invalidation/layout lines 373–425.
- **Behavior and context:** apply flattens all IDs, constructs sets, compares full section dictionaries, scans common IDs for geometry, then requests both delegate metrics and layout attributes and synchronously forces layout. This runs even for a stable one-item tail and can run while that tail is offscreen/unpinned.
- **Impact:** main-thread work remains O(all items) and the flow layout can ask for global size information, weakening the intended targeted reconfigure.
- **Fix / risk:** carry structure generation and changed geometry directly, fast-path stable structure using changedItemIDs only, and consider a one-column cached layout that adjusts one height/content offset. Preserve bottom following, raw-offset restoration, section gaps, hosted preferred heights, and structural animation.
- **Evidence / verify:** the historical isolated AppKit result reported 2.389 ms targeted apply, but current code performs more work. Count sizeForItemAt calls and main-thread layout time for 1k/5k/10k items, pinned and unpinned, and require work proportional to changed visible items.
- **Overlap:** A1 is off-main projection starvation; this is the main-thread apply/layout stage.

### 14 / P1 — Compile directive syntax once and skip impossible text

- **Anchor:** [CodexInlineDirectiveParser.parse](../Sources/CodexCore/Parser/CodexInlineDirective.swift#L15), split lines 33–52, and active call from [CodexTranscriptRenderProjection.contentDrafts](../Sources/CodexCoreUI/TranscriptV2/AppKit/CodexTranscriptRenderProjection.swift#L714).
- **Behavior and context:** split visits every line of prose/final content during a full projection, and parse constructs the same NSRegularExpression per line before knowing whether the line can contain a directive.
- **Impact:** long directive-free history pays repeated regex compilation and line allocations in each A1 pass.
- **Fix / risk:** use a static compiled regex plus a cheap first-non-whitespace double-colon gate; cache source partitions by item revision where appropriate. Preserve exact whitespace/escaping grammar.
- **Evidence / verify:** release microbenchmark at 8,000 lines measured 53.0 ms current versus 6.43 ms with one regex. Test 1k/4k/8k lines with no/sparse directives and changing tails, plus the full directive suite.
- **Overlap:** A1 determines how often stable text reaches the parser.

### 15 / P2 — Parse GFM table cells once and cache at row/cell granularity

- **Anchor:** [CodexTableModel.init](../Sources/CodexCoreUI/CodexBlockProjection.swift#L90), table source reconstruction around line 523, and AppKit cell preparation [CodexTranscriptRenderProjection](../Sources/CodexCoreUI/TranscriptV2/AppKit/CodexTranscriptRenderProjection.swift#L1236).
- **Behavior and context:** the shared table model eagerly Markdown-parses every body cell into attributedRows, but AppKit ignores those values and reparses raw cells. AppKit's cache key uses the whole block digest, so one changing cell invalidates all rows; lossy table reconstruction also defeats A2 reuse.
- **Impact:** large or streaming tables duplicate Markdown work and make per-frame cost grow with all cells rather than the changed tail.
- **Fix / risk:** retain raw cells with renderer-owned lazy prepared values or reuse the shared parsed cells; cache by row/cell revision and carry exact source boundaries. Alignment, escaped pipes, and renderer-specific attributes must remain correct.
- **Evidence / verify:** 100 by 8 cells measured 47.721 ms GFM parse, including 44.705 ms model construction, plus 10.050 ms AppKit cell preparation; 400 by 8 took 204.296 ms. Benchmark one-cell streaming invalidation and assert unchanged-cell cache hits.
- **Overlap:** A2 owns exact streaming reuse; P2 owns duplicate parsing/invalidation.

### 16 / D1 — Create one revision-keyed diff analysis and reuse it

- **Anchor:** AppKit parse in [CodexTranscriptRenderProjection](../Sources/CodexCoreUI/TranscriptV2/AppKit/CodexTranscriptRenderProjection.swift#L458), parser [CodexUnifiedDiffParser.parse](../Sources/CodexCoreUI/TranscriptV2/CodexDiffModel.swift#L23), shell review getter [CodexCoreAppModel.gitReviewSession](../Sources/CodexCoreApp/CodexCoreAppModel+ViewState.swift#L179), prompt summary [CodexPromptPanels](../Sources/CodexCoreUI/CodexPromptPanels.swift#L63), and workspace totals [CodexWorkspaceSummaryContext](../Sources/CodexCoreUI/CodexWorkspaceSummaryContext.swift#L29).
- **Behavior and context:** an unchanged raw diff is split/materialized for visible file rows before expansion checks and separately rescanned into review files, prompt counts, and workspace totals during root evaluation.
- **Impact:** unrelated answer/status/root updates can repeatedly do O(diff bytes) allocation on both projector and MainActor. Large generated diffs can exceed a frame budget per duplicate analysis.
- **Fix / risk:** build one CodexDiffAnalysis keyed by a cheap content revision, with aggregate counts and lazy per-file hunks; parse detailed patches only on expansion. Invalidate on patch update, branch/thread change, staging/review state, and nil reset without losing review drafts.
- **Evidence / verify:** replicated algorithms measured a 1.12 MB diff at about 123 ms prompt summary, 40 ms workspace totals, and 130 ms review parse. Run 120 unrelated updates with 100 KiB/1 MiB diffs; expect one analysis per revision and one detailed parse per expanded row.
- **Overlap:** V2/O3 create unrelated root updates; A1 creates unrelated projector updates.

### 33 / A5 — Reuse TextKit content/layout work inside reused cells

- **Anchor:** [CodexTranscriptCollectionCell](../Sources/CodexCoreUI/TranscriptV2/AppKit/CodexTranscriptCollectionCell.swift#L110), text binding/layout around lines 388–425 and 887–910, and code measurement [CodexTranscriptRenderProjection](../Sources/CodexCoreUI/TranscriptV2/AppKit/CodexTranscriptRenderProjection.swift#L1070).
- **Behavior and context:** a changed/materialized text cell replaces its entire NSTextStorage. Code width is measured off-main during projection, discarded, and synchronously measured again during viewDidLayout.
- **Impact:** view reuse saves hierarchy allocation but not glyph/layout work; newly visible long prose/code and streaming revisions can still block the main thread, especially during scroll/resize.
- **Fix / risk:** carry measured width, skip rebinding identical prepared identity/revision, and replace only changed suffix/block ranges where TextKit permits. Tabs/fonts, link detection, selection, and Markdown restyling must remain exact.
- **Evidence / verify:** duplicate call sites are explicit; frame impact depends on content. Scroll alternating 40k-code and 100k-prose items at 120 Hz and instrument text-storage replacements, boundingRect calls, bind/layout p95, and selection preservation.
- **Overlap:** A3 retains prepared values but A5 determines whether the cell reuses them efficiently.

### 34 / A6 — Retain bounded per-thread render warmth across A to B to A

- **Anchor:** cache filtering in [CodexTranscriptRenderProjection](../Sources/CodexCoreUI/TranscriptV2/AppKit/CodexTranscriptRenderProjection.swift#L580), coordinator filtering near [CodexTranscriptCollectionView](../Sources/CodexCoreUI/TranscriptV2/AppKit/CodexTranscriptCollectionView.swift#L294), and warm-swap test near line 726.
- **Behavior and context:** item IDs include thread ID, but each projection filters revisions, heights, block sources, and hosted preferred heights to only the current thread's live IDs. Switching to B evicts A; returning reprojects/remeasures A.
- **Impact:** warm chat switching preserves session truth/scroll offset but discards rendering warmth, increasing switch latency for long threads.
- **Fix / risk:** keep bounded ThreadRenderState per warm session, aligned with the 12-session LRU, with a separate weighted shared prepared cache. More RSS is the tradeoff; evict on session and theme-generation lifecycle.
- **Evidence / verify:** the current warm-swap test checks offset, not hits/misses. Require zero stable height/block misses on third A activation and measure projection/layout/RSS across 12 sessions.
- **Overlap:** A3 governs byte cost within each retained thread.

### 40 / Q1 — Gate algorithmic performance regressions, not only correctness counters

- **Anchor:** [CodexTranscriptAppKitPerformanceTests](../Tests/CodexCoreUITests/CodexTranscriptAppKitPerformanceTests.swift#L66).
- **Behavior and context:** the harness prints average/max duration but asserts only item count, one changed item, one height miss, and one prepared miss. It uses tiny text, collapsed completed work, and sequential projection—not rich code/table/diff/product content or 17 ms cancellation pressure.
- **Impact:** the current release run averages 23.966 ms yet remains green; a regression that prevents real-time projection has no automated signal.
- **Fix / risk:** keep deterministic counters and add cache-byte, parser-call, layout-size-call, cancellation/completion, and scaling assertions. Run an idle release benchmark lane with broad regression bands rather than brittle debug wall-clock thresholds.
- **Evidence / verify:** isolated debug/release results above and source assertions demonstrate the gap. Rebaseline current AppKit/Fable features and store versioned benchmark artifacts.
- **Overlap:** this is the verification umbrella for A1–A6, P1–P2, and D1.

### 45 / A7 — Update product-tool hosting views in place

- **Anchor:** [CodexTranscriptCollectionCell product host configuration](../Sources/CodexCoreUI/TranscriptV2/AppKit/CodexTranscriptCollectionCell.swift#L358), especially lines 461–466 and 573–584.
- **Behavior and context:** any dynamic product-tool reconfigure removes the existing NSHostingView and creates a new one, discarding SwiftUI subtree state and intrinsic-size work.
- **Impact:** product tools are rare, so overall priority is low-medium; a rich live tool with frequent revisions still causes avoidable allocations/layout callbacks.
- **Fix / risk:** retain the host for the same item/renderer identity and update rootView; recreate only when identity/type changes. Ensure environment/theme and intended host-owned state refresh correctly.
- **Evidence / verify:** object churn is explicit. Replay 120 revisions of a stateful hosted tool and count hosting-view allocations, layout passes, preferred-height callbacks, and state preservation.
- **Overlap:** A4 handles resulting preferred-height/layout invalidation.

## App shell, workspace tools, navigation, and files

### 26 / U1 — Mount only the selected heavy workspace surface

- **Anchor:** panel capacity in [CodexCoreAppModel](../Sources/CodexCoreApp/CodexCoreAppModel.swift#L70), mounted states [CodexWorkspacePanelStore](../Sources/CodexCoreApp/CodexWorkspacePanelStore.swift#L24), union in [CodexChatWorkspace](../Sources/CodexCoreUI/CodexChatWorkspace.swift#L458), and ZStack surfaces in [CodexAgentPanels](../Sources/CodexCoreUI/CodexAgentPanels.swift#L347).
- **Behavior and context:** up to 20 chats' terminal/browser/files/preview sessions are unioned and every surface is mounted in ForEach stacks; inactive ones are hidden with opacity rather than removed.
- **Impact:** opening the deck can create/reload hidden previews and outlines, attach retained WKWebViews, and keep heavy background surfaces alive. Costs scale with recent tool-using chats rather than the selected tool.
- **Fix / risk:** mount only the selected view; retain lightweight session models separately and keep a small global LRU of heavy live surfaces/results. Detaching WKWebView/terminal must preserve focus, navigation, and liveness expectations.
- **Evidence / verify:** the static mount path is direct; typical magnitude needs UI instrumentation. Populate 20 chats with tool tabs and measure panel-open time, load count, RSS, WebContent processes, and background CPU.
- **Overlap:** U2–U4 are multiplied by hidden preview/file surfaces.

### 27 / U2 — Cancel actual preview workers and cache tree-sitter queries

- **Anchor:** [CodexFilePreviewLoader.highlight](../Sources/CodexCoreUI/CodexFilePreviewView.swift#L124), resource lookup lines 152–175, and task lifecycle near line 206.
- **Behavior and context:** cancelling the outer preview task does not cancel its detached read/parse worker; cancellation is checked only after awaiting it. Every load rescans bundles and constructs Language/Query/parser capture machinery.
- **Impact:** rapid tab switching or many hidden previews can finish obsolete reads/highlights and repeatedly compile identical grammar queries.
- **Fix / risk:** retain/cancel the actual worker, use generation checks before/after read and parse, and cache Language/Query by grammar while keeping parsers task-local. Query thread safety and bundle/resource lifetime need validation.
- **Evidence / verify:** task nesting and construction are explicit. Rapidly select 100 same-language 512 KiB files; count query builds, parses completed after final selection, cancellation latency, CPU, and final highlight correctness.
- **Overlap:** U1 determines how many preview views can request work.

### 28 / U3 — Move directory enumeration and metadata sorting off MainActor

- **Anchor:** [CodexFilesNode.loadChildren](../Sources/CodexCoreUI/CodexFilesToolView.swift#L66) and outline callbacks near lines 280–303; selection scan lines 330–341.
- **Behavior and context:** expanding a node synchronously calls contentsOfDirectory, requests resource values for every child, and performs localized sorting from AppKit outline callbacks. Selection updates scan every visible row.
- **Impact:** large, cold, removable, or network directories can directly hitch the UI thread.
- **Fix / risk:** load asynchronously with generation-aware placeholder/result application, index nodes by URL, and use row(forItem:) for selection. Expansion/collapse races, refresh, and selection preservation require tests.
- **Evidence / verify:** blocking calls are directly on the main-actor callback path. Expand 10,000-entry APFS and network directories with signposts; measure blocked main-thread p95 and correct race behavior.
- **Overlap:** U1 can mount several outlines simultaneously.

### 29 / U4 — Use an O(1) preview revision instead of rehashing the full text

- **Anchor:** [CodexFilePreviewView.updateNSView](../Sources/CodexCoreUI/CodexFilePreviewView.swift#L307) and [CodexCodeTextView.apply](../Sources/CodexCoreUI/CodexFilePreviewView.swift#L344).
- **Behavior and context:** every representable update computes text.hashValue before it can discover the content is unchanged. Preview text is allowed up to 2 MiB.
- **Impact:** a no-op parent update performs an O(file bytes) MainActor scan; hidden mounted previews multiply it.
- **Fix / risk:** have the loader publish a content revision incorporating URL, generation/mtime/content identity, and theme revision; compare that before touching text. Missing an external-edit/theme invalidation would show stale content.
- **Evidence / verify:** optimized 2 MiB String.hashValue measured about 3.2 ms per call. Mount several 2 MiB previews and drive tab/resize/parent updates while counting bytes hashed and apply time.
- **Overlap:** U1 controls multiplicity; U2 controls upstream parsing.

### 32 / O3 — Reuse one sidebar snapshot per root evaluation

- **Anchor:** reads in [CodexCoreAppShell.body](../Sources/CodexCoreApp/CodexCoreAppShell.swift#L15), lines 89 and 208; projection in [CodexSidebarNavigationSession.snapshot](../Sources/CodexCoreUI/CodexSidebarNavigation.swift#L240).
- **Behavior and context:** body creates a local sidebarSnapshot but overlay/chatWorkspace bypass it and call the computed projection again. Each pass normalizes paths, builds sets/dictionaries, groups chats, sorts pinned/project rows, maps, and filters.
- **Impact:** chat/search routes can do the same allocation/sort work three times per root invalidation, including V2 token/status invalidations.
- **Fix / risk:** pass the single local snapshot or needed collapsed flag through helpers. Optional cross-update memoization must invalidate chats, projects, pins, statuses, selection, and the time-based recent/older cutoff; same-evaluation reuse is low risk.
- **Evidence / verify:** only this shell calls the computed property and the three reads are explicit. Instrument 100/1,000/10,000 chats over 1,000 root updates and compare projection count, allocations, and frame time.
- **Overlap:** V2/V6 control invalidation frequency; O3 reduces work per invalidation.

### 44 / U5 — Avoid per-row catalog-wide selection lookup

- **Anchor:** row rendering in [CodexPluginRouteView](../Sources/CodexCoreUI/CodexPluginRouteView.swift#L251) and [CodexPluginRouteState.selectedDetail](../Sources/CodexCoreUI/CodexIntegrationCatalogModels.swift#L948).
- **Behavior and context:** every rendered plugin/skill row asks selectedDetail, which scans the full catalog and may redo visible filtering. With all rows materialized, selection checks approach visible rows times catalog size.
- **Impact:** current catalogs may be modest, so priority is low-medium; large installed plugin/skill inventories make search, selection, and scrolling unnecessarily quadratic.
- **Fix / risk:** compare row IDs to selected IDs directly and compute selected detail once for the detail pane. Preserve plugin-versus-skill identity and filtered-selection fallback.
- **Evidence / verify:** static call shape is direct. Benchmark 10/100/1k/5k entries with first/middle/last selections and count list scans/body time.
- **Overlap:** startup catalog serialization/concurrency is O2/C5; this is steady-state UI lookup.

## Generated code and build-time opportunities

### 39 / G1 — Generate only schema surface the runtime or public API needs

- **Anchor:** blanket enum conformance in [generate_app_server_schema_types.py](../Tools/generate_app_server_schema_types.py#L153), public struct initializers near line 201, inventory emission near line 334, and generated inventory [AppServerSchemaTypes.swift](../Sources/CodexCore/Generated/AppServerSchemaTypes.swift#L6656).
- **Behavior and context:** 102 schema enums receive CaseIterable although in-repo runtime does not enumerate them; all 389 structs get public memberwise initializers although only about 20 are explicitly constructed; 1,106 lines of schema inventory are used by tests and exposed without a production caller.
- **Impact:** unnecessary source, type-check work, exported symbols, object/link size, and downstream compile surface. It is build-size rather than hot runtime work because static lets are lazy.
- **Fix / risk:** retain CaseIterable only for method enums/allowlisted uses, emit initializers only for request/reachable construction types, and move validation manifests to test support. All three can break downstream source/API and require a compatibility/major-release decision.
- **Evidence / verify:** removing schema CaseIterable cut 44,944 optimized non-debug object bytes and 306 symbols; removing inventory cut 70 KB; removing all memberwise initializers cut source by 102 KB, 389 exported symbols, isolated dylib by 108,880 bytes, and warm isolated type-check from 3.38–3.44 s to 1.64–2.13 s. Benchmark a selective allowlist and API-diff before adoption.
- **Overlap:** file sharding and grammar pruning were not accepted: sharding lacks an A/B build, and every grammar is actively supported.

## Lower-level accepted nitpicks and compound effects

The following small changes are already represented in the detailed findings above and should be applied only after their parent stage is simplified:

- In C2, switch on the existing CodexAppServerNotificationMethod tag rather than comparing raw strings a second time. Ten-million-call isolated medians improved by roughly 63–126 ns/call; end-to-end impact is deliberately ranked below eliminating payload serialization.
- In A2, store CodexBlock.contentDigest when the immutable block is built. Current AppKit draft paths read the computed full UTF-8 digest multiple times and list blocks allocate joined text.
- In V3, use a last-turn/item fast path even if full index maps are deferred; streaming normally targets the final element.
- In O3, passing the already-computed local snapshot is a safe one-render fix even if cross-render caching is postponed.
- In C5, construct TurnStart metadata without input now; it is a low-risk caller-local improvement even before redesigning typed wire encoding.

## Rejected, stale, or deliberately downgraded claims

- The historical quadratic stdio newline rescan is fixed by commit ff5763c. Current CodexLineBuffer uses scan cursors and periodic compaction; only C4's per-line copy remains.
- Old SwiftUI transcript claims about a broad LazyVStack responder/hover forest, whole-turn hosting, no cell reuse, and completion-wide selection reset are stale on current AppKit.
- Per-token broad NSCollectionView reload is stale: current code has stable IDs and targeted reconfigure. A4 is narrower—the targeted path still performs global ID/layout-metric work.
- Interactive resize remeasuring each width tick, equal-width flow corruption, code clipping, reusable chip leakage, and user-bubble trailing-line issues were fixed in the latest AppKit/Fable merge history.
- WebSocket per-message overhead was not promoted because the repository has no production caller for that transport path.
- CodeReviewPayloadParser and AssistantRenderBlockParser have demonstrable quadratic public-parser fallbacks, but no in-repository production caller at HEAD; they are excluded from the ranked runtime report.
- CodexToolCallCardParser/CodexToolCallMarkdownParser similarly lack a live production caller.
- CodexProseCache's undercharged byte limit is in the dormant SwiftUI transcript path; the active AppKit prepared cache is covered by A3 instead.
- Bottom-terminal monolithic output would scale poorly, but the only current product action emits one small echo command.
- Generic SwiftUI style advice about ForEach(enumerated), GeometryReader, Grid, animation, or theme construction was rejected without a demonstrated expensive active workload.
- Reordering CodexJSONValue scalar decode probes, globally sharing JSONEncoder/JSONDecoder, and small coercion-helper rewrites produced unstable/sub-2-percent wins or add concurrency risk; removing whole serialization passes has priority.
- Sharding the 7,761-line generated file is plausible but lacks a clean A/B build; it is a benchmark proposal, not an accepted win.
- Tree-sitter grammar dependency pruning changes supported languages; all declared grammar products are imported and dispatched.

## Verification and benchmark plan

Verification completed during the audit:

- origin/main freshness confirmed at e5d41c1 after fetch.
- Isolated debug AppKit performance test passed: 33.115 ms average, 53.421 ms max.
- Isolated release AppKit performance test passed: 23.966 ms average, 31.267 ms max.
- Focused reducer/store/diff, dual-stream ingress, hydrator, reconnect, command-stream, and git-review tests run by audit slices passed.
- Worktree remained free of production changes; this report is the only intended file change.

Recommended benchmark order, to prevent double-counting:

1. End-to-end replay the 2,318-frame corpus through transport, Connection, Client, legacy Store, Router, runtime, TranscriptV2, projector, and collection apply; record per-stage CPU, allocations, MainActor time, latency, and RSS.
2. Remove/measure C1, C2, and T1 independently, then repeat the full pipeline.
3. Compare legacy Store enabled versus coalesced/optional and profile S1/V1/V3/V4.
4. Add a five-second 60 Hz rich streaming test with cancellation/completion counters for A1.
5. Add payload matrices: 200 B/64 KiB/4 MiB frames; 1/10/50 MiB turn input; 100 KiB/1 MiB diffs; 100 KiB/1 MiB streaming prose; 100 by 8 and 400 by 8 tables.
6. Add lifecycle/RSS tests for 100 chats, protected history, Store snapshots, subagents, warm render state, and slow/failed hydration.
7. Add delayed deterministic mocks for child hydration, startup concurrency, superseded selection, backpressure, and reconnect shutdown.

## Suggested implementation sequence

No fixes were implemented, but the dependencies imply this order:

1. Add stage-level benchmarks and stable ingress IDs.
2. Decode one envelope and remove Router/content fingerprint serialization.
3. Coalesce or bypass duplicate legacy Store transcript publication and make both stores mutate indexed truth.
4. Publish dirty-turn/item metadata and make AppKit projection non-starvable.
5. Fix block/directive/table/diff cache granularity and global layout invalidation.
6. Bound lifecycle caches/queues, parallelize cold-load RPCs, and cancel stale work.
7. Apply file-tool, navigation, reconnect, and generated-code nitpicks.
