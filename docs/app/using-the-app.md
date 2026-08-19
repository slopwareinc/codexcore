# Use the reference app

The reference app is a native Codex host and living integration example. The [support matrix](../reference/support-status.md) distinguishes working flows from preview-only surfaces.

![CodexCore native macOS workspace](../assets/screenshots/hero-workspace.png)

## Main routes

- **Chat:** project threads, transcript, composer, approvals, plans, and tools.
- **Search:** find and resume existing chats.
- **Plugins:** inspect plugins, skills, and MCP-backed capabilities.
- **Automations:** create, schedule, pause, edit, run, and delete recurring Codex chats.
- **Settings:** appearance, history, sidebar, integrations, and application information.

Settings → About reads the 0.148 app-server process snapshot on demand. It
shows PID, resident memory, macOS physical footprint, and registered diagnostic
gauges. Opening other routes performs no diagnostics work, and About never
polls in the background; use **Refresh** for another point-in-time sample.

The composer `/status` sheet requests the selected thread's estimated credits,
optional USD estimate, and per-model token breakdown when opened. Unsupported
workspaces show an unavailable state. The backend request may take longer than
ordinary local RPCs, so it runs asynchronously and is never part of chat resume,
turn completion, sidebar loading, or transcript rendering.

Settings → Chat sections manages the server-synchronized section name, icon,
and color. Create, edit, clear appearance, and delete use the native 0.148
section APIs; deleting a custom section returns its chats to the unsectioned
list without deleting history. Section icons/colors render directly from each
thread summary in the sidebar, so rows perform no additional reads.

The model picker retains 0.148 catalog lifecycle metadata. Its open popover
labels the model's declared single-agent, multi-agent v1, or multi-agent v2
runtime and shows scheduled retirement plus the replacement model when the
catalog provides them. These strings are projected once when `model/list`
loads; opening or rendering the picker performs no additional RPC or date parse.

Open the unified **Command menu** from Sidebar Search or with `⌘G`. It includes
the route, panel, model, skills, MCP, app, and chat actions available in the
current build. Type to search commands or past chats; use Up/Down and Return to
select, or Escape to close.

### Plugin marketplaces

Plugins → Manage includes a **Marketplace** tab backed only by marketplace entries
returned from `plugin/list`. It shows each registered marketplace’s reported name,
display name, path (or an explicit unknown-path label), and plugin count. Enter a
source URL or path to register it; Upgrade and Remove call the corresponding
app-server marketplace methods and refresh the plugin inventory after success.
CodexCore does not scan or auto-register marketplace manifests from filesystem or
cache guesses. Plugin detail pages load their authoritative Apps, app templates,
MCP servers, Skills, hooks, scheduled tasks, sharing metadata, and description with
`plugin/read`; CodexCore does not reconstruct those relationships from list summaries
or name matching.

The **Apps** inventory comes from app-server `app/list` joined with
`app/installed` by app ID. Catalog availability and local runtime installation,
enablement, and callability stay separate; missing state is shown as unknown rather
than inferred from plugin capability strings. A Manage toggle appears only for an
installed app with reported runtime enablement and writes only
`apps.<appId>.enabled`; it does not claim to connect, install, authorize, or disconnect
the account-owned app.

Skills are shown as `(working directory, path)` occurrences with their reported
scope, enabled state, dependencies, and list errors. Codex currently has no
generated skill-uninstall operation, so CodexCore does not substitute recursive
filesystem deletion; removal remains with the skill's owning package or filesystem
workflow.

MCP runtime health is shown separately from configuration ownership. Adding a new
server supports the current config schema, including stdio environment pass-through,
working directories, environment-backed HTTP headers, tool allow/deny lists, and
timeouts. Existing runtime status rows stay configuration-read-only until complete
config origin/version metadata is available, preventing a status-only row from
overwriting fields it never loaded.

## Automations

Automations are stored locally under the active Codex home in
`automations/<id>/automation.toml`. Templates and **Create via chat** open the
ordinary new-chat composer with an unsent prompt, preserving its project,
permission, model, and attachment controls. The dashboard also supports direct
scheduled creation, editing, enable/disable, run now, and deletion.

The app sidebar includes **Automations** alongside the other primary routes.

When Codex is connected and the app is running, a due automation starts an
independent background thread without changing the chat currently on screen.
The dashboard records running, successful, and failed lifecycle state and posts
a native macOS notification on completion when notification permission is
available. Native notifications are enabled for the packaged `.app`; development
launches through `swift run` skip them because macOS does not provide an
application notification identity to an unbundled executable. Existing
automation chats are preserved when a schedule is deleted.

The pinned app-server protocol has no automation request or notification
methods. Full server-owned parity—including runs while the desktop app is not
open and cross-device schedule synchronization—will require an upstream
protocol upgrade; generated protocol files must then be refreshed through the
normal protocol-upgrade workflow.

## Plugins and skills

The Plugins route follows three connected workflows. Browse uses the installed
strip, OpenAI/workspace/personal scope filters, and grouped catalog rows. Skills
are grouped by Personal, Workspace, and System scope. Select any row for its
description, capabilities, source metadata, enable/install controls, and a
**Try in chat** action when the manifest supplies a default prompt.

Choose **Manage** beside Installed to search and configure Plugins, Apps, MCPs,
Skills, and Marketplaces in one place. Empty tabs are hidden except MCPs, which
stays reachable so the first server can be added. Plugin and skill switches
change their enabled state without uninstalling them. Apps come from accessible
`app/list` entries (not plugin capability metadata) and have
their own enable switches. **Manage MCP servers** opens the complete server
surface for enablement, OAuth login, tools and resources, and add/edit/remove
configuration. Marketplace management supports add, update, and remove;
completed mutations refresh the catalog from app-server state.

## Projects and chats

The sidebar groups chats by project. Chats can be pinned, archived, renamed, forked, copied, searched, and resumed. Projects can be selected, grouped, pinned, reordered, edited, removed, revealed in Finder, or used to archive their chats. Chat reorder/hide/reveal actions are not supported.

A separate **Chats** section contains projectless tasks. **New chat** creates a
projectless task in a generated `Documents/Codex/Chats` workspace; use a
project's new-chat action when the task should inherit that project's folders.
Projectless identity is persisted separately from `cwd`, so generated workspaces
do not appear as projects.

Unread state is local app state, not app-server protocol state. A chat becomes
unread only when the running app receives a completed assistant message for
that chat while its conversation is not visible in the focused main window.
History loading, streaming deltas, tool activity, status changes, failures, and
metadata refreshes do not create unread state. Opening the chat in the focused
conversation view marks it read.

The sidebar reserves one trailing state rail per chat: active work takes
precedence over failure, which takes precedence over unread. Project and section
rows summarize that state while collapsed. Selecting a project or one of its
chats expands the project automatically; pin and archive controls appear only
while the row is hovered.

A project may contain multiple ordered source folders. The first folder is
**Primary**: Codex uses it as `cwd` and looks there for project instructions.
Every source folder is sent as a runtime workspace root and is available to the
task. Choose **Edit project** from the project menu to add or remove folders or
make another folder Primary. Existing single-folder projects migrate without
configuration.

The workspace overview mirrors the current environment with changes, local or
worktree mode, branch, commit/push, and pull-request entries. Its Sources
section shows the most recent file references from the visible transcript and
the current composer.

## Composer

The composer supports:

- model and reasoning selection;
- permission and approval profiles;
- click or hold microphone dictation, with insert, transcribe-and-send, and retry actions;
- Goal and Plan modes;
- file/folder attachments and mentions;
- response text annotations with optional comments;
- slash commands;
- queued follow-ups, explicit steering, and turn interruption.

Type `/` after existing text or in an empty composer to open the command
palette. Model, reasoning, speed, Goal, Plan, MCP, Status, and Side commands
preserve any text already in the composer. Compact and Fork are offered only
for an existing idle task with no other composer text. Skill commands attach
the skill without replacing an existing prompt.

While a turn is running, each send adds another follow-up card above the composer. Choose **Steer** to inject that exact message into the active turn, edit or remove it from the card, or leave the FIFO queue alone. A steered message becomes a new user bubble inside the active turn; it never edits or replaces the turn's original prompt. App-server persists the queue and starts messages in order whenever the thread becomes idle, so queued work survives app restarts and is shared across connected clients.

Steer actions are serialized. If the active turn ends at the same moment you choose **Steer**, the app starts the message as the next turn immediately; it does not leave the message stuck waiting for another completion event.

Start with the least privilege that can complete the task. Review commands, requested permissions, and proposed file changes before approval; inspect resulting files afterward.

## Voice chat

When the composer is empty, choose the waveform button in the send-button
position to start Voice. The microphone beside it remains the separate dictation
control. From a projectless Home draft, Voice creates a dedicated top-level
projectless task with `threadSource: realtime_voice`. Ordinary text and project
tasks do not expose the waveform. Reopen an existing Voice task to start another
Voice session on that task.
The task uses app-server's thread-scoped realtime V3 session, streams microphone
audio and model audio, and shows a live transcript with an animated orb instead
of the text composer. The active controls independently mute the microphone or
speaker and end the call. Only one Voice task can be active at a time.

Voice remains active when you inspect another task; use the floating Voice
control to return or end the call. When the Voice task is not the selected
conversation, CodexCore presents a native always-on-top Voice panel above other
apps and full-screen Spaces. It is click-through by default; moving the pointer
over the panel temporarily enables its controls, while keyboard focus is only
enabled after an explicit interaction and is released automatically. Dragging
or resizing the panel persists its bounds per display and resolution, with a
normalized migration when a monitor is replaced. Escape stops the call, and
the open-thread/focus-composer actions return to the same Voice task without
creating another session. Because Voice is an ordinary Codex thread
with startup context, it can use tools and create subagents. Desktop tasks also
receive the `codex_app` orchestration tools used by the official app: they can
list projects and tasks, create a new top-level project or projectless task,
read a task, or send it a follow-up without moving the visible selection.
You can also explicitly ask Voice to end the call; it invokes the
`end_realtime_voice_call` tool and closes the same realtime session cleanly.
Realtime utterances and canonical delegated work share one arrival-ordered
transcript. Tool activity stays at the point where Voice delegated it and keeps
the normal expandable **Worked for …** disclosure.

### Native overlay verification matrix

Use a real microphone-enabled macOS session to verify the native panel. Each
case should use one Voice thread and confirm that the thread ID and transcript
remain unchanged across the transition:

| Scenario | Expected result |
| --- | --- |
| Switch to another Codex task or another app | The panel remains above the other app and full-screen Spaces; the main-thread Voice view is hidden. |
| Move the pointer over the panel | Controls become hit-testable; moving away restores click-through behavior after a short grace period. |
| Click a control, press Escape, or choose **Focus composer** | The panel temporarily accepts keyboard focus; Escape ends the existing session, while the focus action returns to the same Voice thread. |
| Drag or resize, then move to another display or change resolution | Bounds restore on the matching display/resolution; otherwise normalized coordinates are clamped to the new visible work area. |
| Hide/unhide the app, sleep/wake displays, or close the main window | The overlay follows lifecycle changes without creating a second transport; wake restores its saved frame. |
| Deny microphone permission or force a transport failure | The panel shows a retryable error with **Retry Voice** (same thread) and **Start new** (new thread); no orphaned session remains. |
| Enable Reduce Motion in Settings | Orb animation is static while controls and captions remain available. |

## Transcript

The transcript groups user input, agent work, tool calls, subagents, approvals, plans, diffs, and final answers into canonical turns. Expanded heavy details are materialized on demand.

Selecting text in a completed assistant response opens a compact **Add to chat**
action. It attaches the excerpt to the current composer; confirm the optional
comment editor—an empty comment is valid—to create the attachment. Each confirmed
annotation keeps a numbered marker in the response; you can edit or remove it
from the composer attachment, or remove the attachment as a whole. Annotation
source locations remain local presentation state. On send, Codex receives the
numbered selections and comments as hidden context while the visible user
message remains the request you typed.

![A completed task with expanded command activity and a subagent](../assets/screenshots/subagent-activity.png)

Subagents appear inside the parent turn. Select a subagent chip to inspect its focused transcript without losing the parent task.
