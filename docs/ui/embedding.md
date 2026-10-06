# Embed CodexCoreUI

`CodexCoreUI` provides presentation; your host still owns session lifecycle, policy, persistence choices, and application navigation.

## Main surfaces

- `CodexChatWorkspaceView`: reusable transcript, composer, prompts, and panels.
- `CodexTranscriptViewV2`: transcript-only embedding.
- `CodexPresentationStore`: canonical presentation projection used by production transcript hosts.
- `CodexTranscriptItemPresentationPolicyV2`: host mapping from canonical items to compact semantic activity.
- focused route and tool views for plugins, automations, files, terminal, and browser surfaces. A visible route does not imply that its mutation workflow is wired.

Long `CodexTranscriptViewV2` conversations automatically show a compact turn
navigator at the leading edge. Its markers follow canonical turn geometry,
rise with a tapered neighboring-marker mount on hover, show the user request
and assistant result in a native Liquid Glass preview, and jump to the selected
turn without requiring host integration.

Completed file-edit cards can open Review through `onOpenReviewRequest`. The
request contains the originating turn's bounded review session and the clicked
file path, so a host can open its Review panel directly on that file. The
existing parameterless `onOpenReview` callback remains available for hosts
that only need a generic Review route.

## Workspace skeleton

```swift
CodexChatWorkspaceView(
    presentationStore: presentationStore,
    workspacePath: workspacePath,
    draft: $draft,
    isSending: isSending,
    canSend: canSend,
    onSend: submit,
    onInterrupt: interrupt,
    onOpenThread: { reference in
        navigateToTask(hostID: reference.hostID, threadID: reference.threadID)
    },
    onDisconnect: disconnect
)
.codexAgentTheme(.t3Code)
```

This is intentionally only the minimal initializer path. Add model selection, permissions, panels, MCP state, side chat, subagents, and host actions as your product supports them.

The reference app uses [T3 Code presentation](t3-code-presentation.md), with a
compact sidebar, shared chat/composer lane, typed plan cards, and nonblocking
questions. Existing native theme families remain available. Pass
`workspaceTitle` for the selected project's display name without changing its
server identity.

Use [composer draft identities and recovery](composer-drafts.md) to preserve
independent unsent chats, scoped context and draft storage. Image references in
`CodexComposerSubmission.turnInput` include native `localImage` inputs alongside
the display/path context; authoritative queued input is preserved without
adding those images twice. The local-image path belongs to the runtime's
filesystem. `CodexModelSelection.inputModalities` preserves the catalog's
declaration; nil remains unknown.

For response-scoped forks, pass `onForkResponse` to `CodexTranscriptViewV2`, or
`CodexChatActionHandlers.forkFromResponse` to the workspace. Its
`CodexTranscriptForkRequest` includes the displayed thread and inclusive native
`lastTurnID`. Revalidate that source before dispatching `thread/fork`; a
synthetic/local turn is not a native fork boundary. The parameterless
`onForkChat`/`forkChat` handlers remain available for head-only hosts.

`onOpenThread` is for independent task references produced by `create_thread`,
`read_thread`, `send_message_to_thread`, and received delegation messages. It
must navigate the host's main task workspace. Keep `onOpenSubagent` separate: it
opens collaboration children in the agent side panel. `CodexThreadReferenceV2`
includes the optional host ID so multi-host embedders do not key navigation by a
bare thread ID.

If the host maintains live subagent state outside the parent transcript, pass
`agentDisplayNameByThreadID` and `agentDisplayStatusByThreadID` to
`CodexTranscriptViewV2`. Those values override stale metadata captured when a
collaboration tool call completed, so a running child remains visibly running.

For desktop-style follow-ups, pass the active thread's `[CodexComposerSubmission]` through `queuedFollowUps` and wire `onSteerQueuedFollowUp`, `onRemoveQueuedFollowUp`, and `onEditQueuedFollowUp` by `clientID`. The host remains responsible for serializing `turn/steer` calls and atomically dequeuing exactly one FIFO follow-up while marking its turn pending after each active turn completes. A generic or non-steerable failure returns the selected message to the front of the queue. A missing-active-turn race falls through immediately to `turn/start`; an expected-turn mismatch retries once with the server-reported turn ID. Block queue draining while that recovery sequence is unresolved. Do not gate a completion-triggered dequeue only on a cached canonical `isSending` projection; it may still describe the turn whose terminal event initiated the drain.

The canonical projection keeps the opening prompt in `CodexTurnV2.userMessage`, appends every echoed or optimistic `turn/steer` input to `steeredMessages`, and exposes the authoritative display order through `conversationSegments`. Render the initial segment's work, then each segment's steer bubble followed by only the assistant work produced after that steer. The resulting grammar is opening prompt → earlier assistant work → steer prompt → later assistant work → final answer. Reconcile each optimistic steer by `clientID`; never replace the opening prompt or render the server echo twice.

## Production wiring

1. Own one `Codex` and session model outside the view tree.
2. Project canonical thread state into `CodexPresentationStore`.
3. Keep drafts, selected routes, scroll state, and panel state on the MainActor.
4. Route approval and input requests through explicit host actions.
5. Close leases when their presentation or operation reason ends.

### Device-code login

Keep the identified `CodexLoginAttempt` returned by `Codex.startLogin` in the
host for the entire device-code flow. A Cancel login action calls
`attempt.cancel()` on that attempt; canceling only its completion task does not
send `account/login/cancel`. Scope pending completion and cancellation to the
owning connection and login generation so an obsolete login cannot update a
replacement flow.

`CodexAuthSession.deviceCodeEnded(message:)` clears the visible verification
URL and code after cancellation or failed completion without claiming a
successful sign-in. Call `deviceCodeCompleted()` only for a successful login.
Keep a failed cancellation actionable and retain its attempt until its terminal
outcome is known.

## Workspace tabs

Keep one `CodexWorkspacePanelState` per thread outside transient SwiftUI view
lifetimes. Its `workspaceTabs` module owns tab identity, activation, ordering,
close fallback, right/bottom topology, routes, and restoration.
`CodexChatWorkspaceView` registers its built-in Plan and Review adapters from
the supplied summary and review session; the adapter conformance seam remains
package-internal until external feature adapters have a supported contract.
Callers never construct or switch on tab IDs. Persist
`workspaceTabRestorationState`, then inject it in
`CodexWorkspacePanelState.init` or apply it before opening live tools. Only
routes and per-tab presentation state are durable. Current Plan/Review facts
remain disposable projections and are supplied again after restoration.
Terminal sessions use the same adapter seam; `openTerminal` targets the bottom
panel by default. Server-owned background-terminal facts are exposed through a
metadata/detail adapter with the supported terminate action; the protocol does
not expose a stream-attachment endpoint, so the UI never fabricates a Ghostty
host for those rows. Keep the panel state alive outside the SwiftUI view tree
so moving, hiding, and restoring an interactive terminal never creates a second
host. Restored interactive routes register lazily and create their PTY only when
the user activates the tab; missing canonical background facts remain
unavailable rather than producing a blank detail surface.

Files are opened through the public panel facade:
`panel.openFiles(workspacePath:)` registers the workspace browser and
`panel.openFilePreview(fileURL:ref:)` opens a typed file/ref preview. The
package-internal adapters own replacement, pinning, and active-only editor
policy; hosts persist `workspaceTabRestorationState` rather than constructing
those adapters directly. The current implementation accepts only files from
the active workspace; a non-`nil` ref is rejected with an explicit preview
notice until a bounded ref resolver is supplied.

When a host exposes recursive agent work, pass the active
`CodexSubagentPresentationCoordinator` as `subagentCoordinator` to
`CodexChatWorkspaceView`. The workspace registers one `Subagents` tab through
its package adapter; its durable state contains only the
selected child thread ID. The master list keeps active and done metadata rows,
while the coordinator lazily retains and projects the selected child's
transcript/final response. Back navigation clears that selection, and changing
selection cancels the previous child projection.

CodexCoreUI uses an official-style compact [activity presentation](live-activity.md)
by default. For product-specific live progress, configure the presentation
store with `CodexTranscriptItemPresentationPolicyV2`. The policy can preserve,
suppress, or replace selected canonical items before the transcript chooses its
default activity renderer.

Workspace initializer defaults include constant bindings and no-op actions, including approval resolution. Wire every capability your host exposes. Use `Sources/CodexCoreApp/CodexCoreAppModel.swift` as the reference host, but verify [support status](../reference/support-status.md) and do not copy it wholesale when a smaller adapter is enough.

## Focus a search occurrence

Apply `.codexTranscriptFocus(focusRequest)` to the transcript or workspace host.
Create a `CodexTranscriptFocusRequest(threadID:turnID:itemID:)` after loading the
occurrence's `turnCursor` history page. The request retains the exact protocol
item identity across Markdown blocks, expands collapsed diagnostic ancestors,
and scrolls to the item. Omit `itemID` to focus a turn instead. An unloaded target
remains pending until the corresponding presentation arrives; a request never
navigates a different thread. Set the request to `nil` to cancel pending focus,
and create a fresh request to revisit the same result.

## Synced project identity

Use `CodexProjectSummary.id` as the durable sidebar identity. It returns the
opaque `serverID` for synced projects and falls back to `workspacePath` for
local projects. Keep `workspacePath` separate for folder navigation and reveal
actions: two synced projects can share a folder while retaining distinct IDs.
Pass both facts to `CodexSidebarNavigationSession.selectProject(_:workspacePath:)`;
pass the optional `projectID` when calling `selectChat`, `startNewChat`, or
`syncCurrentWorkspace` so selection does not collapse to a shared folder.

After refreshing projects, call `reconcileProjectIdentities(_:)` and persist the
navigation state when it returns `true`. It migrates legacy folder preferences
to each matching server ID, including shared-root projects, and preserves
explicit server-ID aliases over migrated folder aliases.

## Image resource limits

Remote transcript previews accept at most 32 MiB of encoded image bytes;
plugin icons accept at most 4 MiB. The shared loader checks HTTP success,
rejects oversized declared lengths, bounds chunked bodies, propagates
cancellation, and applies a 20-second resource deadline. Rejected assets use the
existing placeholder. These limits apply to previews, not SDK image inputs.

Raster plugin icons are downsampled off the main actor to at most 256 pixels on
the longest edge. AppKit vector support remains available with bounded source
reads. The icon cache has both a count limit and a decoded-cost limit; transcript
thumbnails retain their separate size-aware cache.
