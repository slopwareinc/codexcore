# CodexCore Domain Language

## App-server protocol

The version-pinned JSON-RPC contract generated from the bundled Codex app-server.
Protocol responses, notifications, and server-originated requests use generated types as
their only production wire representation.

## Connection epoch

The lifetime of one physical app-server connection. Pending request and interaction
identities are scoped to it. A new epoch does not imply that an uncertain mutation from
the prior process should be replayed.

## Local frame ordinal

A diagnostic sequence assigned to inbound frames on one connection. It describes what
this client observed in transport order. It is not a server event sequence, a resume
point, an atomic history/live cut, or proof that no event was missed.

## Codex session

The sole ordered runtime coordinator. One actor owns synchronous request correlation,
canonical reduction, thread runtime state, pending server interactions,
operation-specific trackers, and observation. It is neither UI state nor an actor graph.

## Client request broker

The connection-scoped table correlating exact integer-or-string JSON-RPC IDs with one
pending response decoder and waiter. It does not retain completed requests, infer domain
operation lifecycles, or replay writes.

## Canonical replica

The normalized local materialized view of app-server facts plus the synchronous adapter
and reducer that maintain it. Its primary graph is Thread -> Turn -> ThreadItem, indexed
by composite identifiers. Account, connection, goal, usage, settings, and submission
intents live in explicit partitions. It never contains transcript grouping, scroll
position, or other presentation choices.

## Coverage

How much authoritative data is known for an entity. Coverage is monotonic during normal
merges (`notLoaded < summary < full`); a lower-coverage history payload cannot erase
richer live state. History and live responses may overlap because app-server provides no
atomic resume cut.

## Live overlay

Typed transient data accumulated from deltas before an authoritative completed item is
available. Completion replaces the corresponding protocol fields and releases redundant
overlay storage.

## Submission intent

Local optimistic input registered before `turn/start` or `turn/steer`. It is reconciled
through `clientUserMessageId` / `userMessage.clientId`; it is never represented as a
fabricated protocol turn or item. After an ambiguous connection loss it is not blindly
replayed.

## Thread runtime

Session-owned control state for one thread: its local retainers, desired and best-known
actual subscription state, transition phase, local generation, and opaque history
pagination state. The generation rejects stale local completions; it is not a server
epoch or incarnation.

## Thread history mode

The app-server-declared persistence contract for a thread. In alpha.20, `legacy` returns
authoritative turns from resume and supports fork, rollback, and full thread reads;
`paginated` uses opaque turn/item cursors but does not support those operations. These
are two current protocol modes, not two CodexCore runtimes. One thread runtime selects
the correct hydration strategy from the declared mode and never guesses from null
cursors. CodexCore defaults new alpha.20 threads to legacy until paginated mode reaches
feature parity; paginated threads remain an explicit experiment.

## Retainer

A local reason to desire a thread subscription or keep its detail readily available,
such as selection, a running turn, a pending interaction, an observer, or an open
subagent panel. Multiple retainers converge on one `ThreadRuntime` subscription intent.

## Interaction inbox

The pending-only collection of server-originated JSON-RPC requests, keyed by exact
`(connectionEpoch, requestID)` identity. Resolution removes an entry. Presentation sees
sanitized request bodies, never reply continuations, secrets, or a terminal request
ledger.

## Operation-specific tracker

A small state machine used only when one app-server operation has a real multi-message
lifecycle, such as login completion. Its key, completion, cancellation, and buffering
rules come from that protocol operation rather than a universal registry abstraction.

## State revision

A monotonically increasing canonical commit number. Changed entities record their
latest revision; a turn's aggregate revision also advances for relevant descendant item
and submission changes. Revisions invalidate projections but do not promise event
replay.

## Observation

An atomic scoped snapshot seed followed by coalesced relevant revision signals. A
consumer responds to a signal by reading current canonical state. The session does not
retain a journal so slow consumers can replay every intermediate change.

## Projection

A deterministic, disposable derivation from canonical state. TranscriptV2 grammar,
sidebar rows, plan/diff chrome, request cards, and the subagent tree are projections. A
projection may be dropped and rebuilt without replaying wire events.

## Presentation state

MainActor-owned user interface state such as selected thread, scroll anchor, bottom pin,
expanded rows, drafts, and last-seen attention revision. It never reduces protocol
messages.
