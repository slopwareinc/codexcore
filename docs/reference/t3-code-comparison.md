# T3 Code / CodexCore source comparison

At the audited revision, the native port reproduces substantial T3 presentation and Codex behavior.
Complete interaction parity still requires work on attachments, draft identity,
plan actions, question lifecycle, selected-response forks, workspace integration,
and background workflow ownership. Broad protocol coverage does not establish
that every feature has a complete everyday UI.

## Audit scope and revisions

The feature audit below follows [T3 Code revision `7bf6de17`](https://github.com/pingdotgg/t3code/tree/7bf6de174171ffcf0215bf55556f0e3ee7e6d78f),
the upstream main revision fetched on 2026-10-07, and CodexCore `d0a64f5`.
It traces current production UI, client state, server services, adapters and
native counterparts. Legacy paths and disabled options are distinguished from
the default product. This is a source audit; it includes no new T3 runtime test,
visual parity claim, CPU profile or exhaustive line-by-line review.

The implemented visual adaptations remain based on [revision `3e6b450`](https://github.com/pingdotgg/t3code/tree/3e6b45028ceec5820dacb37dc3852470ebdc9411)
and retain that attribution in `THIRD_PARTY_NOTICES.md`. The later audit revision
does not change the provenance of copied code. See [T3 Code presentation](../ui/t3-code-presentation.md)
for the native source mapping and embedding contract.

T3's current production server already used orchestration-v2 at the earlier pin.
Its latest changes extend that architecture; V2 itself is not newly introduced.

## Major features and ownership

| Feature | How current T3 implements it | CodexCore and the useful next step |
| --- | --- | --- |
| Runtime and recovery | Pure command decider, SQL event/projection/receipt/outbox transaction, effect worker, provider adapters, durable application runs and attempts. | Keep the ordered SDK actor, canonical reducer and native Codex execution. Add host persistence only for workflows the app owns. |
| Inbox and navigation | Project-scoped thread shells, independent draft rows, pinned/active/settled/snoozed sections, persisted ordering, keyboard/range selection. | Flat cards/search/rename/scope are implemented. Independent drafts, settle/snooze and manual active ordering remain gaps. |
| Composer and attachments | Rich semantic context records, persistent scoped drafts, prepared uploads, native image inputs, queue/steer/restart and recall/stash. | Queue/steer and scoped in-memory thread drafts work. Wire real image inputs and independent durable draft sessions first. |
| Transcript and tools | Virtualized chronological rows, persisted reasoning parts, phase-aware messages, typed tool summaries, rich Markdown/artifacts. | Native AppKit virtualization and T3 tool geometry are present. Retain completed reasoning and add bounded rich-output features. |
| Plans, questions and approvals | Composer-local checklist/request surfaces, Refine/Implement actions, persisted async answer/dismiss records and full provider decisions. | Typed plans/questions and exact live RPC resolution work. Add action provenance, durable async lifecycle and consistent decision presentation. |
| Queue, forks and agents | Durable app runs above native turns, native steering, selected-run fork boundaries, context transfers and application delegation. | Native queue/steering/graphs are substantial. Expose selected-turn forks, visible Stop/fork errors and remaining work controls. |
| Files and search | Lazy tree, separate bounded path/content indexes, virtual editor, serialized save coordinator. | Lazy previews and native FS APIs work. Bring path search, content search and explicit editing into the main workspace. |
| Git and worktrees | Shared demand-driven status service, bounded process execution, worktree launch/setup, checkpoints and forge services. | Existing staging/review/commit/push/handoff are real. Share cheap metadata and fix process lifecycle before expanding Git scope. |
| Terminals and panels | Server-owned PTYs with bounded replay, attach ordering, split groups and lightweight persisted panel descriptors. | Retained local Ghostty sessions and lazy native tabs work. Clarify close/undo ownership; splits/restart replay are optional expansion. |
| Integrations and browser/device tools | Provider integrations plus T3's own MCP host tools and browser/device services. | Native plugin/app/skill/MCP/hooks management and MCP Apps already work. Browser automation/device services are separate host features. |
| Account, voice, schedules and remote access | Provider/environment catalog, server schedules and remote client/server infrastructure; inspect actual capability defaults. | Native account/realtime/remote protocol controls exist. Persistent remote connections and durable scheduling require distinct host services. |
| Settings, notifications and efficiency | Scoped settings/search targets, shell-driven notifications, metadata streams and stable row identities. | Share action metadata, coordinate background transitions and measure/narrow sidebar projection work. Preserve native rendering foundations. |

## 1. Runtime, durable effects and recovery

[`runtimeLayer.ts`](https://github.com/pingdotgg/t3code/blob/7bf6de174171ffcf0215bf55556f0e3ee7e6d78f/apps/server/src/orchestration-v2/runtimeLayer.ts#L200)
composes the production stores, adapter registry, worker and recovery services.
`EventSink.ts:239–261,332–394,527–592` commits command identity, events,
projections and effects together, then publishes after commit. `EffectOutbox.ts`
has durable effect identity and per-thread execution lanes. Provider I/O runs
outside the pure `Orchestrator`, through services such as `ProviderTurnStartService`
and the real `CodexAdapterV2` selected by `provider/Drivers/CodexDriver.ts`.

T3's application run can span several native turns or provider attempts. Native
CodexCore directly models server threads/turns through `CodexSession`, leases,
identified submission intent and the canonical replica. Connection loss marks
written mutations indeterminate instead of replaying them blindly. Preserve that
contract; a second execution queue or reducer would create conflicting owners.

On T3 restart, unstarted queued runs survive but are held until explicit
`queue.resume` (`ProviderRuntimeRecoveryService.ts:287–300`). Restart continuation
and usage-limit auto-resume are separate opt-in settings, both false by default
(`packages/contracts/src/settings.ts:1237–1239,1306–1307`). Recovery reconciles
process-bound effects separately from effects safe to retry. Native reconnect
rehydrates leased state but does not implement T3's host continuation policy.
If added, reconcile authoritative status first and preserve stop/new-message
exclusions and stable continuation identity.

## 2. Inbox, project scope and draft navigation

[`Sidebar.tsx:2700–2810`](https://github.com/pingdotgg/t3code/blob/7bf6de174171ffcf0215bf55556f0e3ee7e6d78f/apps/web/src/components/Sidebar.tsx#L2700)
partitions current thread shells. Settlement and snooze require advertised server
capabilities. Subagent lineage is excluded; turn completion alone does not settle
a chat. The legacy sidebar and optional Working shelf both default off
(`settings.ts:462,466`). Scope is persisted independently of the selected chat,
and is removed only after live catalogs prove the project missing.

`packages/client-runtime/src/state/threadSort.ts` owns the common web/mobile
ordering rules: new/reopened unarranged active chats first, then fractional
manual order; pins use saved order then creation time; settled history uses its
settlement/completion anchor. A reorder normally writes one key to one thread.
Snooze affects visibility while work continues, and wakes on time or fresh
approval/input/failure/completion (`threadSettled.ts:88–216`). An earliest-wake
timeout replaces continuous timer polling. History begins with ten rows and
keeps the open deep-history chat visible.

Native `CodexT3SidebarInboxProjection`, `InboxView`, `ThreadRow` and the shell
implement loaded flat cards, pins, creation order, scope, search, range selection,
inline rename and archived pagination. Archived remains the real native server
feature. Native has no T3 settlement/snooze/manual active-order records; those
need explicit host persistence and wake/undo/navigation policies.

T3's scope picker is searchable. Server chat search uses 200 ms and a
two-character floor (`state/queries.ts:74–101`); native uses 180 ms and local
fallback without that floor. Native Cmd-N calls projectless `startNewChat()`
(`CodexCoreApp.swift:223–226`), while the sidebar resolves scope/current-project
selection separately. A shared New Chat action policy should serve both.

## 3. Composer, context and image inputs

[`composerDraftStore.ts`](https://github.com/pingdotgg/t3code/blob/7bf6de174171ffcf0215bf55556f0e3ee7e6d78f/apps/web/src/composerDraftStore.ts#L89)
persists versioned scoped-thread/DraftId content with a 300 ms debounce and unload
flush. `useHandleNewThread.ts:170–210,331–360` reuses empty drafts but preserves
drafts containing user work as independent sessions. Context records identify
files, images, terminal selections, elements, previews, reviews, skills and
threads. The Tiptap editor carries those identities through caret/clipboard
operations. Prompt recall and stash are distinct features.

Native `CodexComposerStateSession` correctly preserves existing-thread text,
files and annotations in memory. `clearThreadState()` does not erase those
dictionaries. However every unassigned draft uses `__codex_unassigned_draft__`,
and there is no durable draft load/save. New projects/chats share that slot.
Skills and selected mention names also have different ownership: skills clear
on navigation; selected names can survive and associate a later draft with an
old path. Introduce explicit draft-session identity, then serialize content and
context under the same scope. Do not persist the shared nil key as a substitute.

T3's `CodexAdapterV2.ts:2977–3020` converts uploaded image bytes to native image
inputs; other files remain path context. Native picker/drop thumbnails currently
lead to `CodexComposerSubmission.turnInput:45–53`, which sends skills, mentions
and text containing file paths. The SDK already supports `.image`; the app never
constructs it from those attachments. Add submit-time image materialization,
queue/restoration support and model capability feedback. Non-image paths can
retain their current tool-access semantics.

## 4. Transcript, reasoning and rich output

[`MessagesTimeline.tsx`](https://github.com/pingdotgg/t3code/blob/7bf6de174171ffcf0215bf55556f0e3ee7e6d78f/apps/web/src/components/chat/MessagesTimeline.tsx#L506)
uses LegendList, stable row projection and bounded disclosure/scroll state.
The adapter preserves reasoning summary/content parts, and the timeline exposes
an expandable completed trace (`CodexAdapterV2.ts:3102–3189`;
`MessagesTimeline.tsx:3174`). Tool presentation is typed, count-aware and ordered;
reasoning is excluded from tool counts. Commentary/final phases come from native
message data rather than text heuristics.

Native preserves AppKit collection virtualization, prepared rendering, T3 user
bubbles, assistant flow, tool grouping, changes and terminal output. Canonical
reasoning data survives, but `CodexCanonicalTranscriptProjector.swift:270–274`
uses reasoning only as a live tail; completion removes its display. Add a typed
reasoning disclosure using the retained parts, with bounded layout/cache state.

T3 `ChatMarkdown.tsx` supports GFM, sanitized HTML, Mermaid, artifact-template
cards, citations/context references, media and some explicit host actions.
Native already has Markdown/code/table/media/diff/directive foundations; Mermaid
and artifact-template use cards are bounded gaps. Editor richness and shell
execution belong to host interaction policy. Literal HTML fallback is an
intentional native rendering boundary, not evidence of a missing Codex RPC.

## 5. Plans, questions and approvals

[`proposedPlan.ts:102–133`](https://github.com/pingdotgg/t3code/blob/7bf6de174171ffcf0215bf55556f0e3ee7e6d78f/apps/web/src/proposedPlan.ts#L102)
distinguishes Refine (nonempty composer text, plan mode) from Implement (full
plan, default mode). ChatView supports current/new-thread actions with a durable
source-plan record. Checklist progress is a composer badge with expandable
steps. Native already opts into the checklist and renders typed proposed plans
with matching preview/full copy/export; it lacks those plan actions and the
composer-local checklist placement. Add action/provenance callbacks to the
existing card instead of another plan renderer.

T3 live blocking requests resolve the provider's pending RPC. Async assistant
questions instead become message-capability application requests:
`CodexAdapterV2.ts:4645–4685`, `Orchestrator.ts:7117–7214`.
Resolution and ordinary message dispatch commit together, with deterministic
answer identity, active steering when supported, queue fallback and persisted
dismiss/answer history. Both apps' normal composer follow-up setting defaults
to queue; T3's async-answer branch independently prefers steering.

Native blocking approval/input uses exact epoch/request identity. Its async
card correctly submits an ordinary user message with awaited receipt,
thread/account guards, duplicate lockout and retry retention. Its 128-entry UI
store is ephemeral: reset/eviction/restart can make an accepted question
answerable again. Add durable host answer/dismiss records keyed to originating
thread/turn/item and preserve the existing receipts. Cross-client atomicity
requires a shared service; local persistence alone cannot promise it.

T3 places full approval/question context at the composer, including available
provider decisions and warnings. Native popup and transcript affordances differ;
the inline card's bool Allow/Deny exposes less than the SDK supports. Share a
request presentation model across surfaces and retain full details/decision
availability. Generalized T3 question attachments/multi-select should be gated
by the actual selected protocol schema.

## 6. Queue, selected-turn forks, Stop and delegation

[`operations/commands.ts`](https://github.com/pingdotgg/t3code/blob/7bf6de174171ffcf0215bf55556f0e3ee7e6d78f/packages/client-runtime/src/operations/commands.ts#L626)
prepares workspace/attachments, dispatches messages and exposes queue controls.
T3's app run/attempt layer preserves identity across steer/restart/recovery.
Native durable queue and serialized steering already reconcile client IDs,
retry one reported active-turn mismatch and start immediately after the
no-active-turn race. Keep native server queue ownership. In-place queue editing
must respect available native methods; remove-and-restore is a different action.

T3 forks from a selected source run and resolves the inclusive native turn
boundary (`ThreadForkService.ts`, `CodexAdapterV2.ts:6875–6948`). Native generated
and lease APIs already accept `lastTurnID`, but transcript Fork invokes whole
`forkCurrentChat()` without selected turn identity. Wire that identity through
the public callback and surface errors; the app currently has an empty catch.

T3 Stop includes remaining background/delegated work and reports failure.
Native has graph interruption reports and individual background-terminal
controls, while main Stop only interrupts `activeTurnLease` and suppresses
errors (`CodexCoreAppModel.swift:4011–4017`). Build a coordinator over existing
controls, expose partial failures and verify native descendant propagation
before issuing multiple interruptions.

T3's application delegation/context-transfer/mailbox services are distinct from
provider-native subagents. Native already observes recursive Codex collaboration
and forks. Cross-provider child tasks, durable result delivery and conversation
merge-back would be new host services. T3 itself rejects consuming pending
merge-back through queued dispatch (`Orchestrator.ts:4770–4782`); it is not
universal seamless merge. Latest T3 groups native autonomous goal turns into one
app run. Native already exposes goals, and should verify presentation continuity
without adopting a second execution owner.

## 7. Workspace files, search and editing

[`FileBrowserPanel.tsx`](https://github.com/pingdotgg/t3code/blob/7bf6de174171ffcf0215bf55556f0e3ee7e6d78f/apps/web/src/components/files/FileBrowserPanel.tsx#L105)
loads only opened directories and performs separate bounded path search. T3's
`workspace/WorkspaceSearchIndex.ts` keeps path and content indexes distinct,
creates content indexing only on demand, and expires idle resources after
15 minutes. Initial scans and individual queries have explicit budgets; incomplete
results and errors have different meanings. `ProjectContentSearchDialog` exposes
case/whole-word/regex search with clickable file results.

T3's file editor uses `fileSaveCoordinator.ts` to debounce and serialize writes,
track confirmed revisions and flush the latest change on disposal. Reads are
bounded and binary content is rejected; external absolute files are read-only.
Native `CodexFilesToolView` already loads directories lazily off the main actor,
caps direct children at 2,000 and owns cached selection. `CodexFilePreviewView`
caps text at 2 MiB/highlighting at 512 KiB, but the workspace preview is read-only
and rejects historical refs. Native FS read/write/watch and fuzzy path search
are implemented in the runtime features surface.

Bring those existing services into the main Files/preview workflow, disclose
truncation and handle dirty-close/external-write conflicts. Add repository
content search through a cancellable, time/result/byte-bounded `rg` service
before adopting a permanent index. Historical content can use an on-demand
bounded ref reader; keep search/editor state outside canonical thread facts.

## 8. Lean Git, worktrees and file rewind

[`VcsStatusBroadcaster.ts`](https://github.com/pingdotgg/t3code/blob/7bf6de174171ffcf0215bf55556f0e3ee7e6d78f/apps/server/src/vcs/VcsStatusBroadcaster.ts#L612)
shares pollers by resolved checkout and stops them when demand ends. T3 caches
local/remote status and forge reads separately, debounces focus refresh, and
gates its default 30-second remote fetch by background demand with failure
backoff. Only Git is registered as a VCS driver at this pin. Its generic
registry does not establish shipping support for other VCS implementations.

Native already has selected/all staging, unstage, tracked restore, branches,
commit/push with partial-success reporting, draft GitHub PRs, selected-file
patch loading, staged/unstaged/branch/commit review and transcript-derived Last
Turn diffs. Patch content is lazy and bounded. Summary's branch picker is also
lazy, but loads a full review snapshot to obtain branch metadata. Summary and
Review own separate repository actors; worktree/environment code has a third
Git implementation. Completed metadata/mutation state is not shared.

Use one compact service per normalized checkout: cheap branch/status summary,
refs/log on demand, and selected-source file metadata. Coalesce duplicate reads,
bound the cache and invalidate after known mutations. Preserve stale-revision
guards and partial commit/push outcomes. No periodic fetch, automatic LLM commit
text, generic VCS registry or forge database is required for that improvement.

Current Review `CodexBoundedProcess` does support cancellation and bounded pipe
reads. It still lacks deadlines/escalation and can miss cancellation before
launch. Shared snapshot tasks outlive cancelled waiters. The environment runner
still blocks in `waitUntilExit`, has no cancellation/deadline, and checks
temporary-file output size only after exit. These are verified implementation
limits with static hang/disk-growth risks, not reproduced failures. A small
shared owned runner should address launch cancellation, live caps, deadlines,
termination escalation and cleanup before expanding worktree features.

T3 first-send worktree launch binds the prepared checkout before provider start,
with setup progress and retry. Native existing-chat handoff preserves tracked
and untracked changes while leaving the source checkout intact. These are
different useful workflows. Fresh-chat worktree launch can reuse the native
provider after fixing its runner.

T3's `CheckpointService`, `GitVcsDriver` and rollback service capture hidden Git
refs after application runs, use a temporary index, and optionally restore files
while rewinding provider conversation. An app run may span multiple native turns.
Native conversation-only `thread/revert` already works and explicitly leaves
files unchanged. Full filesystem rewind needs deliberate snapshot/retention,
isolation and external-mutation policy; keep it a separate feature. Earlier-turn
canonical diffs and transcript-accessible history revert can come first.

T3 also has a large five-forge PR client with review/comments/checks caches.
Native's on-demand GitHub details/create and Codex `review/start` are already
real. Surface the latter's currently swallowed start failure. A full forge
inbox remains optional product scope.

## 9. Terminals and panel lifecycle

[`ThreadTerminalDrawer.tsx`](https://github.com/pingdotgg/t3code/blob/7bf6de174171ffcf0215bf55556f0e3ee7e6d78f/apps/web/src/components/ThreadTerminalDrawer.tsx#L464)
renders a Ghostty WASM surface, while T3's server owns PTYs, bounded replay
history, ordered snapshot/attach buffering and TERM/KILL cleanup. Detach and
close have distinct semantics. `rightPanelStore` persists lightweight resource
descriptors and split groups; feature owners retain actual resource state.
Current T3 plans are inline and Agents use lineage, replacing their former
standalone panel routes.

Native local Ghostty sessions already survive hidden panels/chat changes,
pause display work while hidden, and materialize restored tabs lazily. Workspace
tabs own placement, preview replacement, pinning, close fallback, undo and
bounded retained chat resources. Keep that model. Browser is still a legacy
route/deck, so migration remains incomplete despite the general panel ADR.

Explicit terminal close can retain the last closed tab for undo, whose adapter
captures its session. That is a source ownership inference requiring a lifecycle
test, not a proven process leak. Define close versus hide versus undo semantics.
Split groups and restart replay are useful optional additions; remote PTY
ownership is a larger service. Agent background terminals remain metadata-only
because the native protocol exposes no attach-stream endpoint.

## 10. Integrations, browser/device tools and artifacts

[`McpHttpServer.ts:765–777`](https://github.com/pingdotgg/t3code/blob/7bf6de174171ffcf0215bf55556f0e3ee7e6d78f/apps/server/src/mcp/McpHttpServer.ts#L765)
registers T3's own browser, device, HTML, thread, project, worktree and forge
toolkits. Scoped credentials identify the invoking provider/session/thread;
the Codex adapter injects this MCP server. Those host services create the
functionality. Provider-owned integrations and skill discovery are separate.
Current T3's Integrations settings primarily configures browser/device services;
it does not provide the same Codex plugin/MCP/hooks administration as native.

Native Plugins/Apps/Skills/Marketplaces/MCP/OAuth/resources/tools/hooks are wired
to the connected control-plane provider. MCP Apps use account/thread-scoped
callbacks and an isolated nonpersistent WKWebView bridge. Preserve and validate
these existing capabilities rather than recreating T3's thinner administration.

T3's collaborative browser uses Electron or server Chromium/Playwright/CDP,
persisted human profiles and isolated agent contexts, explicit tab ownership,
semantic snapshots/screenshots and action tools. Responsive controls, annotations,
recording and cookie-profile import are real source paths. Agent browser access
defaults true, with project/capability gates; proactive panel opening defaults
false. Native Browser is a manual retained WKWebView with shared website storage
and navigation controls. The launcher/plugin search is not an automation bridge.
An injectable browser-control host with ownership, user takeover and scoped tools
is the required foundation before adding more preview controls.

T3 `DeviceService`/hub helpers stream and drive development simulators/emulators
through local or SSH hosts. Helper support and agent control default separately
false. Native paired-device settings configure remote Codex clients; they do not
implement a simulator viewer. A device provider/panel would be a separate host
feature. T3 desktop SnapShot actually captures screen/accessibility context into
an anchored composer image attachment. Native Computer Use is currently a
launcher/install boundary, not an implemented capture/control service.

T3 `html_preview`/`html_render` perform headless QA and publish thread-owned HTML
attachments with authenticated viewers (`htmlRender/HtmlRender.ts:418–447`).
That artifact workflow differs from MCP Apps resource/bridge rendering. Native
has real interactive MCP Apps but no equivalent HTML publish tools. Add a
distinct artifact store/reference and contained preview, then richer PDF/media/
rendered Markdown previews. Reuse containment machinery while preserving each
feature's origin, resource and lifecycle contract.

## 11. Accounts, voice, schedules and remote environments

[`ProviderInstanceRegistry`](https://github.com/pingdotgg/t3code/blob/7bf6de174171ffcf0215bf55556f0e3ee7e6d78f/apps/server/src/provider/ProviderInstanceRegistry.ts#L197)
owns multiple harness instances and credential bindings. Authentication targets
environment/instance and exact flow/interaction IDs. Usage merges provider
limits and source-attributed estimates across environments; its Codex mapper
intentionally filters model-specific limit rows. Native account login/cancel,
gateway/Bedrock/verification, model-keyed limits and daily usage are implemented.
Multi-profile homes and pooled analytics are potential expansion; cross-harness
adapters belong outside Codex's generated protocol models.

At this pin T3 exposes iOS 26+ local mobile dictation; non-iOS native transcription
returns unavailable. Its retained realtime event contracts do not establish a
production realtime UI/RPC path. Native macOS dictation and full WebRTC Codex
voice are implemented. Preserve those strengths and their teardown/draft-owner
semantics; native dictation can fall back from on-device recognition.

[`ScheduledTaskService.ts`](https://github.com/pingdotgg/t3code/blob/7bf6de174171ffcf0215bf55556f0e3ee7e6d78f/apps/server/src/scheduledTasks/ScheduledTaskService.ts#L798)
persists server schedules and new-thread execution context, or queues to an
explicit existing thread. Interval/fixed-time/weekday/webhook triggers have
bounded ingress and restart recovery. Its reported success means dispatch
acceptance, whereas native automation awaits the terminal agent turn; those
statuses must not be treated as equivalent.

Native automations are real local TOML-backed recurring tasks, but the app must
remain running. Save/delete/load failures are discarded by the host, despite
the store reporting them. The task model lacks saved workspace/model/permission/
environment context, and execution uses current app `threadStartParameters()`.
`targetThreadID` is a last-run link rather than a bound-thread execution policy.
Fix write-before-publish/error handling and capture context first, then define
new versus bound-thread dispatch and interrupted-run records. A background
runner needs single-owner coordination, durable receipts and restart semantics;
interval/webhooks/remote scheduling can follow that foundation.

T3 has a secure persistent connection catalog, ordered fallback routes, SSH
bootstrap, Tailscale endpoints, relay-account discovery/linking and a separate
React Native client. Desktop catalog storage is encrypted through safeStorage;
mobile credentials use secure storage. Relay sign-in is separate from provider
sign-in. These are substantial host services, not a change to chat colors.

Native SDK has an injectable WebSocket transport. The reference app still
constructs one local stdio client; it has no equivalent saved multi-host catalog.
Executor add/status/info and Codex remote-control pairing/client revoke are
actually wired, but represent different upstream features. The executor view
advertises chat environment selection; the audited app turn builders contain no
selection consumer. Treat that as an incomplete integration seam and verify it
before promising executor switching. A remote host product should start with
stable catalog/credential/session identity and scoped UI/reconnect ownership;
SSH, Tailscale, relay and mobile are later workstreams.

## 12. Settings, notifications and frontend efficiency

T3 splits device-local settings from environment/project settings, serializes
hydration and writes, and reports persistence failures (`hooks/useSettings.ts`).
Its `components/settings/settingsSearch.ts` indexes individual settings with
scope/platform/capability availability and stable targets. Native shares settings
window/route wiring and versioned preferences, but search indexes routes rather
than individual setting rows. One action/setting metadata source can improve
search and availability without duplicate controls.

T3 notifications watch shell transitions, skip initial/archived/subagent
baselines and deduplicate attention/completion before choosing sound, in-app
toast, desktop notification and badge. Desktop and in-app notifications default
off. Native has actionable macOS requests and automation/turn completion, but
ordinary completion notifications originate from the selected main-turn monitor,
which navigation cancels. Canonical index observation still updates unread/dock.
Move notification transition ownership outside displayed-chat lifetime without
hydrating all histories or retaining a lease merely to notify.

[`ShellStream.ts:199–244`](https://github.com/pingdotgg/t3code/blob/7bf6de174171ffcf0215bf55556f0e3ee7e6d78f/apps/server/src/orchestration-v2/ShellStream.ts#L199)
suppresses equivalent metadata deltas except a five-second cursor-progress resend.
T3 strips transcript bodies before shell retention, reuses thread presentation
through WeakMap source identity, preserves unchanged arrays and memoizes rows
with stable callback refs. Count-only draft subscriptions keep composer typing
from invalidating the parent sidebar.

Native already has scoped/coalesced SDK observations, a canonical index, lazy
rows, local hover/edit state, bounded rendering caches and AppKit virtualization.
Five source-backed opportunities remain:

1. Gate status publication on visible tuple changes. Selected item-content
   observations currently republish the same status with a fresh Date. That
   date is not copied to sidebar rows, so it does not by itself break snapshot
   equality or prove all rows redraw.
2. Stop reading the full computed `model.sidebarSnapshot` for scalar flags.
   `CodexCoreAppShell.swift:24,138,501–502` repeats projection work, including
   while the sidebar is hidden.
3. Share identity/visibility resolution and construct the topology consumed by
   the current presentation. `CodexSidebarOrganization.swift:319–477` builds
   both grouped previews and inbox; the adapter eagerly builds fallback arrays
   even when complete inbox data exists. Grouped mode is still used and is not
   dead code.
4. Index project membership/counts once. `presentedProjects:230–240` scans the
   roster for each server project before later grouping builds its own indexes.
   Preserve distinct opaque IDs and multi-folder/path fallback semantics.
5. Read/cache one consumed inbox projection and search result. Current cache
   compares the full deep snapshot on repeated property access; highlight
   changes can repeat local search with an unchanged query.

Measure projection/status/search counts and allocations with 1,000–2,000 chats,
one streaming turn, scope changes, collapsed sidebar and search hover/keyboard
navigation. Source redundancy establishes optimization opportunities, not
measured jank or a universal speed advantage of one UI framework. Keep the
SDK reducer and native transcript architecture.

## Recommended implementation order

1. **Existing correctness:** surface Stop/fork/review/automation errors; fix
   automation persistence/context and the shared Git runner's lifecycle.
2. **Core chat usability:** native image inputs and independent durable drafts,
   including skill/mention ownership and shared New Chat dispatch.
3. **Complete interactions:** selected-turn fork, plan Refine/Implement,
   completed reasoning, durable async answer/dismiss and consistent approvals.
4. **Measured efficiency and workspace:** narrow sidebar publication/projection,
   share lean Git metadata, integrate Files search/edit and bounded content search.
5. **Host extensions:** browser automation/artifacts, then device/capture,
   persistent remote connections and background scheduling. Keep each in its
   own issue/service with capability and lifecycle boundaries.

The first four steps primarily reuse existing native SDK capabilities. New
browser/device/relay/checkpoint/delegation services should not be counted as
implemented merely because a protocol type, launcher, fixture or theme exists.

## Audit verification and limits

Six specialist workers inspected runtime, chat, workspace, integrations,
account/remote/voice/schedules and efficiency; the parent traced sidebar,
settings and notifications and checked the synthesis against production paths.
The existing PR's build/test CI was green at `d0a64f5`. No executable source was
changed for this audit, so no new feature test result is claimed. Source paths
and pinned upstream links are validated as documentation checks.

Absence findings are bounded source-search conclusions. Live provider behavior,
audio/devices, scroll feel, subprocess hangs, remote services and visual parity
still require targeted fixtures/runtime checks when their implementations change.
External relay infrastructure and every third-party/provider branch were not
exhaustively inspected. This map is an implementation guide, not an assertion
that every possible defect has been found.

## Implemented interaction changes at the visual-port revision

T3's `apps/server/src/provider/Drivers/CodexDriver.ts` constructs a per-provider-instance app-server adapter with a separate effective Codex home/process, plus a separate `codex exec` text-generation service. It delegates chat behavior to `apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.ts`. CodexCore's typed SDK, connection epochs, leases, identified native operations, and canonical state are richer for a Codex-only host and should remain the integration foundation.

Concrete presentation prerequisites found and implemented:

1. `CodexAdapterV2.ts:1194–1241` sends `tools.update_plan.enabled: true` with every thread start, resume, and fork. Codex 0.160 defaults this checklist tool to disabled; official `core/src/config/config_tests.rs:611` confirms it. CodexCore had the checklist renderer but never opted into the tool. The app now does so consistently for text/projectless/fork/voice paths, with voice realtime flags merged rather than replacing the checklist opt-in. SDK defaults remain untouched.
2. `CodexAdapterV2.ts:761` explicitly requests `summary: "detailed"` on every turn, including resumed conversations, because the model catalog can default to none. CodexCore omitted it. The reference app now requests detailed summaries for ordinary/voice turns. Official pinned `core/src/client.rs:873` gates the outgoing Responses summary by the model's `supports_reasoning_summary_parameter`; unsupported models omit the parameter safely. SDK caller-provided parameters remain untouched.
3. `CodexAdapterV2.ts:1966–2041` terminalizes running command presentation when a parent turn interrupts/fails without an item completion. CodexCore's projector previously kept payload `status: inProgress` as a spinner forever and discarded streamed output on terminal parent turns. It now settles these presentation rows and retains the output overlay until an authoritative command completion replaces it. Canonical payload/status remain intact, including explicit failed/declined/unknown outcomes; the turn retains its interrupted/failed reason.
4. `CodexAdapterV2.ts:4392` treats `agentMessage { delivery: "async", questions: [...] }` as structured, nonblocking, message-mode questions. `CodexAdapterV2.test.ts:2294` verifies that the question survives provider completion and is not a live RPC. CodexCore's generated types preserved those fields but its projector ignored them and mislabeled the text as a final answer. The projector now emits a typed question narrative card. The card supports suggestions, custom answers, multiple-question progress, collapse, and explicit sending/staging. Its scrollable body materializes options lazily; a bounded thread/question keyed presentation owner preserves drafts, step, and collapse state across native collection-cell reuse. `Orchestrator.ts:6955–7030` formats answers as `question\nanswer` pairs separated by blank lines and sends an ordinary user message; CodexCore now uses the same format. The host sends directly from an independent composer submission, preserving the user's draft and checking the original thread/account generation, live lease, and 32 KiB bound. It never resolves an approval RPC or invents an app-server request ID.
5. `CodexToolPresentation.ts` uses MCP result metadata for readable browser/computer/MCP identities. `CodexMCPToolPresentationV2` now projects source name, action title, symbol, and bounded HTTP(S) page URL from the same documented fields, preserving raw tool data and MCP App identity. URL priority matches T3: screenshot page, browser-use URL, then the latest valid open tab. Native bundle names are resolved only from the bounded known-name table. Logos/favicons are not fetched and the displayed URL does not trigger navigation.

## Semantics already present in CodexCore

The current T3 sidebar is the default (`legacySidebarEnabled: false`), distinct
from `LegacySidebar.tsx`. CodexCore's T3 presentation now uses its flat,
project-scoped inbox and 78-point active cards. Its full loaded roster is
independent of native five-row project previews. Creation-based ordering keeps
activity from moving rows, typed canonical flags supply Approval/Input, and
branch metadata comes from the server. Pinned order, search scope, inline rename,
and visible-range selection are presentation state. Turn completion never
creates T3's separate application-owned settlement or snooze state.

- T3's `message_steering/codex_output.ts` asserts one run/native provider turn with both opening and steering user inputs visible. CodexCore already retains `userMessage`, `steeredMessages`, and canonical `conversationSegments`, reconciles client IDs, serializes steering, retries the reported active turn once, and immediately starts a new turn for the no-active-turn race.
- T3 advertises native queue, interrupt, session model/runtime switching, file/command approvals, structured blocking input, proposed plans, checklist updates, tool output, and subagents (`CodexProviderCapabilitiesV2`, lines237–329). CodexCore already exposes these through typed APIs, durable queue control, canonical prompts, thread leases, and recursive thread graph state.
- T3's plan-mode turn parameters use native `collaborationMode` and explicit approval reviewer per turn (`buildCodexTurnStartParams`). CodexCore likewise constructs native collaboration/permission settings, with additional protections for model-specific service tiers and reasoning effort across target threads.
- T3 distinguishes commentary from a final answer by the native agent-message phase. CodexCore uses the same wire grammar. The transcript port changes geometry and grouping without regex guesses about message meaning.
- `ChatView.logic.ts:1225` evicts optimistic user rows only after the actual visible server turn-item row exists. CodexCore's canonical submission projection already performs client-ID reconciliation from server item state.

## Remaining implementation boundaries / follow-up candidates

- T3's browser/computer activity may show remote branded icons and page favicons. This port uses theme-compatible native symbols and a validated page URL without new remote image traffic; existing isolated MCP App cards remain intact.
- T3's server owns cross-provider orchestration records, durable async-question resolution/dismissal, filesystem checkpoints, and background-run continuations. Those are T3 application state, not extra Codex app-server methods. CodexCore's async card cannot claim a server-owned answered/dismissed state merely from a local click. Replies remain standard visible user submissions and follow the host's active follow-up policy.
- T3's `ChatView.logic.ts:183` proactively opens a diff only for three or more files or 50 changed lines, while respecting user panel choices/PR panels. This is application navigation policy, not a Codex correctness gap; the existing SDK/review-session model should be preserved if that UI policy is adopted.
- T3 has multi-provider/handoff/environment services, browser/device panels, web/mobile surfaces, and per-question attachment preparation. They should not be accidentally presented as implemented by a native styling port.

## Verification

`CodexCoreAppModelServiceTierRequestTests` verifies checklist and summary request construction. `CodexCanonicalTranscriptProjectorTests` covers terminal-turn output retention and typed narrative projection. `CodexAsyncQuestionTests` and `CodexMCPAppModelScopeTests` cover answer formatting, presentation-state retention, submission receipts, draft preservation, and stale thread/account guards. `CodexT3TranscriptPresentationTests` covers native layout, streaming continuity, plans, diffs, and reading gestures. These checks run with `swift test`.
