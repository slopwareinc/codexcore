# CodexCore Visual Audit — Component Polish

## Cross-cutting, system-wide embarrassments (read first)

### 1. Inconsistent border opacity across the entire module
No shadow system, no glass system tokens, and border opacity changes between every card:

- `CodexStatusChip.swift:27` — `color.opacity(0.16)` hardcoded
- `CodexRateLimitBanner.swift:26-29` — `0.12` + `0.35` hardcoded
- `CodexNoticeCard.swift:21` — `border.opacity(0.72)`
- `CodexToolCallCard.swift:22, 133` — `border.opacity(0.74)`, `border.opacity(0.72)`
- `CodexFileChangeCard.swift:68, 261` — `border.opacity(0.74)`
- `CodexSubagentRunView.swift:89` — `border.opacity(0.72)`
- `CodexCompletedWorkTraceView.swift:19, 121` — `0.58` and `0.42`
- `CodexAggregateFileChangeCard.swift:103` — full-opacity `theme.colors.border` (only one in module doing this)
- `CodexOperationSummaryCard.swift:39, 48` — `0.58` divider, `0.72` outer
- `CodexMessageContentView.swift:227` — `border.opacity(0.8)` (ReasoningCard)
- `CodexBlockView/CodexTableBlockView.swift:47` — full-opacity `theme.colors.border`
- `CodexStructuredPanelCards.swift:233` — full-opacity `theme.colors.border`

Border opacity values in use: **0.16, 0.18, 0.24, 0.28, 0.32, 0.34, 0.35, 0.42, 0.58, 0.72, 0.74, 0.8, 1.0**. Thirteen distinct opacities for what should be one `theme.effects.borderOpacity` token. Cards built from the same component look subtly different next to each other in the same chat thread.

### 2. Almost no shadow usage anywhere — then a single bespoke shadow appears once
Across ~2500 lines of card/overlay code, only `.shadow(` calls: `CodexCommandPaletteOverlay.swift:79` — `.shadow(color: .black.opacity(0.32), radius: 28, x: 0, y: 18)`, plus `CodexAgentPanels.swift:260` — `.shadow(color: .black.opacity(theme.effects.glowOpacity), radius: 24, x: -8)`. Every other "elevated" surface refuses to lift off the page. App reads flat everywhere then surprises you with one shadow on the command palette.

### 3. Haptic feedback is entirely absent across the entire module
Nothing calls `UIImpactFeedbackGenerator`/`UINotificationFeedbackGenerator` (or macOS equivalent). Nothing on toggle (`CodexCollapsibleCard.swift:53`), nothing on copy (`CodexMessageContentView.swift:482`), nothing on send (`CodexComposerBar.swift:1262`), nothing on stop, nothing on status-transition. For an iOS app with frequent tap-to-expand cards and icon-only buttons, this is the most "amateur" miss of all.

### 4. Default `ProgressView()` used verbatim in seven different places
- `CodexStatusChip.swift:14`
- `CodexSubagentRunView.swift:97` and `:116`
- `CodexMCPStatusSheet.swift:56`
- `CodexCommandPaletteOverlay.swift:117`

Same default circular spinner plastered into a `6×6`-chip (wrong at that size) and a sheet header. A custom circle/dot/throbber would unify these.

### 5. `.monospacedDigit()` is applied nowhere
App renders thousands of numbers — line counts, character counts, byte counts, exit codes, timings, token counts. `+3 -5` digits in `CodexFileChangeCard`/`CodexAggregateFileChangeCard` wobble horizontally with each change. None use `.monospacedDigit()`.

---

## 1. CodexStatusChip.swift

**1. `:14-20`** — Streaming state uses default `ProgressView()` (`.controlSize(.mini)`); non-streaming state uses a bare 6×6 `Circle().fill(color)`. Mini `ProgressView` is bigger than 6px dot, so streaming chips jitter in size.
**Fix:** Single SF Symbol that can play streaming role (`circle.dotted` or `KeyframeAnimation`-driven `circle.fill`), constant 6×6 size across states.

**2. `:27`** — `color.opacity(0.16)` hardcoded. Standardise chip fill via `theme.colors.chipFill(for: color)` or `color.opacity(theme.effects.chipFillOpacity)`.

**3. `:18-24`** — State encoded by color AND label color only. Colorblind users cannot tell `success` from `danger` if both read as the same 6×6 dot.
**Fix:** Add tiny status pictograph (`checkmark`/`xmark`/`bolt`) before the dot, or change the dot's *shape* (ring for "ready", filled for "done", dashed circle for "in-progress").

**4. No `accessibilityLabel` anywhere.** VoiceOver reads "label" only, missing "success" or "warning" context.
**Fix:** `.accessibilityElement(children: .ignore)` + `.accessibilityLabel("\(status) — \(label)")`.

**5. `:12` `HStack(spacing: 5)` hardcoded** — chips elsewhere use `HStack(spacing: 8)`. Standardise via `theme.spacing.chipGap`.

---

## 2. CodexRateLimitBanner.swift

**6. `:26-30`** — `warning.opacity(0.12)` fill and `.warning.opacity(0.35)` stroke, both hardcoded.
**Fix:** `theme.effects.bannerFillOpacity` / `theme.effects.bannerBorderOpacity`.

**7. `:24-25`** — `.padding(.horizontal, 12)` `.padding(.vertical, 9)` hardcoded. Other cards use `.horizontal 10 / vertical 8`. Geometry silently disagrees.
**Fix:** Use `theme.spacing.cardPadding`.

**8. No close button, no timeout, no fade-out.** Once shown, stays until parent removes. No `@State var dismissed` or `onTimeout`.
**Fix:** Trailing `Image(systemName: "xmark")` button + auto-dismiss transition.

**9. Only warning tone exists.** No informational/success variant despite app needing all four severities. `CodexNoticeCard` handles all severities; this banner duplicates the pattern locked to one.
**Fix:** Either fold `CodexRateLimitBanner` into `CodexNoticeCard` or generalize to take a `severity`.

**10. No haptic, no `.accessibilityLabel("Rate limit warning: \(message)")`.**
**Fix:** `.accessibilityElement(children: .combine)`.

---

## 3. CodexNoticeCard.swift

**11. `:21` `border.opacity(0.72)` — yet another opacity number.**

**12. `:53-58` — chevron shown even when `isExpandable == false`.** Only alpha tweaked to 0.25. Dimmed chevron baits tapping; tapping does nothing.
**Fix:** Hide entirely with `if isExpandable { ... }`.

**13. `:53-58` — chevron rotation `isExpanded ? 0 : -90` rotates a down-pointing chevron to pointing-left, not up.** Tapping doesn't visually "open" the card. Rest of app uses `chevron.down` rotated 0/-90 AND alternately `chevron.right` rotated 0/90. Two unrelated mental models coexist in the same conversation.
**Fix:** Pick one SF Symbol + rotation pair (`chevron.right` rotated 0/90 is the iOS disclosure standard).

**14. `:62` `surfaceElevated.opacity(0.18)` hardcoded**, bottom strip uses `opacity(0.24)` (`:88`). Same card, two elevated-fill opacities.

**15. `:79` `Text(notice.kind)` displayed verbatim** as a footer caption (e.g. "warning", "danger"). Raw enum string.
**Fix:** Localize with `.displayName` on severity enum.

**16. `:68` `ForEach(Array(notice.metadata.enumerated()), id: \.offset)`** — offsets as IDs cause animation glitches on metadata shuffle.
**Fix:** Stable IDs upstream or hash contents.

**17. `:39` `.lineLimit(1)` on title truncates long warnings** with no tooltip/help showing full string.
**Fix:** Drop lineLimit to 2 or add hover tooltip.

---

## 4. CodexToolCallCard.swift

**18. `:80` `Text(toolCall.isStreaming ? "Waiting for tool output..." : "No output")`** — arbitrary inline placeholder. Same pattern as `"Running..."`, `"No reasoning captured"`, `"No diff available"` elsewhere — every card invents its own verb tense and ellipsis style.
**Fix:** Centralize placeholders (running/no output/no data) into `CodexEmptyCopy` namespace.

**19. `:183-189` `formattedDuration` manually computes** `"\(duration)ms"`, `String(format: "%.1fs", seconds)`, `"\(Int(seconds.rounded()))s"`. No relative formatter, no consistency, no `.monospacedDigit()`.
**Fix:** Decimal-align with `.monospacedDigit()` and shared `CodexDurationFormatter.format(milliseconds:)`.

**20. `:49-52` — timing label "Running for 1.2s"/"Ran for 1.2s" + redundant status chip "running"/"done" (`:171-175`) + streaming icon (`play.circle` vs `checkmark.circle` `:29`). Three redundant states in one header.**
**Fix:** Drop either text status or timing label.

**21. `:97-105` — wrap-output button is icon-only** (`text.line.first.and.arrowtriangle.forward` / `text.alignleft`). On iOS (no hover), the affordance is invisible.
**Fix:** Labeled `Label("Wrap", systemImage: ...)` toggle, or context Menu.

**22. `:131-134` — `.overlay(RoundedRectangle(...).stroke(border.opacity(0.72), lineWidth: 1))` AND `.background(codeHeader)` AND `.clipShape(RoundedRectangle(...))`.** Every detail block layered three ways: fill + clip + stroke. Classic iOS-2014 visual noise.
**Fix:** `theme.materials.codeInset` or `.background(.thinMaterial, in: RoundedRectangle(...))` once without overlay border.

**23. `:148` `ScrollView(.horizontal, showsIndicators: false)` wraps `Text(code)`** with `.fixedSize(horizontal: true, vertical: true). On narrow widths, row grows tall with blank whitespace to the right, no scroll affordance (no chevron, no gradient fade).
**Fix:** Trailing `LinearGradient` fade overlay + small `chevron.left.forwardslash.chevron.right` icon hint at right edge.

**24. `:177-181` `statusColor` is the only state signal in header icon, no separate success/danger shape.** Colorblind users cannot distinguish "failed" from "done".
**Fix:** Use `xmark.circle` for failure (already done) AND swap `play.circle` glyph into `xmark.octagon.fill` on failure so shape, not just color, encodes error.

**25. `:53` — status chip already shows color + label, header ALSO shows color + label (timing) AND an icon. Densest header row in the app.** At narrow widths three pieces collide so `truncationMode(.middle)` (`:39`) cuts the tool name to "..", hiding the row's purpose.
**Fix:** Move status chip into swipe-action / overflow, OR collapse inline timing into the chip ("Ran 1.2s ✓").

---

## 5. CodexFileChangeCard.swift

**26. `:96-99` em-dash "−" (`U+2212`) for "removed" prefix:**
```swift
Text("+\(facts.addedLineCount)").foregroundStyle(theme.colors.success)
Text("−\(facts.removedLineCount)").foregroundStyle(theme.colors.danger)
```
**Compare with `CodexAggregateFileChangeCard.swift:78-79` which uses ASCII hyphen-minus "-":**
```swift
Text("+\(row.addedLineCount)")...
Text("-\(row.removedLineCount)")...
```
Aggregate card displays `+12 -3` while per-file card directly below shows `+12 −3`.
**Fix:** Pick one symbol across the module (em-dash "−" for typography) and centralize as `CodexDiffCounter` view.

**27. `:94-117` — header row has five trailing elements (diff counter, status chip, undo button, review button, chevron) plus the path/kind label.** On narrow widths it overflows; `Spacer(minLength: 8)` won't save it.
**Fix:** Move Undo/Review to trailing swipe-actions or trailing ellipsis `...` overflow Menu.

**28. `:179` `change.isStreaming ? "Updating files..." : "No diff available"`** — placeholder copy invented local-only.
**Fix:** See cross-cutting #18 strings.

**29. `:96-100, 150-153` no `.monospacedDigit()`** — counts grow from 9→10→100, diff pill width jumps.
**Fix:** Apply `.monospacedDigit()` on the diff counter HStack.

**30. `:110-117` `CodexFileChangeActionButton`** — Capsule with both `.background(...opacity(0.34), in: Capsule())` AND `.overlay(Capsule().stroke(border.opacity(0.74)))`. Three background layers per button. At a row of two plus chevron, ~6 nested capsule shapes in one header.
**Fix:** Drop the stroke; chip legibility from surface tint alone.

**31. `:114-117` Review button label says "Review" with systemImage "eye".** But action is `toggle() + reviewAction?(change)` — it both expands card AND triggers external callback. Label gives no hint card will also expand inline.
**Fix:** Drop `toggle()` (let external reviewer show its own diff UI) or relabel "Expand".

**32. `:340-344` `lineBackground` uses `success.opacity(0.08)` / `danger.opacity(0.08)` hardcoded.**
**Fix:** Tokenize as `theme.colors.diffAddBgOpacity`.

---

## 6. CodexAggregateFileChangeCard.swift

**33. `:103` `RoundedRectangle(...).stroke(theme.colors.border, lineWidth: 1)` — full-opacity border, only card in module doing this.** Every sibling uses 0.72 or 0.58. Nesting aggregate above per-file cards (which use 0.74) means aggregate is visually heavier-bordered than its children — inversion of emphasis.
**Fix:** Use same lower-opacity border token as children.

**34. `:41-47` — "Open in" chip shown inline with no attached target.** Just `Text("Open in")` in a capsule — neither button nor label. Mockup text shipped.
**Fix:** Connect to real action (`onOpenInEditor`) or delete.

**35. `:78` uses ASCII "-" minus.** Mismatch with per-file card below.

**36. `:85-94` `Button { ... } label: { Text(hiddenRowsTitle)... }`** — "show all rows" toggle looks like hyperlink text only: no padding, no tap slop, no hover, no chevron.
**Fix:** `Label` with `chevron.right` rotated (`showsAllRows ? .down : .right`).

**37. `:117-133` `actionRow`'s buttons vary enabled/disabled based on `changes.count == 1`.** When 2+ files, both Undo and Review appear enabled-but-totally-inert (user taps, `performAction` short-circuits). Visually indistinguishable from enabled.
**Fix:** Render as disabled or hide when `changes.count > 1`.

**38. `:120` `ForEach(summary.actionTitles, id: \.self)`** — keyed by title string ("Undo", "Review"). Localized re-translation will relayout.
**Fix:** Stable `CodexLiveTurnActionKind` enum as id.

**39. `:107` `.accessibilityLabel(accessibilityLabel(for: summary))`** — builds single label including "1 file +12 -3 (+2 actions)"; the actions part just prints "Undo, Review" as text, no action trait.
**Fix:** Build `accessibilityActions` for each available action.

---

## 7. CodexCollapsibleCard.swift

**40. `:38` Header divider `Rectangle().fill(theme.colors.border).frame(height: 1)`, full opacity.** Elsewhere runs at 0.58 — here it's solid. Internal divider out-emphasizes surrounding card border.
**Fix:** Use `theme.colors.border.opacity(0.4)` or `Divider()`.

**41. `:42-44` — `.background(background)` + `.clipShape(RoundedRectangle)` + `.overlay(RoundedRectangle stroke border, lineWidth: 1)`.** Three layered drawing passes with no `.shadow`. iOS standard "card" feeling comes from soft shadow, not a 1pt stroke.
**Fix:** Drop the stroke. Use `theme.materials.card` background, rely on contrast for separation; OR add `shadow(...)` and drop border. Don't do stroke + nothing.

**42. `:36-41` — when `isExpanded` toggles, only inner `VStack` appears/disappears — no `withAnimation` wraps the conditional.** Animation depends on caller calling `withAnimation(.snappy)` in toggle (`:53`), which only animates the binding, not the conditional insertion. Jump-cut on first expand.
**Fix:** Wrap the conditional in `if isExpanded.wrappedValue { ... }.transition(.opacity.combined(with: .move(edge: .top)))`.

**43. `:53` `.snappy(duration: animationDuration)` with no haptic.** Tapping a card to expand is exactly when soft `UIImpactFeedbackGenerator(.light)` belongs.
**Fix:** Add haptic on toggle.

**44. `:49` `.frame(maxWidth: maxWidth, alignment: .leading)` applied at the shell level, but `CodexToolCallCard`/`CodexFileChangeCard` ALSO pass `maxWidth: theme.spacing.cardMaxWidth` and then independently call `.frame(maxWidth: ...)`.** Double-frame constraints.
**Fix:** The card itself shouldn't constrain maxWidth; let the caller.

---

## 8. CodexStructuredPanelCards.swift

**45. `:230-234` `StructuredPanelShell` — `.background(surface.opacity(glassOpacity))` + `RoundedRectangle.stroke(border, lineWidth: 1)` full-opacity border.** No shadow. Same stack-three-times pattern as CollapsibleCard.
**Fix:** Same as #41.

**46. `:179` `statusPill` compares `title == "Enabled"` as a literal string.** If upstream sends "enabled", "Authorized", etc., color flips silently.
**Fix:** Typed `.enabled: Bool` or enum.

**47. `:86-95` `progressRow` builds custom progress bar out of ZStack of two Capsules.** Uses `color.opacity(0.72)` hardcoded for filled portion, `theme.colors.surfaceSunken.opacity(glassOpacity)` for track. SwiftUI has `ProgressView(value:)` with `.tint`. Reimplementing from capsules loses a11y and native motion.
**Fix:** `ProgressView(value: fraction, total: 1) { ... }` with `.tint(color)` and `.progressViewStyle(.linear)`.

**48. `:96` `.frame(height: 6)` for bar — hardcoded; doesn't scale with dynamic type.**
**Fix:** Tie to `theme.spacing.progressBarHeight`, ideally `@ScaledMetric`.

**49. `:125-130` `Text("No server rows").font(theme.fonts.chat)` — uses chat body font for an empty state line.** Reads larger than rest of panel content.
**Fix:** `theme.fonts.caption` + subtle SF Symbol.

**50. `:209, 219` — panel icon's pattern is accent-tinted.** Both `StructuredPanelShell` and `CodexMCPStatusSheet.swift:29` use same `server.rack` glyph with different sizes (15 vs 18 here) — visible inconsistency between inline panel and modal sheet.

---

## 9. CodexBlockView.swift / CodexTableBlockView.swift

**51. `CodexBlockView.swift:205` — bullet character as raw text `"•"`.** Ordered list markers as `"\(offset + 1)."` strings without `.monospacedDigit()`. Width differs between markers.
**Fix:** Small `Circle().fill(.tint).frame(width: 4, height: 4)` for unordered, `Text("\(offset + 1).").monospacedDigit()` for ordered.

**52. `:168-176` Hardcoded heading sizes 20/17/15/14/13.** Not tied to `@ScaledMetric` or `.font(.system(.title, design:))`. App's own `theme.fonts.label/caption` system bypassed.
**Fix:** Map heading levels to `Font.largeTitle / .title2 / .title3 / .headline / .subheadline`.

**53. `:103` inline code background `theme.colors.accentSoft.opacity(0.4)` hardcoded.** Other soft-backgrounds in code blocks use `0.08`. Visible tonal mismatch between inline `code` and fenced ```code``` blocks within the same message.
**Fix:** Token to `theme.colors.codeInlineBg`.

**54. `:80-81` `isBaseBold` determined by substring match on name** — `DMSans-Medium` matches as bold (`"medium"` substring). Medium-weight fonts get further bolded on strong-emphasized runs.
**Fix:** `NSFontManager.shared.fontDescriptor.symbolicTraits.contains(.bold)` rather than substring matching.

**55. `:132-134` `private static func fontFingerprint(_ font: Font) -> String { String(describing: font) }`** — `String(describing: Font)` returns `Font<SplitViewTextStyle...>` and is brittle for cache keys.
**Fix:** Hash into `theme.fonts.chat` identifier directly.

**56. `CodexTableBlockView.swift:21-40` — no horizontal scroll.** `Grid` with `horizontalSpacing: 16`, `frame(maxWidth: cardMaxWidth, alignment: .leading)`. If table widths exceed `cardMaxWidth`, cells get clipped silently.
**Fix:** Wrap in `ScrollView(.horizontal, showsIndicators: false)` when total column-width exceeds available width.

**57. `:21-40` no zebra striping, no header bold-styling beyond color.** On dense tables (5+ rows), all rows blur together.
**Fix:** `backgroundColor: theme.colors.surfaceElevated.opacity(0.32)` alternating row tint, `.font(theme.fonts.label.weight(.semibold))` on headers.

**58. `:33-39` `ForEach(Array(model.rows.enumerated()), id: \.offset)` and likewise for cells.** Offsets as IDs break diffing on insertion; entire content hash re-matches on every render.
**Fix:** Add a stable `CodexTableRow.id` upstream.

---

## 10. CodexSubagentRunView.swift

**59. `:97` and `:116` default `ProgressView()` for `.spawning`/`.running` states** — twice in this file (cross-cutting #4).

**60. `:49` `Text(date, format: .dateTime.hour().minute())` — fixed-clock time, no relative format.**
**Fix:** `.dateTime.relative(presentation: .named, unitsStyle: .wide)` or `RelativeDateTimeFormatter`.

**61. `:155` `count == 1 ? "1 agent" : "\(count) agents"` manual pluralization.**
**Fix:** `^[\(count) agent](inflect: true)` AttributedString.

**62. `:113-114` SubagentRun status `.spawning` uses `Image(systemName: "sparkles")`.** Everything else uses circle-fill / exclamationmark.triangle idiom. `sparkles` interrupts the glyph idiom.
**Fix:** `circle.dotted` for spawning.

**63. `:81-83` — when `showsDetails == true`, the VStack has `.background(theme.colors.surface.opacity(0.32))` but no border.** Header above has `.background(surfaceElevated.opacity(0.18))`. Detail zone looks lighter than header despite being deeper/lower priority.
**Fix:** Swap: detail `surfaceSunken`, header `surface`.

**64. `:85-90` `.background(...).clipShape(...).overlay(stroke border.opacity(0.72))` stack-three-times.** Same noise pattern as CodexCollapsibleCard.

---

## 11. CodexCompletedWorkTraceView.swift

**65. `:17-19` Border opacity `0.42` for non-failing, `theme.colors.danger.opacity(0.38)` for failing.** Yet another pair; held to a totally different border philosophy than sibling cards.
**Fix:** One border token; communicate failure via icon + accent stroke only.

**66. `:167-169` Status encoded solely by 5×5 `Circle().fill(...)`.** No label, no icon. Colorblind users cannot tell failed from completed.
**Fix:** `exclamationmark.circle.fill` for failed; `.accessibilityLabel`.

**67. `:93` and `:269` `count == 1 ? "1 item" : "\(count) items"` — manual pluralization twice in same file.**
**Fix:** Single `.inflect` helper.

**68. `:222-231` Nested `ScrollView(.vertical)` inside `ScrollView(.horizontal)` to display operation's raw text.** Hardcoded `maxHeight: 220`. No gradient/affordance at scroll boundaries. Long plan text gets tiny window in Card-in-Card-in-Card.
**Fix:** "Show full" link → popover sheet, or larger/animated height.

**69. `:81, 187` Two different chevron styles: top-level uses `chevron.right` rotated 0/90; smaller groups same. Good — but `CodexOperationSummaryCard.swift:30` (separate file) puts a static `chevron.right` at opacity 0.72 with no rotation.** Disclosure pattern partly consistent.
**Fix:** Apply consistent pattern across sibling file too.

**70. `:243-258` `rawDetailTitle` returns hardcoded strings "stdout / stderr", "diff", "tool details", "plan details", "reasoning", "notice details", "details".** Should be localized strings.

---

## 12. CodexOperationSummaryCard.swift

**71. `:54-61` `icon(for:)` does brittle title-string matching:**
```swift
if normalized.hasPrefix("read ") { return "doc.text.magnifyingglass" }
if normalized.hasPrefix("edited ") || normalized.hasPrefix("created ") { ... }
if normalized.contains("test") { return "checkmark.circle" }
return "terminal"
```
"answered test question" would get "checkmark.circle"; "edit-test ran" would get edit icon (not test). Prone to drift.
**Fix:** Carry typed `CodexLiveTurnOperationRow.Kind` from producer side.

**72. `:30-32` `Image(systemName: "chevron.right").foregroundStyle(theme.colors.textTertiary.opacity(0.72))` — chevron opacity hardcoded 0.72, row text `textTertiary` at full opacity, no chevron animation.** Rows look tappable but `CodexOperationSummaryCard` has no `onSelect` handler — display-only.
**Fix:** Remove chevron entirely, or wire the rows.

**73. `:38-43` `Rectangle().fill(theme.colors.border.opacity(0.58)).frame(height: 1).padding(.leading, 34)`** — manually drawn 1pt divider with hardcoded left-pad 34. `SwiftUI.List` and `InsetGroupedListStyle` handle this for free; manual separator doesn't respect text scaling/dynamic type.
**Fix:** Use `Divider()` and apply `.padding(.leading, 34)` outside if alignment matters.

**74. `:16-43` No hover state, no pressed state, no `.buttonStyle`.** Rows sit on `theme.colors.surfaceElevated.opacity(0.18)` background but tapping does nothing — no `Button` wrapper. Looks like a list, behaves like static text.
**Fix:** Either declare static (drop chevron) or wrap each row in Button with highlight background.

---

## 13. CodexMCPStatusSheet.swift

**75. `:83` `.frame(width: 560, height: 460)` — sheet fixed at 560×460.** On macOS fine; on iOS unusable (iPhone width 375-430). No `.presentationDetents`, no `.presentationDragIndicator`, no adaptive layout.
**Fix:** Drop fixed frame; `.presentationDetents([.medium, .large])` and let SwiftUI size.

**76. `:80` `.frame(height: 330)` on server ScrollView.** Hardcoded. 0 servers = empty state in 330pt blank pane; 30 servers = scroll within 330pt inside 460pt sheet — wasteful.
**Fix:** `ScrollView` with no fixed height; sheet presents at `.medium`/`.large`.

**77. `:30-51` Header uses raw `.font(.system(size: 18, weight: .semibold))` etc — six hardcoded sizes in one file.** No use of `theme.fonts.label/.caption/.micro`. Sheet frozen on exact px sizes; will not respond to app-wide font customization.
**Fix:** Map to `theme.fonts.*` tokens.

**78. `:62-69` Error path: `Text(error).foregroundStyle(theme.colors.danger)`.** No SF Symbol, no retry, no elevation, no shadow.
**Fix:** `CodexErrorState` inline component: warning glyph + caption + retry button.

**79. `:66-69` Empty path: `Text("No MCP servers")` alone.** No illustration, no CTA, no explanation.
**Fix:** "Get started" CTA + one-line explanation.

**80. `:39` and `:46` Icon buttons `.frame(width: 28, height: 28)` for refresh/close.** 28pt tap target below iOS 44pt recommendation. Icon-only Buttons without `.accessibilityLabel` — `.help` set but no a11y; iOS VoiceOver has no button name.
**Fix:** 44×44 (using `.contentShape(Rectangle())` to grow tap area without growing glyph) + `.accessibilityLabel`.

**81. `:138-144` `previewEntries` joined with " · " and `.lineLimit(2)` truncates** with no "… +5 more" suffix.
**Fix:** Cap to `prefix(3)` + append `Text("+\(total-3) more")`.

---

## 14. CodexEnvironmentPanel.swift

**82. `:204` `.frame(width: 440)` — fixed width, no detents, on sheet body.**
**Fix:** `.presentationDetents([.medium, .large])` + relative frames.

**83. `:184-191` Validation errors as multiple red captions in VStack.** No SF Symbol, no error aggregate. Wall of red text.
**Fix:** Single `CodexFormError(errorMessages)` with `exclamationmark.circle` prefix.

**84. `:104-108` Result card has the only full-opacity border in the surrounding panel group:** `RoundedRectangle.stroke(theme.colors.border, lineWidth: 1)`. Inconsistent with rest of panel cards.

**85. `:55-62` "Create environment" button `.frame(maxWidth: .infinity)` + `.buttonStyle(.bordered) .controlSize(.small)`.** Full-width CTA shrinks to small size — reads as secondary action, not primary.
**Fix:** `.controlSize(.regular)` or `.large` for primary CTAs; accent fill for prominence.

**86. `:36-39` `.pickerStyle(.segmented).labelsHidden()` — VoiceOver announces "Segmented control, 3 buttons, ..."** with no semantics of what each option means.

---

## 15. CodexGitReviewPanel.swift

**87. `:180, 191, 193` — multiple buttons `.disabled(true)` with `help("... is not wired in this build")`.** Most embarrassing text in the module — a user reading this tooltip has developer experience interrupted. Buttons exist purely to communicate "feature coming later", mocking themselves in live UI.
**Fix:** Remove unwired buttons entirely or move behind feature flag.

**88. `:193` `actionButton` for disabled state uses `.opacity(enabled ? 1 : 0.72)`** — manually dimming instead of letting `.disabled(true)` style the button.
**Fix:** Drop manual opacity; let `.buttonStyle(.bordered)` + `.disabled(true)` produce standard treatment. Or remove entirely (#87).

**89. `:60-80` Toolbar Toggle uses `.toggleStyle(.switch)`** for display-only filters. `.tint` unset — toggled state uses default system accent (blue), unrelated to `theme.colors.accent`.
**Fix:** `.tint(theme.colors.accent)`, or `.toggleStyle(.checkbox)` for filter-style.

**90. `:152-171` File row `+12 -3` uses `theme.colors.textSecondary`** for the `+X -Y` text, not standard success/danger used elsewhere (`CodexFileChangeCard.swift:96-99`).
**Fix:** Tokenize `+.success / -.danger`.

**91. `:139-142` `Toggle` "Include unstaged" has no help/hint.**
**Fix:** Small "explanation" caption underneath.

**92. `:164` `Text("+\(file.addedLines) -\(file.removedLines)")` (ASCII "-")** — disagrees with em-dash in `CodexFileChangeCard.swift:98`. Same module, two glyphs for minus.

**93. `:43-49` Menu uses `.menuStyle(.borderlessButton)`** with `Button(action: {})` action empty and `.disabled(true)` for every branch option. Whole branch menu is a dead selection list with a checkmark.
**Fix:** Implement actual branching, or render current branch as static label without menu affordance.

---

## 16. CodexCommandPaletteOverlay.swift

**94. `:45` `Color.black.opacity(0.42)` — hardcoded scrim.** iOS 14+ best-practice: `.ultraThinMaterial` to inherit user's Reduce Transparency settings. Currently bypasses accessibility.
**Fix:** `.background(.ultraThinMaterial)` (or `theme.materials.scrim`).

**95. `:73` `.frame(width: 620, height: 540, alignment: .top)` — entirely hardcoded.** On 375pt iPhone it crashes the layout entirely: 620pt-wide palette in 375pt screen. No detents, no responsive layout.
**Fix:** `.frame(maxWidth: 540, maxHeight: .infinity).padding(.horizontal, 16)` with `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)`.

**96. `:74` `.background(theme.colors.surface.opacity(0.98), ...)` — almost-opaque.** Combined with shadow on `:79`, palette looks like a floating window from macOS transplanted onto iOS — jarring on phone.
**Fix:** iOS sheet-like pattern: full blur material, no shadow.

**97. `:79` ONLY shadow in the module — `.shadow(color: .black.opacity(0.32), radius: 28, x: 0, y: 18)`.** Other modal-ish surfaces (MCPStatusSheet 440×460, WorktreeHandoffSheet 440pt, Git panels) have no shadow. Palette alone "lifts" off the page because of one magic shadow.
**Fix:** Tokenize `theme.shadows.palette` and either apply uniformly or remove from here.

**98. `:117-119` `ProgressView().controlSize(.small)`** — default spinner in search field.
**Fix:** Custom dots pulsing inside the search field.

**99. `:229` `emptyCategoryRow`: `Text(title == "Chats" ? ... : "No quick actions")`** — stringly-typed branch on `title == "Chats"`. If section renamed, empty copy desyncs.
**Fix:** Typed `CodexCommandPaletteSection.Kind` upstream.

**100. `:159-160` `statusRow` is `Text(title).foregroundStyle(isError ? theme.colors.danger : theme.colors.textTertiary)`.** Error status as bare red text — no icon.
**Fix:** `Label(title, systemImage: isError ? "exclamationmark.triangle" : "info.circle")` with severity-tinted icon.

**101. `:219` Row buttons have `.background(theme.colors.surfaceElevated.opacity(0.34), in: RoundedRectangle(...))` applied OUTSIDE Button's label.** SwiftUI doesn't propagate `.background` as part of `buttonStyle(.plain)` pressed/hover state — the row never shows a pressed/hover response. The 0.34-tinted bg is permanent, not interactive.
**Fix:** Move background inside `label:` closure; add `.opacity` change via `ButtonStyle` custom struct.

**102. `:228-235` `emptyCategoryRow` background fills but no `.help` or icon.** Looks like inert rectangular card area.
**Fix:** Small exploration glyph and reword textually.

**103. `:48` `.onTapGesture(perform: onClose)` on scrim.** iOS supports but scrim dismissal on tap is debatable UX. No animation on dismiss.
**Fix:** Wrap in `withAnimation(.easeInOut)` and confirm with haptic.

---

## 17. CodexComposerBar.swift

**104. `:139` Placeholder text: `"Ask Codex anything about this workspace..."` — 38-char placeholder.** Truncates on iPhone widths even before user types. "Codex" branding baked into placeholder (see Codex-name discussion).
**Fix:** Shorten to "Ask anything…" and brand through `assistantName` slot, not placeholder.

**105. `:183, 966, 1041, 1128, 1243` Corner radius chaos.** Main composer uses `theme.radii.large`; four palettes use `theme.radii.composer`. If `radii.composer ≠ radii.large`, input bubble and popovers mismatch visibly.
**Fix:** Centralize one `composerCornerRadius` token; bubble and any popover attached must share it.

**106. `:216` `.background(CommandPaletteEscapeMonitor(...) ...)`** — on iPad/iPhone builds this branch isn't compiled (`#if canImport(AppKit)`). Fine but worth knowing.

**107. `CodexAgentPanels.swift:564` `composerChip("5.5", help: "Side chat model")` hardcoded — marketing model name "5.5" baked into a chip-render call.** Other menus (`ComposerModelMenu`) work dynamically.

**108. `:856-872` `ComposerChipLabel` icon-only variant `.frame(minWidth: title == nil ? 28 : 0, minHeight: 28)` then `.padding(.horizontal, title == nil ? 0 : 10)`.** Icon-only chips are 28×28; tap area below iOS 44pt standard.
**Fix:** `.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())` with visible glyph remaining at 18pt.

**109. `:875-894` `ComposerStopButton` uses different idiom from `SendButton` (`:1255`):** Stop = dark circle bg `surfaceSunken`, danger red `stop.fill`. Send disabled = dark circle bg, gray `arrow.up`. Send enabled = accent-filled circle, `onAccent` `arrow.up`. No forced uniform size — Send uses `iconLarge + 4`. Stop uses same shape idiom with no shadow while Send has none either — visually two distinct actions (Stop = destructive interrupt) should differ more strongly.
**Fix:** `.shadow(color: theme.colors.danger.opacity(0.2), radius: 6)` on Stop, or dashed border to differentiate.

**110. `:1083, 1097, 1105` Three icon-only `CodexComposerMCPStatusPalette` buttons ("arrow.clockwise", "arrow.up.right.square", "xmark") — each with `.help(...)` but NO `.accessibilityLabel(...)`.** VoiceOver announces the SF Symbol name only.
**Fix:** `.accessibilityLabel("Refresh MCP servers")` etc.

**111. `:1117-1124` MCP server row `.frame(maxHeight: 188, alignment: .top)` — magic 188.** With more servers, area clips, no scrollbar/indicator.
**Fix:** `.frame(maxHeight: 320)` or compute from theme spacing.

---

## 18. CodexComposerAddMenuModels.swift

**112. `:113-124` Title-case casing inconsistency:** Sentence case ("Files and folders", "Goal", "Plan mode", "Plugins", "Browser", "Computer", "Files and chats") mixed with Title Case ("Documents", "PDF", "Spreadsheets", "Presentations", "Template Creator", "GitHub"). Slop.
**Fix:** Sentence case throughout.

**113. `:201-205` Marketing-legalese copy baked into the model.** `"Open and control the in-app browser for local development pages and files. Navigate, inspect, click, and take screenshots from chat."` — a paragraph. Other plugins get one-line `detail: "Work with pull requests and issues"` — tonal mismatch.
**Fix:** Trim each ~10 words, capabilities not benefits.

**114. `:218` `"Computer Use can operate local Mac apps after installation and OS permission approval. Appshot is represented as a packaged capture boundary. This native build shows the install/permission boundary and does not invoke the permission flow."`** — dev-speak ("packaged capture boundary", "Appshot", "this native build") leaking directly into UI.
**Fix:** Plain language.

**115. `:212` `title: "Computer Use"` (title case) but opened by `CodexComposerAddMenuItem(id: .computer, title: "Computer", ...)` on `:122`.** Two labels for same surface.
**Fix:** Single source of truth.

**116. `:203-205` `legalLinks: ["Website", "Privacy Policy", "Terms of Service"]` raw strings.** URLs missing; if rendered as links, dead; if decorative chips, dead.
**Fix:** Carry `CodexPluginLegalLink(url:title:)`.

**117. `:271-273` All artifact launchers say same description:** `"... support is represented as a plugin boundary. This build does not invoke artifact generation from the add menu until the plugin is installed and selected."` — 100% developer-facing phrasing. Repeated 5× across artifact kinds.
**Fix:** Plain `"Create and edit \(kind) in chat"`-style.

---

## 19. CodexAgentPanels.swift

**118. `:18-20` `chatTitle: String = "Codex"` — hardcoded brand default.** Marketing name leaks into a default parameter, breaking product display name alignment. If app's display name is "CodexCore" or whatever the host ships as, "Codex" branding still appears.
**Fix:** Inject through `CodexBranding` value.

**119. `:260` `.shadow(color: .black.opacity(theme.effects.glowOpacity), radius: 24, x: -8)` — single bespoke shadow for side panel.** No token. Other panels have no shadow. Side panel lifts while floating panel doesn't. Cross-component inconsistency.
**Fix:** Token `theme.shadows.sidePanel`.

**120. `:64-69, 88-93, 107-113, 347-355` Four empty states, all `"No X yet"` one-liners.** No icon, no CTA, no description. Same pattern across Outputs/Sources/Side chats/no tab.
**Fix:** Unify into `CodexEmptyState(icon:systemImage:title:detail:action:)`.

**121. `:136-143` `SummarySection` shows static `chevron.down` that doesn't rotate, change color, or animate** — visually suggests "collapsible section" but section is not collapsible. Misleading affordance.
**Fix:** Make collapsible (`DisclosureGroup`) or drop chevron.

---

## TL;DR — the ten highest-leverage fixes

1. **Wire `CodexAgentThemePreset` into a Settings picker** above the raw color editors. Five finished themes exist; surface them.
2. **Replace `CodexThemeModePreview` with a real mini chat row** driven by `editableTheme.agentTheme(...)`. Kill 92pt abstract tile.
3. **Use SwiftUI `ColorPicker`** instead of `CodexHexColorRow`; kill dead "Import"/"Copy theme" pills; remove the three disabled vapor rows.
4. **Add `borderSoft / border / borderStrong` color tokens** to absorb 13 hand-picked border opacity values.
5. **Standardize one chip vocabulary** across `CodexStatusChip`, `CodexInlineChatStatus`, `CodexFileChangeActionButton`, `ComposerChipLabel` — one shape, one border rule, one background recipe, `chipPadding` token.
6. **Pick one disclosure chevron convention** (`chevron.right` rotated 0/90 — iOS standard) and apply to NoticeCard, ToolCallCard, FileChangeCard, OperationSummaryCard, AgentPanels SummarySection.
7. **Add haptic feedback** on every card toggle, send/stop, status-transition, theme/mode selection.
8. **Drive all non-sidebar typography through `theme.fonts.*`** — `panelTitle`, `routeTitle`, `sheetTitle`, `micro` tokens. The codebase already proves (via SidebarTypography) it knows how.
9. **Use `.monospacedDigit()`** on every diff counter, byte count, exit code, timing, token count.
10. **Replace raw `ProgressView()`** with a single shared spinner (or animated SF Symbol), and add `CodexEmptyState`/`CodexErrorState` components to replace four "No X yet" one-liners and bare red `Text(error)` strings.