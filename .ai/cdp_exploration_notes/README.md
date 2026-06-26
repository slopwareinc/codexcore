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

### D. Dictation & Audio Toggles
* **Dictation Button**: Button labeled with a microphone icon (`aria-label="Dictate"`). Clicking activates transcription. If dictation services are offline, displays inline warning: `"Dictation warning: services unavailable"`.

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
