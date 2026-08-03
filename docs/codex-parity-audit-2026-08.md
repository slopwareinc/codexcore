# Codex desktop parity audit — August 2026

Comparison of **CodexCore 0.9.0** against the shipping **OpenAI Codex desktop app**
(`/Applications/ChatGPT.app`, version `26.727.51351`, bundling `codex-cli 0.146.0-alpha.9.2`).

Evidence sources on the Codex side:

| Surface | Path |
| --- | --- |
| App-server / CLI runtime | `Contents/Resources/codex` (270 MB Rust binary) |
| Code-mode IPC host | `Contents/Resources/codex-code-mode-host` |
| Screen-memory sidecar | `Contents/Resources/codex_chronicle` |
| Electron main process | `app.asar` → `.vite/build/*.js` |
| Renderer (React) | `app.asar` → `webview/assets/*.js` |
| Settings index | `webview/assets/_virtual_settings-search-documents-*.js` (2,040 labels) |
| Bundled plugins | `Contents/Resources/plugins/openai-bundled/` (10 plugins) |
| Bundled skills | `Contents/Resources/skills/skills/` |
| Native helpers | `Contents/Resources/native/` (12 addons/binaries) |
| Localization | 83 `.lproj` bundles + 64 native-menu locale files |

Method: seven parallel audits — protocol, native/OS integration, conversation UI,
configuration/auth/models, extensibility (plugins/skills/MCP/agents), git/worktrees/cloud,
and an internal-health pass on our own codebase.

---

## 1. Headline

The **SDK layer is close to complete**. 126/127 client methods, 70/70 notifications, 11/11
server requests are generated and typed; thread items are stored as raw JSON so no field is
lost. `CodexIntegrationControlPlane` is genuinely good architecture.

**The product layer is where we are weak, in three distinct ways:**

1. **Wired but never called.** ~13 control-plane operations and 6 account/config RPCs have
   zero product call sites. `marketplace/add`, `mcpServer/oauth/login`, `plugin/skill/read`,
   `config/mcpServer/reload`, `account/logout`, `account/usage/read`, `configRequirements/read`
   — all typed, all routed, all dead.
2. **Decoded but dropped.** 12 notification types hit `default: break` in
   `CodexSession.processNotification`, which makes three whole request families
   (`fs/watch`, `process/spawn`, streaming fuzzy search) non-functional despite having
   working request builders.
3. **Absent by construction.** Worktrees, cloud tasks, hooks UI, AGENTS.md, PR lifecycle,
   menu bar extra, global hotkeys, URL scheme, updates, localization, notarization.

Two things stand out as unusually honest and should be preserved:
`docs/reference/support-status.md` (its "Presentation only" status caught most of what the
facade hunt found) and the bounded-buffer / typed-error discipline in the transport layer.

---

## 2. Top 30, ordered by what I would fix first

| # | Finding | Domain | Sev |
| --- | --- | --- | --- |
| 1 | `swift test` crashes with SIGSEGV; no CI exists to catch it | internal | Critical |
| 2 | Transport discards 100% of subprocess stderr | internal | Critical |
| 3 | App quits on last-window-close, killing in-flight turns and the automation scheduler | native | Critical |
| 4 | `automation.toml` round-trip silently un-pauses paused automations | extensibility | Critical |
| 5 | Connection lifecycle never surfaces; a dead backend looks like "thinking" | internal | Critical |
| 6 | Uncapped reconnect loop — permanent process-spawn storm on a reproducible failure | internal | Critical |
| 7 | Managed/enterprise `configRequirements` never read — Full access offerable under MDM policy | config | Critical |
| 8 | MCP servers are read-only: no add/edit/remove, no OAuth login, no enable toggle | extensibility | Critical |
| 9 | Worktrees do not exist as a product; the implementation is unreferenced dead code | git | Critical |
| 10 | No thread↔worktree binding → no parallel-agent story at all | git | Critical |
| 11 | MCP tool calls render as raw `CodexJSONValue.description` dumps | chat UI | Critical |
| 12 | Reasoning/thinking is dropped at turn end and unrecoverable | chat UI | Critical |
| 13 | No find-in-conversation | chat UI | Critical |
| 14 | `fs/changed`, `process/outputDelta`, `process/exited` dropped → 3 dead request families | protocol | Critical |
| 15 | Marketplace add/remove/upgrade are `tryInChat` prompts over live RPCs | extensibility | Critical |
| 16 | No hardened runtime, no entitlements, no notarization — undistributable | native | Critical |
| 17 | No cloud tasks / cloud environments; `.cloud` resolves to a hardcoded failure | git | Critical |
| 18 | No external editor/terminal launching (Codex detects ~28 targets) | native | Critical |
| 19 | `codex` binary discovery uses `$PATH` — broken for Finder-launched bundles | native/internal | High |
| 20 | No menu bar extra, dock menu, or dock badge — finished turns are invisible | native | High |
| 21 | Notifications cover automations only: no approval, question, or turn-complete | native | High |
| 22 | No `account/logout`; no browser OAuth login (device-code only) | config | High |
| 23 | No Usage/plan/credits pane (364 settings labels on the Codex side) | config | High |
| 24 | Hooks fetched then discarded; no UI, 10 hook events unmodeled | extensibility | High |
| 25 | No AGENTS.md discovery/layering/editing — and it carries authorization weight | extensibility | High |
| 26 | `ANSITerminalStyle` is fully written and referenced by nothing; exec output shows escape codes | chat UI | High |
| 27 | Per-hunk stage/unstage/revert missing; no inline diff comments; unified-only diff | git | High |
| 28 | No live repo watching → Review is stale during turns, so mutations fail the revision guard | git | High |
| 29 | System Reduce Motion and Dynamic Type ignored in favour of app-local prefs | internal | High |
| 30 | English-only, no string catalog (Codex ships 83 locales) | native | High |

---

## 3. Protocol / app-server

Bundled `0.146.0-alpha.9.2` vs pinned `0.145.0` (`Tools/UPSTREAM_VERSION`).

### Dropped notifications (all `default: break` in `Client/CodexSession.swift:2280`)

| Notification | Consequence | Sev |
| --- | --- | --- |
| `fs/changed` | `Codex+FS.swift:32` `watch()` has no delivery path | Critical |
| `process/outputDelta`, `process/exited` | `Codex+Process.swift` spawn/write/kill unusable — no output, no exit code | Critical |
| `fuzzyFileSearch/sessionUpdated`, `sessionCompleted` | `sessionStart` succeeds, nothing arrives | High |
| `mcpServer/oauthLogin/completed` | must poll `mcpServerStatus/list` | Medium |
| `app/list/updated` | `app/list` goes stale with no invalidation | Medium |
| `remoteControl/status/changed` | pairing transitions invisible | Medium |
| `externalAgentConfig/import/progress`, `/completed` | import is fire-and-forget | Medium |
| `windowsSandbox/setupCompleted` | no completion signal | Medium |

Fix pattern already exists twice in-tree: `Session/CommandOutputRouter.swift` and
`Session/SkillsChangeObserverHub.swift`.

### Version drift (regenerate closes all of this)

- Missing method: `externalAgentConfig/import/recordHistory`.
- `CommandExecutionThreadItem` gains `pluginId`, `scriptPath` — a **core streaming item type**.
- `Thread`/`ThreadListParams`/`ThreadMetadataUpdateParams` gain `isPinned`.
- `ConfigRequirements` gains 8 fields incl. `browserUse`, `feedback`, `modelCatalogJson`.
- `AppToolSummary` gains `isEnabled`/`isReadOnly`/`disabledReason`; `SkillInterface` gains icon URLs.
- `AppMetadata.firstPartyType` removed upstream; ours still has it.

### Modelling defects

- `Protocol/V2Types.swift:40` `AskForApproval` is a flat string enum: no `granular` case,
  and carries `on-failure`, which is **not** in the 0.146 enum. It is public API and it lies.
- `Protocol/V2Types.swift:145` `CodexInput` lacks `AudioUserInput`, `LocalAudioUserInput`,
  `ImageDetail`, and `text_elements`.
- `rawResponseItem/completed` / `rawResponse/completed` are absent from the notification enum
  entirely, so `experimentalRawEvents` produces events that land in `.unknownMethod` and vanish.
- 93 untagged-union types degrade to opaque `CodexJSONValue` typealiases. Lossless, but
  `AskForApproval`, `SandboxPolicy`, `UserInput`, `ContentItem`, `ReviewTarget`, `ResponseItem`
  all lose type safety. `CodexReviewTarget.swift` is the one hand-written wrapper — the pattern
  to replicate in `Tools/generate_app_server_schema_types.py`.
- `mcpServerOpenaiFormElicitation` capability is never opted into (`CodexSession.swift:110`)
  even though `ServerRequestProtocol.swift:552` already handles `"openai/form"`. One line.
- `ServerRequestProtocol.swift:561` hard-throws on an unknown elicitation `mode` instead of
  degrading to a declinable unknown, unlike the `.unknown` fallback used for methods.

### Verified clean

All 8 streaming deltas, turn interrupt/steer (with a dedicated race handler), token and
rate-limit accounting, compaction, fork/rollback/resume, review mode, all 6 exec-approval
decision shapes including `acceptWithExecpolicyAmendment`, all 3 MCP elicitation modes,
unified exec / PTY / background-terminal request builders, all 18 `ThreadItem` discriminators
with `.unknown` fallback, 11/11 server requests.

---

## 4. Configuration, auth, models, sandbox

`ConfigToml` on the Codex side has **96 fields**; the app-server `Config.ts` exposes 23 writable.
Because we are an app-server client, most keys are *honoured* — the gap is what the UI shows
and which RPCs we call.

### Security-relevant

- **`configRequirements/read` never called.** 24 enterprise-policy elements
  (`allowedApprovalPolicies`, `allowedSandboxModes`, `allowedWebSearchModes`,
  `defaultPermissions`, `allowManagedHooksOnly`, `enforceResidency`, …). Our option list comes
  only from `permissionProfile/list`, which does not carry them. On an MDM-managed Mac we can
  present Full access when policy forbids it, with no "managed by your organization" state.
- **`CodexChatConfigurationModels.swift:121`** — the fallback option list is
  `[.askForApproval, .approveForMe, .fullAccess, .custom]`. The degraded path drops the
  *safest* option and keeps the *most dangerous* one. Mitigated by
  `safeFallbackApprovalSelection` never auto-selecting `.fullAccess`, but still wrong.
- **`configWarning` notification unhandled.** Hand-edited `config.toml` misconfigurations
  are silent.
- **`cli_auth_credentials_store` is hard-forced to `"file"`**, so tokens sit in
  `~/.codexcore/auth.json` in plaintext. Codex defaults to Keychain-backed storage and supports
  `file`/`keyring`/`auto`/`ephemeral`. This is a deliberate isolation trade-off — it should be
  stated as such in `docs/getting-started/authentication.md`.
- `approval_policy`: only `on-request` and `never` are ever sent. `untrusted` and `on-failure`
  are unreachable.
- `approvals_reviewer`: `guardian_subagent` is never selectable despite existing in
  `V2Types.swift:47` and having a whole `ItemGuardianApprovalReview*` notification family.

### Not surfaced at all

`sandbox_workspace_write.{writable_roots, network_access, exclude_tmpdir_env_var,
exclude_slash_tmp}`, custom `[permissions.*]` profiles (only the 3 built-in IDs map),
`[projects.*] trust_level` / trust-on-first-use, `tools.web_search` mode,
`model_reasoning_summary`, `model_verbosity`, `personality`, `plan_mode_reasoning_effort`,
`hide_agent_reasoning`, `shell_environment_policy` (7 sub-keys), `[otel]`, `[features]`
flags, `[profiles.*]` (29 fields — no profile support at all), `notify`, `file_opener`,
`memories`, `notice.*`, `ghost_snapshot`, `model_providers.*` (18 fields — no custom/OSS
provider UI), `analytics`/`feedback.enabled`.

### Auth

| Gap | Detail |
| --- | --- |
| No browser OAuth | `CodexCoreAppModel.swift:343` builds only `apiKey` and `chatgptDeviceCode`. The generated union has all five including `chatgpt` (returns `authUrl`) and `amazonBedrock`. |
| No logout | `CodexSessionCommands.swift:748` wrapper exists, zero call sites. Users must delete `auth.json` by hand. |
| No account switching | `AuthMode` has 7 variants; we string-format one label. |
| Token refresh disabled | `accountRead(.init(refreshToken: false))` at `CodexCoreAppModel.swift:244`; the `account/chatgptAuthTokens/refresh` server request is unhandled; no re-auth CTA. |
| No workspace/org selection | `forced_chatgpt_workspace_id` / `forced_login_method` modeled in generated types, absent from UI. |

### Models

The catalog **is** correctly dynamic (`CodexChatConfigurationModels.swift:481` maps live
`model/list`; nothing hardcoded outside a `#Preview`). Reasoning ladder covers all 8 values.

Weak spots: `CodexModelSelectorGridV2.swift:62,325` matches the literal string `"5.6"` to order
columns and pick tints; `Model.upgradeInfo`, `availabilityNux`, `inputModalities`,
`supportsPersonality`, `hidden`, `additionalSpeedTiers` are dropped; `model/rerouted` and
`model/safetyBuffering/updated` are unhandled, so silent reroutes are invisible.

### Settings panes

Codex ships ~24; we ship 6, and `.git` is filtered out of `supportedRoutes`
(`CodexSettingsAboutRouteView.swift:347`) so it is defined but unreachable. Entirely missing:
Usage, Data controls, Personalization, Import (from Claude Code / Cursor / Claude Cowork),
Cloud environments, Security, Hooks, Memory/Chronicle, Keyboard shortcuts, Worktrees,
Code review, Browser use, Computer use, Connections/remote, Pets, Voice, Appshots.

---

## 5. Conversation surface

### Composer

- No photo/image attachment path in the add menu; images only arrive via drag-drop.
- No paste-image and no large-pasted-text→attachment chip. The composer is a plain SwiftUI
  `TextField` with no paste interception at all.
- `@`-mentions are files-only and parse only the trailing token
  (`draft.lastIndex(of: "@")`). Codex mentions files, chats, skills, agents, apps, plugins,
  sites, browser tabs, and ChatGPT conversations, as editable chips anywhere in the string.
- No inline context-window meter or token counter — usage exists only behind `/status`.
- Height caps at 6 lines with no internal scrolling.
- No message-history recall; drafts are memory-only.
- 10 slash commands vs ~22 + skills. Missing `/init`, `/review`, `/new`, `/feedback` — all four
  map to capabilities we already have elsewhere.
- Disabled send button gives no reason (Codex has ~20 distinct `composer.submit.*` messages).
- No "Full access is on" persistent banner, no mid-conversation model-change warning.

### Transcript

- **Reasoning is ephemeral.** `CodexCanonicalTranscriptProjector.swift:372` sets `turn.liveTail`
  only while streaming; `finishPresentation` drops it. `CodexNarrativeEntry` has no reasoning
  case. After a turn ends, all reasoning summary text is gone.
- No KaTeX/math, no mermaid, no charts.
- Markdown block coverage is 6 types. Missing blockquotes, horizontal rules, task-list
  checkboxes, footnotes. List nesting hardcodes 2-space indent (`depth = leading / 2`), so
  4-space and tab lists collapse; multi-paragraph list items truncate.
- Syntax highlighting is regex-based over **7 languages**
  (`CodexCodeHighlighter.swift:42`). Rust, Go, C++, HTML, CSS, YAML, TOML, SQL, Java, Kotlin
  are unstyled. Codex ships lowlight (~190 grammars).
- `CodexMessageContentView.swift:64` is a *second*, entirely unhighlighted code path — the
  dual-parser hazard `docs/transcript-ui-audit.md` §B already flags.
- **No file citations.** `file.swift:42` in assistant prose is inert text. Codex has a full
  `markdown.fileCitation.*` / `fileReference.*` surface with reveal/open/copy-contents.
  This is the highest-value transcript gap for a coding client.
- Inline markdown images silently dropped; no audio/video; no copy/expand on tables.
- `CodexBlock.htmlFallback` is declared, handled in 4 places, and never produced — dead branch.
- The streaming reuse fast path reconstructs prior source by *re-serializing* blocks; if the
  original markdown differed syntactically the prefix check fails and every delta re-lexes the
  whole message — silent O(n²) on long turns.
- `CodexBlockProjection.swift:34` documents SHA-256; `:112` implements FNV-1a.

### Tool cards

- **MCP calls dump raw JSON** (`CodexTranscriptRenderProjection.swift:2095`). Codex has 889
  typed per-tool labels plus structured content-block rendering and a "show raw output" escape
  hatch.
- **Browser/computer-use never appear in the transcript.** `CodexBrowserToolView` and
  `CodexTerminalToolView` are side-panel-only; those actions render as generic `.other` rows.
- **Exec output is not ANSI-rendered.** `ANSITerminalStyle.swift` maps every ANSI colour and is
  referenced by nothing outside its own declaration. Escape codes render literally.
- Exec cards capture `exitCode` and throw it away; no cwd; one merged copy action.
- Background-terminal lifecycle unmodeled.
- Web search rows carry `{id, query, status}` — **no results array**. Nothing clickable.
- apply_patch cards have no undo/reapply/stage; no in-progress ("Editing"), interrupted
  ("Stopped editing"), or rejected per-file states.
- Approval cards are two flat buttons: no "allow similar", no "allow for this conversation",
  no risk labelling, no parameter disclosure.
- No compaction markers, no auto-review display, no hook stats, no model-change notices
  (`CodexTurnNoticeV2` plumbing exists; nothing emits).

### Navigation and actions

- **No find-in-conversation.** Codex has a scoped find bar (chat / diffs / browser page).
- No keyboard navigation in the transcript at all — no `keyDown`, no arrow traversal.
- **No retry/regenerate.** The only "Retry" is the projection-error banner.
- No feedback thumbs or turn rating.
- Interrupted turns are indistinguishable from failed ones; elapsed-before-stop is lost.
- No stream-error/reconnection UI — a dropped stream leaves the turn spinning.
- **Plan/todo lives only in the side panel.** No transcript entry, no progress pill above the
  composer. `turn/plan/updated` and `item/plan/delta` unhandled.
- No elicitation/question-answering surface in the conversation.
- Empty state is 4 hardcoded strings with a dead `detail` branch.

Where we are ahead: block-level caching with stable ids, prepared-text cache, scroll
anchoring, pin-to-bottom, turn minimap, display-cost recorder.

---

## 6. Extensibility — plugins, skills, MCP, subagents, hooks

The seam is right; the surface is missing. **13 of 30 control-plane operations have no product
caller.** Most High findings here are "build a sheet and call the existing method."

### Facades

| Surface | Reality |
| --- | --- |
| "Add plugin marketplace" / "Create plugin" / "Create skill" | `onAction(.tryInChat(prompt:))` — while `marketplace/add`, `/remove`, `/upgrade` sit typed and routed three files away |
| Skill detail sheet | 900×780 points rendering the one-sentence frontmatter `description`; `plugin/skill/read` never called, so `references/` and body never load |
| Apps tab | Re-renders the plugin list with a hardcoded "Installed" checkmark; `appList`/`appRead` responses are fetched and never read |
| MCP panes | Display-only. Only buttons are Refresh and Close |
| Hooks | `hooksList` called once inside a refresh loop whose result is `_ = await …` and discarded |

### Permission fields — none of them modeled

Across plugins (`capabilities`), MCP (`approval_mode`, `default_tools_approval_mode`,
`enabled_tools`, `disabled_tools`, `enabled`), skills (`allowed-tools`,
`disable-model-invocation`), and AGENTS.md (trusted-content status), **not one
permission-relevant field is surfaced** — while Codex treats all of them as load-bearing
inputs to its guardian policy. If one theme deserves a dedicated workstream, it is this.

### MCP specifics

No add/edit/remove (`grep mcp_servers Sources/` → no hits outside generated code).
No OAuth login despite a full error taxonomy upstream (`InsufficientScope` carries
`required_scope` and `upgrade_url` — both actionable). No transport modelling (stdio vs
streamable-HTTP is a trust distinction). Tool schemas flattened to `{name, title, detail}` and
truncated to **4 entries** total across tools+resources+templates. No `prompts` capability.
`mcpServer/startupStatus/updated` unsubscribed, so status is stale until manual refresh, and
`failureReason` — the structured *why* — is dropped. `CodexMCPStatusSheet.swift:152` switches
on string literals with `default:` → green checkmark: a fail-open display bug.

Genuine parity: MCP elicitation. All three modes (`form`, `openai/form`, `url`) round-trip.

### Subagents

Observation is strong — the tree renders faithfully across `CodexSubagentStoreV2`,
`CodexSubagentPresentationCoordinator`, and both `collabAgentToolCall` and `subAgentActivity`
paths. **Control is absent**: no spawn, no cancel, no close. A runaway subagent cannot be
stopped from the UI. No model/effort/agent-type overrides. No `agents/openai.yaml` parsing.

### Automations — the sharpest bug in the audit

`CodexAutomationStore.swift` hand-rolls TOML by line-splitting, against real files that carry
multi-KB escaped prompts. Four field mismatches vs real `~/.codex/automations/*/automation.toml`:

| Field | Codex writes | We write / read |
| --- | --- | --- |
| `kind` | `"heartbeat"` | hardcoded `"schedule"` |
| `status` | `"PAUSED"` (uppercase) | reads only lowercase → `CodexAutomationStatus(rawValue: "PAUSED")` fails → `?? .enabled` |
| `created_at` | integer epoch ms | quoted ISO8601 |
| `updated_at` | present | not written, not read |

Net effect: **loading and saving a real paused automation silently resumes it.**

### Slash commands and prompts

`CodexSlashCommand.observedCommands` is a hand-written literal array, so the built-in list
drifts from what Codex actually supports. `~/.codex/prompts/` is never read. MCP prompts
cannot become slash commands.

### AGENTS.md

`grep -rn "AGENTS.md" Sources/` returns **one hit** — a hardcoded UI placeholder string in
`CodexWorkBlockViewV2.swift:264`. No discovery, no layering, no editor, no indication of which
files are in effect. Given AGENTS.md establishes `user_authorization` in the guardian model,
this is a security-transparency gap, not just a convenience one.

---

## 7. Git, worktrees, review, cloud

The **Review workbench is genuinely functional** — stages, unstages, reverts, commits, pushes,
opens draft PRs through a serialized actor with expected-revision checks. Arguably more careful
about mutation safety than Codex. Everything around it is a shell.

### Worktrees — the largest structural gap

`CodexLocalProjectEnvironmentProvider` and `CodexProjectEnvironmentPanel` implement a worktree
handoff and are **referenced by nothing outside their own definitions and one test file**.
`docs/app/tools-and-worktrees.md` still says the reference app omits worktree handoff — which
is the accurate description of shipped behaviour.

Where our implementation differs from Codex's, and is less safe:

| | Codex | CodexCore |
| --- | --- | --- |
| Path | `<root>/<uuid[0:4]>/<basename>` — collision-proof, GC-matchable | user-typed absolute, or `<repo>-worktrees/<slug>` — collides on repeated titles |
| Creation | `worktree add --detach`, branch created after | `worktree add -b` eagerly — a failed handoff orphans a branch |
| Uncommitted work | captured diff + `git apply --3way`, untracked copied individually; **source never touched** | `stash push --include-untracked` on the **source**, then `stash apply` |
| Crash safety | force-removes worktree and deletes branch on failure | a crash between push and apply leaves work only in a stash |
| cwd | repo-relative prefix preserved | not preserved |

Also absent: worktree registry/listing, auto-cleanup (Codex keeps 15 with pinned/in-progress/
young-ownerless protections and a separate empty-bucket sweep), snapshot/restore, deletion UI,
`environment.toml` setup scripts, setup auto-fix, stable worktrees, configurable root.

**No thread↔worktree binding at all** — Codex's entire parallel-agent model rests on
`resolve-worktree-for-thread` / `set-worktree-owner-thread` / `move-thread-to-worktree`.
Consequence: `CodexCoreAppModel.swift:2398` forks always into the same cwd, so two agents edit
the same tree and race.

Live inconsistency: `CodexWorkspaceSummaryContext.swift:55` detects worktrees by matching
`"/.codex/worktrees/"` — Codex's default root — while
`CodexEnvironmentHandoffModels.swift:317` creates them at `<repo>-worktrees/`. **Nothing we
create will ever be labelled a worktree.**

### Diff viewer

Unified-only. No split view, no word diff, no whitespace toggle, no syntax highlighting
(tree-sitter is imported but used only in `CodexFilePreviewView`), **no per-hunk
stage/unstage/revert** (file-level only), **no inline diff comments**, no forward
`apply-patch`, no blame, no image/PDF previews, no in-diff search, no merge-conflict marker
detection.

`viewedFileRevisionByID` keys "mark as viewed" to the exact snapshot revision, so any change
anywhere in the repo resets every viewed flag — hostile during an active turn.

### No live repo watching

Codex uses `watch-repo` / `subscribe-live-query` / `invalidate-git-read-caches`. We are
manual-only (⇧⌘R). While an agent edits, Review is stale, and every mutation then hits the
stale-revision guard and fails — which will read as flakiness rather than staleness.

### Commits and PRs

No commit-message generation (we throw "Commit message is required"). No PR title/body
generation. `gh pr create --draft` is hardcoded — non-draft PRs are impossible. Plain
`git push` with no `--force-with-lease`. No merge, no review submission, no PR comments, no
checks actions, no PR inbox, no watch-and-fix, no draft↔ready transitions.

### Conflicts

`ensureSafeMutationState` correctly detects `MERGE_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`,
`BISECT_LOG`, rebase and sequencer states and refuses all mutations. That is safe and honest —
and it is the entirety of the conflict story. No resolution UI, no per-file marking, no
hand-off to the agent.

### Cloud

Absent entirely. `grep -rn "cloud"` over the UI returns the `.cloud` enum case and a hardcoded
"Cloud environment unavailable" notice inside a panel that is itself dead code. Codex ships
~90 settings labels for cloud environments alone (machine tier, setup/maintenance scripts,
container cache, Docker-in-Docker, secrets with per-secret domains, network allow/block lists,
sharing visibility), plus task creation/monitoring, apply-diff-locally with conflict reporting,
and a 15-step local↔cloud handoff progress model.

Note: **best-of-N is a Codex Cloud web feature, not a desktop one** — no desktop gap.

### Threads

`threadUnarchive` and `threadDelete` are generated and never called. No archived-chats view,
no undo. Search is a flat capped-25 query with `archived: false` hardcoded. Unread state is
derived from live in-session revisions only, so it is **lost on relaunch**, with no manual
mark-unread and no per-project rollup. No resume-failure taxonomy. No PR chip / needs-input /
branch-mismatch states on rows. Fork has no destination choice.

---

## 8. Native macOS integration

CodexCore is a single-window, single-locale, unsigned-for-distribution SwiftUI app with a
hand-rolled 4-item main menu. **58 gaps; 9 Critical.**

### Distribution and lifecycle — fix first

- `scripts/package-app.sh:73` signs with `codesign --force --deep --sign` and **no
  `--options runtime`, no `--entitlements`, no `--timestamp`**. No `.entitlements` file exists.
  Without hardened runtime there is no notarization; without a stable signature, TCC grants
  (microphone) reset every rebuild — which the script itself warns about.
- No notarization or stapling. Any downloaded `build/CodexCore.app` is Gatekeeper-blocked.
- `applicationShouldTerminateAfterLastWindowClosed` returns `true` unless a **voice** session is
  active. Closing the window kills in-flight turns and the 30-second automation scheduler.
  Codex explicitly does *not* quit on packaged macOS, and guards quit with a confirmation that
  names active local chats and scheduled tasks.
- No `ProcessInfo.beginActivity` / `IOPMAssertion` anywhere. Long turns and the scheduler get
  App-Napped when backgrounded and interrupted by sleep.
- `Codex.swift:425` walks `ProcessInfo.environment["PATH"]`. A Finder-launched bundle inherits
  launchd's minimal PATH, so a Homebrew `codex` is invisible from the Dock but found from a
  terminal — the exact flow README documents. Resolve through a login shell or ship the binary.

### Shell surface

No menu bar extra (Codex's tray carries running/unread/pinned threads and usage limits).
No dock menu, no dock badge, no dock tile plug-in. With none of these, a finished turn is
invisible unless the window is frontmost.

Main menu is App/File/Edit/View only: no Window menu (so ⌘M does nothing), no Help, no About,
no Hide/Hide Others/Show All, no Services, no Enter Full Screen, no Paste and Match Style.
4 menu commands vs Codex's ~45 (⌘1–⌘9 thread switching, next/prev thread, new/close window,
copy deeplink / session id / working directory, show keyboard shortcuts).

No global hotkeys of any kind, no bare-modifier/double-tap trigger, no quick-entry hotkey
window, no global appshot. The `CodexVoiceOverlayPanel` chassis
(`CodexVoiceOverlay.swift:256` — borderless, non-activating, all-spaces, sleep/wake aware)
is a good starting point for a quick-entry composer.

No URL scheme (`CFBundleURLTypes` absent), so no deep links, no OAuth callback, no CLI→app
bridge, no "copy deeplink". No cold-launch URL queueing. No single-instance lock, which
matters because two instances would race on the same `CODEX_HOME`.

No `CFBundleDocumentTypes` — Codex declares `public.folder` (drop a repo on the dock icon),
plus spreadsheet types and an owned `.skill` UTI. We never appear in Finder's *Open With*.

**No external editor/terminal launching.** Codex detects ~28 targets (VS Code, Cursor, Zed,
Xcode, all JetBrains IDEs incl. a Toolbox scan, Ghostty, iTerm2, kitty, Warp, WezTerm, …) with
global and per-path preferences and user-extensible `custom_file_handlers`. We have
`NSWorkspace.selectFile` (reveal) and `open(url)` (default handler) only. Native implementation
is *easier* than Codex's — `NSWorkspace.urlForApplication(withBundleIdentifier:)` needs no
helper binary. `CodexGitReviewWorkbenchView.swift:401` already has an `Open` button where a
target picker belongs.

Worth noting the inverse: our embedded Ghostty terminal (`libghostty-spm`) is something Codex
does *not* have.

### Notifications

`CodexAutomationNotificationService` posts exactly one type ("Automation finished"). Codex has
`permission`, `question`, and `turn-complete` kinds with action buttons, inline reply,
never-timeout for blocking prompts, and a custom sound. We register no
`UNNotificationCategory`, set **no `UNUserNotificationCenterDelegate` at all** (so even taps do
nothing), and discard both the granted flag and the error from `requestAuthorization`.

### Updates, crashes, diagnostics

No updater of any kind (Codex ships Sparkle with EdDSA appcast signing and an in-app install
confirmation). No crash reporting, no `NSSetUncaughtExceptionHandler`. No app-wide file log —
`CodexVoiceLog.swift` is voice-specific. No diagnostic bundle export.

### Permissions and capture

No accessibility (`AXIsProcessTrusted`), Input Monitoring, or screen-recording permission flow.
No deep links into System Settings privacy panes on denial. Microphone is declared and
`SFSpeechRecognizer.requestAuthorization` is called, but there is no `AVCaptureDevice` status
check and no denial-recovery path.

No screen capture, no computer-use, no appshot, no Chronicle equivalent. Notably, Codex has a
`realtimeVoiceScreenContextEnabled` setting that lets voice inspect the foreground app — the
closest adjacent win to something we already have.

### Localization

Zero `.lproj` / `.strings` / `.xcstrings` in the repo. All UI strings are hardcoded English
literals. Moving to `String(localized:)` + a `.xcstrings` catalog costs little and unblocks
community translation.

### Windows and misc

Single main window (`newWindow(_:)` is misnamed — it reuses the one window). No `WindowGroup`,
no `openWindow`. Window restoration is frame-only for the main window; the settings window is
re-centred every launch. No `NSQuitAlwaysKeepsWindows` decision either way. No
`collectionBehavior` on the main window while the voice panel sets `.canJoinAllSpaces` —
untested under Stage Manager. `orderFrontRegardless()` on every show can steal focus across
Spaces. Clipboard writes plain text only, so copying a diff or code block loses formatting and
images cannot be copied at all. `CFBundleVersion` is hardcoded `1` and never bumped, so the
About panel always reports build 1.

Minimum OS is macOS 26 vs Codex's 12 — not a bug given Liquid Glass and Swift 6.2, but a
four-major-version-narrower install base worth stating in the README.

---

## 9. Internal health

`swift build` exits 0 with no warnings. The codebase is genuinely well-engineered: one TODO in
324 files, zero `try!`, zero empty catch blocks, no placeholder data, no `#if DEBUG` fixture
leakage, disciplined task lifecycle, bounded buffers with typed overflow errors, and an
`ObservationHub` that is textbook.

### Critical

- **`swift test` crashes (SIGSEGV).** Bisected to
  `CodexTranscriptAppKitIntegrationTests.swift:55` — `NSWindow.isReleasedWhenClosed` defaults to
  `true`, so `close()` plus ARC double-frees. It is the only test that calls `window.close()`;
  production gets this right in all four places. ~770 tests run before the crash and their
  results are discarded.
- **No CI.** `.github/` does not exist. This is why the above shipped on `main`, and it means
  no finding in this report would have been caught automatically.

### High

- `Transport.swift:289` reads stderr and drops the chunk. A panicking app-server, a bad
  config, a failed auth refresh, an OOM — all reduce to "Codex transport connection is closed."
  The version probe at `Codex.swift:307` *does* capture stderr, so this is an oversight.
- `CodexSession.lifecycle` has **zero consumers**, and `CodexConnectionState` (with
  user-facing `.label` strings) is initialized to `.disconnected` and never transitioned.
  A backend that dies mid-turn looks identical to a model that is thinking.
- `CodexReconnectPolicy` has no `maximumAttempts`. Any error outside the non-retryable
  allowlist that reproduces on every launch forks a subprocess every 5 seconds forever, with no
  UI indication and no give-up.
- **System accessibility settings ignored.** `reduceMotion` is an *app* preference;
  `@Environment(\.accessibilityReduceMotion)` is read in exactly one file. Zero occurrences of
  `dynamicTypeSize` anywhere. Reduce Transparency is handled correctly — the one bright spot.
- VoiceOver: 127 `.accessibilityLabel` against 236 `Button(`, but only **5** hints, **2**
  actions, and **0** `accessibilitySortPriority` in a custom AppKit transcript — so reading
  order within a turn is incidental and hover-revealed turn actions are largely unreachable.
- **Every control in `CodexGitReviewPanel` is `Button(action: {})` + `.disabled(true)`**, and
  it is user-reachable: `CodexAgentPanels.swift:1573` routes to it whenever `workspaceURL ==
  nil`. Both "Projectless chats" and "Review workbench" are listed **Supported**.

### Medium

- `Transport.write` does a blocking `write(contentsOf:)` on the actor's executor. The read side
  was carefully moved off the cooperative pool; the write side was not. A full 64KB pipe blocks
  a pool thread while holding the actor, and a concurrent `close()` deadlocks behind it.
- `verifyPinnedRuntime` does `run()` + `readDataToEndOfFile()` + `waitUntilExit()` synchronously
  inside `startReading` — on every connect *and every reconnect*.
- Exact-version pin (`components[1] == "0.145.0"`) is reconnect-fatal. `brew upgrade codex` to
  0.145.1 bricks the app until the user downgrades or pins a path.
- `CodexPreferenceStorage.swift` has 12 `try?` and no migration. Any non-additive change to
  `CodexAppearanceSettings` silently resets theme, font size, and reduce-motion to `.official`.
  Failed encodes leave stale state persisted while memory diverges.
- `CodexAutomationStore.load` swallows both unreadable-file and unparseable-TOML into `nil`,
  and runs synchronously on the main actor during `init`. A hand-edited typo makes an
  automation vanish with no feedback.
- `CodexPluginIconView` decodes local PNGs synchronously on the main actor — the exact class of
  hitch `docs/transcript-scroll-120fps-findings.md` was written about.
- The AppKit performance test asserts **no** elapsed time — only cache-miss counts.
  `docs/performance-nitpick-audit.md` records 33ms average / 53ms max projection against an
  8.3ms ProMotion budget, and says plainly that the test passes anyway.
- `applicationShouldTerminate` calls `model.disconnect()` **only when voice is active**.
  Quitting mid-turn skips lease closing and the SIGTERM→2s→SIGKILL sequence entirely.
- No session restore: `selectedThreadID` is never persisted, though window frame is.

### Doc accuracy

`docs/transcript-scroll-120fps-findings.md` cites two files that no longer exist, and its
top-priority recommendation (quadratic transport buffer) **has been fixed**.
`docs/performance-nitpick-audit.md` is a 596-line open-issue list with no cross-reference to
what has landed. `docs/app/tools-and-worktrees.md` and `CodexEnvironmentPanel.swift` contradict
each other. README documents `swift test`, which fails.

---

## 10. Suggested sequencing

**Tier 0 — stop the bleeding (all small)**

1. `isReleasedWhenClosed = false` in the AppKit integration test; add a GitHub Actions workflow
   running `swift build` + `swift test` + `Tools/tests`.
2. Capture stderr into a bounded ring; attach the tail to `connectionClosed`.
3. Call `model.disconnect()` unconditionally in `applicationShouldTerminate`; stop quitting on
   last-window-close while turns or automations are live.
4. Fix the `automation.toml` codec (real TOML parser, `heartbeat`, uppercase status, epoch ms,
   `updated_at`).
5. Add `maximumAttempts` to the reconnect policy; surface `CodexSession.lifecycle` as a banner.
6. `.readOnly` back into `CodexApprovalSelection.defaultOptions`.
7. Fix `CodexWorkspaceSummaryContext` worktree detection (currently wrong for paths we produce).
8. `ProcessInfo.beginActivity` around turns and the scheduler; login-shell PATH resolution.

**Tier 1 — cheap, high-visibility**

9. `Tools/regenerate.sh` against 0.146 — closes one missing method and all field drift.
10. Route the 12 dropped notifications; `CommandOutputRouter` is the pattern.
11. Wire `ANSITerminalStyle` into exec output (already written, zero callers).
12. `configRequirements/read` on connect, intersected with the option list.
13. `account/logout` + browser OAuth login.
14. Menu bar extra + dock menu + dock badge (all read the same thread state).
15. Approval / turn-complete notifications with a delegate and action buttons.
16. Complete the main menu (Window, Help, Services, Hide, About).
17. Composer context-window meter; plan progress pill; turn retry.

**Tier 2 — structural**

18. MCP add/edit/remove/enable + OAuth login + transport + tool schemas.
19. Marketplace add/remove/upgrade sheets over the existing RPCs; `plugin/skill/read` on detail.
20. Hooks UI; AGENTS.md discovery and editor.
21. File-path citations in the transcript; typed MCP content-block rendering;
    find-in-conversation; reasoning persistence.
22. External editor/terminal targets; `public.folder` document type; URL scheme.
23. Thread↔worktree binding, then worktree creation reworked to Codex's model, then registry,
    GC, and `environment.toml`.
24. Live repo watching; per-hunk stage/revert; commit-message and PR-body generation.
25. Hardened runtime + entitlements + notarization, then Sparkle.

**Tier 3 — decide explicitly, then act**

- Cloud tasks and cloud environments (§7). If out of scope, **remove** the `.cloud` case rather
  than leaving a menu item that always fails.
- Chronicle screen recording, Codex Micro hardware, pets/avatar overlay, computer-use — likely
  non-goals; worth documenting as such.
- The Chromium-inherited AppleScript suite is not a model to copy; a small Codex-shaped `.sdef`
  would be more useful than cloning it.

**Also worth deleting rather than fixing:** `CodexBlock.htmlFallback` (never produced),
`Protocol/V2Types.swift` `ReasoningEffort` (single `.none` case, duplicates the generated type),
and either wiring or removing `CodexProjectEnvironmentPanel` / `CodexLocalProjectEnvironmentProvider`
— unreferenced public API that implies a shipped feature is the worst of both states.
