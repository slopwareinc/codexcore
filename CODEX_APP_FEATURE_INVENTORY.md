# Codex Mac App — Feature Inventory

## 1. Method & caveats

Black-box inventory via CDP (`playwright-core` → `chromium.connectOverCDP('http://127.0.0.1:9222')`) against the single page `app://-/index.html`. One live session used **Full access** approval mode, so no approval prompt appeared. Bottom terminal content is canvas/xterm and did not surface as plain text in DOM dumps.

## 2. App shell & navigation

| Feature | Location | Exact labels | Behavior notes |
|---------|----------|--------------|----------------|
| New chat | Sidebar top | `New chat` / `New chat⌘N` | Creates blank chat |
| Search | Sidebar top | `Search` / `Search⌘G` | Opens search UI (⌘G) |
| Plugins | Sidebar top | `Plugins` | Full-page plugins browser |
| Automations | Sidebar top | `Automations` | Automations list/templates |
| Projects header | Sidebar | `Projects` | Section label |
| Collapse all | Projects header | `Collapse all` | Collapses all project groups |
| Project sidebar options | Projects header | `Project sidebar options` | Menu: Archive all chats, Organize sidebar, Sort by |
| Add new project | Projects header | `Add new project` | Adds project folder |
| Project row | Sidebar | Project name (e.g. `CodexCore`) | Click selects/expands |
| Project actions | Project row hover | `Project actions for <name>` | See menus section |
| Start new chat in project | Project row hover | `Start new chat in <name>` | New chat scoped to project |
| Collapse/Expand project | Project row | `Collapse project` / `Expand project` | Toggles chat list |
| Chat history row | Under project | Title + relative time (e.g. `9h`, `1w`) | Click opens chat |
| Pin chat | Chat row hover | `Pin chat` | Pins chat in sidebar |
| Archive chat | Chat row hover | `Archive chat` | Archives chat |
| Show more | Project chat list | `Show more` | Expands truncated history |
| Chats section | Sidebar lower | `Chats` | Non-project chats |
| Filter sidebar chats | Chats header | `Filter sidebar chats` | Filter UI |
| Chats New chat | Chats header | `New chat` | New non-project chat |
| Settings | Sidebar footer | `Settings` | Opens account menu |
| Open Codex mobile | Sidebar footer | `Open Codex mobile` | Mobile pairing |
| Hide sidebar | Header | `Hide sidebar` | Toggles sidebar (⌘B) |
| Back / Forward | Header | `Back` / `Forward` | Navigation history |
| Chat actions | Header | `Chat actions` | Chat ellipsis menu |
| Open in | Header | `Open in` | External editor/terminal picker |
| Secondary action | Header | `Secondary action` | Additional header action |
| Toggle pinned summary | Header | `Toggle pinned summary` | Summary panel pin |
| Toggle bottom panel | Header | `Toggle bottom panel` | Bottom terminal (⌘J) |
| Toggle side panel | Header | `Toggle side panel` | Right summary panel (⌥⌘B) |
| Sidebar resize | Sidebar edge | (drag handle) | Resizable sidebar width |

## 3. Composer & input

| Feature | Location | Exact labels | Behavior notes |
|---------|----------|--------------|----------------|
| Composer editor | Bottom center | (contenteditable) | ProseMirror-style; supports multiline |
| Placeholder (blank) | Main area | `What should we build in CodexCore?` | Project-specific blank state |
| Add files | Composer left | `Add files and more` | Attachment/create menu |
| Approval chip | Composer footer | `Full access` | Opens approval policy menu |
| Model chip | Composer footer | `5.5` + `Medium` (shown as `5.5Medium` in aria) | Model + reasoning picker |
| Dictate | Composer footer | `Dictate` | Voice input |
| Send | Composer footer | `Send message` / `Send` | Submits prompt |
| Stop | Composer footer | `Stop` | Appears during agent run; Esc shortcut per prior teardown |
| Work locally | Composer context | `Work locally` | Local vs cloud mode |
| Project chip | Composer context | `CodexCore` | Current project |
| Branch chip | Composer context | `main` | Current git branch |
| Environment chip | Composer/summary | `Environment` | Environment selector |
| Connect messaging | Blank state cards | `Connect messaging` / `Get context from recent team discussions` | Onboarding plugin suggestion |
| Connect email | Blank state cards | `Connect email` / `Summarize stakeholder asks from email` | Onboarding suggestion |
| Connect files | Blank state cards | `Connect files` / `Review results, research, and plans` | Onboarding suggestion |
| @-mention | Typing `@` | Plugin rows + `Files` | See @-mention list below |
| Slash commands | Typing `/` | Command palette above composer | Scrollable list + Skills section |

**@-mention entries observed:** `Plugins` section with `Documents` (`Create and edit document artifacts`), `Spreadsheets`, `Presentations`, `Browser`, `Computer`, `Linear`, `Gmail`, `Slack`; `Files` (`Type to search for files`).

## 4. Slash commands

| Command | Description | Notes |
|---------|-------------|-------|
| /Chat | Don't work in a project |  |
| /Cloud | Run this chat in the cloud |  |
| /Code review | Review unstaged changes or compare against a branch |  |
| /Fast | 1.5x speed, increased usage |  |
| /Feedback | Send feedback about this chat |  |
| /Goal | Set a goal that Codex will keep working towards |  |
| /Init | Create an AGENTS.md file with instructions for Codex |  |
| /MCP | Show MCP server status |  |
| /Memories | Use off, generate off | Current state shown in menu |
| /Model | GPT-5.5 | Shows current model |
| /New worktree | Run this chat in a new worktree |  |
| /Personality | Choose how Codex responds |  |
| /Pet | Wake or tuck away the desktop pet |  |
| /Plan mode | Turn plan mode on |  |
| /Project | Choose project for new chats |  |
| /Reasoning | Medium | Shows current reasoning level |
| /Status | Show chat id, context usage, and rate limits |  |

**Note:** `/side` was not present in the scrolled slash palette capture but executed successfully in the live session (creates a `Side chat` artifact). `Fork` appears in **Chat actions**, not in the slash list captured here.

### Skills section (65 installed)

| Skill | Description | Scope |
|-------|-------------|-------|
| 1-Shot SVG | Generate and locally vectorize web assets | Personal |
| Agents Sdk | Build AI agents on Cloudflare Workers using the Agents SDK. Load when creating stateful agents, durable workflows, real-time WebSocket apps, scheduled tasks, MCP servers, chat applications, voice agen… | Personal |
| AppKit Interop | Bridge SwiftUI into AppKit for native macOS behavior | Personal |
| Browser | Browser lets Codex open and control the in-app browser, mainly for local development pages and files. Use it to navigate, inspect, click, type, and take screenshots while testing pages inside Codex. | Personal |
| Build / Run / Debug | Build and debug macOS apps with shell-first workflows | Personal |
| Caveman | Ultra-compressed communication mode. Cuts token usage ~75% by dropping filler, articles, and pleasantries while keeping full technical accuracy. Use when user says "caveman mode", "talk like caveman",… | Personal |
| Channel Summarization | Summarize one Slack channel | Personal |
| Cloudflare | Comprehensive Cloudflare platform skill covering Workers, Pages, storage (KV, D1, R2), AI (Workers AI, Vectorize, Agents SDK), feature flags (Flagship), networking (Tunnel, Spectrum), security (WAF, D… | Personal |
| Cloudflare Email Service | Send and receive transactional emails with Cloudflare Email Service (Email Sending + Email Routing). Use when building email sending (Workers binding or REST API), email routing, Agents SDK email hand… | Personal |
| Daily Digest | Summarize today's Slack activity | Personal |
| Diagnose | Disciplined diagnosis loop for hard bugs and performance regressions. Reproduce → minimise → hypothesise → instrument → fix → regression-test. Use when user says "diagnose this" / "debug this", report… | Personal |
| Documents | Create and edit Word and Google Docs files | Personal |
| Durable Objects | Create and review Cloudflare Durable Objects. Use when building stateful coordination (chat rooms, multiplayer games, booking systems), implementing RPC methods, SQLite storage, alarms, WebSockets, or… | Personal |
| Gmail | Summarize threads and draft replies | Personal |
| Grill Me | Interview the user relentlessly about a plan or design until reaching shared understanding, resolving each branch of the decision tree. Use when user wants to stress-test a plan, get grilled on their … | Personal |
| Grill with Docs | Grilling session that challenges your plan against the existing domain model, sharpens terminology, and updates documentation (CONTEXT.md, ADRs) inline as decisions crystallise. Use when user wants to… | Personal |
| Hatch Pet | Hatch Codex-compatible animated pet spritesheets | Personal |
| Image Gen | Generate or edit images for websites, games, and more | System |
| Improve Codebase Architecture | Find deepening opportunities in a codebase, informed by the domain language in CONTEXT.md and the decisions in docs/adr/. Use when the user wants to improve architecture, find refactoring opportunitie… | Personal |
| Inbox Triage | Triage an inbox into action buckets | Personal |
| Linear | Manage Linear issues in Codex | Personal |
| Liquid Glass | Adopt modern macOS SwiftUI design and Liquid Glass | Personal |
| OpenAI Docs | Reference OpenAI docs, Codex self-knowledge, and model migration guidance | System |
| Packaging & Notarization | Inspect packaging, signing, and notarization readiness | Personal |
| Plugin Creator | Scaffold plugins and marketplace entries | System |
| Polymarket Alpha Lab | Run research-only Polymarket alpha discovery swarms with specialist agents, hypothesis scoring, public-data evidence, wallet/source/microstructure analysis, and hillclimb-style next-generation prompts… | Personal |
| Presentations | Create polished PowerPoint and Google Slides decks | Personal |
| Prototype | Build a throwaway prototype to flush out a design before committing to it. Routes between two branches — a runnable terminal app for state/business-logic questions, or several radically different UI v… | Personal |
| Reply Drafting | Draft Slack replies from context | Personal |
| Resume From Claude | Resume a Claude session from Codex, Amp, OpenCode, and more. Use when the user says `/resume-from-claude`, `/kmf-claude`, asks to resume a Claude conversation here, or wants another agent to recover C… | Personal |
| Resume From Codex | Resume a Codex session from Claude, Amp, OpenCode, and more. Use when the user says `/resume-from-codex`, `/kmf-codex`, asks to resume a Codex conversation here, or wants another agent to recover Code… | Personal |
| Resume From Opencode | Resume an OpenCode session from Codex, Claude, Amp, and more. Use when the user says `/resume-from-opencode`, `/kmf-opencode`, asks to resume an OpenCode conversation here, or wants another agent to r… | Personal |
| Sandbox Sdk | Build sandboxed applications for secure code execution. Load when building AI code execution, code interpreters, CI/CD systems, interactive dev environments, or executing untrusted code. Covers Sandbo… | Personal |
| Setup Matt Pocock Skills | Sets up an `## Agent skills` block in AGENTS.md/CLAUDE.md and `docs/agents/` so the engineering skills know this repo's issue tracker (GitHub or local markdown), triage label vocabulary, and domain do… | Personal |
| Signing & Entitlements | Inspect codesign, entitlements, and Gatekeeper failures | Personal |
| Skill Creator | Create or update a skill | System |
| Skill Installer | Install curated skills from openai/skills or other repos | System |
| Slack | Summarize threads and draft posts | Personal |
| Slack Notification Triage | Triage Slack attention signals | Personal |
| Slack Outgoing Message | Compose final outbound Slack text | Personal |
| Spreadsheets | Create and edit spreadsheet or Google Sheets-ready files | Personal |
| SwiftPM macOS | Build, run, and test macOS Swift packages | Personal |
| SwiftUI Liquid Glass | Build SwiftUI Liquid Glass features | Personal |
| SwiftUI Patterns | Build native macOS SwiftUI scenes, menus, settings, and windows | Personal |
| SwiftUI Performance Audit | Audit SwiftUI runtime performance | Personal |
| SwiftUI UI Patterns | Apply practical SwiftUI UI patterns | Personal |
| SwiftUI View Refactor | Refactor large SwiftUI view files | Personal |
| Tdd | Test-driven development with red-green-refactor loop. Use when user wants to build features or fix bugs using TDD, mentions "red-green-refactor", wants integration tests, or asks for test-first develo… | Personal |
| Telemetry | Add lightweight Logger instrumentation and verify macOS runtime events | Personal |
| Test Triage | Run and explain macOS test failures with focused reruns | Personal |
| To Issues | Break a plan, spec, or PRD into independently-grabbable issues on the project issue tracker using tracer-bullet vertical slices. Use when user wants to convert a plan into issues, create implementatio… | Personal |
| To Prd | Turn the current conversation context into a PRD and publish it to the project issue tracker. Use when user wants to create a PRD from the current context. | Personal |
| Triage | Triage issues through a state machine driven by triage roles. Use when user wants to create an issue, triage issues, review incoming bugs or feature requests, prepare issues for an AFK agent, or manag… | Personal |
| View Refactor | Refactor macOS SwiftUI views and scenes toward stable desktop structure | Personal |
| Web Perf | Analyzes web performance using Chrome DevTools MCP. Measures Core Web Vitals (LCP, INP, CLS) and supplementary metrics (FCP, TBT, Speed Index), identifies render-blocking resources, network dependency… | Personal |
| Window Management | Customize SwiftUI window chrome, drag regions, behavior, and placement | Personal |
| Workers Best Practices | Reviews and authors Cloudflare Workers code against production best practices. Load when writing new Workers, reviewing Worker code, configuring wrangler.jsonc, or checking for common Workers anti-pat… | Personal |
| Wrangler | Cloudflare Workers CLI for deploying, developing, and managing Workers, KV, R2, D1, Vectorize, Hyperdrive, Workers AI, Containers, Queues, Workflows, Pipelines, and Secrets Store. Load before running … | Personal |
| Write A Skill | Create new agent skills with proper structure, progressive disclosure, and bundled resources. Use when user wants to create, write, or build a new skill. | Personal |
| Zoom Out | Tell the agent to zoom out and give broader context or a higher-level perspective. Use when you're unfamiliar with a section of code or need to understand how it fits into the bigger picture. | Personal |
| iOS App Intents | Build and debug iOS App Intents integrations | Personal |
| iOS Debugger Agent | Debug iOS apps on Simulator | Personal |
| iOS ETTrace Performance | Profile symbolicated iOS simulator flows with ETTrace | Personal |
| iOS Memgraph Leaks | Capture and prove iOS simulator memory leaks | Personal |
| iOS Simulator Browser | Mirror iOS Simulator | Personal |


## 5. Menus (verbatim)

### Approval mode menu (from `Full access` chip)

Header: `How should Codex actions be approved?` with `Learn more`

- `Learn more`
- `Ask for approval` — Always ask to edit external files and use the internet
- `Approve for me` — Only ask for actions detected as potentially unsafe
- `Full access` — Unrestricted access to the internet and any file on your computer
- `Custom (config.toml)` — Uses permissions defined in config.toml

### Model / reasoning menu (from `5.5` / `Medium` chip)

Reasoning: `Low`, `Medium`, `High`, `Extra High`

Models: `GPT-5.5`, `Speed`

### Add files and more menu

- `Add photos & files`
- `Attach Google Chrome`
- `Create`
- `Plan mode`
- `Pursue goal`
- `Plugins`

### Chat actions menu (`Chat actions`)

- `Pin chat` ⌥⌘P
- `Rename chat` ⌥⌘R
- `Archive chat` ⇧⌘A
- `Open side chat` ⌥⌘S
- `Copy`
- `Fork`
- `Add automation…`
- `Open in new window`

### Open in menu (`Open in`)

- `VS Code`, `Cursor`, `Zed`, `Finder`, `Terminal`, `Ghostty`, `Warp`, `Xcode`

### Project actions menu (per project)

- `Pin project`
- `Reveal in Finder`
- `Create permanent worktree`
- `Rename project`
- `Archive chats`
- `Remove`

### Project sidebar options

- `Archive all chats`
- `Organize sidebar`
- `Sort by`

### Account menu (sidebar `Settings` click)

- `betterclever10@gmail.com` / `Personal account`
- `Profile`
- `Settings` ⌘,
- `Usage remaining`
- `Log out`

## 6. Settings

Navigation groups: **Personal** (General, Profile, Appearance, Configuration, Personalization, Keyboard shortcuts, Usage & billing), **Integrations** (Appshots, MCP servers, Browser, Computer use, Coding, Hooks, Connections), **Git** (Environments, Worktrees, Archived, Archived chats).

### General

- `Work mode`: `For coding` / `For everyday work`
- `Permissions`: `Default permissions`, `Auto-review`, `Full access` (descriptive warnings)
- `Default open destination` (e.g. `Zed`)
- `Language` (`Auto Detect`)
- `Show in menu bar`
- `Bottom panel` — show header control
- `Default terminal location`: `Bottom` / `Right`
- `Prevent sleep while running`
- `Speed`: `Standard`
- `Code review` start mode: `Inline` / `Detached`
- `Import work from other AI apps` + `Import`
- `Open source licenses` + `View`
- `Show context window usage`
- `Follow-up behavior`: `Queue` / `Steer` (⌘⏎ toggles per message)
- `Require ⌘ + enter to send long prompts`
- `Popout Window hotkey`: `Off` / `Set`
- `Default to projectless chat`
- Dictation: `Hold-to-dictate hotkey`, `Toggle dictation hotkey`, `Keep dictation bar visible`, `Dictation dictionary`
- Notifications: `Turn completion notifications` (`Only when unfocused`), `Enable permission notifications`, `Enable question notifications`

### Profile

- `Private`, `Edit`, `Token activity` (Daily/Weekly/Cumulative), `Activity insights`, `Most used plugins`

### Appearance

- `Theme`: Light / Dark / System
- `Dark theme` editor (Import, Copy theme)
- `Accent`, `Background`, `Foreground`, `UI font`, `Code font`
- `Translucent sidebar`, `Contrast`

### Configuration

- `Custom config.toml settings` / `Open config.toml`
- `Approval policy`: `Never` (and other options)
- `Sandbox settings`: `Full access`
- `Workspace Dependencies` (version, `Codex dependencies`, `Diagnose`, `Reinstall`)

### Personalization

- `Personality`: `Friendly` (+ custom)
- `Custom instructions` + `Save`
- `Memory (experimental)`: `Enable memories`, `Generate new memories…`, `Chronicle research preview`, `Skip tool-assisted chats`, `Reset memories`

### Keyboard shortcuts

Full searchable table of actions with keybindings. Sample entries:

| Action | Shortcut |
|--------|----------|
| Archive chat | ⇧⌘A |
| New chat | ⌘N |
| Open side chat | ⌥⌘S |
| New quick chat | ⌥⌘N |
| Toggle pin | ⌥⌘P |
| Find (in chat) | ⌘F |
| Toggle bottom panel | ⌘J |
| Toggle sidebar | ⌘B |
| Toggle side panel | ⌥⌘B |
| Open terminal | ⌃` |
| Search (sidebar) | ⌘G |
| Rename chat | ⌥⌘R |

(See `settings-Keyboard_shortcuts.txt` capture for full list.)

### Usage & billing

- `Loading usage settings…` (observed during capture)

### MCP servers

- `Connect external tools and data sources. Learn more.`
- `Servers` + `Add server`
- Observed servers: `deepwiki`, `node_repl`, `playwright`

### Browser

- `Let Codex control the built-in browser`
- `Browsing data` / `Clear all browsing data`

### Computer use

- `Any App` — `Let Codex control apps on your computer` / `Install`
- `Google Chrome` — browser extension connection

### Hooks

- `Manage lifecycle hooks from config and enabled plugins`
- `No hooks found` (empty state)

### Connections

- `Control this Mac`, `Control other devices`, `SSH`
- `Allow this device to be discovered and controlled`

### Git

- `Branch prefix`
- `Pull request merge method`: Merge / Squash
- `Show PR icons in sidebar`

### Environments

- `Local environments tell Codex how to set up worktrees for a project`
- `Select a project`, `Add project`, per-project rows

### Worktrees

- `No worktrees yet` empty state

### Archived chats

- `Delete all`, `Filter archived chats`, `Group archived chats`
- Per-chat: `Unarchive`, `Delete archived chat`

## 7. Panels

### Right floating summary panel (Toggle side panel)

Sections observed during live session:

- `Environment`
- `Changes` (with `Local`, branch `main`, `Commit or push`, `Pull request status unavailable`)
- `Side chats` — row `Side chat` after `/side`
- `Sources` — `No sources yet`

Prior teardown also documents `Outputs` / `No artifacts yet` and transient `Subagents` rows during delegated runs (not observed in this minimal live session).

### Side chat split view

After `/side`: right pane opens with title `Side chat`, own composer (`Full access`, `5.5`, `Medium`), independent from main transcript.

### Bottom terminal panel (Toggle bottom panel)

Toggle present in header (⌘J). DOM text capture did not expose terminal output; prior inspection shows project-named tab, horizontal resizer, xterm-like surface (~280px tall).

## 8. Approvals & live-session observations

**Session:** New chat in `CodexCore`, prompt: `Create a file hello.txt containing exactly 'hi'. Do nothing else, keep it minimal.`

| Phase | Exact UI |
|-------|----------|
| Submit | User bubble with full prompt; composer shows `Stop` |
| Running | `Thinking` (duplicate label observed) |
| Complete | `Worked for 1s` then `Done.` |
| File change | Card `Edited hello.txt` with `+1` `-0`, buttons `Undo`, `Review` |
| Approval | **None** — `Full access` mode auto-approved file write |
| Summary panel | `Changes`, `Sources`, git actions as above |
| /side | `Side chats` section gains `Side chat` row; split side chat opens |

**Chat archived** via `Chat actions` → `Archive chat` after session.

## 9. Search / Automations / Plugins

### Search (⌘G)

Opens from sidebar; overlaps with composer context when active. Dedicated search dialog text was not isolated cleanly in CDP capture — sidebar label `Search⌘G`.

### Automations screen

- Header: `Automations`
- Subcopy: `Run chats on a schedule or whenever you need them. Learn more`
- Actions: `View templates`, `Create via chat`
- Empty state: `Create your first automation`
- Template chips: `Daily brief`, `Weekly review`, `Project monitor`

### Plugins screen

- Tabs/sections: `Skills`, `Plugins`
- Header: `Work with Codex across your favorite tools`
- Search: `Search plugins and skills`
- `Curated by OpenAI` featured: `evo-hq` (Added/Manage), `Computer Use`, `Chrome`, `Data Analytics`, `Product Design`, `Creative Production`
- Categories with `Add plugin` rows: Business & Operations, Communication, Creativity, Data & Analytics, Developer Tools, Education & Research, Finance, … (many third-party plugins)

## 10. Master parity checklist

- [ ] New chat (⌘N)
- [ ] Search (⌘G)
- [ ] Plugins sidebar nav
- [ ] Automations sidebar nav
- [ ] Projects section header
- [ ] Collapse all
- [ ] Project sidebar options
- [ ] Add new project
- [ ] Per-project folder row
- [ ] Project actions menu
- [ ] Start new chat in project
- [ ] Collapse/Expand project
- [ ] Show more (project chats)
- [ ] Chats section
- [ ] Filter sidebar chats
- [ ] Chats section New chat
- [ ] Settings (sidebar footer)
- [ ] Open Codex mobile
- [ ] Sidebar resize handle
- [ ] Pin chat (hover)
- [ ] Archive chat (hover)
- [ ] Hide sidebar (⌘B)
- [ ] Back (⌘[)
- [ ] Forward (⌘])
- [ ] Chat title/header area
- [ ] Chat actions menu
- [ ] Open in menu
- [ ] Secondary action
- [ ] Toggle pinned summary
- [ ] Toggle bottom panel (⌘J)
- [ ] Toggle side panel (⌥⌘B)
- [ ] Contenteditable composer
- [ ] Add files and more menu
- [ ] Approval mode chip
- [ ] Model/reasoning chip
- [ ] Dictate button
- [ ] Send message
- [ ] Stop (during run)
- [ ] Environment chip
- [ ] Work locally chip
- [ ] Project chip (CodexCore)
- [ ] Branch chip (main)
- [ ] Blank-state heading
- [ ] Connect messaging card
- [ ] Connect email card
- [ ] Connect files card
- [ ] Slash command palette
- [ ] @-mention palette
- [ ] Scroll-to-bottom button
- [ ] Copy message
- [ ] Slash command /Chat
- [ ] Slash command /Cloud
- [ ] Slash command /Code review
- [ ] Slash command /Fast
- [ ] Slash command /Feedback
- [ ] Slash command /Goal
- [ ] Slash command /Init
- [ ] Slash command /MCP
- [ ] Slash command /Memories
- [ ] Slash command /Model
- [ ] Slash command /New worktree
- [ ] Slash command /Personality
- [ ] Slash command /Pet
- [ ] Slash command /Plan mode
- [ ] Slash command /Project
- [ ] Slash command /Reasoning
- [ ] Slash command /Status
- [ ] Skill: 1-Shot SVG
- [ ] Skill: Agents Sdk
- [ ] Skill: AppKit Interop
- [ ] Skill: Browser
- [ ] Skill: Build / Run / Debug
- [ ] Skill: Caveman
- [ ] Skill: Channel Summarization
- [ ] Skill: Cloudflare
- [ ] Skill: Cloudflare Email Service
- [ ] Skill: Daily Digest
- [ ] Skill: Diagnose
- [ ] Skill: Documents
- [ ] Skill: Durable Objects
- [ ] Skill: Gmail
- [ ] Skill: Grill Me
- [ ] Skill: Grill with Docs
- [ ] Skill: Hatch Pet
- [ ] Skill: Image Gen
- [ ] Skill: Improve Codebase Architecture
- [ ] Skill: Inbox Triage
- [ ] Skill: Linear
- [ ] Skill: Liquid Glass
- [ ] Skill: OpenAI Docs
- [ ] Skill: Packaging & Notarization
- [ ] Skill: Plugin Creator
- [ ] Skill: Polymarket Alpha Lab
- [ ] Skill: Presentations
- [ ] Skill: Prototype
- [ ] Skill: Reply Drafting
- [ ] Skill: Resume From Claude
- [ ] Skill: Resume From Codex
- [ ] Skill: Resume From Opencode
- [ ] Skill: Sandbox Sdk
- [ ] Skill: Setup Matt Pocock Skills
- [ ] Skill: Signing & Entitlements
- [ ] Skill: Skill Creator
- [ ] Skill: Skill Installer
- [ ] Skill: Slack
- [ ] Skill: Slack Notification Triage
- [ ] Skill: Slack Outgoing Message
- [ ] Skill: Spreadsheets
- [ ] Skill: SwiftPM macOS
- [ ] Skill: SwiftUI Liquid Glass
- [ ] Skill: SwiftUI Patterns
- [ ] Skill: SwiftUI Performance Audit
- [ ] Skill: SwiftUI UI Patterns
- [ ] Skill: SwiftUI View Refactor
- [ ] Skill: Tdd
- [ ] Skill: Telemetry
- [ ] Skill: Test Triage
- [ ] Skill: To Issues
- [ ] Skill: To Prd
- [ ] Skill: Triage
- [ ] Skill: View Refactor
- [ ] Skill: Web Perf
- [ ] Skill: Window Management
- [ ] Skill: Workers Best Practices
- [ ] Skill: Wrangler
- [ ] Skill: Write A Skill
- [ ] Skill: Zoom Out
- [ ] Skill: iOS App Intents
- [ ] Skill: iOS Debugger Agent
- [ ] Skill: iOS ETTrace Performance
- [ ] Skill: iOS Memgraph Leaks
- [ ] Skill: iOS Simulator Browser
- [ ] Approval mode menu
- [ ] Model/reasoning menu
- [ ] Add files menu
- [ ] Chat actions menu
- [ ] Open in menu
- [ ] Project actions menu
- [ ] Project sidebar options menu
- [ ] Account/profile menu
- [ ] Filter sidebar chats
- [ ] Settings dialog
- [ ] Settings > General
- [ ] Settings > Profile
- [ ] Settings > Appearance
- [ ] Settings > Configuration
- [ ] Settings > Personalization
- [ ] Settings > Keyboard shortcuts
- [ ] Settings > Usage & billing
- [ ] Settings > Appshots
- [ ] Settings > MCP servers
- [ ] Settings > Browser
- [ ] Settings > Computer use
- [ ] Settings > Hooks
- [ ] Settings > Connections
- [ ] Settings > Git
- [ ] Settings > Environments
- [ ] Settings > Worktrees
- [ ] Settings > Archived chats
- [ ] Floating summary: Environment
- [ ] Floating summary: Changes
- [ ] Floating summary: Side chats
- [ ] Floating summary: Sources
- [ ] Side chat split view
- [ ] Bottom terminal panel
- [ ] Plugins screen
- [ ] Automations screen
- [ ] Universal search (⌘G)
- [ ] Live: Thinking state
- [ ] Live: Worked for Ns
- [ ] Live: Done state
- [ ] Live: Edited file card
- [ ] Live: Undo on file card
- [ ] Live: Review on file card
- [ ] Slash command /side (side chat creation; verified live)
- [ ] Live: /side creates Side chats row
- [ ] Side chat independent composer
- [ ] Settings > Coding (nav item present; tab content not captured)

