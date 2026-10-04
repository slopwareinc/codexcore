# Repository design audit — 2026-10-05

This audit covers the SDK, reference app, UI, tests, build scripts, generators, and CI. It follows the Codex 0.160.0 upgrade merged in PR #260 and tracks cleanup in issue #261 / PR #262. Findings below describe the inspected implementation; they are not a promise that every possible defect has been discovered.

## Coverage and method

The initial inventory contained 381 Swift, Python, and shell files: 230 production sources, 129 tests, 19 tool files, and three scripts. Inspection combined repository-wide searches for duplicate windows, private symbols with only one textual reference, unchecked conversions, dictionary construction, swallowed errors, process ownership, and cache growth with targeted tracing of the largest components and their tests. This was not a manual line-by-line review of every file.

| Area | Paths and contracts inspected |
| --- | --- |
| Runtime and SDK | `Codex.swift`, session correlation/cancellation/reconnect/outbound ordering, transports, bounded line/stderr capture, observation hubs, history paging and leases |
| State and protocol | Reducer batches/revisions, configuration/thread/catalog adapters, unknown wire values, generated schema and generation boundaries |
| Parsing | Assistant blocks, Markdown fences, review payload candidates, scalar coercion, highlighting |
| Transcript and UI | Projection/cell/collection layout, image/icon caches, prepared text and height caches, sidebar organization/navigation, MCP editor, settings, previews |
| Reference app | App model task ownership, startup, environment discovery, Git runners, automation persistence/scheduling, dictation and voice logging |
| Tooling | Package manifest/resolution, schema generators and overlays, pinned installer/drift checks, runtime smoke, packaging, CI and local run commands |
| Tests | Existing regression and performance coverage plus targeted tests for each changed correctness contract; full-suite integration validation |

Generated protocol boilerplate, request factories, and legacy public compatibility APIs were not treated as dead code merely because they are large or have no internal caller. Duplicate-window results were checked for different ownership and semantics before consolidation.

## Fixed in this cleanup

| Problem | Result and evidence |
| --- | --- |
| Swift character indices mixed with Foundation UTF-16 offsets | Assistant rendering now preserves Unicode around fences; emoji, combining marks, and non-Latin regression cases |
| Thumbnail cache collisions, stale local images, and unlimited decoded image cost | Full-source digests, local modification/size identity, positive dimensions, count and byte-cost bounds; replacement/collision tests |
| Repeated regex compilation and overlapping string/comment highlighting | Compiled patterns reused; one token pass; a temporary 5,000-render debug benchmark improved from 0.289s to 0.043s, not an end-to-end scrolling claim |
| Plugin icon cache growth and duplicate concurrent work | Bounded cache, in-flight coalescing, background image construction, cancelled-view guard; concurrent request test |
| Numeric conversions could trap on large/nonfinite external values | Shared coercion uses exact conversion after truncation; reconnect delay saturates and sleep conversion clamps; boundary tests |
| Repeated scalar decoders | Configuration, thread, catalog and voice paths share existing coercion while retaining their whitespace/strictness policies |
| Automation save used stale cached unknown TOML and silently overwrote malformed files | Reads current disk metadata, refuses malformed/unsupported-kind overwrite, handles first-save file absence; persistence tests |
| Unsupported RRULEs quietly approximated daily runs; duplicate keys could trap | Unsupported rules remain intact and have no automatic next run; edits explicitly replace them; round-trip and malformed-rule tests |
| Skills and queue observer hubs duplicated lifecycle machinery | Thin wrappers share scoped invalidation delivery, filtering, termination and newest-value coalescing; existing epoch/queue tests |
| Ordered realtime events silently dropped when full | Bounded oldest-event buffer terminates visibly on overflow; retained events preserve order; overflow regression test |
| Small runtime/Git probes blocked or read without deadlines | Shared cancellation-aware probe with output cap, timeout, merged drains and final-byte handling; timeout, excess-output, cancellation and exit-status tests |
| Two settings surfaces duplicated bindings and actions | One shared host composition carries the same actions and preferences |
| Transcript metadata retained old chats; height cache retained every previous width/theme | Cache pruning retains live image sources and current layout variants; chat-switch and repeated-resize tests |
| Duplicate external MCP/catalog/normalized alias keys could trap | Defined last-value policy for assignments/catalog updates and deterministic canonical-path precedence for aliases; boundary tests |
| Review JSON candidates and malformed fences repeatedly rescanned suffixes | Single brace scan, lazy candidate materialization, shared fence recognition, stop after an unterminated outer fence; large malformed and nested/Unicode tests |
| CI did not exercise relocated app packaging | CI now packages with an ad-hoc identity and runs the packaging script's extracted-archive signature/resource checks |
| Dead and redundant internals found by tracing | Removed unused linked-worktree probe/path holder, duplicate disconnect cancellation, obsolete automation document cache and unnecessary diff allocations |

## Findings and execution order

Priority here means engineering order: P1 can lose a user-visible operation or leave work stuck; P2 is a reproducible ownership/capacity or maintainability defect; P3 is a bounded follow-up requiring product or measurement decisions. These findings are not all fixed by PR #262. Resolved follow-ups are marked explicitly.

### 1. P1 — Automation UI commits memory before durable storage, and hides failures

`CodexCoreAppModel.performAutomationRouteAction` saves/toggles/deletes lifecycle state before writing disk. Delete has an empty catch; `persistAutomation` uses `try?`; `runAutomationScheduler` ignores the load result's errors. A failed save can look successful, and a failed delete can reappear on restart. The stricter store now correctly returns errors, but the host still discards them.

Extract an automation controller with injected persistence and an observable error state. For save/toggle/delete, prepare the prospective lifecycle, write first, then publish it and cancel work/remove notifications. Runs need a separate policy for persisting start/finish metadata without pretending that a completed external turn can be rolled back. Test failing stores, partial loads, and restart behavior.

### 2. P1 — Mutating Git execution has a cancellation-before-launch race and no final deadline

`CodexGitRepository`'s private `CodexBoundedProcess` stores an optional process but does not remember cancellation before it exists/is running. Work executes in a detached task. Its cancellation path sends signals without a terminal escalation deadline; pipe readers can also await EOF from descendants. A hook or helper can keep the operation alive indefinitely.

Introduce a runner that records cancellation before launch, concurrently drains bounded output, owns termination policy and reports uncertain mutation outcomes. Test early cancellation, ignored signals, stalled hooks and inherited pipe descriptors. Do not route mutations through the new small read-only probe without preserving their completion/error semantics.

### 3. P2 — Project environment Git runner independently blocks and bounds output only afterward

`CodexLocalProjectEnvironmentProvider` redirects into temporary files and calls `waitUntilExit` in a detached task. It checks size after completion, allowing ongoing disk growth, and does not propagate cancellation to the process. Temporary-file setup also needs cleanup coverage on partial failure.

Use the same owned mutation runner as finding 2, including stdin support, live byte bounds and cleanup. Test cancellation and output exhaustion while the process is running.

### 4. P2 — Static automation encoding depends on unrelated previous decodes

`CodexAutomationFileStore.encode/decode` retain a static compatibility cache keyed only by automation ID. Decode documents from two homes with the same ID, then encode the first value: unknown metadata can come from the second document. File saves no longer use this cache, so the remaining defect is in the public compatibility API.

Represent the original document/opaque metadata as an explicit value instead of global state. Keep compatibility shims with a documented migration and add two-document/same-ID tests.

### 5. P2 — RPC request admission and cancelled written-request contexts are unbounded

`CodexSession.pendingClientRequests` and outbound admission have no explicit overall request/byte cap. Cancellation after a request was written correctly retains its context until reply/disconnect, but a runtime that remains connected and never replies can accumulate those contexts.

Add admission limits and deadlines with method-aware policy. Preserve uncertain mutation correlation and prohibit automatic replay. Test a connected nonresponding runtime, cancellation storms and admission recovery. Simply deleting written-request state would break an important correctness guarantee.

### 6. P2 — App and session ownership is too concentrated for safe incremental changes

`CodexCoreAppModel` is approximately 3,900 lines and owns startup, many task generations, sidebar state, integration refreshes, leases, voice, notifications, projects and automations. `CodexSession` is approximately 4,300 lines. These are real responsibility boundaries, not a reason to split files into arbitrary extensions.

Extract the automation controller first, then integration/startup and project lifecycle controllers with explicit dependencies. Inside the session, extract synchronous request/waiter/queue helpers owned by the same actor. Keep one ordered runtime owner; use existing epoch, history-order and ambiguous-write tests as migration constraints.

### 7. P2 — Renderer measurement and configuration remain coupled across large switches

The projector and collection cell each exceed 2,500 lines. Render-kind preparation, sizing, interaction and accessibility knowledge spans several switches, so adding a kind requires synchronized edits in multiple places.

Move one kind at a time into a preparation/measurement/configuration contract. Preserve the render oracle and test measured-versus-rendered sizes. Avoid a generic view abstraction that hides kind-specific behavior. Measure actual scrolling before attributing latency to file size.

### 8. Resolved — Downloaded image bytes were unbounded before downsampling

Thumbnail/icon callers previously used whole-body `URLSession.data` before image decoding. The compatibility follow-up replaces both with one pooled, chunked loader: success-status validation, declared/chunked byte limits (4 MiB icons, 32 MiB transcript previews), cancellation and a 20-second resource deadline. Raster icons are downsampled to 256 pixels off the main actor and cache cost is computed from the decoded image; bounded AppKit vector support is preserved. Regression tests cover concurrent isolation, cancellation, oversized bodies and raster/vector assets.

### 9. P2 — Voice log queue is unbounded even though log files rotate

`CodexVoiceLogFileWriter.enqueue` captures each line in a serial `queue.async` block. Slow storage can accumulate arbitrary queued memory before the bounded disk rotation runs. `fileURL` synchronizes with that queue and may block its caller.

Use a bounded byte queue with dropped-line counters and explicit flush behavior. Stress it with a deliberately slow writer and keep sensitive-content handling unchanged.

### 10. P2 — Automation path identity is not validated at its filesystem boundary

Save/delete append an externally supplied ID as a directory component, and loaded document IDs are not checked against their containing directory. Malformed IDs or mismatched folders can target the wrong location or fail unpredictably.

Validate a single directory component, enforce document/folder identity during load, and test empty, separator, dot-component and mismatched IDs. Define compatibility handling for existing invalid documents before relocating them.

### 11. P3 — Clean dependency resolution follows mutable grammar branches/tags

`Package.resolved` protects the current checkout, but several `Package.swift` grammar dependencies use branches and Ghostty uses a version range. A fresh resolution can select different source/resources than the tested lockfile.

Pin validated revisions where exact parser/resource behavior is required and make upgrades explicit. Run grammar parsing and relocated-resource verification after each upgrade. The new packaging CI closes one existing verification gap; it does not make upstream references immutable.

### 12. P3 — Internal uniqueness assumptions need explicit ingestion boundaries

Remaining `Dictionary(uniqueKeysWithValues:)` uses often follow intentional canonical deduplication. Some public mutable input arrays can still violate those invariants. A blanket last-value-wins replacement would hide contradictory state.

Document and test uniqueness at ingestion, returning a recoverable error or deterministic merge according to the data contract. Prioritize public sidebar order and transcript turn inputs; retain strict canonical-state assertions internally.

### 13. P3 — Tooling and local run commands have smaller robustness gaps

The method generator now rejects malformed/empty inventories, malformed arms, duplicate methods and Swift case collisions, with five dedicated tests; exact pinned drift still passes. Remaining local process-kill commands can affect same-named apps from another checkout. Toolchain selection in sampling scripts can prefer an installed beta without an explicit request.

Add schema-fixture failure tests without editing generated output, scope process selection to the checkout/executable, and make toolchain selection configurable. These are follow-up changes, not blockers for the current pinned runtime.

### 14. P3 — Parser and performance budgets are not yet comprehensive

The review brace scan is now linear and candidates are lazy, but repeated JSON decoding of nested complete candidates can still cost more than linear time. Core cache tests prove bounded retention and reuse, not production frame-time performance. The Ghostty-backed panel test emits an existing publishing-during-view-update warning.

Set a review decoding budget if realistic payload measurements justify it. Capture representative long-chat, resize, image and terminal traces; isolate the Ghostty state mutation warning before changing dependency code. Keep temporary microbenchmarks distinct from measured app performance.

## Design worth retaining

The single ordered session actor, no-replay policy for uncertain mutations, pure reducer batch validation, scoped coalescing observation, indexed FIFO queues, bounded transport lines/stderr, history concurrency limits, thread leases, preview read/highlight limits, and injected dictation/startup seams are useful invariants. Replacing them with shorter but less explicit code would be a regression. Generated schema volume is necessary wire coverage, not a cleanup target.

## Compatibility follow-up

The verified target remains Codex 0.160.0. Thread leases now expose settings and durable attachment pages/add/remove; turn leases expose exact-turn settings updates. Shared identity checks reject mismatched or closed leases before sending. The tests preserve service-tier omission/null/value, return `targetUnavailable` without retrying another turn, and keep opaque attachment cursors. Generated schemas and factories remain untouched; the handwritten API and guide were updated together.

## Validation

The complete Swift test run passed: 305 UI, 324 SDK and 22 app XCTest cases (one opt-in SDK test skipped), plus 368 UI, 11 SDK and 34 app Swift Testing cases. All 35 Python tests passed, and exact 0.160.0 protocol drift passed. The explicit isolated pinned-runtime smoke test passed. Packaging uses an ad-hoc signature and verifies the extracted archive and relocated resources; distribution notarization requires the separately configured signing workflow.

Existing Ghostty view-update warnings remain visible in the test output. No claim of a warning-free build, exhaustive security review, or production performance certification is made. For subsequent fixes, preserve this report's remaining findings until their specific failure cases are tested and resolved.
