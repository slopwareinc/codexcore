# Transcript UI/UX Audit — July 2026

> **Historical engineering note:** Point-in-time audit and external-reference research, not current product documentation.

Consolidated findings from four research tracks: (1) AppKit-migration regression audit, (2) inline directive survey over 465 session rollouts, (3) design-reference mining of the official Codex app's DOM (CDP captures in `~/.codex-ui-capture`), (4) protocol event → UI mapping from wire captures (`~/.codexcore-capture`, `~/.codex-ui-capture/*/wire`) and `LUNA-UX-NOTES.md` (Codex 5.6-luna deep pass, repo root).

## A. Confirmed regressions from the AppKit migration

| # | Issue | Root cause | Official-app reference |
|---|---|---|---|
| 1 | User bubble doesn't hug text; big empty gap on right | Projector gives every user item fixed width `min(contentWidth, 560)` (`CodexTranscriptRenderProjection.swift:612`); cell draws background at full item width (`CodexTranscriptCollectionCell.swift:327-333`) | Bubble hugs content, `max-w-77%`, `rounded-2xl` (~16px), `px-3 py-2`, translucent `foreground/5` fill, right-aligned |
| 2 | Spacing collapsed (was 28px between turns / 18px within; now 14 / ~0) | `minimumLineSpacing = 0` + section inset 14 (`CodexTranscriptCollectionView.swift:205,547`) | 16px between conversation items, 4px within a group |
| 3 | User text is markdown-rendered instead of verbatim | `prepareMarkdown` applied to user text (`CodexTranscriptRenderProjection.swift:293-296`) | User text is verbatim |
| 4 | Code block chrome lost (header band, language label, animated Copied ✓) | AppKit item draws bare `codeBackground`, disabled language button, silent copy (`CodexTranscriptCollectionCell.swift:264-284`) | Header row: language label left + Copy right, `rounded-lg`, code-block bg token, no line numbers |
| 5 | Transcript column ~16px left of viewport center | Cell width `availableWidth - 32` with left inset 0; content centered on cell midX (`CodexTranscriptCollectionView.swift:197,205`; cell:325). Multiple competing insets (−48, −32, −48) — unify into one shared `TranscriptColumnMetrics` | Column `max-w + mx-auto`, symmetric |
| 6 | Expand/collapse + streaming not animated | `apply(animatingDifferences: false)` (`CodexTranscriptCollectionView.swift:306`) | Live activity collapses into "Worked for Ns" button; shimmer on working labels |
| 7 | No copy feedback anywhere | All AppKit copy buttons fire silently; SwiftUI `CodexCopyButton` (animated checkmark) unused in new path | — |

## B. Deeper UX gaps (Luna pass, `LUNA-UX-NOTES.md` has full detail)

- **Dual markdown parsers**: SwiftUI path `AttributedString(markdown:)` vs AppKit `NSAttributedString(markdown:)` — measurement/display can disagree. → One canonical parse-once pipeline with explicit link attributes, paragraph-style list indentation (not space-prefix hacks), stable tables.
- **Selection disabled while streaming** (`allowsTextSelection = !turnIsStreaming`).
- **Approvals invisible in transcript** — lives only in `CodexApprovalRequestsPanel`; a waiting turn looks stalled. → inline "Approval needed" card.
- **Active work vanishes mid-turn**: `shouldRenderWork` hides the running command chip once final text starts streaming. → keep a compact live chip until turn completes.
- Links not styled (auto-detection only, no `linkTextAttributes`), TextKit 1, no syntax highlighting, work rows clickable-looking whether or not they have detail, no loading/disconnected/projection-error states (projection errors are swallowed in `requestProjection`), 78px hard-coded top inset, jump button has no "new output" affordance, no anchor-based scroll restoration when earlier items change height.

## C. Inline directives (parse before markdown; assistant-role text only, exclude developer-role docs)

Regex: `::([a-zA-Z0-9-]+)\{([^}]*)\}`, one per line. Found across 465 rollouts:

| Directive | Keys | ~Count | UI |
|---|---|---|---|
| `created-thread` | `threadId` \| `pendingWorktreeId` \| legacy `clientThreadId` | 812 | Jump chip → `onOpenSubagent` path; live badge if child running |
| `code-comment` | `title, body, file, start, end, priority(0-3)` | 760 | Review card: title + P-badge + markdown body + `file:line` + Open/Copy |
| `git-commit` / `git-stage` / `git-create-branch` / `git-push` | `cwd`, `branch` | ~1,740 | Grouped git action chips (official app puts git status in right panel) |
| `git-create-pr` | `cwd, branch, url, isDraft` | 343 | PR link chip with provider icon |
| `archive`, `automation-update`, `codex-inline-vis`, `archive-thread` | various | ~60 | Later |

Official app never shows these raw — pre-rendered (e.g. "Created an agent" card expanding to agent-id button + instructions).

## D. Protocol events → rendering map (wire evidence)

Reducer (`CodexTranscriptReducerV2.apply`) handles only: `turn/started|completed|failed`, `item/started|completed`, `item/agentMessage/delta`, `item/reasoning/summaryTextDelta`, `item/commandExecution/outputDelta`, `error`. Everything else hits `default: break`.

Observed wire frequencies (all `out_` server→client streams): `item/agentMessage/delta` 2259, `mcpServer/startupStatus/updated` 493, `item/started`/`completed` ~215 each, `process/outputDelta`+`process/exited` 113 each, `thread/status/changed` 83, `item/commandExecution/outputDelta` 83, `thread/tokenUsage/updated` 76, `account/rateLimits/updated` 76. Item types seen: reasoning, agentMessage, commandExecution, userMessage, collabAgentToolCall, mcpToolCall, subAgentActivity, fileChange, dynamicToolCall, webSearch.

Dropped events with UI value:
- `thread/tokenUsage/updated` (has `total/last` token breakdown + `modelContextWindow`) — context meter; currently only surfaced outside transcript.
- `account/rateLimits/updated` (`usedPercent`, `resetsAt`, `planType`) — quota indicator.
- `item/mcpToolCall/progress`, `item/fileChange/patchUpdated` — chips stay frozen until completion.
- `item/autoApprovalReview/started|completed`, approval server requests — invisible in transcript (see B).
- `turn/diff/updated` (cumulative turn diff), `turn/plan/updated`, `item/plan/delta` — unhandled; `turn/diff/updated` is the natural feed for a "Changes" panel/diff card.
- `hook/started|completed`, `thread/compacted`, `model/rerouted`, `warning`/`guardianWarning`/`deprecationNotice`/`configWarning` — silent.
- `process/outputDelta` (base64) / `process/exited` — unified-exec output path ignored.

Multi-row stacking (the "agent creation shows 3 lines" complaint): each `collabAgentToolCall` (`spawnAgent`, `wait`, `sendInput`, `closeAgent`) plus each `subAgentActivity` (`started`/`interacted`/`interrupted`) becomes its own work row (`makeRow`, reducer:219-247). Payload carries `receiverThreadIds`, `agentsStates{message}`, `prompt`, `model` — enough to key ONE chip per agent thread id and mutate its state in place (official app: "started working" → "finished" text mutation, shimmer while live).

`fileChange` items carry per-file `changes[] {path, kind, diff}` (`CodexSchemaFileUpdateChange`) — the reducer keeps only paths + one diff string; enough data exists for a per-file diff card (+n/−n counts, expand/collapse).

## E. Ranked plan

1. **Bubble intrinsic width + shared column metrics** (A1, A5) — small, most visible.
2. **Spacing scale 16/4 + verbatim user text** (A2, A3) — small.
3. **Code block header + copy feedback** (A4, A7) — small.
4. **Unified in-place lifecycle chip** keyed on item id (D: command/mcp/webSearch/fileChange/subagent; fixes stacking + frozen chips + vanish-mid-turn) — medium.
5. **Canonical markdown pipeline** (B: links, lists, tables; then bounded syntax highlighting) — medium.
6. **Inline approval card** (B/D) — medium.
7. **Directive renderer** (C: created-thread chip first, then git/PR chips, code-comment card) — medium.
8. **Diff card fed by fileChange changes[] + turn/diff/updated** — medium/large.
9. **Animations (diffable apply + shimmer), loading/error states, token/rate-limit meters, scroll anchoring** — follow-ups.
