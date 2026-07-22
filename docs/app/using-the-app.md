# Use the reference app

The reference app is a native Codex host and living integration example. The [support matrix](../reference/support-status.md) distinguishes working flows from preview-only surfaces.

![CodexCore native macOS workspace](../assets/screenshots/hero-workspace.png)

## Main routes

- **Chat:** project threads, transcript, composer, approvals, plans, and tools.
- **Search:** find and resume existing chats.
- **Plugins:** inspect plugins, skills, and MCP-backed capabilities.
- **Settings:** appearance, history, sidebar, integrations, and application information.

## Projects and chats

The sidebar groups chats by workspace. Chats can be pinned, archived, renamed, forked, copied, searched, and resumed. Projects can be selected, grouped, pinned, reordered, aliased, removed, revealed in Finder, or used to archive their chats. Chat reorder/hide/reveal actions are not supported.

## Composer

The composer supports:

- model and reasoning selection;
- permission and approval profiles;
- Goal and Plan modes;
- file/folder attachments and mentions;
- slash commands;
- queued follow-ups, explicit steering, and turn interruption.

While a turn is running, each send adds another follow-up card above the composer. Choose **Steer** to inject that exact message into the active turn, edit or remove it from the card, or leave the FIFO queue alone. A steered message becomes a new user bubble inside the active turn; it never edits or replaces the turn's original prompt. CodexCore starts exactly one queued message when the current turn completes; any remaining messages wait for each new turn to complete in order.

Steer actions are serialized. If the active turn ends at the same moment you choose **Steer**, the app starts the message as the next turn immediately; it does not leave the message stuck waiting for another completion event.

Start with the least privilege that can complete the task. Review commands, requested permissions, and proposed file changes before approval; inspect resulting files afterward.

## Transcript

The transcript groups user input, agent work, tool calls, subagents, approvals, plans, diffs, and final answers into canonical turns. Expanded heavy details are materialized on demand.

![A completed task with expanded command activity and a subagent](../assets/screenshots/subagent-activity.png)

Subagents appear inside the parent turn. Select a subagent chip to inspect its focused transcript without losing the parent task.
