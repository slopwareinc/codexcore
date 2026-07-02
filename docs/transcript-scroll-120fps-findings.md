# Transcript scroll: 120fps gap — findings (2026-07-02)

Status after PR #50 / issue #49 fix: **beachball/hang is resolved**. Scrolling long threads (~1085 items) no longer blocks the main thread. User-reported gap: scroll still does not feel like **120fps** on ProMotion.

Evidence sources:
- macOS `sample codex-chat-example` during active scrolling: `/tmp/codex-scrollfps-1.sample.txt`, `/tmp/codex-scrollfps-2.sample.txt`
- Codex CLI analysis (GPT-5.5, read-only) of samples + row-view code audit

## What changed in #49 (confirmed working)

The hang was caused by scroll-driven **full-tree invalidation**, not raw scroll throughput:

1. Bottom-anchor `GeometryReader` preference fired every scroll frame → `@State` writes → O(n) LazyVStack relayout loop
2. `.environment(\.codexTranscriptScrollActive, …)` flipped on scroll start/stop → ~1000 rows invalidated twice per gesture (bypasses `.equatable()`)
3. `ScrollViewReader.scrollTo` + debounced `DispatchWorkItem` forced layout of intervening lazy content
4. `.id(scrollTrigger.transcriptIdentity)` rebuilt the scroll hierarchy on identity churn
5. Computed `CodexTranscriptTimelineItem.id` hot during diffing
6. Unbounded row count (1083 live rows)

Fix (merged in branch `perf/transcript-scroll-rewrite-49`, PR #50): `defaultScrollAnchor(.bottom)` + `.sizeChanges`, `onScrollGeometryChange` (transition-only state), `ScrollPosition`, 150-item windowing, stored ids, deleted preference/ScrollViewReader/environment machinery. Container ~450 → ~171 LOC.

**Post-fix samples:** main thread idle ~85% of scroll time (sample 1: ~17.4s idle / 20.6s; sample 2: ~12.8s idle / 20.1s). No beachball pattern.

## Why 120fps still drops frames

At 120fps the frame budget is **8.3ms**. Visible jank comes from **bursts** when new rows materialize, not sustained blocking.

### Ruled out (not primary)

- `onScrollGeometryChange` closures (trivial boolean math; cold in samples)
- Row `body` evaluation alone (present but small vs layout/text)
- CoreAnimation compositing / row-level shadows / `codexGlass` (minimal in transcript rows)
- Scroll container feedback loops (fixed in #49)

---

## Ranked findings (by measured + code impact)

### 1. Text measurement/drawing on row first appearance — HIGH

**Evidence (sample 2):**
- `StyledTextLayoutEngine.sizeThatFits` / `ResolvedStyledText.StringDrawing.sizeThatFits` ~47 samples
- `__NSStringDrawingEngine` ~45 samples
- CoreText flat costs: `OTL::Coverage::SearchFmt2Binary` ~141, `ItemVariationStore::ValueForDeltaSet` ~91, `TGlyphIterator…` ~67

**Code:**
- `Sources/CodexCoreUI/CodexBlockView.swift` — `CodexProseBlock`, list/table styling
- `Sources/CodexCoreUI/CodexTableBlockView.swift`
- `Sources/CodexCoreUI/CodexTranscriptView.swift` — `CodexUserMessageView`, `StreamingAssistantText`

**Mechanism:** First time a variable-height row enters the LazyVStack viewport, SwiftUI synchronously measures styled prose/tables via CoreText. One long message can exceed 8.3ms alone.

**Fix:**
- Precompute and cache `AttributedString` + measured heights keyed by `(contentDigest, font, theme, width)` before rows enter viewport
- Store block digests at projection time; avoid `CodexBlock.contentDigest` / `CodexProseCache.makeStyled` from row `body`
- For very long prose/code: AppKit-backed `NSTextView`/`TextKit 2` with retained layout, or split into smaller stable text blocks

---

### 2. SwiftUI layout / AttributeGraph bursts on lazy materialization — HIGH

**Evidence (sample 2, main thread):**
- `NSHostingView.layout` ~491 samples
- `ViewGraphRootValueUpdater.render` ~488
- `AG::Graph::UpdateStack::update` ~589 flat / ~905 recursive
- `LayoutEngineBox.sizeThatFits` ~411
- `ModifiedElements.makeElements` ~420
- `LazySubviewPlacements.updateValue` / `LazyLayoutViewCache.updatePrefetchPhases` (materialization path)

**Code:**
- `Sources/CodexCoreUI/CodexTranscriptView.swift` — `LazyVStack` + 150-row window
- `CodexTranscriptTimelineRow`, `CodexAgentRow`
- `Sources/CodexCoreUI/CodexCollapsibleCard.swift` — nested overlays/backgrounds
- Nested `ScrollView`s in cards: `CodexMessageContentView.swift`, `CodexFileChangeCard.swift`, `CodexToolCallCard.swift`

**Mechanism:** LazyVStack has no cell reuse; each newly visible row pays full layout + display-list build. 150-row window bounds worst case but does not eliminate per-row spikes.

**Fix:**
- Reduce live row count further (e.g. 80–100) if acceptable
- Flatten row modifier stacks; avoid nested scroll views in collapsed cards where possible
- **Hard 120fps target:** `NSTableView` / `NSCollectionView` + diffable data source + height cache; SwiftUI rows via `NSHostingView` in cells (Codex sample analysis explicitly recommends this escalation path)

---

### 3. Hover / hit-test responder traversal during scroll — MEDIUM-HIGH

**Evidence (sample 2):**
- `MultiViewResponder.containsGlobalPoints` ~464
- `-[NSView hitTest:]` ~87
- `HoverResponder.containsGlobalPoints` ~59

**Code:**
- `CodexAssistantMessageView`, `CodexUserMessageView` — row + footer `.onHover`
- `CodexMessageMetaFooter` — timestamp + action bar each with `.onHover`; buttons at `.opacity(0)` still exist and participate in hit testing
- Delayed hide `Task` in `CodexMessageHoverReveal`

**Fix:**
- One hover region per row (not three)
- Do not instantiate footer action buttons until row is hovered
- Remove footer/action-bar hover handlers; use `allowsHitTesting(false)` on non-visible chrome during scroll if needed

---

### 4. `.equatable()` compares large payloads — HIGH (code audit)

**Code:**
- `CodexTranscriptTimelineRow.==` compares `lhs.message == rhs.message`
- Synthesized `CodexChatMessage` equality includes full `text`, diffs, tool results, `projectedBlocks`
- `CodexBlock ==` compares full strings (`CodexBlockProjection.swift`)

**Fix:**
- Lightweight render key: `(messageID, streamingRevision, contentDigest, timestamp)` instead of full message equality

---

### 5. Digest / cache-key work in body/update paths — LOW-MEDIUM

**Evidence:** `CodexTranscriptInput.init` → `CodexTranscriptTimelineDigest.messages`; `CodexBlockView.body` → `contentDigest` → hash full block text (~1–5 samples per path, unnecessary work on hot paths)

**Fix:** Precompute transcript structural digests and block digests outside SwiftUI invalidation (at timeline build / block projection)

---

### 6. Background stdio transport CPU steal — MEDIUM (off main thread)

**Evidence (sample 2, `Thread_4875565: NSFileHandle.fd_monitoring`):**
- ~20,092 samples in `CodexStdioTransport.start`
- `Collection.firstIndex(of:)` ~8,941, `Data._Representation.subscript` ~3,503 at `Transport.swift:119`

**Mechanism:** Quadratic buffer rescanning on every read; steals a core during streaming, reduces headroom for UI/render threads.

**Fix:** Cursor-based line buffer or ring buffer; linear parsing without repeated `firstIndex` + `subdata` + `removeSubrange`

---

### 7. Minor / easy wins — LOW

- Timestamp formatting in row `body` (`Text(timestamp, format: …)`) — preformat at build time
- Lifecycle detail preview string normalization in `body` (`CodexAgentLifecycleBlock`)
- Aggregate file-change diff stats recomputed in `body` (`CodexAggregateFileChangeCard`, `CodexLiveTurnModels`)
- `ProgressView` spinners on streaming rows (`CodexStatusChip`) — continuous invalidation

---

## Recommended fix order

| Priority | Item | Effort | Impact |
|----------|------|--------|--------|
| 1 | Transport line buffer (`Transport.swift:119`) | Small | Frees CPU during streaming |
| 2 | Hover consolidation + lazy footer buttons | Small–medium | Cuts hit-test samples ~550 |
| 3 | Precomputed text layouts + stored block digests | Medium | Cuts largest per-frame spikes |
| 4 | Lightweight row equality keys | Medium | Reduces diff churn |
| 5 | Lower window / flatten card layout | Medium | Reduces layout burst size |
| 6 | NSTableView transcript (optional) | Large | Only guaranteed path to locked 120fps |

## Top 5 expensive subtrees during scroll (sample 2)

1. `UC::DriverCore → CA::Transaction::commit → NSDisplayCycleFlush → NSHostingView.layout → ViewGraphRootValueUpdater.render`
2. `GraphHost.runTransaction → AG::Subgraph::update → AG::Graph::UpdateStack::update`
3. `LazySubviewPlacements.updateValue → placeSubviews → _LazyLayoutViewCache.withMutableCacheState`
4. `StyledTextLayoutEngine.sizeThatFits → NSAttributedString.MetricsCache → boundingRectWithSize → CoreText`
5. `ViewGraph.renderDisplayList → DisplayList.ViewUpdater…` + `-[CALayer _display]`

## Related

- Fixed: issue #49, PR #50
- Follow-up: (new issue for 120fps — see GitHub)
