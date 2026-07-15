# AppKit transcript parity matrix

This matrix is the acceptance contract for issue #126. The V2 reducer,
models, and wire grammar remain authoritative. The AppKit presentation may
change how those values are rendered, but it may not introduce a second
transcript projection or omit a V2 value.

Selection v1 is deliberately scoped to native selection within one user,
prose, final-answer, code, or expanded-output surface. Continuous drag
selection across turn boundaries is not part of this experiment.

| Surface / behavior | V2 source of truth | Current behavior to preserve or restore | AppKit owner | Required evidence |
|---|---|---|---|---|
| User message | `CodexTurnV2.userMessage` | Right-aligned bubble, server echo reconciliation, optimistic text, stable timestamp, selection | user render block + TextKit cell | reducer reconcile test; render projection and copy tests |
| Commentary prose | `.prose(CodexAssistantTextV2)` | Chronological Markdown inside the work block, streaming updates, selectable text | Markdown block projector + TextKit/code cells | fixture ordering; stable-ID/revision test; streaming selection regression |
| Final answer | `CodexTurnV2.finalAnswer` | Markdown below work, streaming tail, stable timestamp, selection | final Markdown block projector + TextKit/code cells | fixture projection; copy-final and selection regression |
| Work header | `CodexTurnStatusV2` | Thinking/Working, completed disclosure, failed message, elapsed duration | AppKit working-header cell | duration grammar tests; only active header 1 Hz instrumentation |
| Work expansion | turn status + session expansion set | Completed work collapses; live work expands; state survives A → B → A | per-thread UI session + disclosure cell | session restoration and projection tests |
| Work-group header | `CodexWorkGroupV2.header` | Synthesized V2 grammar in narrative order | fine-grained group-header cell | existing fixture/header suite; projection ordering |
| Command row | `.command` | Running/completed/failed state, command label, duration, bounded output disclosure | command row + expanded TextKit output block | fixture replay; expansion/bounds/copy-output tests |
| File change | `.fileChange` | File list, state, duration, selectable diff disclosure | file row + expanded TextKit diff block | projection and disclosure tests |
| MCP tool | `.mcpToolCall` | App/server + tool, state, error first line, arguments/result disclosure | MCP row + expanded TextKit detail block | MCP failure fixture; copy-output test |
| Web search | `.webSearch` | Query and state in work-group chronology | web-search row | fixture/projection test |
| Dynamic product tool | `.productToolCall` | Host renderer when supplied; complete fallback otherwise | fine-grained product-tool cell; scoped hosting view only for host renderer | renderer/fallback integration test |
| Subagent lifecycle | `.collabAgent` + `CodexSubagentStoreV2` | Created/input/waited/closed rows, messages, lifecycle state | collab row + detail block | existing collab fixtures; projection test |
| Open subagent | `agentThreadIDs` | Selecting a subagent row opens its existing panel tab | collab row action callback | callback integration test |
| Notices / unknowns | `.notice`; reducer handled-type grammar | Muted notices; unknown wire items remain skipped | notice TextKit cell | reducer and projection tests |
| Empty state | empty transcript | Prompt suggestions when ready | surrounding SwiftUI wrapper | workspace integration/manual harness |
| Loading state | `isThreadLoading` | Loading presentation while cold history is restored | surrounding SwiftUI wrapper | warm/cold workspace integration |
| Theme | `CodexAgentTheme` | Canvas, text hierarchy, bubbles, borders, code/status colors, custom fonts | AppKit theme bridge | theme-key invalidation/visual harness |
| Layout | theme spacing + workspace offset | transcript max width, summary-panel horizontal shift, turn/block spacing | AppKit layout metrics | width/height cache tests; visual harness |
| Composer inset | measured overlay height | Last content rests above composer | `NSScrollView.contentInsets` | inset geometry test/manual harness |
| Pin/follow | per-thread pin state | Follow only while pinned and not selecting; no transcript-change scroll | scroll coordinator | scrolled-up streaming and selection harness |
| Jump to latest | pin geometry | Appears while unpinned with newer content; returns to pinned bottom | AppKit overlay control | geometry/action test |
| Raw scroll restore | per-thread raw offset | Exact A → B → A offset restoration before pin adjustment | warm UI session | LRU/session and host swap tests |
| Row expansion restore | per-thread turn/row sets | Work and output disclosures survive A → B → A | warm UI session | session state test |
| Timestamp stability | per-thread turn timestamp map | A turn does not acquire a new visible timestamp on rerender/switch | warm UI session | timestamp restoration test |
| Warm sessions | per-thread reducer + UI state | Last 12 threads retained; A → B → A is a state swap, not history replay | LRU session store | hydration-count/LRU test |
| History restore | reducer `restoreHistory` | One reducer projection path; cold history fills once | session store + existing history loader | warm restore test; existing history tests |
| Live ingress | V2 notification grammar | Notifications route by their actual thread ID, including inactive parents; child traffic remains isolated | runtime session → session/status stores | interleaved-thread integration test |
| Thread running state | turn lifecycle | Sidebar state updates without selecting the thread | independent thread-status store | status routing test |
| Thread failed state | turn failure | Failure remains visible independently of transcript visibility | independent thread-status store | status routing test |
| Inactive unread | completed/failed lifecycle | Inactive completion/failure marks unread; selecting clears it | independent thread-status store | unread-clear test |
| Streaming cadence | reducer mutations | Reducer truth updates immediately; active presentation applies at most 60 fps and collapses obsolete deltas | session publisher + diffable snapshot scheduler | burst diagnostics regression |
| Diff scope | stable block IDs/revisions | Insert/delete/reconfigure only changed fine-grained blocks; never `reloadData` per token | table diffable data source | snapshot instrumentation test |
| Markdown cost | V2 assistant text | Block projection is incremental and off-main; cells bind prepared content | background projector | executor/instrumentation test |
| Height cost | item/revision/width/font/theme | Reuse measured heights; invalidate only affected keys | height cache | cache-key/hit test |
| Native selection | prepared selectable content | Standard responder-chain Copy; selection survives unrelated/delta snapshots when its item remains | read-only `NSTextView` | selection-preservation test/manual harness |
| Explicit copy | turn/block payloads | Copy turn, final answer, code, command output/diff/tool detail | AppKit menus/buttons + clipboard hook | copy payload/action tests |
| Edit/action hooks | user/turn identity | Stable identities remain available for current/future edit and action affordances | render item action context | identity/action-context test |
| Accessibility | semantic V2 item role/state | Readable labels, buttons/disclosures, selectable text, status values | cell accessibility roles/labels | accessibility-label tests/manual AX inspection |
| Timers/animation | active work only | No shimmer tree or timer forest; at most one active work header ticks at 1 Hz | list controller | timer-count diagnostic |
| Cell reuse | render block identity | Real reusable cells; no whole-turn `NSHostingView` row | `NSTableView` view reuse | reuse/snapshot diagnostics |
| Performance evidence | same long-thread/streaming shape as SwiftUI findings | Compare publication, reload, projection, height-cache, and main-thread work counters | diagnostics harness | reproducible results in draft PR |

## List choice

The experiment uses `NSCollectionView`. The transcript remains one vertical
column, but its protocol grammar is explicitly turn-grouped and heterogeneous.
A diffable section maps directly to one stable turn ID while data-source items
remain user, work-header, Markdown block, group-header, work-row, expanded
detail, product-tool, notice, live-tail, final block, and footer identities.
Section spacing preserves the three-part turn grammar without making a turn a
single hosted row. Product-tool hosting is limited to its own fine-grained
item.

The legacy transcript already projected stable block-level identities, and
the failed parked AppKit experiment demonstrated that the damaging choice was
whole-turn rows plus broad reload/remeasure—not AppKit itself. Compared with
`NSTableView`, collection sections and supplementary/decoration support retain
that grouping without synthetic separator rows, while a one-column flow
layout still gives explicit cached variable heights and real cell reuse.
