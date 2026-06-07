# Codex Mac App UI Teardown

Black-box inspection of `/Applications/Codex.app` via Chrome DevTools Protocol on `app://-/index.html`. No packaged app code was unpacked or reverse engineered.

## Evidence

Screenshots captured during inspection:

- Initial signed-in home: `/var/folders/35/3j8rkfv52tx03c4rhn9b57d40000gn/T/opencode/codex-initial.png`
- Chat after first turn: `/var/folders/35/3j8rkfv52tx03c4rhn9b57d40000gn/T/opencode/codex-chat-created.png`
- Approval/access menu: `/var/folders/35/3j8rkfv52tx03c4rhn9b57d40000gn/T/opencode/codex-access-menu.png`
- Model/reasoning menu: `/var/folders/35/3j8rkfv52tx03c4rhn9b57d40000gn/T/opencode/codex-model-menu.png`
- Slash command/skills menu: `/var/folders/35/3j8rkfv52tx03c4rhn9b57d40000gn/T/opencode/codex-slash-menu.png`
- Chat actions menu: `/var/folders/35/3j8rkfv52tx03c4rhn9b57d40000gn/T/opencode/codex-chat-actions-menu.png`
- Side chat artifact state: `/var/folders/35/3j8rkfv52tx03c4rhn9b57d40000gn/T/opencode/codex-side-chat-after-submit-attempt.png`
- Bottom terminal panel: `/var/folders/35/3j8rkfv52tx03c4rhn9b57d40000gn/T/opencode/codex-bottom-terminal.png`
- Subagent prompt running: `/var/folders/35/3j8rkfv52tx03c4rhn9b57d40000gn/T/opencode/codex-subagent-prompt-running.png`
- Active subagent summary rows: `/var/folders/35/3j8rkfv52tx03c4rhn9b57d40000gn/T/opencode/codex-subagent-final.png`
- Completed subagents after closure: `/var/folders/35/3j8rkfv52tx03c4rhn9b57d40000gn/T/opencode/codex-subagent-completed-closed.png`
- Side chat reopened after subagents: `/var/folders/35/3j8rkfv52tx03c4rhn9b57d40000gn/T/opencode/codex-side-chat-row-after-subagents.png`

## Core Design Tokens

- Font stack: `Geist, Inter, -apple-system, system-ui, Segoe UI, sans-serif`
- Body font: `16px / 24px / 430`
- Chat text: `14px / 20px / 430`
- Sidebar/nav text: `13px / 18.6px / 430`
- Primary text: `#fcfcfc`
- Secondary text: `color-mix(in srgb, #fcfcfc 65%, transparent)`
- Tertiary/description text: `rgba(252, 252, 252, 0.47)`
- Page background: `#0f0f0f`
- Main surface: `#111111`
- Composer/dropdown surface: `rgb(36, 36, 36)` / `rgba(36, 36, 36, 0.96)`
- Border: `rgba(252, 252, 252, 0.075)`
- Light border: `rgba(252, 252, 252, 0.038)`
- Toolbar height: `46px`
- Bottom pane toolbar height: `40px`
- Standard nav row height: `31px`
- Menu row height: `29px`
- Composer shell radius: `25px`
- Floating summary panel radius: `25px`
- Menu radius: `15px`
- Row/chip radius: `12.5px` or full pill for composer chips

## Information Architecture

### Home/Blank Chat

- Left sidebar is visible by default on the home screen, about `303px` wide.
- Top sidebar rows: `New chat`, `Search`, `Plugins`, `Automations`.
- Project section groups chats by workspace/project.
- Main blank state is centered and asks: `What should we work on in <project>?`
- Blank-state prompt cards sit under the composer:
  - `Connect messaging` - get context from team discussions
  - `Connect email` - summarize stakeholder asks
  - `Connect files` - review results, research, and plans
- Composer control row exposes add/context, approval mode, model/reasoning, dictation, and send.

### Chat View

- Header stays as a thin fixed toolbar with navigation, title, chat actions, and panel toggles.
- Main content is a centered transcript column.
- User messages are right-aligned rounded rectangles with max width around `77%` of the content area.
- Assistant messages are left-aligned Markdown blocks with action buttons below.
- Assistant action buttons observed: copy, good response, bad response, fork from this point.
- Bottom composer is sticky, centered, and remains visible after a turn.
- A floating scroll-to-bottom button appears as a 32px circular control when not pinned to bottom.

### Floating Summary Panel

- Right floating panel is a rounded dropdown-like surface, normally around `300px` wide.
- Sections observed:
  - `Outputs` with `No artifacts yet`
  - `Side chats` with count/state
  - `Subagents` while delegated agents are active, with one row per generated agent name
  - `Sources` with `No sources yet`
- Section headers are disclosure-style rows with tertiary text.
- Panel is independent of the transcript and floats from the top right with padding.

### Bottom Terminal Panel

- Toggle opens a resizable terminal pane at the bottom.
- Observed height: about `280px`.
- A horizontal drag separator sits at the top of the pane.
- Pane has its own tab bar, with the project name as the tab label.
- Terminal implementation appears xterm-like in DOM and visually uses the same `#111111` surface.

### Side Chat / Subagent UX

- `/Side` creates a side-chat artifact/entry rather than immediately replacing the main transcript.
- The floating summary panel adds a `Side chats` section with a count and/or `Side chat` row.
- Asking the app to use side chats/subagents produced inline assistant lifecycle blocks in the main transcript: `Spawning`, `Spawning 1 agent`, `Input: ...`, and then `Spawned 2 agents`.
- Generated agent names were visible: `Chandrasekhar` for chat/composer inspection and `Copernicus` for side panel/terminal inspection.
- While the subagents were active, the floating summary panel inserted a transient `Subagents` section below `Side chats`, with `Chandrasekhar` and `Copernicus` rows.
- After completion, the assistant summarized both subagent results inline in the parent transcript and stated both side agents were closed.
- Once closed, the transient `Subagents` section disappeared from the floating summary panel; the persistent `Side chats` section remained.
- A split-view state was observed in DOM during side-chat creation:
  - Main thread compressed left.
  - Vertical separator at the split boundary.
  - Right side panel had its own toolbar, tab bar, tabpanel, transcript space, and composer.
- Opening the persistent `Side chat` row after subagent completion reopened the right split panel, not a named completed-subagent detail view.
- The right split panel was about `320px` wide, with a vertical resizer/separator, its own `46px` toolbar, tablist, tabpanel, scroll-to-bottom control, and sticky composer.
- Side chat should be modeled as an ephemeral fork/subthread attached to the parent transcript, not as a normal assistant message.
- Subagent runs should be modeled separately from durable side chats: active runs appear as summary-panel rows, while completed findings are folded back into the parent transcript unless the app exposes a durable child session.

## Menus And Controls

### Approval Mode Menu

Opened from `Full access` composer chip.

- Placement: bottom-anchored above composer.
- Size observed: about `479x223`.
- Header: `How should Codex actions be approved?` with `Learn more` link.
- Options:
  - `Ask for approval` - always ask to edit external files and use the internet
  - `Approve for me` - only ask for potentially unsafe actions
  - `Full access` - unrestricted internet and files
  - `Custom (config.toml)` - uses permissions defined in config

### Model / Reasoning Menu

Opened from `5.5 Medium` composer chip.

- Size observed: about `208x214`.
- Section `Reasoning`: Low, Medium, High, Extra High.
- Model choices: GPT-5.5, Speed.
- Selected row has subtle fill `rgba(252, 252, 252, 0.07)`.

### Slash Command Menu

Opened by typing `/` in the composer.

- Placement: above composer.
- Size observed: about `736x320`.
- Visual: rounded `20px` panel, dropdown background, 1px border, vertical scroll fade.
- Rows are `29px`, with icon/title/description and selected row highlight.
- Commands observed:
  - Code review
  - Compact
  - Fast
  - Feedback
  - Fork
  - Goal
  - MCP
  - Model
  - Personality
  - Pet
  - Plan mode
  - Reasoning
  - Side
  - Status
- After commands, a `Skills` section lists installed skills with title, long description, and scope badge such as `Personal`.

### Chat Actions Menu

Opened from the toolbar ellipsis.

- Size observed: about `220x255`.
- Options:
  - Pin chat
  - Rename chat
  - Archive chat
  - Open side chat
  - Copy
  - Fork
  - Add automation...
  - Open in new window
- Includes keyboard shortcuts in trailing text for some rows.

## SwiftUI Reusable Component Map

Recommended components for native reuse:

- `CodexAppShell`: root dark surface, toolbar, optional sidebar, transcript, floating panels, bottom terminal, split panes.
- `CodexToolbar`: traffic-light-safe top toolbar with back/forward, chat title, chat actions, pinned summary toggle, bottom/side panel toggles.
- `CodexSidebar`: `303px` project/chat navigator with fixed top commands, collapsible project groups, hover-only action buttons.
- `CodexProjectRow`: project folder row with disclosure icon, actions, and new-chat button.
- `CodexChatHistoryRow`: recent chat row with title, relative time, pin/archive hover actions.
- `CodexTranscript`: centered scrollable chat column with bottom anchoring.
- `CodexUserBubble`: right-aligned rounded user message, `20px` radius, muted foreground fill.
- `CodexAssistantMessage`: Markdown content plus hover/action footer.
- `CodexMessageActionBar`: copy, thumbs up, thumbs down, fork.
- `CodexComposer`: sticky 736px max-width composer with ProseMirror-equivalent native editor, 25px rounded shell, footer chips.
- `CodexComposerChip`: full-pill chip for approval/model/project controls.
- `CodexApprovalMenu`: approval mode picker with explanatory subtitles.
- `CodexModelMenu`: model and reasoning picker.
- `CodexSlashCommandPalette`: command/skill picker with selectable rows, scroll fade, section headers.
- `CodexFloatingSummaryPanel`: right floating card with Outputs, Side Chats, Sources sections.
- `CodexSideChatArtifactRow`: summary-panel row representing a side chat/subagent fork.
- `CodexSubagentSection`: transient summary-panel section for active delegated agents.
- `CodexSubagentLifecycleBlock`: inline transcript block for spawn/run/complete events.
- `CodexSplitSideChat`: optional right split with vertical resizer, tab bar, tabpanel, and independent composer.
- `CodexBottomTerminalPanel`: bottom xterm-like pane with tab bar and horizontal resizer.
- `CodexResizableSeparator`: shared vertical/horizontal separator with invisible 16px hit area and 1px visual line.

## Implementation Notes For SwiftUI

- Use a single `CodexTheme` token source matching the observed values above.
- Prefer `Material.ultraThin`/blur only for menus and composer; the official app uses translucent dark surfaces but not heavy glass.
- Keep menus data-driven: title, optional subtitle, trailing shortcut, icon, selected state.
- Keep side chats as child sessions/artifacts of the parent chat; the UI should show them in the summary panel and optionally open them in a split pane.
- Preserve hover-only controls for desktop polish, but keep all controls accessible by VoiceOver labels.
- The composer should support slash-command discovery, not just plain text entry.
- The bottom terminal should be an optional docked pane, not part of the transcript.
