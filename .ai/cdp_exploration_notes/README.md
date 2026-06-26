# Codex App UI Surface Parity & Implementation Specification

This directory contains the precise UI/UX layout, elements, states, accessibility labels, and behaviors of the official Codex app discovered through Playwright/CDP exploration. These notes and captures serve as the specification to guide the SwiftUI clone in `CodexCoreUI` and `CodexChatExample`.

## Directory Map
* **[dumps/](file:///Users/betterclever/Projects/slopware/CodexCore/.ai/cdp_exploration_notes/dumps/)**: Cleaned HTML structures of various menus, routes, and views.
* **[screenshots/](file:///Users/betterclever/Projects/slopware/CodexCore/.ai/cdp_exploration_notes/screenshots/)**: Visual representations of settings tabs, dropdown states, hover rows, and menus.

---

## 1. Sidebar & Folder Operations (`CodexExampleSidebar.swift`)

### A. Thread List Interactions
* **Hover State Controls**:
  * Hovering over a thread row in the sidebar reveals two absolute-positioned, round buttons on the right side of the row:
    1. **Pin Chat** (`aria-label="Pin chat"` or `aria-label="Unpin chat"` if already pinned)
    2. **Archive Chat** (`aria-label="Archive chat"`)
  * When not hovered, the row displays a timestamp or relative time (e.g., `"2d"`, `"4d"`).
* **Renaming Flow**:
  * Double-clicking a thread row triggers a dialog overlay (`role="dialog"`) titled **"Rename chat"**.
  * Subtext: *"Keep it short and recognizable"*.
  * Input: Text field (`aria-label="Chat title"` or placeholder `"Add a title…"`).
  * Buttons: **Cancel** and **Save**.
* **Right-Click Context Menu**:
  * Right-clicking the thread title does **not** trigger a native context menu. All actions are handled via the hover overlay buttons or double-click rename.

### B. Project Section Header & Folder Actions
* **Folder Row Structure**:
  * Hovering over a project folder row reveals:
    1. **Collapse/Expand Project** arrow (`aria-label="Collapse project"` / `aria-label="Expand project"`)
    2. **Project Actions Popover Trigger** (`aria-label="Project actions for [ProjectName]"`)
    3. **Start Chat in Project** (`aria-label="Start new chat in [ProjectName]"`)
* **Project Actions Popover Menu Options**:
  * Clicking the project actions button triggers a menu with the following choices:
    * `Pin project` / `Unpin project`
    * `Reveal in Finder`
    * `Create permanent worktree`
    * `Rename project`
    * `Archive chats`
    * `Remove`

---

## 2. Composer & Chat Inputs (`CodexComposerBar.swift`)

### A. Model Selector Dropdown
* **Display State**: A rounded-full button displaying the active model name (e.g., `"5.5"`) and intelligence tier (e.g., `"Medium"`, `"High"`).
* **Dropdown Menu Options**:
  * **Section Header**: `"Reasoning"`
  * **Tiers (Radio Selection)**:
    * `Light`
    * `Medium` (Default)
    * `High`
    * `Extra High`
  * *Separator Line*
  * **Submenus / Actions**:
    * `GPT-5.5` (or active base model selector submenu)
    * `Speed` (quality vs speed toggle)

### B. Sandbox / Access Mode Selector
* **Display State**: A rounded-full label displaying the current sandbox enforcement state: `"Default"`, `"Auto-review"`, or `"Full access"`.
* **Dropdown Menu Options**:
  * `Default` (Restricted filesystem operations, prompt confirmation required)
  * `Auto-review` (Semi-automated review of shell and write actions)
  * `Full access` (Silent execution of filesystem, shell command and terminal actions)

### C. Composer Add Button Menu
* **Display State**: A button labeled `+` (`aria-label="Add files and more"`).
* **Dropdown Menu Options**:
  * `Add file...` (Opens native file picker)
  * `Add folder...` (Opens native folder picker)
  * `Search workspace...`
  * `Web URL...`

### E. Steer Queue Pipeline (`above-composer-queue-portal`)
* **Placement & Portal**: Renders inside `#above-composer-queue-portal` directly above the composer text entry box, allowing multiple queued inputs during active model generations.
* **Layout Design**:
  * Backdrop styling: uses semi-transparent background with blur (`bg-token-input-background/70 backdrop-blur-sm`) and thin borders (`border-token-border/80 border-x border-t`). The first item in the queue has rounded top corners (`first:rounded-t-2xl`).
  * Scroll limit: scrollable container with max height `max-h-[30dvh]` and hidden scrollbar.
* **Queued Message Row Elements**:
  1. **Drag Handle**: Grab/drag handle button on the left (`cursor-grab`, active: `cursor-grabbing`) supporting drag-and-drop reordering.
  2. **Message Content Snippet**: Displays the typed prompt truncated to a maximum of two lines (`line-clamp-2`) in muted secondary color (`text-token-text-secondary`).
  3. **Row Action buttons**:
     * **Steer Button**: Pill button with label `"↳ Steer"` to bypass queue order and inject current item directly as active guide/feedback.
     * **Delete Button**: Standard trash/close icon button (`aria-label="Delete queued message"`).
     * **Actions Button**: Triple-dot options dropdown trigger (`aria-label="Queued message actions"`).

---

## 3. Global Settings View (`CodexGlobalSettingsSheet.swift`)

### A. Sidebar Navigation Layout
Settings is a full-screen panel with a sidebar list (`nav[aria-label="Settings"]`) structured under four sections:

1. **Personal**:
   * **General**: Work mode toggles (*"For coding"* vs *"For everyday work"*), sandbox default levels, dictation transcription history logs (with a copy button for past transcripts).
   * **Profile**: Personal account details, avatar customization.
   * **Appearance**: Theme selection (Light, Dark, System), custom font size/zoom sliders, and line-wrapping rules.
   * **Configuration**: Default model overrides, temperature parameters, and system instructions.
   * **Personalization**: Pre-prompt injection, memory settings.
   * **Pets**: A dedicated companion panel to manage screen companion characters (see below).
   * **Keyboard shortcuts**: Full list of searchable and custom hotkeys (e.g., `⌘,` for Settings, `⌘G` for Search, `⌘N` for New Chat).
   * **Usage & billing**: Usage remaining bar, usage logs, subscription level, and Credit Top-up.
2. **Integrations**:
   * **Appshots**: App context screen logs and capture history.
   * **MCP servers**: List of active Model Context Protocol servers, status indicators, and an **"Add Server"** configuration sheet.
   * **Browser**: Config for automated web inspection.
   * **Computer use**: Configuration options for local command-use tools.
3. **Coding**:
   * **Hooks**: Custom scripts triggered by file edits.
   * **Connections**: Remote servers and SSH configuration.
   * **Git**: Author info, branch patterns, auto-commits.
   * **Environments**: Local dev environment paths.
   * **Worktrees**: List of directory profiles and active worktree paths (`~/.codex/worktrees/`).
4. **Archived**:
   * **Archived chats**: Manage and restore previous chats.

### B. Pets Settings Section Details
* **Selected Companion State**: Displays the active companion.
* **Available Pets List**:
  * `mudiji`: A tiny meme-safe chibi parody desktop pet with white hair, beard, glasses, side-eye, and tiny feet.
  * `Rascal`: A playful raccoon with bright curious energy.
  * `Codex`: The original green robotic Codex companion.
  * `Dewey`: A calm duck.
  * `Fireball`: A glowing flame.
  * `Hoots`: A sharp-eyed owl.
  * `Rocky`: A steady rock for large diffs.
  * `Seedy`: Small green shoots for new ideas.
  * `Stacky`: A balanced stack of blocks.
* **Action Buttons**:
  * `Create your own pet`
  * `Refresh`
  * `Wake Pet`
  * `Select` / `Selected` toggle button.

---

## 4. Overlay & Navigation Panels

### A. Search Overlay (`⌘G`)
* Triggered via sidebar `"Search"` button or `⌘G`.
* Input: search input text field (`placeholder="Search chats…"`).
* Renders a layout of matching chats, matching message snippets, and quick jump buttons.

### B. Side Panel & Bottom Panel
* **Side Panel**: Renders workspace analysis, list of active file outputs (e.g., `COMPANY_TRACKER.md`), and markdown outline views.
* **Bottom Panel**: Renders active terminals, stdout/stderr logs from spawned background processes, and MCP server logs.

---

## 5. Active Chat Timeline & Tool Call Display

### A. Message Turns & Status Indicators
* **Assistant Message Generation Timing Header**:
  * Shows a collapsible timing header label indicating active tool duration: `"Worked for [time]s"` or `"Working for [time]s"`.
  * The label is housed in an inline button with hover style (`hover:bg-token-bg-subtle`).
  * A thin horizontal hairline separator (`border-token-border-light`) sits right below it.
* **Active Status / Shimmering Loader**:
  * The model renders pure text loaders for thinking/tool steps: `"Thinking"` or `"Running [command]"` (e.g. `Running find /Users/betterclever ...`).
  * Shimmer state utilizes keyframe sweeps (`loading-shimmer-pure-text _cadencedShimmer_18j3y_1 _cadencedShimmerActive_18j3y_46`) with background sweeps and highlights.

### B. Nesting & Collapsible Tool Call Cards
* **Tool / Commands Summary Header**:
  * Multiple tool steps are grouped under a single button row: `"Ran [N] commands"` (e.g., `"Ran 2 commands"`).
* **Collapsible Command Row Structure**:
  * Rendered as nested, individual buttons (`button.group/activity-header`) within the group.
  * Header shows the exact command line/description (e.g. `$ git status --short` or `rg --files ...`).
  * Timing status listed on the right side: `"Ran for [time]s"` or `"Running for [time]s"`.
* **Standard Terminal Code Block Output**:
  * Expanding a command row slides down a formatted dark terminal panel (`bg-token-text-code-block-background border-token-input-background`).
  * Code block top bar displays data type label (e.g., `"text"` or `"shell"`) and copying/wrapping icon toggles.
  * Command stdin/stdout prefix styling uses a grey prefix (`$ git status --short`) followed by monospace outputs.


