# Activity presentation

CodexCoreUI presents agent work with the same basic grammar as the official
Codex app:

1. Assistant commentary appears as ordinary transcript prose.
2. Model-authored reasoning summaries appear verbatim as the quiet live
   headline; reasoning content is never synthesized from commands.
3. Every typed `commandAction` becomes its own semantic row. One command
   execution can therefore reveal several `Read …`, `Searched …`, or
   `Listed …` rows without exposing the parent shell pipeline.
4. Commands, reads, searches, edits, MCP calls, and collaboration events until
   the next commentary update form one chronological work group.
5. While active, the group shows its latest action, such as
   `Searching for liveTail in Sources`. Once closed, it uses the official
   category order to produce a summary such as
   `Edited files, read files, ran a command`.
6. The same stable row updates in place and shimmers while active. Completed
   summaries are static.
7. Clicking a summary reveals the underlying rows, outputs, diffs, and payloads.

Dynamic product tools use the same compact treatment by default. CodexCoreUI
humanizes their canonical names (`create_issue` becomes `Create issue`) rather
than displaying protocol discriminants or a generic tool card.

This keeps the default reading path as a transcript—assistant prose interleaved
with concise activity—not a second event feed. Canonical detail remains
available when it is useful for debugging or review.

Read, search, and list actions all belong to exploration. Their completed
collapsed phrase is `Read files`, including search-only and list-only slices.
Skill-definition reads are counted separately as `Loaded a tool`. Counts select
singular or plural (`Ran a command` versus `Ran commands`) but are not printed.

## Host semantic projection

A product that has stronger domain language can replace selected canonical
items before the default grammar renders them. Configure
`CodexTranscriptItemPresentationPolicyV2` on the production
`CodexPresentationStore`:

```swift
import CodexCore
import CodexCoreUI

let activityPolicy = CodexTranscriptItemPresentationPolicyV2 { context in
    guard context.kind == .dynamicToolCall,
          let toolValue = context.payload["tool"],
          case .string(let tool) = toolValue else {
        return .standard
    }

    switch tool {
    case "begin_catalog_index":
        return .inlineActivity(.init(
            id: "catalog-index",
            label: "Indexing the catalog",
            systemImage: "books.vertical",
            status: context.status
        ))
    case "update_catalog_index":
        return .inlineActivity(.init(
            id: "catalog-index",
            label: "Checking 24 records",
            systemImage: "books.vertical",
            status: context.status
        ))
    case "internal_telemetry":
        return .hidden
    default:
        return .standard
    }
}

let presentationStore = CodexPresentationStore(
    adapter: .init(session: session),
    itemPresentationPolicy: activityPolicy
)
```

The policy has three decisions:

- `.standard` preserves CodexCoreUI's official-style default projection;
- `.hidden` suppresses the selected item;
- `.inlineActivity(...)` replaces it with a host-authored semantic row.

With no policy, the default activity grammar is used unchanged.

## Stable identity and lifecycle

Reuse the same `CodexInlineActivityV2.id` for successive canonical items that
describe one logical activity. Projection removes the previous activity with
that ID and inserts the latest label in its place. Assistant prose remains a
separate chronological entry.

Use `context.status` unless the product owns a stronger lifecycle:

- `.inProgress` receives the restrained shimmer treatment;
- `.completed` and `.failed` are static;
- an in-progress activity is finalized automatically when its turn terminates.

Set `detail` when the compact semantic row has useful learner-facing context
behind it. The row then receives a disclosure affordance and expands inline.
Omit `detail` for a label-only activity; label-only activities never display a
dead chevron. Detail should explain domain progress, not dump protocol payloads
or duplicate the transcript.

Set `imagePath` to a local image when expansion should reveal an inline
160-point preview. Canonical `imageView` items use this path automatically and
render as `Viewed an image`; selecting the preview opens the original image.

The activity ID is scoped by transcript turn. Include a domain identifier only
when one turn can contain multiple concurrent activities.

Canonical file-change rows preserve their per-file wire entries in
`CodexFileChangeRowV2.changes`. Each `CodexFileChangeV2` has a stable ID, source
path, optional rename destination, add/modify/delete/rename kind, and exact
patch text. Lifecycle belongs to the aggregate row rather than being duplicated
across independently mutable per-file values. Consumers should use `changes`
for review data instead of trying to split the legacy aggregate `diff`.

Diff hunks and line counts are prepared when the canonical turn is projected,
not when a transcript view renders. Hosts constructing Transcript V2 directly
can continue to use `CodexFileChangeRowV2.init(id:files:status:durationMs:diff:)`;
that initializer prepares its aggregate patch once as well.

The app-server `changes[].diff` field is kind-dependent: add and delete entries
carry raw file content, while updates carry a unified diff. Preparation
normalizes those forms once, preserves exact wire text in `changes`, and exposes
an ordered prepared entry whose `sourceIndex` resolves back to the exact wire
change. Empty renames still produce a prepared zero-line entry. Duplicate paths
remain distinct by source position, while file-change identity uses kind,
destination, and content fingerprints. Incremental projection reconciles a
structurally identical prior change when a live patch evolves, avoiding
identity churn for the normal same-file update.

Prepared display data is capped independently by retained bytes, lines, files,
and entries while streaming the entire wire value for exact addition/removal
counts. Canonical item revision reuses immutable preparation across
lifecycle-only or unrelated turn updates. Only the subagent visible in the side
panel receives a transcript projection; that projection is byte-bounded and
discarded when selection ends. Its compact cost ledger reweighs only upserted
turns, removes deleted turn weights, and keeps bounded structural overhead, so
streaming the current turn never rescans unchanged history. Selected-child
projections carry no pending-request payload; an unexpected request fails the
display-cost check closed. An over-limit selection keeps lightweight lifecycle
metadata live while showing a display-limit placeholder instead of retaining
transcript bytes.

File-change lifecycle values preserve `declined` and future status strings as
non-success states. Do not treat any explicit status other than `completed` as a
successful edit.

## Policy rules

- Keep the closure deterministic, sendable, and inexpensive. It runs whenever
  a dirty canonical turn is projected.
- Treat payload arguments and results as untrusted input.
- Return `.standard` for items the host does not explicitly own.
- Do not hide a blocking item unless its pending interaction remains available
  through the approval or user-input flow.
- Prefer a short verb phrase. The row belongs to the current assistant turn,
  not a dashboard.

For a rich per-call view that intentionally keeps each dynamic tool's own
identity, use [custom tool cards](custom-tool-cards.md).
