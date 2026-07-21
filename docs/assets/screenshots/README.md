# Screenshot inventory

Public screenshots must be captured from the current CodexCore source, not from official Codex reference images or historical QA output.

| Asset | Scenario | Source commit | Theme | Window |
| --- | --- | --- | --- | --- |
| `hero-workspace.png` | Populated workspace with a completed coding turn | pending capture | dark | 1440×900 |
| `first-run-auth.png` | ChatGPT and API-key sign-in choices | pending capture | dark | 1200×800 |
| `search-resume.png` | Search results with a resumable chat | pending capture | dark | 1200×800 |
| `composer-controls.png` | Model, reasoning, permissions, Plan/Goal, attachment controls | pending capture | dark | 1200×800 |
| `approval-prompt.png` | A command or file approval before execution | pending capture | dark | 1200×800 |
| `files-preview.png` | File tree and syntax-highlighted preview | pending capture | dark | 1200×800 |
| `workspace-terminal.png` | Real interactive workspace terminal side panel | pending capture | dark | 1200×800 |
| `capability-inventory.png` | Read-only plugin, skill, and MCP inventory | pending capture | dark | 1200×800 |
| `sidechat-subagents.png` | Side chat and subagent activity | pending capture | dark | 1200×800 |
| `appearance-settings.png` | Implemented appearance settings | pending capture | dark | 1200×800 |

Window values are layout dimensions in points; record exported pixel dimensions after capture. Do not publish screenshots that imply support for Git review/commit/push/PR, automation scheduling, mobile pairing, plugin mutation, or worktree handoff.

## Capture checklist

- build the exact source commit;
- use a disposable repository and isolated Codex home;
- use neutral project, branch, and account names;
- hide secrets, usernames, home-directory paths, rate limits, and unrelated apps;
- show successful populated states rather than placeholders;
- capture at a consistent window size and Retina scale;
- crop consistently and optimize without making text unreadable;
- add useful alt text where the image is embedded.

Never publish images from `.ai/oracle/`; those are external design references. Historical `.ai/visual-qa/` captures may guide composition but must be recaptured before publication.
