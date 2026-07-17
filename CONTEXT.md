# CodexCore Domain Language

## App-server protocol

The version-pinned JSON-RPC contract generated from the bundled Codex app-server.
Protocol responses, notifications, and server-originated requests are all ordered wire
facts. Generated types are the only wire representation used by production code.

## Wire cursor

The local `(connectionEpoch, ordinal)` assigned to each inbound frame. A wire cursor
orders frames observed on one connection; it is not proof that no server events were
missed across a disconnect.

## Codex session

The sole ordered runtime coordinator. It correlates JSON-RPC requests and responses,
applies every state-bearing frame exactly once, owns pending server requests and local
submission intents, and publishes revision-based observations. It is not UI state.

## Canonical state

The normalized local materialized view of app-server facts. Its primary graph is
Thread -> Turn -> ThreadItem, indexed by composite identifiers. Account, connection,
goal, usage, settings, and ephemeral operation facts live in explicit partitions of the
same session state. Canonical state never contains transcript grouping, scroll position,
or other presentation choices.

## Coverage

How much authoritative data is known for an entity. Coverage is monotonic during normal
merges (`notLoaded < summary < full`); a lower-coverage payload cannot erase richer
state. An active turn resumed without an item-level durable cursor is explicitly partial
until a terminal authoritative item page replaces it.

## Live overlay

Typed transient data accumulated from deltas before an authoritative completed item is
available. Completion replaces the corresponding protocol fields and releases redundant
overlay storage.

## Submission intent

Local optimistic input registered before `turn/start` or `turn/steer`. It is reconciled
through `clientUserMessageId` / `userMessage.clientId`; it is never represented as a
fabricated protocol turn or item.

## Request ledger

The exact-once lifecycle of server-originated JSON-RPC requests. The JSON-RPC request ID
is the primary identity. The ledger owns reply capability and terminal arbitration;
presentation receives only sanitized snapshots.

## State revision

A monotonically increasing session commit number. One ordered inbound frame produces at
most one atomic state commit. Consumers use revisions and bounded change sets to catch up
or request a scoped reset.

## Projection

A deterministic, disposable derivation from canonical state. Transcript grammar,
sidebar rows, plan/diff chrome, request cards, and the subagent tree are projections.
A projection may be dropped and rebuilt without replaying wire events.

## Presentation state

MainActor-owned user interface state such as selected thread, scroll anchor, bottom pin,
expanded rows, drafts, and last-seen attention revision. It never reduces protocol
messages.

## Retention lease

A reason canonical detail cannot currently be evicted, such as a selected thread,
running turn, pending server request, active observer, or open subagent panel. Historical
detail without a lease may be evicted back to explicit `notLoaded` coverage and reloaded
from app-server.
