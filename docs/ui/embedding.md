# Embed CodexCoreUI

`CodexCoreUI` provides presentation; your host still owns session lifecycle, policy, persistence choices, and application navigation.

## Main surfaces

- `CodexChatWorkspaceView`: reusable transcript, composer, prompts, and panels.
- `CodexTranscriptViewV2`: transcript-only embedding.
- `CodexPresentationStore`: canonical presentation projection used by production transcript hosts.
- focused route and tool views for plugins, automations, mobile, files, terminal, and browser surfaces. A visible route does not imply that its mutation workflow is wired.

Long `CodexTranscriptViewV2` conversations automatically show a compact turn
navigator at the leading edge. Its markers follow canonical turn geometry,
preview the user request and assistant result on hover, and jump to the selected
turn without requiring host integration.

## Workspace skeleton

```swift
CodexChatWorkspaceView(
    presentationStore: presentationStore,
    activities: activities,
    connectionState: connectionState,
    workspacePath: workspacePath,
    draft: $draft,
    isSending: isSending,
    canSend: canSend,
    onSend: submit,
    onInterrupt: interrupt,
    onDisconnect: disconnect
)
.codexAgentTheme(.officialDark)
```

This is intentionally only the minimal initializer path. Add model selection, permissions, panels, MCP state, side chat, subagents, and host actions as your product supports them.

For desktop-style follow-ups, pass the active thread's `[CodexComposerSubmission]` through `queuedFollowUps` and wire `onSteerQueuedFollowUp`, `onRemoveQueuedFollowUp`, and `onEditQueuedFollowUp` by `clientID`. The host remains responsible for serializing `turn/steer` calls and atomically dequeuing exactly one FIFO follow-up while marking its turn pending after each active turn completes. A generic or non-steerable failure returns the selected message to the front of the queue. A missing-active-turn race falls through immediately to `turn/start`; an expected-turn mismatch retries once with the server-reported turn ID. Block queue draining while that recovery sequence is unresolved. Do not gate a completion-triggered dequeue only on a cached canonical `isSending` projection; it may still describe the turn whose terminal event initiated the drain.

The canonical projection keeps the opening prompt in `CodexTurnV2.userMessage`, appends every echoed or optimistic `turn/steer` input to `steeredMessages`, and exposes the authoritative display order through `conversationSegments`. Render the initial segment's work, then each segment's steer bubble followed by only the assistant work produced after that steer. The resulting grammar is opening prompt → earlier assistant work → steer prompt → later assistant work → final answer. Reconcile each optimistic steer by `clientID`; never replace the opening prompt or render the server echo twice.

## Production wiring

1. Own one `Codex` and session model outside the view tree.
2. Project canonical thread state into `CodexPresentationStore`.
3. Keep drafts, selected routes, scroll state, and panel state on the MainActor.
4. Route approval and input requests through explicit host actions.
5. Close leases when their presentation or operation reason ends.

Workspace initializer defaults include constant bindings and no-op actions, including approval resolution. Wire every capability your host exposes. Use `Sources/CodexCoreApp/CodexCoreAppModel.swift` as the reference host, but verify [support status](../reference/support-status.md) and do not copy it wholesale when a smaller adapter is enough.
