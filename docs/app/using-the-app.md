# Use the reference app

The reference app is a native Codex host and living integration example. The [support matrix](../reference/support-status.md) distinguishes working flows from preview-only surfaces.

## Main routes

- **Chat:** project threads, transcript, composer, approvals, plans, and tools.
- **Search:** find and resume existing chats.
- **Plugins:** inspect plugins, skills, and MCP-backed capabilities.
- **Automations:** prepare supported automation prompts through chat; there is no scheduler or run history.
- **Codex mobile:** display remote-control status; pairing actions are not wired.
- **Settings:** appearance, history, sidebar, stored Git preferences, and application information.

## Projects and chats

The sidebar groups chats by workspace. Chats can be pinned, archived, renamed, forked, copied, searched, and resumed. Projects can be selected, grouped, pinned, reordered, aliased, removed, revealed in Finder, or used to archive their chats. Chat reorder/hide/reveal actions are not supported.

## Composer

The composer supports:

- model and reasoning selection;
- permission and approval profiles;
- Goal and Plan modes;
- file/folder attachments and mentions;
- slash commands;
- turn interruption and steering.

Start with the least privilege that can complete the task. Review commands, requested permissions, and proposed file changes before approval; inspect resulting files afterward.

## Transcript

The transcript groups user input, agent work, tool calls, subagents, approvals, plans, diffs, and final answers into canonical turns. Expanded heavy details are materialized on demand.
