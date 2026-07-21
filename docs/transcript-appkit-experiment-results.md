# AppKit transcript experiment results

> **Historical engineering note:** Completed experiment record, not current user documentation.

Issue: [#126](https://github.com/slopwareinc/codexcore/issues/126)

## Decision and shape

The experiment uses one vertical `NSCollectionView` because V2 turns map
naturally to diffable sections while user messages, work headers, Markdown
blocks, work-group headers, individual tool rows, expanded details, product
tools, notices, live tails, final blocks, and timestamps remain independent
stable items. `NSTableView` would also provide reuse, but would require
synthetic grouping rows or a second grouping model for the official
user/work/final turn grammar.

Cells are real reusable `NSCollectionViewItem` instances. Read-only native
`NSTextView` surfaces own selectable user, prose, final, code, table, and
expanded-output text. Only a host-provided dynamic product-tool view uses a
fine-grained `NSHostingView`; its intrinsic height feeds a targeted layout
invalidation. No entire turn is a hosted row.

The V2 reducer, models, and wire grammar remain the only transcript truth.
The UI layer adds stable block revisions, prepared attributed content,
revision/width/font/theme height caching, per-thread UI sessions, and a
diffable presentation. It does not add another wire reducer.

## Reproducible performance evidence

The historical SwiftUI investigation used a long thread of approximately
1,085 timeline items. Its post-hang-fix samples still recorded burst costs:
491 `NSHostingView.layout` samples, 589 flat / 905 recursive AttributeGraph
update samples, and 47 styled-text measurement samples. The two scroll
samples left the main thread idle for about 17.4/20.6 seconds and 12.8/20.1
seconds, respectively, but materialization bursts still missed the 8.3 ms
120 Hz budget. See `docs/transcript-scroll-120fps-findings.md`.

The AppKit harness uses 217 turns with five fine-grained visible items per
turn, exactly 1,085 items, followed by 120 append-only streaming frames on
the final answer. Run:

```sh
swift test --filter CodexTranscriptAppKitPerformanceTests
swift test --filter 'CodexTranscriptAppKitIntegrationTests/diffableCollectionUsesFineGrainedItemsAndNeverBroadReloads'
```

Isolated results on 2026-07-15:

| Measurement | Result |
|---|---:|
| Off-main projection, 1,085 items × 120 frames | 13.289 ms average; 15.064 ms max |
| Changed render items | 120 total; exactly 1 per frame |
| New height measurements | 120 total; exactly 1 per frame |
| New prepared attributed values | 120 total; exactly 1 per frame |
| Structural diffable snapshots | 1 initial snapshot; 0 additional streaming snapshots |
| Streaming reconfigure | 1 targeted pass, 1 stable item |
| Broad collection reloads | 0 |
| Targeted AppKit apply/layout | 2.389 ms |
| Cold initial 1,085-item snapshot/apply/layout | 56.239 ms |

The reducer still applies all 120 deltas immediately. The active presentation
publisher is capped to one publication per 17 ms window and counts discarded
pure-delta presentation work. If a newer publication arrives while projection
is pending, the obsolete projection task is cancelled. The only repeating UI
timer is the active main transcript's working header at 1 Hz.

## Regression harness coverage

- Long streaming while unpinned preserves the exact raw offset and exposes
  Jump to latest; Jump returns to pinned bottom.
- Native selection survives a changed stable item's reconfiguration, suppresses
  pinned following, and standard responder-chain Copy returns the selected text.
- Explicit Copy turn, Copy code/output, edit-message, fork-chat, and open-subagent
  hooks remain reachable.
- A → B → A restores transcript, raw offset, pin, turn/row expansion sets, and
  stable timestamps from the bounded 12-session LRU without reducer recreation.
- Notification routing uses the wire thread ID, mirrors inactive thread running/
  failed/unread status, clears unread on selection, and pairs duplicate main/global
  stream events before applying them to V2 once.
- V2 fixture replay covers user/commentary/final ordering, commands, file changes,
  MCP failures, web, product tools, notices, and classic/official/ultra subagents.
- The full suite passes: 227 XCTest tests plus 31 Swift Testing tests (258 total).

## Remaining limitations

- Cross-turn drag selection is intentionally outside selection v1. Selection is
  native and reliable within one text/code/output item.
- Each coalesced presentation still performs a lightweight O(n) stable-ID and
  revision pass off the main actor. Only the changed Markdown tail is parsed,
  prepared, and measured, and obsolete passes cancel, but the ID pass is not yet
  driven by reducer-emitted changed-turn metadata.
- The cold 1,085-item mount is a one-time 56.239 ms operation in the isolated
  harness; warm thread swaps and streaming use state swap/targeted invalidation.
- The automated harness measures projection and AppKit snapshot/reconfigure work,
  not display-server composition on a ProMotion panel. A fresh interactive
  Instruments trace is still useful before taking the draft PR out of draft.
