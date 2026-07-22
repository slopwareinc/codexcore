# Transcript V2 — Turn-Centric Redesign Spec

> **Historical engineering note:** Superseded implementation specification. Verify current transcript behavior against production source and tests.

Rebuild CodexCoreUI's transcript pipeline around the turn structure the wire
protocol actually provides, matching the official Codex.app presentation
grammar captured via wire traces + CDP DOM snapshots (2026-07-09 capture).

## Why

The current pipeline is ~7,900 lines across 21 files with four overlapping
projection paths (`CodexChatTranscriptState`, store-projected messages,
`CodexTranscriptTimeline`, `CodexLiveTurnModels`) and a flat
`[CodexChatMessage]` model that doesn't even carry a turn id. Known defects:
duplicate user bubbles (no `clientId` reconcile), empty "Thinking" rows
(no empty-reasoning guard), raw discriminants in status text ("Usermessage"),
and no live work block (grouping is post-hoc only).

## Official presentation grammar (ground truth from captures)

A turn renders as exactly three things:

```text
[user bubble]                        one, timestamped
[work block]                         ONE per turn; "Working for Ns" live,
                                     "Worked for Xm Ys ›" collapsed when done
[final answer bubble]                timestamped
```

Expanded (and always while live), the work block is a chronological
narrative:

```text
Working for 36s
  "I'll take a quick repo pulse: git state, top-level structure…"   ← prose
  Listed files, ran 2 commands                                      ← group header
      Ran `git status --short --branch`                             ← lean rows
      Ran `git log --oneline -8`
  "So far: clean main, synced with origin/main…"                    ← prose
  Read 4 files, ran a command
      Read Package.swift · README.md · handoff.md · justfile
      Ran `git show --stat HEAD`
  Searching files in AGENTS.md folder                               ← live tail
```

Rules extracted from the captures:

1. `agentMessage.phase` is the skeleton: `"commentary"` messages are prose
   INSIDE the block; `"final_answer"` is the bubble below it. Fallback when
   phase is null (legacy models): the last assistant message of the turn is
   the final answer; earlier ones are commentary.
2. Consecutive work items between two prose paragraphs form ONE group with a
   synthesized header aggregating verbs and counts: "Read 4 files, ran a
   command", "Listed files, ran 2 commands", "Created 2 agents",
   "Read 2 files and searched code, ran 2 commands".
3. Reasoning is NEVER content. It only feeds the live tail phrase ("Thinking",
   or the latest summary headline when non-empty). Empty reasoning items
   (empty `summary` and `content` — common on the wire) produce nothing.
4. Collab agents render as lean lines: "Created Kepler with the
   instructions: …", "Closed 2 agents". Lifecycle counted once per phase.
5. The block exists from the turn's first non-message item. Loose rows never
   float in the transcript.
6. The user echo (`userMessage` item) carries `clientId` matching the
   optimistic local bubble — reconcile, never duplicate. A later user item in
   the same active turn is a steer: preserve the opening prompt and append a
   distinct user bubble.

## New model (Sources/CodexCoreUI/TranscriptV2/)

```swift
public struct CodexTranscriptV2: Sendable, Equatable {
    public var turns: [CodexTurnV2]          // ordered by wire arrival
}

public struct CodexTurnV2: Identifiable, Sendable, Equatable {
    public var id: String                    // wire turn id (params.turn.id)
    public var userMessage: CodexUserMessageV2?
    public var steeredMessages: [CodexUserMessageV2] // later user items in this turn
    public var narrative: [CodexNarrativeEntry]   // inside the work block
    public var finalAnswer: CodexAssistantTextV2? // streaming-capable
    public var liveTail: String?             // derived phrase, live only
    public var status: CodexTurnStatusV2     // .working(since:) | .done(durationMs:) | .failed(message:)
}

public enum CodexNarrativeEntry: Identifiable, Sendable, Equatable {
    case prose(CodexAssistantTextV2)         // commentary agentMessage, streamed
    case workGroup(CodexWorkGroupV2)         // batched consecutive work items
    case productToolCall(CodexProductToolCallV2)  // dynamicToolCall → host renderer
    case notice(CodexTurnNoticeV2)           // errors/warnings, muted single line
}

public struct CodexWorkGroupV2: Identifiable, Sendable, Equatable {
    public var id: String
    public var header: String                // synthesized, see header rules
    public var rows: [CodexWorkRowV2]
    public var isLive: Bool                  // any row still in progress
}

public enum CodexWorkRowV2: Identifiable, Sendable, Equatable {
    case command(...)        // command, parsed action label, status, exitCode, durationMs, output (expandable)
    case fileChange(...)     // per-file ±counts, status, diff (expandable)
    case mcpToolCall(...)    // appName ?? server, tool, status, durationMs, error first line, args/result (expandable)
    case webSearch(...)      // query
    case collabAgent(...)    // created/waited/closed, agent names, instructions
    case other(...)          // imageView, sleep, etc. — muted one-liner
}
```

Notes:
- Keep names/structure idiomatic; the shapes above are the contract, not
  the literal field lists. Fill in fields from the v2 `ThreadItem` schema
  (`codex app-server generate-ts --experimental`).
- `dynamicToolCall` items with any namespace become `.productToolCall`
  entries preserving tool name, namespace, arguments, status, contentItems,
  success — hosts render them via a renderer slot (Phase 2); the model layer
  just carries them in narrative order.

## Reducer (Sources/CodexCoreUI/TranscriptV2/CodexTranscriptReducerV2.swift)

Pure, `Sendable`-friendly, no SwiftUI import. One entry point:

```swift
public struct CodexTranscriptReducerV2 {
    public let threadID: String
    public private(set) var transcript: CodexTranscriptV2
    public mutating func apply(method: String, params: CodexJSONValue) // or typed notification
    public mutating func submitLocalUserMessage(text: String, clientID: String)
}
```

Reduction rules:

1. **Thread filter**: ignore notifications whose `params.threadId` (or nested
   equivalent) doesn't match `threadID`. The subagents fixture interleaves
   child-thread traffic on the same connection to test exactly this.
2. **Turn lifecycle**: `turn/started` opens a turn keyed by `params.turn.id`
   (NOT a top-level `turnId` — it doesn't exist). `turn/completed` closes it,
   status `.done(durationMs:)`, clears `liveTail`, marks all groups not live.
   `turn/failed`/error → `.failed`.
3. **User echo reconcile**: `submitLocalUserMessage` inserts an optimistic
   user message with `clientID`. When the `userMessage` item arrives with
   matching `clientId`, adopt the server item id and content — never append a
   second. Without a pending local match, insert normally. Attach to the
   turn opened by `turn/started`; a `userMessage` arriving before its
   `turn/started` (observed on the wire) must open/route to the correct turn
   via its notification's turn id. The first user item is `userMessage`; every
   later user item in the same turn is appended to `steeredMessages` in item
   order. A pending steer appears optimistically there and reconciles by
   `clientId` when its echo arrives.
4. **agentMessage**: `phase == "commentary"` → `.prose` narrative entry,
   streamed via `item/agentMessage/delta` (deltas keyed by `itemId`).
   `phase == "final_answer"` → `finalAnswer`, streamed. `phase == nil` →
   buffer as provisional final answer; if another agentMessage starts later
   in the same turn, demote the previous one to `.prose` in place.
5. **reasoning**: never creates a narrative entry. While in progress, set
   `liveTail` to the latest non-empty summary headline (from
   `item/reasoning/summaryTextDelta` accumulation) or "Thinking" when empty.
   On completion, discard.
6. **Grouping**: a non-message work item (command, fileChange, mcpToolCall,
   webSearch, collab, other) appends a row to the OPEN work group; a group
   closes when a `.prose` entry or `.productToolCall` begins. `item/started`
   creates the row in-progress; `item/completed` updates it in place
   (match by item id). Group header re-synthesized on every row change.
7. **Live tail**: derived from the newest in-progress item:
   command → "Running <short command>", mcp → "Asking <appName ?? server>",
   dynamicToolCall → "Using <tool>", webSearch → "Searching",
   fileChange → "Editing files", reasoning → see rule 5, none → "Working".
   Raw discriminants must never appear anywhere.
8. **History restore**: a separate entry point replays a
   `thread/items/list`-shaped array through the same rules to rebuild
   `CodexTranscriptV2` (fabricate turn boundaries from item order: a
   userMessage item starts a new turn). No second projection path.

## Group header synthesis

Aggregate rows by category, in first-appearance order, joined per official
style. Categories and verbs:

| Category | Detection | Singular | Plural |
|---|---|---|---|
| read | command action is a file read (`cat`, `sed -n`, editor read) or fileRead action | "Read X" | "Read N files" |
| list | `ls`/list actions | "Listed files" | "Listed files" |
| search | `grep`/`rg`/`find`/search actions, webSearch | "searched code" | "searched code" |
| run | any other command | "ran a command" | "ran N commands" |
| edit | fileChange | "edited a file" | "edited N files" |
| mcp | mcpToolCall | "called <App>" | "called <App> N times" |
| collab created | collab spawn | "Created an agent" | "Created N agents" |
| collab closed | collab close | "Closed an agent" | "Closed N agents" |

Join rule: first category capitalized, subsequent lowercased, comma-joined
with the last two joined by ", " as in captures ("Read 2 files and searched
code, ran 2 commands" — use "and" between read/search when both present,
comma before run). Match capture examples exactly in tests:
- "Listed files, ran 2 commands"
- "Read 4 files, ran a command"
- "Read 2 files and searched code, ran 2 commands"
Use `commandActions` from the wire for read/list/search detection; fall back
to `run`.

## Fixtures + tests (Tests/CodexCoreUITests/Fixtures/)

Already present (raw server-notification JSONL, in wire order):

- `turn-repo-inspect.jsonl` — 305 notifications, 14 commands, 5 commentary +
  final agentMessages, 5 reasoning (some empty). Expect: one turn, one user
  message, narrative alternating prose/workGroups, exact group headers above,
  final answer set, no reasoning entries.
- `turn-subagents.jsonl` — 651 notifications INCLUDING child-thread traffic
  on the same connection. Expect: child threads fully ignored; collab rows
  "Created …"/"Closed …" grouped; intermediate commentary as prose.
- `turn-mcp-failure.jsonl` — 46 notifications; 3 mcpToolCall (one failed
  GitHub 404), 5 reasoning with EMPTY summary/content. Expect: zero
  reasoning narrative entries; failed MCP row carries error first line;
  empty-reasoning yields liveTail "Thinking" while live and nothing after.

Test style: replay each fixture line through the reducer, snapshot-assert the
resulting `CodexTranscriptV2` structure (turn count, entry kinds in order,
group headers, row labels, final answer prefix, no duplicate user messages).
Also unit-test: clientId reconcile (local submit then echo), phase-nil
demotion, header synthesis table, live-tail derivation.

Register fixtures as SPM resources for the test target in Package.swift.

## Constraints

- Phase 1 (this spec's scope): model + reducer + header synthesis + tests
  ONLY. No SwiftUI views, no changes to existing pipeline files, no
  deletions. Everything new lives under `Sources/CodexCoreUI/TranscriptV2/`
  (or `Sources/CodexCore` if a file has zero UI deps — fine either way).
- Swift 6 concurrency-clean (`Sendable` value types, no globals).
- `swift build` and `swift test` must pass.
- Do not touch `CodexChatRuntimeSession` or any existing public API yet.
