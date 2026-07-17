# Transcript V2 UI/UX Overhaul — Implementation Plan

This plan is written so another model can execute it end-to-end without re-deriving context. Read this whole file before starting. Companion research documents: `docs/transcript-ui-audit.md` (findings + evidence) and `LUNA-UX-NOTES.md` (design rationale). Work top-to-bottom; phases are ordered by dependency and impact. Commit after each phase with a passing build.

---

## 0. Context, architecture contract, and ground rules

### Architecture (do not violate)

The transcript renders through this pipeline:

```
app-server JSON-RPC notifications
  → CodexTranscriptReducerV2 (Sources/CodexCoreUI/TranscriptV2/CodexTranscriptReducerV2.swift)
      produces CodexTranscriptV2 { turns: [CodexTurnV2 { userMessage, narrative: [CodexNarrativeEntry], finalAnswer, liveTail, status }] }
  → CodexTranscriptRenderProjector (actor, Sources/CodexCoreUI/TranscriptV2/AppKit/CodexTranscriptRenderProjection.swift)
      flattens turns into flat CodexTranscriptRenderItem values with stable IDs, content-fingerprint revisions,
      cached prepared NSAttributedStrings, and pre-measured heights
  → CodexTranscriptListHost.Coordinator (Sources/CodexCoreUI/TranscriptV2/AppKit/CodexTranscriptCollectionView.swift)
      NSCollectionViewDiffableDataSource<String, CodexTranscriptRenderItemID>; when section/item structure is
      unchanged it does targeted reconfigure of changedItemIDs only (line ~284), else applies a diffable snapshot
  → CodexTranscriptCollectionItem (Sources/CodexCoreUI/TranscriptV2/AppKit/CodexTranscriptCollectionCell.swift)
      one reusable cell class that shows exactly one of: preparedText / code / workHeader / workRow / productTool / footer
```

Ingress: `CodexChatRuntimeSession.swift:496-501` routes notifications into `transcriptSessions.apply(...)` and `subagentStoreV2.apply(...)`. History restore goes through `reducer.restoreHistory`. `CodexAgentStateMapping.swift:145` synthesizes `item/started`/`item/completed` calls.

Performance invariants — every change in this plan must respect these:
1. **Stable item IDs, revision-gated updates.** An in-place update = same `ItemDraft.id`, changed `fingerprint`. Never mint a new item ID for a state change of the same logical entity.
2. **No work on the scroll path.** All parsing/measuring happens in the projector actor; cells only bind pre-prepared values.
3. **Cache keys** for prepared text are `theme.fingerprint + style + digest(content)` (projection file, `cachedPreparedText`, line ~790). New renderers must go through this.
4. **No `NSHostingView` in high-count rows.** Hosting is allowed only for rare card-type items (product tool today; diff card / review card in this plan). Chips are pure AppKit.
5. Heavy detail (command output, diffs, MCP payloads) is only materialized when its item is expanded (existing pattern: `expandedRowIDs`, detail child item `":row:<id>:detail"`).

### Verification commands

- Build: `swift build --target CodexCoreApp` (or `just build`)
- Tests: `swift test` (targets: `CodexCoreTests`, `CodexCoreUITests`). UI-side tests live in `Tests/CodexCoreUITests/` — e.g. `CodexTranscriptCollectionViewTests.swift`-style tests use `Coordinator.waitForProjectionForTesting()`, `renderedItemIDsForTesting`, `collectionItemForTesting(_:)`, and the `*ForTesting` hooks on the cell.
- Run app: `just run` (kills old instance, rebuilds, launches).
- After each phase: build + full test suite + a manual `just run` sanity check against a real thread.

### Theme access

AppKit theme values come from `CodexTranscriptAppKitTheme` (projection file, lines 115-176), which is derived from `CodexAgentTheme`. When you need a new color/metric, add it to BOTH `CodexAgentTheme` (SwiftUI side, find it via `theme.colors.*` usages) and `CodexTranscriptAppKitTheme`, and **include it in `fingerprint`** if it affects rendered output.

Design targets extracted from the official Codex app (see audit doc §design-reference): user bubble = translucent fill (foreground at ~5% alpha), radius 16, padding 12h/8v, max width 77% of column, hugging content, right-aligned; turn gap 16px, intra-group gap 4px; paragraph gap ~20px; list indent 24px; running states use a text shimmer, not a spinner; completed work collapses into a clickable "Worked for Ns" row.

---

## Phase 1 — Layout correctness (bubble, spacing, centering, verbatim user text)

### 1.1 Single source of truth for column geometry

**Problem:** three places compute widths with different insets: projector `contentWidth = max(280, min(availableWidth - 48, theme.transcriptOuterMaxWidth))` (projection ~206), coordinator `sizeForItemAt` returns `availableWidth - 32` (collection view ~197), and the cell recomputes `outerWidth = max(200, min(view.bounds.width - 48, theme.transcriptOuterMaxWidth))` and centers on the **cell's** midX (cell ~324-326). Net effect: the column sits ~16px left of viewport center.

**Change:** add to the projection file:

```swift
struct CodexTranscriptColumnMetrics: Sendable, Equatable {
    var viewportWidth: CGFloat
    static let horizontalMargin: CGFloat = 24   // symmetric gutter each side
    var cellWidth: CGFloat { max(1, viewportWidth) }                 // cells span the viewport
    func outerWidth(_ theme: CodexTranscriptAppKitTheme) -> CGFloat {
        max(280, min(viewportWidth - Self.horizontalMargin * 2, theme.transcriptOuterMaxWidth))
    }
}
```

- Projector: replace the ad-hoc `contentWidth` computation with `CodexTranscriptColumnMetrics(viewportWidth: availableWidth).outerWidth(theme)`.
- Coordinator `sizeForItemAt`: return `NSSize(width: metrics.cellWidth, height: item.measuredHeight)` — i.e. **full viewport width**, no `- 32`. (Cells spanning full width is fine; content is positioned inside the cell.)
- Cell `viewDidLayout`: compute `outerWidth` via the same metrics type from `view.bounds.width`, and center on `view.bounds.midX + contentHorizontalOffset` — because the cell now spans the viewport, cell-midX == viewport-midX and the 16px bias disappears.
- Delete the three divergent formulas; all call sites use the metrics type.

**Acceptance:** with a wide window, the transcript column's left and right gutters are equal (measure via screenshot or by logging `contentX` for a full-width item vs viewport width).

### 1.2 User bubble hugs its text

**Problem:** `.user` drafts get `maxWidthKind: .user` → fixed `min(contentWidth, theme.userBubbleMaxWidth)` (projection ~612); the cell paints `backgroundView.frame = contentFrame` at that full width (cell ~327-333), so short messages show a wide empty bubble while the footer under it right-aligns to the true edge.

**Change (projector-side intrinsic width):**
1. In `CodexTranscriptRenderItem` add `var intrinsicContentWidth: CGFloat?` (and to `ItemDraft`).
2. In the projector, when building the user draft (after `prepared` exists, ~line 287-306): measure the prepared text's natural width at the max width:
   ```swift
   let maxTextWidth = min(contentWidth, theme.userBubbleMaxWidth) - 28   // 14pt inset each side (cell insetX)
   let bounds = prepared.attributedString.boundingRect(
       with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
       options: [.usesLineFragmentOrigin, .usesFontLeading])
   draft.intrinsicContentWidth = min(theme.userBubbleMaxWidth, ceil(bounds.width) + 28)
   ```
   This runs in the actor, once per revision, and is cheap relative to the existing height measurement (which already does a boundingRect for the same string — compute both from one call: refactor `Self.measure` to also return width for `.user` drafts, or measure here and pass `fixedHeight`).
3. Cell `viewDidLayout`: `let contentWidth = min(item.intrinsicContentWidth ?? item.maxContentWidth, outerWidth - item.indentation)`. Trailing alignment already places `contentX = outerMinX + outerWidth - contentWidth`, so the bubble now hugs and stays flush right.
4. Update `theme.userBubbleMaxWidth` semantics: set it to `0.77 * outerWidth` dynamically instead of a fixed 560 — do this in the projector (`min(contentWidth * 0.77, theme.userBubbleMaxWidth)`) so narrow windows behave.

**Acceptance:** a one-word user message renders as a small pill flush against the right column edge, directly above its timestamp; a long message wraps at ≤77% of the column. Existing test hooks: add a UI test asserting `intrinsicContentWidth < maxContentWidth` for a short message and that trailing `contentX + contentWidth == outerMaxX` (expose via a `*ForTesting` accessor on the cell if needed).

### 1.3 Verbatim user text

**Problem:** user text goes through `prepareMarkdown` with style `"user-markdown"` (projection ~288-296).

**Change:** replace with `Self.preparePlain(user.text, font: theme.bodyFont, color: theme.textPrimary, theme: theme)` and style key `"user-plain"`. Keep the fingerprint including the raw text. Do NOT change `copyText` (already raw).

**Acceptance:** send a message containing `*stars*`, `# heading`, `` `ticks` `` — it displays exactly as typed.

### 1.4 Spacing scale

**Problem:** `minimumLineSpacing = 0` (container init, collection view ~547) + section insets top 14 / bottom 14 (~205). Everything inside a turn butts together; turns are 28px apart (14+14) in effect but items are 0.

**Change (keep line spacing 0 — heights are pre-measured; encode spacing in measured heights instead, which keeps the invalidation model simple):**
1. In the projector, add a `verticalPadding` concept per draft kind: prose blocks keep their current +4; work rows keep fixed 30; **add a 4px inter-item rhythm by increasing fixed heights**: work header 28→32, group header 24→28, live tail 24→28.
2. Turn separation: change section insets to `top: section == 0 ? 0 : 8, bottom: 8` and give the **first item of each turn** (user bubble or work header) an extra 8px of measured top padding — OR simpler and preferred: set section insets to `NSEdgeInsets(top: section == 0 ? 0 : 16, left: 0, bottom: 0, right: 0)` and add `bottom: 0`; 16px between turns, once, matching the official app's `--conversation-item-gap: 16px`.
3. Space above the final answer: in the projector, when a turn has both work items and a final answer, the first final-answer draft gets +8 measured height with the text laid out at the bottom (the cell already insets prose by `insetY: 2`; bump `.finalAnswer`-role first block to `insetY` handled via measure verticalPadding — keep it simple: add an 8px-high spacer only if visually needed after inspection).

Keep this phase iterative: implement, `just run`, compare against the official app screenshots, tune the three constants (turn gap, intra-turn gap, answer gap), then freeze them as named constants on `CodexTranscriptColumnMetrics` or the theme (`spacing.turnGap`, `spacing.itemGap`).

**Acceptance:** visual — a turn reads as one grouped paragraph; 16px clear separation between turns; no double-spacing regressions in long threads. All existing `CodexCoreUITests` pass (heights changed — update any test asserting exact `measuredHeight`).

---

## Phase 2 — Code block chrome + copy feedback

### 2.1 Code block header band

**Problem:** AppKit code item (cell ~264-284, layout ~341-347) draws one background, a disabled language `actionButton`, and an icon-only copy button. The SwiftUI original (`CodexMessageContentView.swift:36-83`, `CodexCodeBlock`) had a distinct header band using `theme.colors.codeHeader` and a Copy button that animates to "Copied".

**Change (pure AppKit, in the cell):**
1. Add a `codeHeaderView = NSView()` (layer-backed) to the cell, hidden by default, reset in `prepareForReuse`.
2. In `configure` for `item.code != nil`: show `codeHeaderView` with `theme.codeHeader` background; language label (reuse `actionButton`, keep disabled-as-label OR replace with an `NSTextField(labelWithString:)` — replace it: the disabled button is a known affordance bug); copy button stays.
3. In `viewDidLayout` for code items: header frame = top 32px of `contentFrame` with corner radius on top corners only (`maskedCorners`); text frame starts below it (adjust the existing `y: 10, height: bounds.height - 50` math to `height - 42` under a 32px header). Update `Self.measure` code branch: header contributes to the +58 vertical padding — recheck the constant so measured and laid-out heights agree (`max(82, ceil(bounds.height) + 58)` → verify against new layout, adjust to header(32) + padding(10+10) + text).

### 2.2 Copied ✓ feedback everywhere

**Change:** add to the cell a helper:
```swift
private func flashCopyConfirmation(_ button: NSButton) {
    let original = button.image
    button.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
    button.contentTintColor = appKitTheme?.success
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak button, weak self] in
        button?.image = original
        button?.contentTintColor = self?.appKitTheme?.textTertiary
    }
}
```
Call it from `copyItem()` / `copyTurn()` with the button that triggered (change the selectors to `@objc private func copyItem(_ sender: Any?)` and check `sender as? NSButton`). Cover: `copyButton`, `footerCopyItemButton`, `footerCopyTurnButton`.

**Acceptance:** clicking any copy affordance shows a checkmark for ~1.2s then reverts; clipboard contains the right text (existing `copyItemForTesting` tests still pass; add one asserting the image swap via a new `copyButtonImageNameForTesting`).

---

## Phase 3 — Markdown pipeline quality

All changes in `CodexTranscriptRenderProjection.swift` (`prepareMarkdown`, `prepare(block:)`) plus `CodexSelectableTranscriptTextView`.

### 3.1 Explicit link styling + click policy

1. In `prepareMarkdown` (~882): after applying base attributes, enumerate `.link` attributes (Foundation's markdown parser DOES emit `.link` for `[text](url)`), and add `.foregroundColor: theme.accent` and `.underlineStyle: NSUnderlineStyle.single.rawValue` on those ranges. (Add `linkColor` to both themes if `accent` reads poorly; include in fingerprint.)
2. In `CodexSelectableTranscriptTextView.init` (cell ~29-42): set `isAutomaticLinkDetectionEnabled = false` when bound content already has explicit links; set `linkTextAttributes = [.foregroundColor: accent, .underlineStyle: ...]`, `displaysLinkToolTips = true`. Keep automatic detection ON only for plain-role text (expandedOutput). Practical route: make it a `configureLinkAppearance(theme:)` method called from `configure`.
3. URL opening: `NSTextView` handles `.link` clicks natively via `clickedOnLink` → default opens with NSWorkspace. That is acceptable; no delegate needed unless tests show otherwise.

### 3.2 Nested list indentation via paragraph styles

**Problem:** `prepare(block: .list)` (~849-853) encodes depth as two leading spaces and renumbers with the flat item index.

**Change:** build the list manually instead of re-parsing through markdown:
```swift
case .list(_, let ordered, let items):
    let result = NSMutableAttributedString()
    var counters: [Int: Int] = [:]                      // per-depth ordered counters
    for item in items {
        counters[item.depth, default: 0] += 1
        for d in (item.depth + 1)...8 { counters[d] = 0 }  // reset deeper counters
        let marker = ordered ? "\(counters[item.depth]!). " : "•  "
        let style = NSMutableParagraphStyle()
        style.lineSpacing = theme.lineSpacing
        style.paragraphSpacing = 4
        let indent = CGFloat(item.depth) * 24 + 0
        style.firstLineHeadIndent = indent
        style.headIndent = indent + 24                   // wrap alignment past the marker
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 24)]
        // marker + inline-markdown-rendered item text, then "\n"
        ...
    }
```
Render each item's text through `prepareMarkdown` (inline emphasis/code still works), then override its paragraph style with the computed one. Keep the existing cache (the whole list block is one cached prepared text keyed by the block digest — unchanged).

### 3.3 Paragraph rhythm

In `paragraphStyle(_:)` (~992) add `style.paragraphSpacing = 10` (approximating the official 20px `p+p` gap at our type size — tune visually). Verify `combine(...)` separator logic (~861-880) doesn't double it; if it does, drop the `"\n\n"` separator to `"\n"`.

### 3.4 Selection during streaming

**Problem:** `allowsTextSelection = !turnIsStreaming && ...` (projection ~229).

**Change:** drop the `turnIsStreaming` term: `let allowsTextSelection = draft.footer == nil && (draft.preparedText != nil || draft.code != nil)`. The cell already preserves selection across rebinds when identity is preserved (`configure` ~219-222, `bind(_:preserving:)`), and the projector emits stable IDs for completed blocks (only the tail block's revision churns). Also remove the `:selectable:` component from the fingerprint (it exists solely to flip revisions when streaming ends — no longer needed) — this also kills a gratuitous full-turn reconfigure at stream end.

Risk note: selection inside the *actively appending* tail item will shift as text grows — acceptable; the ranges the user selects are usually complete blocks above the tail.

### 3.5 Syntax highlighting (bounded, last in this phase)

1. New file `Sources/CodexCoreUI/TranscriptV2/AppKit/CodexCodeHighlighter.swift`:
   ```swift
   protocol CodexCodeHighlighter: Sendable {
       func highlight(_ code: String, language: String?, theme: CodexTranscriptAppKitTheme) -> NSAttributedString?
   }
   ```
   Implement `CodexRegexCodeHighlighter` with small tokenizers for: swift, javascript/typescript, python, json, bash/shell/zsh, diff (lines starting `+`/`-`/`@@`). Token classes: keyword, string, comment, number → colors from four new theme slots (`codeKeyword`, `codeString`, `codeComment`, `codeNumber`; add to both themes + fingerprint). Return `nil` for unknown languages (falls back to plain).
2. Wire in the projector, NOT the cell: today code blocks skip prepared-text (cell binds raw string, cell ~269-277). Change: the projector prepares code text too — `draft.preparedText` for code items = highlighted (or plain) attributed string, cached via `cachedPreparedText(style: "code-\(language)")`. The cell's code branch then binds `item.preparedText` instead of constructing an attributed string inline. **Do not highlight while the source block is still streaming** — `CodexBlockProjector.project` already marks streaming; pass that through the draft and highlight only when the block is stable.
3. Cap: if `code.count > 40_000` chars, skip highlighting (plain), and truncate display via the existing `codexAppKitDisplayPrefix` pattern with a "Show all" affordance (reuse the row-expansion mechanism: emit the code item collapsed with a `toggleRow` action when oversized).

**Acceptance for phase 3:** links are colored/underlined and clickable; nested ordered lists number correctly (`1.`, `2.` with nested `1.` restarting); text can be selected while a turn streams; code blocks show keyword/string coloring in a fenced swift block; `swift test` green.

---

## Phase 4 — Unified in-place lifecycle chips (the "3 lines per agent" fix)

This phase changes the reducer so each logical operation is ONE row whose state mutates, and upgrades row rendering from text-button lines to real chips.

### 4.1 Reducer: correlate subagent lifecycle into one row

**Problem:** `makeRow` (reducer ~203-253) creates a distinct row per `collabAgentToolCall` (spawnAgent/wait/sendInput/closeAgent) and per `subAgentActivity` (started/interacted/interrupted). Each has its own item id → separate rows stack up.

**Change:** in `applyWork` (~182), before the generic row upsert, add a coalescing step for collab rows:
1. Extend `CodexCollabAgentRowV2` with `var timeline: [CodexCollabActionV2]` (append-only) and keep `action` = latest.
2. New reducer helper `mergeCollabRow(_ incoming: CodexCollabAgentRowV2, turn: Int) -> Bool`: find an existing `.collabAgent` row in the turn whose `agentThreadIDs` intersects `incoming.agentThreadIDs` (or, for `subAgentActivity` rows which carry `agentPath`/`agentThreadId` in `agentNames`, match on that). If found: update in place — `action = incoming.action`, `status = incoming.status`, merge `agentMessages`, append to `timeline`, keep the ORIGINAL row id (stable item identity → in-place reconfigure downstream). Return true.
3. `canAppend` special-casing for collab rows (~337) becomes unnecessary for merged rows; keep it as fallback.
4. Label (models `CodexCollabAgentRowV2.label`, models file ~103-114): derive from latest action + status: created+inProgress → "Agent <name> · working", sentInput → "Agent <name> · messaged", waited+completed → "Agent <name> · finished", interrupted → "Agent <name> · interrupted". Multi-agent: "3 agents · working".
5. `spawnAgent` with `pendingWorktreeId`-style payloads and later `wait` events referencing the resolved thread id must still merge: match on intersection of receiver ids OR on `senderThreadId+tool` sequence within the same turn when ids are absent (fallback: if the turn has exactly one live collab row, merge into it).

**Tests:** extend `Tests/CodexCoreUITests/` reducer tests (find existing reducer tests via `grep -l ReducerV2 Tests -r`): feed a spawnAgent item/started, then wait item/completed, then sendInput item/completed with the same receiverThreadIds → assert exactly ONE `.collabAgent` row whose `timeline` has 3 entries and whose row id equals the first item's id.

### 4.2 Keep a live status chip visible while the answer streams

**Problem:** `shouldRenderWork` (projection ~1011-1018) returns false for a working turn once `finalAnswer` is non-empty — running work disappears mid-turn.

**Change:** when `case .working` and finalAnswer has text, still emit the work header (and the in-progress rows only) IF any row `isInProgress`. Concretely: `shouldRenderWork` returns true also when `turn.narrative.contains { if case .workGroup(let g) = $0 { g.rows.contains(where: \.isInProgress) } else { false } }`. In the expanded-narrative loop, when this "tail mode" is active (working + non-empty finalAnswer), emit only in-progress rows (skip completed ones) so the transcript shows: user → compact live chip(s) → streaming answer.

### 4.3 Chip visual upgrade (cell)

**Problem:** work rows are a single attributed-title `NSButton` (cell `workRowTitle` ~604-620) — glyph + label + unicode chevrons; inert rows look identical to actionable ones; language of state is only a colored glyph.

**Change:** give work rows a real chip layout inside the existing cell (no new cell class; still one item kind):
1. Add cell subviews (lazily created, reused): `chipIconView (NSImageView)`, `chipLabel (NSTextField)`, `chipDurationLabel`, `chipDisclosureView (NSImageView, chevron.right/chevron.down)`, `chipBackground (NSView, layer, corner radius = height/2? no — use theme.cardRadius; full-rounded pills are for subagent links only)`.
2. `configure` workRow branch: icon by row kind+status — running: `arrow.triangle.2.circlepath` (or kind icon) tinted `theme.running`; completed: kind icon (`terminal` for commands, `doc.text` for file edits, `magnifyingglass` for search, `app.connected.to.app.below.fill` for MCP, `person.2` for agents) tinted `textTertiary` with a small leading `checkmark` only on hover-expandable rows — keep it simple: statusColor-tinted kind icon; failed: `exclamationmark.triangle` tinted `danger`.
3. Rows with `hasDetail || isSubagentLink` get pointer-on-hover (`NSTrackingArea` exists at the view level; set `chipBackground` visible on hover with `theme.surfaceSunken`) and a trailing chevron/arrow icon; rows without detail render as a plain non-button label (`actionButton.isEnabled = false` AND no hover background).
4. **Shimmer for in-progress**: implement `CodexShimmerTextField` (or a `CALayer` mask on `chipLabel`): a `CAGradientLayer` with a moving highlight animated via `CABasicAnimation` on `locations`, applied as `chipLabel.layer.mask` only while `status == .inProgress`. Start/stop in `configure`; stop in `prepareForReuse`. This replaces any spinner; matches official app.
5. The work row **fixed height stays 30** (projection `fixedHeight: 30`) so no measurement changes.
6. Keep `updateWorkingHeader` ticker mechanism untouched (collection view ~502-524) — it only touches the header title.
7. To pass richer data than `CodexTranscriptWorkRowRender` currently carries, extend it with `var kind: CodexWorkRowKind` (enum: command, fileChange, mcp, webSearch, agent, other) and `var isActionable: Bool` — set in the projector from the row case.

**Acceptance:** run a real task (`just run`): a command shows one shimmering chip that flips to a check + duration in place; spawning a subagent shows ONE chip mutating "working → finished" with an ↗ open affordance; nothing stacks; expanding shows output below; collapsed old turns unchanged. `swift test` green (update `CodexAccessibilityLabelTests` for new labels).

---

## Phase 5 — Inline directive rendering (`::created-thread{...}`, git, PR, code-comment)

Full directive inventory + payload semantics: `docs/transcript-ui-audit.md` §C. Directives appear on their own line inside assistant text (finalAnswer or commentary prose).

### 5.1 Parser (CodexCore, pure + tested)

New file `Sources/CodexCore/Parser/CodexInlineDirective.swift`:
```swift
public struct CodexInlineDirective: Sendable, Equatable {
    public var name: String                      // "created-thread", "git-commit", ...
    public var attributes: [String: String]      // key -> value (quotes stripped), numbers kept as strings
    public var range: Range<String.Index>        // range of the full ::name{...} in the source line
}
public enum CodexInlineDirectiveParser {
    /// Matches ::name{k="v" k2=3 ...} — one per line, tolerant of unknown keys.
    public static func parse(line: String) -> CodexInlineDirective?
    public static func split(text: String) -> [(text: String, directive: CodexInlineDirective?)]
    // split returns the text partitioned into plain-text segments and directive lines, in order.
}
```
Regex: `^\s*::([a-zA-Z0-9-]+)\{(.*)\}\s*$` per line; attributes via `([a-zA-Z][a-zA-Z0-9]*)=("([^"]*)"|[^\s}]+)`. Handle escaped quotes inside values (`\"`). **Tests first** (`Tests/CodexCoreTests/CodexInlineDirectiveParserTests.swift`): all real examples from the audit doc — `created-thread` (all three key variants), `git-create-pr` with `isDraft=true`, `code-comment` with multiline-ish body and priority, `archive-thread{}` empty, non-directive lines containing `::` mid-text must NOT match, developer-doc template forms should parse (they're only excluded upstream by role, not by the parser).

### 5.2 Block-level integration

Directives must become their own render items so they get chip UI and don't disturb prose caching. Integrate at the **projector** level (not the reducer — history restore and streaming both flow through the projector, so one integration point covers both):

In `projectBlocks`' consumers (`messageDrafts` path, projection ~617-668): before block projection, run `CodexInlineDirectiveParser.split` on the source text; project each plain-text segment through `CodexBlockProjector` as today (namespacing cache by segment index), and interleave directive drafts. Simpler and equally correct alternative (choose this if `CodexBlockProjector` internals resist segmenting): keep block projection on the full text but post-process the produced `.prose` blocks — a prose block whose text is exactly a directive line becomes a directive draft; a prose block containing directive lines among prose is split. The `CodexBlockProjector` is line-based (see audit §B), so directive lines will already sit in prose blocks; splitting prose text on directive lines is safe.

New draft/render kinds:
- `CodexTranscriptRenderItem.directive: CodexTranscriptDirectiveRender?`
- ```swift
  struct CodexTranscriptDirectiveRender: Sendable, Equatable {
      enum Kind: Sendable, Equatable {
          case createdThread(threadID: String?, pendingWorktreeID: String?)   // clientThreadId maps into threadID after strip
          case gitAction(verb: String, branch: String?, cwd: String?)          // commit/stage/create-branch/push
          case pullRequest(url: String, branch: String?, isDraft: Bool)
          case codeComment(title: String, body: String, file: String, start: Int?, end: Int?, priority: Int?)
          case unknown(name: String)                                            // render as muted small text, not raw
      }
      var kind: Kind
  }
  ```
- Item IDs: `"\(sourceID):directive:\(index)"`; fingerprint = the raw directive string. Fixed heights: chips 32, code-comment card measured (title+body via prepared text) — reuse the existing measure path with a card layout constant.

### 5.3 Directive chip rendering (cell)

Reuse the Phase 4 chip subviews. In `configure`:
- **createdThread**: icon `arrow.triangle.branch`, label "Created thread · <short-id>" (short = first 8 chars after last `-`… use the existing `shortAgentName` logic in the reducer — move it somewhere shared), trailing ↗. Action: new `CodexTranscriptRenderAction.openSubagent(threadID:)` — ALREADY EXISTS; wire directly. For `pendingWorktreeId` and legacy `client-new-thread:` ids: strip the `client-new-thread:` prefix; if the id can't resolve to a thread, render the chip disabled with tooltip "Thread pending".
- **gitAction**: icon per verb (`checkmark.seal` commit, `tray.and.arrow.up` push, `arrow.triangle.branch` branch, `square.stack.3d.up` stage), label "Committed" / "Pushed <branch>" / "Created branch <branch>" / "Staged changes". Non-clickable (status chips).
- **pullRequest**: icon `arrow.up.right.square`, label "PR · <branch>" + "· draft" when `isDraft`; click opens URL: add `case openURL(String)` to `CodexTranscriptRenderAction`, handle in coordinator `perform(_:)` with `NSWorkspace.shared.open(URL(...))` (guard scheme == https).
- **codeComment**: this is a card, not a chip. Layout inside the cell: title bold + right-aligned `P<n>` badge (small rounded label, color: P0/P1 danger, P2 running, P3 textTertiary), body as prepared markdown below, footer line `<file>:<start>` in codeFont + a "Copy location" button. Body goes through `prepareMarkdown` with the standard cache. Height measured in projector (title + body + footer + paddings). Clicking the file line: `case openFile(path: String, line: Int?)` action — coordinator handler opens via `NSWorkspace` (`open -R` equivalent: `NSWorkspace.shared.selectFile`)… check whether the app has a file-preview facility (`CodexFilePreviewLoaderTests` exists — grep for its production type and use that route if it accepts absolute paths); otherwise fall back to revealing in Finder.
- **unknown**: muted `captionFont` text `"<name>"` with tooltip showing the raw string — never show raw `::…{…}` (but keep raw in `copyText`).

`copyText` for every directive item = the raw directive string (debuggability).

**Acceptance:** open the historical thread from the user's screenshot (`019f670d-ce61-7cb2-a1eb-3b9bc5256026` era): `::created-thread{...}` lines render as chips, clicking opens the subagent panel/thread; a session with `git-create-pr` shows a clickable PR chip; unit tests for the parser + a projector test feeding text with an embedded directive asserting item kinds and order (prose, directive, prose).

---

## Phase 6 — Per-file diff card

### 6.1 Diff model + parser

New file `Sources/CodexCoreUI/TranscriptV2/CodexDiffModel.swift`:
```swift
struct CodexDiffFile: Sendable, Equatable { var path: String; var kind: String; var added: Int; var removed: Int; var hunks: [CodexDiffHunk] }
struct CodexDiffHunk: Sendable, Equatable { var header: String; var lines: [CodexDiffLine] }
struct CodexDiffLine: Sendable, Equatable { enum Kind { case context, add, remove }; var kind: Kind; var text: String }
enum CodexUnifiedDiffParser { static func parse(_ diff: String) -> [CodexDiffFile] }
```
Parser: split on `diff --git` / `+++`/`---` headers, hunks on `@@`. Tolerant: unparseable input → one pseudo-file with the raw text as context lines. Tests with a real multi-file diff captured from a session (grep a session rollout for a `fileChange` item's `changes[].diff`).

### 6.2 Rendering

Reducer already stores `CodexFileChangeRowV2 { files, status, durationMs, diff }`. Projection today: label "Edited a.swift · b.swift" row + raw diff text as expanded detail (~1092-1095 `detail(for:)` returns `value.diff`).

**Change:**
1. Collapsed row (unchanged mechanics, better label): "Edited 3 files · +42 −18" — compute counts by parsing the diff ONCE in the projector when building the row label; cache parse result per row revision in the projector (`diffByRowFingerprint: [String: [CodexDiffFile]]`, pruned with the other caches at ~492-500).
2. Expanded detail: instead of one `preparePlain` blob, emit per-file child items: `":row:<id>:diff:<fileIndex>"` — each a code-kind item (monospaced, horizontally scrollable — reuses ALL existing code-item cell machinery) whose prepared text colors `+` lines with `theme.success`, `-` with `theme.danger`, hunk headers with `textTertiary` (prepare in projector via `cachedPreparedText(style: "diff-file")`). Each file item gets a small header line (path + `+n −n`) as its first attributed line (bold codeFont) — no new cell layout needed.
3. Cap each file's rendered hunks at 400 lines with the existing `codexAppKitDisplayPrefix` truncation + full text still in `copyText` ("Copy patch").

**Acceptance:** ask the app to edit files; expanding "Edited … files" shows per-file sections with colored +/- lines; copy on a file item yields its full patch; parser unit tests green.

---

## Phase 7 — Inline approval card

Approvals currently live outside the transcript (`CodexPromptStateSession` / `CodexApprovalRequestsPanel` — grep `CodexApprovalRequestsPanel` for the surface; server requests: `item/commandExecution/requestApproval`, `applyPatchApproval`, `execCommandApproval`, `item/fileChange/requestApproval`).

1. Find where approval requests are received and stored (`Sources/CodexCore/Client/Approvals.swift` + `CodexPromptStateSession`). Add the pending approvals for the thread into `CodexThreadUIPresentation` (grep its definition — it already carries `expandedRowIDs`, scroll state, etc.) so the projector sees them.
2. Projector: for each pending approval belonging to the last working turn, emit an item `":approval:<requestID>"` after the work header — icon `hand.raised`, amber tint (add `warning` color to both themes), label "Approval needed — <first line of command/patch summary>", two real `NSButton`s "Allow" / "Deny".
3. Cell: approval branch with the two buttons; actions route via new `CodexTranscriptRenderAction.resolveApproval(requestID: String, approve: Bool)` → coordinator → a new closure `onResolveApproval` plumbed through `CodexTranscriptListHost` (same pattern as `onEditUserMessage`) → whatever `CodexApprovalRequestsPanel` calls today (reuse its resolve path exactly; do not invent a second protocol call).
4. When the approval resolves (serverRequest/resolved or local action), the presentation drops it → item disappears on next projection.

**Acceptance:** set approval mode to `.ask` (see memory: apps opt into `.ask`), trigger a command approval; the card appears inline under the working header, Allow proceeds, the card disappears; the side panel still works.

---

## Phase 8 — Motion, states, and finishing touches

Order within this phase is free; each item is independent.

1. **Animated diffs:** `dataSource.apply(diffable, animatingDifferences: true)` (collection view ~306) — but ONLY when `!switchedThread && !presentation.isPinnedToBottom` is false… keep it simple: animate when the visible region is affected and the user is not mid-scroll-restore; verify no jitter while pinned during streaming (structure changes while streaming are rare — deltas take the reconfigure path). If pinned-follow jitters, animate only non-pinned applies.
2. **Turn expand/collapse animation:** in `perform(.toggleWork/.toggleRow)` the reprojection lands as a structural apply — with (1) this animates for free.
3. **Empty/loading/error states:** in `requestProjection`'s catch (collection view ~221-225), on non-cancellation errors set a coordinator flag surfaced through `CodexTranscriptListHost` (add optional `onProjectionError: ((String) -> Void)?`) so the SwiftUI wrapper (`CodexTranscriptViewV2.swift`, which still owns the empty state at ~55-61) can show an error banner with a Retry button (retry = `requestProjection(width: lastProjectedWidth)`). Add distinct empty-state text when the thread is still loading history vs genuinely empty (presentation should carry `isLoadingHistory` — check `CodexThreadUISessionStore` for an existing flag before adding one).
4. **Jump button "new output" badge:** in `finishApply`, if `!presentation.isPinnedToBottom` and the apply inserted/changed items in the LAST section, set `container.jumpButton.title`/badge — simplest: swap the button image to `arrow.down.circle.fill` with `contentTintColor = accent` until the next `jumpToLatest`/pinned scroll (`updateJumpButton` resets).
5. **Scroll anchoring on expansion:** in `perform(_:)` before triggering reprojection, record the topmost visible item id + its offset from the viewport top (`collectionView.indexPathsForVisibleItems` → min indexPath → `layoutAttributesForItem.frame.minY - clipView.bounds.origin.y`); in the completion of the structural apply, if not pinned, find the item's new frame and `setBoundsOrigin` so its on-screen offset is unchanged. Guard: only when the toggled item is ABOVE the anchor.
6. **Token usage meter (optional, small):** `thread/tokenUsage/updated` already reaches other stores (see `CodexChatRuntimeSession.swift:496-501` neighborhood and `CodexStructuredPanelModels.swift`). Surface `total.totalTokens / modelContextWindow` as a thin progress element wherever thread status is already shown (NOT in the transcript). Skip if the header UI has no obvious slot — file a TODO instead.
7. **Cleanup:** delete `LUNA-UX-NOTES.md` reference from repo root — move its content into `docs/` or delete after Phase 8 (it's research scratch; the audit doc is canonical). Remove now-dead SwiftUI paths ONLY if the transcript no longer references them (`CodexTurnViewV2.userBubble` etc. — verify with grep before deleting; `CodexWorkBlockViewV2.duration`/`showsWorkingDuration` ARE used by the projector, keep them).

---

## Execution notes for the implementing model

- After EVERY sub-phase: `swift build --target CodexCoreApp && swift test`. Fix forward before proceeding.
- Visual verification: `just run`, open a real historical thread (sessions exist under `~/.codex/sessions`), and compare against the design targets in §0. The two user-reported bugs (bubble alignment, raw `::created-thread`) are the acceptance bar for Phases 1 and 5.
- When touching `CodexTranscriptAppKitTheme`, ALWAYS update `fingerprint` if the new value affects output — otherwise theme changes won't invalidate caches.
- When adding fields to `CodexTranscriptRenderItem`/`ItemDraft`, include them in the draft `fingerprint` if they affect pixels; the revision system is the only thing that triggers cell updates.
- Do not regenerate anything under `Sources/CodexCore/Generated/` (owned by `Tools/regenerate.sh`).
- Keep commits per phase: `git commit` after each green phase with message `Transcript V2: <phase title>`.
- If a described anchor has drifted (line numbers are from July 2026), locate by symbol name — all symbols in this plan are exact.

---

## Phase 9 — User-message enrichment layer (attachments, harness templates, hover references)

Goal: user messages containing harness-injected structure (e.g. `# Files mentioned by the user:` / `## <file>.png: /path` / `## My request for Codex: <text>`) must render as: attachment thumbnails ABOVE the bubble + only the real request text INSIDE the bubble, with reference tokens like `(image 1)` / `[Image #1]` hover-highlighting the matching attachment. Design for many such templates, not just this one.

1. **Parser** (`Sources/CodexCore/Parser/CodexUserMessageEnricher.swift`): ordered registry of extractors, each `(String) -> CodexEnrichedUserMessage?`; first match wins, no match = passthrough.
   `CodexEnrichedUserMessage { displayText: String; attachments: [Attachment { name, path, kind: .image/.file }]; references: [(Range<String.Index>, attachmentIndex: Int)] }`.
   Extractor #1: the files-mentioned template above. Unit-test against real session payloads. Raw text is NEVER discarded — reducer/copy paths keep the original.
2. **Projection**: run the enricher in the projector, cached by message-text digest. Emit attachment render items with stable IDs `"<sectionID>:user:<id>:attachment:<n>"` above the bubble item, trailing-aligned. Bubble uses `displayText`.
3. **Thumbnails**: async, downsampled via `CGImageSource` thumbnail API (never full decode), memory-capped cache keyed by path+mtime. Missing/ephemeral paths (`/var/folders/...`) → filename chip placeholder — mandatory case, these paths expire.
4. **Hover references**: while preparing bubble text, tag reference ranges with a custom attribute (`.codexAttachmentRef: Int`). Cell hover tracking resolves the attribute under the cursor → coordinator callback → highlight border on the matching attachment cell. Same mechanism generalizes to file/thread mentions later.
