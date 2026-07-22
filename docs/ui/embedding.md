# Embed CodexCoreUI

`CodexCoreUI` provides presentation; your host still owns session lifecycle, policy, persistence choices, and application navigation.

## Main surfaces

- `CodexChatWorkspaceView`: reusable transcript, composer, prompts, and panels.
- `CodexTranscriptViewV2`: transcript-only embedding.
- `CodexPresentationStore`: canonical presentation projection used by production transcript hosts.
- focused route and tool views for plugins, automations, mobile, files, terminal, and browser surfaces. A visible route does not imply that its mutation workflow is wired.

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

For desktop-style follow-ups, pass the active thread's `[CodexComposerSubmission]` through `queuedFollowUps` and wire `onSteerQueuedFollowUp`, `onRemoveQueuedFollowUp`, and `onEditQueuedFollowUp` by `clientID`. The host remains responsible for calling `turn/steer`, preserving a failed steer at the front of the queue, and starting one queued follow-up after the active turn completes.

## Production wiring

1. Own one `Codex` and session model outside the view tree.
2. Project canonical thread state into `CodexPresentationStore`.
3. Keep drafts, selected routes, scroll state, and panel state on the MainActor.
4. Route approval and input requests through explicit host actions.
5. Close leases when their presentation or operation reason ends.

Workspace initializer defaults include constant bindings and no-op actions, including approval resolution. Wire every capability your host exposes. Use `Sources/CodexCoreApp/CodexCoreAppModel.swift` as the reference host, but verify [support status](../reference/support-status.md) and do not copy it wholesale when a smaller adapter is enough.
