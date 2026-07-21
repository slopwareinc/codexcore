# Screenshot inventory

Public screenshots must be captured from the current CodexCore source, not from official Codex reference images or historical QA output.

| Asset | Scenario | Source commit | Theme | Exported pixels |
| --- | --- | --- | --- | --- |
| `hero-workspace.png` | Completed read-only project inspection with a concise rendered answer | PR #142 capture build | dark | 1193×768 |
| `first-run-auth.png` | ChatGPT and API-key sign-in choices | pending capture | dark | 1200×800 |
| `search-resume.png` | Search results with a resumable chat | pending capture | dark | 1200×800 |
| `composer-controls.png` | Model, reasoning, permission, and composer controls | `ae80282` | dark | 1193×768 |
| `approval-prompt.png` | A command or file approval before execution | pending capture | dark | 1200×800 |
| `files-preview.png` | File tree with rendered README preview | PR #142 capture build | dark | 1193×768 |
| `workspace-terminal.png` | Real interactive workspace terminal with Swift version output | PR #142 capture build | dark | 1193×768 |
| `browser-panel.png` | Manual embedded browser showing Swift documentation | PR #142 capture build | dark | 1193×768 |
| `capability-inventory.png` | Read-only plugin, skill, and MCP inventory | pending capture | dark | 1200×800 |
| `subagent-activity.png` | Expanded command rows and completed subagent activity | PR #142 capture build | dark | 1193×768 |
| `appearance-settings.png` | Implemented theme, typography, and motion settings | `ae80282` | dark | 951×768 |

Pending rows are capture candidates, not promised screenshots. Published captures must be reviewed deliberately for visible account, path, and project context. Never expose secrets, tokens, private source, or unrelated applications, and never imply support for Git review/commit/push/PR, automation scheduling, mobile pairing, plugin mutation, or worktree handoff.

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
