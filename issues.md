# Protocol architecture remediation

Tracking issue: https://github.com/slopwareinc/codexcore/issues/124

This document records the evidence, invariants, and intended commit slices from the
2026-07-14 runtime and wire-protocol audit. It is deliberately kept in the fix
worktree so implementation decisions remain reviewable with the code.

## Protocol invariants

1. The app-server emits each JSON-RPC notification once. The client may expose it
   through global and scoped stream Interfaces, but a semantic projection must
   reduce it exactly once.
2. Both agent item grammars are required:
   - `collabAgentToolCall` has started/completed lifecycle items.
   - `subAgentActivity` is commonly completed-only and can coexist with classic
     `wait` calls in ultra mode.
3. Two wire Adapters do not justify two agent-state Implementations. Historical
   and live agents must converge on one root-scoped graph.
4. `thread/read(includeTurns:true)` owns the real turn envelope: ID, status,
   error, timestamps, duration, item view, and items. History must not flatten
   that envelope into fabricated turns.
5. `TurnError` is structured. Its user-facing message is in `error.message`.
6. Ultra agent history identifies a child through `agentThreadId`.
7. Agent source metadata is nested at
   `source.subAgent.thread_spawn.{parent_thread_id,depth,agent_path,...}`.
8. Official clients recursively list/read descendants. Historical hydration must
   do the same with a visited set and per-child failure retention.
9. Child thread history can contain inherited parent-prefix turns. Exact parent
   turn IDs must not be duplicated into the child-owned transcript.

## Confirmed defects

### 1. Transcript V2 has two live ingress owners — critical

Disposition: fixed on `codex/architecture-protocol-integrity`. The global stream
is the sole Transcript V2 ingress; the scoped main-turn stream retains lifecycle
and focused-state projection.

`NotificationRouter` yields one notification to the global stream and its turn
stream. `CodexChatRuntimeSession` currently invokes `applyToTranscriptV2` in both
consumers. A deterministic reproduction routed one `WIRE` delta and produced
`WIREWIRE`.

Required change: preserve both stream Interfaces, but nominate one transcript
owner. In the application the permanent global stream is the transcript ingress;
the scoped main-turn stream remains responsible for turn lifecycle and focused
state updates.

### 2. Protected cache refresh erases Transcript V2 — critical

Disposition: fixed. Restore results require an explicit lossless Transcript V2
payload, and protected live refreshes snapshot the runtime transcript and current
pagination state instead of constructing a default-empty replacement.

`refreshThreadHistoryCache` constructs a restore result without V2 items. The
default empty array overwrites the populated protected entry. Switching away and
back restores an empty reducer.

Required change: cache a lossless transcript/history payload, not a flattened or
default-empty reconstruction. A tactical "keep old values when empty" rule is
unsafe because it would stale legitimate live mutations.

### 3. Agent state has competing owners — high

Disposition: excluded from this remediation by delegated scope. Agent-store
unification and presentation merge behavior are unchanged.

History populates `CodexAgentStateMapper`; live traffic populates
`CodexSubagentStoreV2`. Presentation uses an all-or-nothing fallback. Discovering
one live agent therefore hides every historical agent. The stores also disagree
on close/wait statuses.

Required change: normalize both grammars, history, and metadata into one agent
graph. At minimum merge by thread ID with live facts overriding stale historical
facts; the target architecture gives one store complete ownership.

### 4. Global agent traffic is not root-scoped — high

Disposition: excluded from this remediation by delegated scope. Agent discovery
and root-scoped agent projection are unchanged.

Transcript reduction rejects another thread's notification, but agent reduction
runs unconditionally. A foreign spawn appears in the selected thread's agent UI.

Required change: validate the root thread before applying main agent projection.
Child-thread transcript events remain valid when the child belongs to the current
root graph.

### 5. History destroys turn envelopes — high

Disposition: fixed for Transcript V2 history restoration. Real schema turn
envelopes now retain stable order and IDs, exact wire status, timing, items view,
and structured `TurnError`, including empty/no-user turns.

History flattens all `turns[].items`. The reducer fabricates `history-*` IDs and
forces done status without timing or errors. Two real turns, including a failed
turn with no user message, restored as one successful `history-1` turn.

Required change: restore from raw/schema turn envelopes and preserve order, IDs,
status, duration, timestamps, structured error, and empty/no-user turns.

### 6. Structured errors are misread — high

Disposition: fixed for non-agent live and history paths. A shared exact
`TurnError` adapter feeds client/store and Transcript V2 projections; generic
errors retain their turn identity and `willRetry` keeps retrying turns active.
Live completion also preserves an explicit failed wire status when the server
does not include an error payload.

Live completion, generic error notifications, thread hydration, and historical
agent projection look for a string where the protocol supplies `TurnError`.

Required change: centralize exact error-message extraction and account for
`willRetry` without prematurely making a retrying turn terminal.

### 7. Ultra and nested history hydration are incomplete — high

Disposition: excluded from this remediation by delegated scope. Ultra child
extraction and recursive agent hydration are unchanged.

The history child extractor ignores `subAgentActivity.agentThreadId`, and the
hydrator reads only direct children. Root -> A -> B restores only A.

Required change: recognize the exact ultra field, recursively hydrate descendants,
guard cycles/duplicates, keep stable discovery order, and retain partial failures.

### 8. Thread-spawn source decoding is one level shallow — high

Disposition: excluded from this remediation by delegated scope. Agent source
decoding and discovery metadata are unchanged.

The runtime unwraps `subAgent` but reads path/depth before unwrapping
`thread_spawn`. Path and depth are lost.

Required change: decode the exact tagged variant. Do not introduce broad
camel/snake alternate-key probing: notification envelopes are camelCase; snake
case is required inside this specific source variant.

### 9. Hydrated child projection includes inherited context and wrong status — high

Disposition: excluded from this remediation by delegated scope. Child-agent
transcript ownership and status semantics are unchanged.

Child reads can include parent prefix turns. Current projection copies every turn
and then marks the child completed regardless of active/interrupted state.

Required change: exclude turn IDs already owned by ancestors and derive child
status from the child thread/latest owned turn.

### 10. Cache and notification buffers lack complete lifecycle bounds — medium

Disposition: fixed. Pending turn replay is bounded per turn, globally by unknown
turn ID count, and globally by event count with deterministic oldest-first
eviction. Cache protection uses balanced reference-counted leases that release
on completion and submission failure before capacity eviction resumes.

Protected cache entries never unprotect, so capacity only bounds unprotected
entries. Pending notifications are capped per turn but not by number of unknown
turn IDs.

Required change: explicit protection lifecycle plus a global pending-ID/event
budget with deterministic oldest-first eviction.

### 11. Pagination discards partial progress — medium

Disposition: fixed. Every successful page is merged into the retained raw turn
envelope immediately. Failure returns cumulative counts plus the failed turn and
nullable cursor; the public pagination adapter retries from that point while
skipping completed turns and deduplicating retained items.

A failure on a later page/turn returns the original parent and discards earlier
successful pages.

Required change: retain successfully merged pages, return failed state and cursor
metadata, and allow retry from the remaining cursor.

### 12. Handwritten and generated protocol types can drift — risk

Disposition: fixed with bounded coverage. Pinned drift now also validates a
categorized inventory of all 66 handwritten/generated overlaps. Exact generated
notifications adapt explicitly into ergonomic turn/error/item/login models;
conversion tests retain timestamps, structured errors, items, and login failure.
Nested non-agent drift in `ThreadSortKey.recencyAt` and
`ThreadStartParams.mockExperimentalField` is also covered. The scoped public
login wait now retains id-less completion failures instead of converting them to
`loginStreamEnded`.

Pinned drift checks validate generated files but not overlapping handwritten V2
compatibility types.

Required change: keep generated types as the exact wire Interface, keep ergonomic
types only as domain Adapters, and add conversion/inventory tests. Do not perform
an unreviewable wholesale type rewrite in one commit.

## Required parallel Interfaces

The following are intentional and must not be collapsed merely because they look
duplicated:

- global, main-turn, side-chat, and goal streams;
- `collabAgentToolCall` and `subAgentActivity` wire Adapters;
- Store state and Transcript V2 presentation projections;
- generated wire types and genuinely ergonomic domain types;
- the high-level `Codex` facade and lower-level `CodexClient`.

## Verification baseline

- Pinned protocol: `codex-cli 0.144.1`.
- Generated drift check passed: 102 enums, 389 structs, 95 raw aliases.
- Existing Transcript V2 suite: 15 tests passed.
- Existing NotificationRouter suite: 4 tests passed.
- Existing direct-child history hydration test passed.
- Official capture oracle: concatenated server deltas matched completed text once
  for 27/27 assistant messages.
- Eight focused audit reproductions failed exactly at the defects listed above.

## Scoped remediation verification

- Full Swift suite: 235 XCTest cases and 22 Swift Testing cases passed.
- Transcript V2: 18 cases passed, including ingress, envelope, and retry errors.
- History/cache: 4 cases passed, including partial-page retry and lease release.
- Notification router: 7 cases passed, including global bounds and login failure.
- Pinned drift: 102 enums, 389 structs, 95 raw aliases; 66 handwritten overlaps.
- Pinned version: `codex-cli 0.144.1`.

## Commit plan

1. Add this audit record and regression-test scaffolding.
2. Establish single transcript ingress and root-scoped notification projection.
3. Converge historical/live agent presentation while preserving both grammars.
4. Preserve turn envelopes and structured errors through history and cache.
5. Recursively hydrate ultra/nested agents and exact spawn-source metadata.
6. Correct child ownership/status, pagination retention, and lifecycle bounds.
7. Add generated/handwritten protocol conversion coverage and final integration
   verification.
