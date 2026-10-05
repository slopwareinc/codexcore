# T3 Code presentation

The reference app defaults to the **T3 Code** presentation for new appearance
settings. Existing saved theme choices stay intact; select **Settings →
Appearance → T3 Code** to use it on an existing installation. Light and dark
appearance follow the system unless explicitly pinned.

The native port is based on the official
[T3 Code source](https://github.com/pingdotgg/t3code/tree/3e6b45028ceec5820dacb37dc3852470ebdc9411)
at `3e6b45028ceec5820dacb37dc3852470ebdc9411`. The upstream MIT notice is in
[`THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md) and ships in the packaged
application's Resources directory.

## Source mapping

| Upstream source | Native ownership |
| --- | --- |
| `apps/web/src/index.css` | `CodexT3CodePalette`, `CodexAgentTheme.Spacing.t3Code`, `Radii.t3Code` |
| `Sidebar.tsx`, `sidebar/SidebarChrome.tsx` | `CodexProjectSidebarView`, sidebar organization views |
| `chat/ChatHeader.tsx` | `CodexChatHeader`, host-supplied project breadcrumb |
| `chat/ComposerSurface.tsx`, `ChatComposer.tsx`, `ComposerControl.tsx` | `CodexComposerBar`, compact model and permission controls |
| `composerFooterLayout.ts` | Gesture-driven reading mode and composer reservation |
| `chat/MessagesTimeline.tsx`, work-log summaries | Native transcript render projection and virtualized collection cells |
| `chat/ProposedPlanCard.tsx`, `proposedPlan.ts` | Typed proposed-plan presentation with title, preview, copy, and export |
| `provider/Drivers/CodexDriver.ts`, `CodexAdapterV2.ts` | App checklist and reasoning-summary opt-ins; typed asynchronous questions |
| `provider/CodexToolPresentation.ts`, `McpToolPresentation.ts` | Bounded browser/computer tool source labels and page context |

The [Codex adapter comparison](../reference/t3-code-comparison.md) records the
runtime behaviors found in source and the application boundaries.

The shared lane is 736 points, the header is 52 points, and the composer has
22-point corners with 16-point expanded insets. The palette preserves T3's
neutral light/dark surfaces and blue primary actions. Chrome uses flat surfaces
and hairline borders. This preset has no atmosphere or system Liquid Glass;
the generated hue families still provide those treatments.

Assistant prose reads directly on the canvas. User messages occupy up to 80%
of the lane in a neutral bubble. Work logs use compact rows and counted,
collapsible summaries; ordinary completed activity stays muted. Turn changes
follow the assistant answer. Proposed-plan cards originate only from typed
Codex `plan` items, so arbitrary assistant prose is never guessed to be a plan.

The composer gives space back when the user scrolls into history. Returning to
the bottom or interacting with the editor expands it. Losing focus does not
collapse it. Multiline drafts, recording, and active suggestion menus keep the
editor readable. The workspace preserves the expanded bottom reservation so
expansion does not cover the last transcript rows.

## Embed it

```swift
CodexChatWorkspaceView(
    presentationStore: presentationStore,
    workspacePath: workspacePath,
    workspaceTitle: projectDisplayName,
    draft: $draft,
    isSending: isSending,
    canSend: canSend,
    onSend: submit,
    onInterrupt: interrupt,
    onDisconnect: disconnect
)
.codexAgentTheme(.t3Code)
```

`workspaceTitle` is a display name; keep project identity keyed by the server's
opaque project ID. Several projects may share one directory.

`CodexAgentTheme.interfaceStyle` separates T3 presentation conventions from
the existing native conventions. Hosts can reuse the palette or geometry while
supplying their own theme. The Swift SDK and canonical state remain the source
of truth, and the native transcript retains virtualization, exact-item focus,
selection, and host-owned approvals and navigation.

### Plans and asynchronous questions

`CodexNarrativeEntry.proposedPlan(CodexProposedPlanV2)` carries typed plan
markdown separately from commentary and the final answer. Long plans show a
bounded preview; expansion preserves the full markdown, and copy/export use the
complete source rather than the preview.

`CodexNarrativeEntry.questions(CodexAsyncQuestionV2)` comes from an
`agentMessage` with `delivery: async` and typed `questions`. It is a nonblocking
card and can remain answerable after its originating turn completes. Suggested
options, custom answers, and multi-question progress belong to the UI;
`answerMessage(answers:)` produces an ordinary user message only after every
question has an explicit nonempty answer. Bounded state keyed by the rendered
thread, turn, and item preserves drafts and progress across collection-cell
reuse. Replacing the presentation store clears that UI state.

Wire `CodexChatWorkspaceView.onSubmitTranscriptUserMessage`, or the
transcript-only `CodexTranscriptViewV2.onSubmitUserMessage`, to submit that text
without consuming a separate in-progress composer draft. Capture the displayed
thread and account generation when constructing the host callback, then check
both before sending. The async callback returns a
`CodexTranscriptUserMessageReceipt`: `accepted`, `retainedForRetry(message:)`, or
`rejected(message:)`. Submission disables the action immediately; accepted or
retained answers cannot be accidentally sent twice, while rejection keeps the
answer editable for another attempt. Acceptance means the host accepted the
ordinary submission for processing, not a server-owned question resolution.
These cards have no pending server-request ID and never
resolve an approval or input RPC. Hosts that only wire message editing may stage
the answer for manual sending instead.

Transcript-only hosts can observe `onReadingHistoryChanged` to drive a custom
composer. `CodexComposerBar.isReadingHistory` and `onRestingChanged` support the
same integration, with geometry changes and scroll restoration excluded from
user reading gestures.

### Codex behavior

The reference app opts into `tools.update_plan.enabled` for start, resume, fork,
and voice threads and requests detailed reasoning summaries for turns. Codex
filters the summary parameter for models that do not support it. These defaults
belong to the app; SDK callers retain their own request parameters.

When a turn ends before a running command receives its own completion, its UI
stops spinning and retains streamed output. The canonical item remains intact;
the turn's terminal reason and explicit item failures remain visible.

## Verify

`just gallery --theme t3Code` renders production components in both appearances.
The `chat-workspace` scene includes the sidebar, header, transcript, and
composer. Run `just run-app` for the actual AppKit transcript and keyboard,
scroll, selection, and interaction checks.
