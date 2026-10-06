# Composer drafts

A host owns `CodexComposerStateSession` outside the view tree. Its ordinary
thread-based APIs remain available; hosts that omit a local draft identity use
the compatibility unassigned draft until they select a native thread.

Create a new `CodexComposerDraftID` with `newDraft` for every independent chat
that has no native thread yet. The identity owns text, file references, response
annotations, selected skills, and selected file mentions. Repeated
`setActiveThreadID(nil)` calls preserve an explicitly selected pre-thread draft.
`clearThreadState()` clears transient side-chat/search state while retaining
unsent context. `draftRecords` exposes the active draft and other drafts with
invested content for host navigation, together with optional workspace, opaque
project ID, and projectless metadata.

```swift
var composer = CodexComposerStateSession(followUpBehavior: .queue)
let draftID = composer.newDraft(workspacePath: "/workspace", projectID: "project-id")
composer.draft = "Inspect this workspace"
let submission = composer.consumeDraftForTurn()!

// The native thread ID comes only from the runtime's successful thread creation.
composer.draft = "Follow-up typed while the launch was pending"
composer.promoteDraft(draftID, to: "native-thread-id")

// A failed submission restores its originating draft even after navigation.
composer.newDraft(workspacePath: "/other-workspace")
composer.restore(submission)
```

`CodexComposerSubmission.draftID` is local ownership metadata. Send only the
native `threadID` to runtime thread methods. Promotion binds the original local
identity to the native thread and preserves text/context typed after the first
submission was consumed. It does not replace an unrelated active selection.
Queued protocol input, queue IDs, and client user-message IDs retain their
existing reconciliation semantics.

Persistence is explicit and injectable. `CodexComposerDraftsSnapshot` is an
immutable `Codable`, `Sendable` value; restore it with
`CodexComposerStateSession(restoring:followUpBehavior:)`. The snapshot includes
active selection and draft metadata/context. Side-chat text, search results,
and follow-up queues are transient; hydrate durable queued submissions from
the runtime separately. File references retain their paths and classification
without loading file contents or checking whether those paths still exist.

```swift
let store = CodexComposerDraftFileStorage(fileURL: hostChosenDraftFileURL)
if let saved = try store.load() {
    let restored = try CodexComposerStateSession(restoring: saved, followUpBehavior: .queue)
    composer.mergeDrafts(from: restored)
}
try store.save(composer.draftSnapshot())
```

The host chooses the storage URL, account/project scope, save cadence, and
error presentation. Constructing a session performs no filesystem access.
For an asynchronous initial load, `mergeDrafts(from:)` imports only persisted
draft content and bindings, retaining live queue state, search results,
follow-up policy, and text typed during loading. Existing native thread
bindings determine identity when a restored record used a different local ID.
Repeated hydration does not duplicate already imported prompt paragraphs or
context. Selection remains unchanged by default; request
`activateRestoredDraft: true` only when restoring selection is appropriate.
Activation requires no invested local draft content and no selected native
thread.
For off-main-actor persistence, copy `activeDraftID` and `draftRecords` on the
owning actor, then create/save the snapshot on the storage actor. Flush the
latest snapshot when the host closes or changes persistence scope.

Snapshots reject unknown schema versions, duplicate identities/thread bindings,
invalid context metadata, and invalid annotation ranges. They permit up to 128
drafts, 256 KiB of prompt text per draft, and 64 entries of each context kind.
Encoded JSON is capped at 4 MiB. `CodexComposerDraftFileStorage` bounds reads and
writes atomically; a rejected save leaves the prior file intact. Hosts can inject
a different `CodexComposerDraftStorage` implementation without changing composer
ownership.

## Sidebar recovery

Pass `drafts`, `activeDraftID`, and `onSelectDraft` to `CodexProjectSidebar` to
surface invested pre-thread drafts above the chats. The parameters have
source-compatible defaults. Both the T3 inbox and grouped native presentation
show a compact draft section; empty drafts and drafts already bound to native
threads are omitted. Project scoping matches each draft's opaque `projectID`,
never a shared workspace path. Projectless drafts appear only in All projects.

```swift
CodexProjectSidebar(
    serverName: nil, isThreadReady: false, snapshot: sidebarSnapshot,
    onNewChat: {}, onOpenSearch: {}, onSelectRoute: { _ in },
    onToggleProject: { _ in }, onStartProjectChat: { _ in },
    onSelectProject: { _ in }, onOpenFolder: {}, onSelectChat: { _ in },
    onTogglePinChat: { _ in }, onArchiveChat: { _ in },
    drafts: composer.draftRecords,
    activeDraftID: composer.activeDraftID,
    onSelectDraft: { draftID in composer.setActiveDraftID(draftID) },
    onDiscardDraft: { draftID in composer.discardDraft(draftID) }
)
```

Replace the ordinary sidebar no-op callbacks with the host's navigation actions.
Selection callbacks should restore the record's workspace/project context as
well as the local composer identity. `onDiscardDraft` is optional; providing it
adds an explicit Discard draft context-menu and accessibility action. Return or
Space opens a focused row. Drafts display their first prompt line or attachment
count/context label without invented runtime status or recency.

## Reference app storage

The packaged reference app saves drafts under the selected Codex home's
`codexcore/drafts` directory. ChatGPT scope uses a confirmed account email/ID,
with hashed filenames; auth-mode-only notifications do not create a shared
account bucket. API-key drafts are explicitly scoped to the isolated home,
because the account protocol does not identify individual API keys. Use
different homes for separate API-key profiles.

Storage runs on an actor, debounces changes by 300 ms and flushes on disconnect
or account changes. New directories/files use private permissions. Late older
writes cannot replace a newer saved revision. Load/write errors remain visible
with Retry; unreadable files are preserved and automatic writes stay paused.
Typing retained during a failed load/account change is recoverable in the same
app session. Recovered draft selection restores its workspace/project context
before any native resume/start.
