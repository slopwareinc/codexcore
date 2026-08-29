# Official transcript widget and state oracle

Issue [#253](https://github.com/slopwareinc/codexcore/issues/253) records a read-only audit of the installed official ChatGPT/Codex renderer to make [#240](https://github.com/slopwareinc/codexcore/issues/240) implementation-ready. This is point-in-time engineering evidence, not public API documentation. Production protocol types and CodexCore tests remain authoritative.

The companion [`official-transcript-widget-inventory.v1.json`](official-transcript-widget-inventory.v1.json) is the canonical detailed matrix. [`official-transcript-fixture-recipes.v1.json`](official-transcript-fixture-recipes.v1.json) contains sanitized recipes, not captured conversations. Run `python3 Tools/validate_transcript_widget_oracle.py` after editing either file.

## Provenance and confidence

Audit date: 2026-08-29. Installed bundle: `com.openai.codex` 26.825.32147 (build 7303). ASAR SHA-256: `0462b03e878f0e78b223b849ee14cbba0de043f2c16acebee163cb95daa622ef`; bundled runtime SHA-256: `67ea03c98e7726eeebd161bc3bc92d8937f412f1899790a28e4ee9b80803c4d7`.

Evidence labels are deliberately strict:

- **bundle**: read-only ASAR filename, string, class-token, import, or state-discriminator evidence. Paths are relative to the bundle and hashes identify the inspected bytes. No proprietary source is copied.
- **live**: direct accessibility-tree or safe screenshot observation. The Mac was locked during this audit, so live-only claims remain explicitly unverified; no screenshot is committed.
- **public**: official OpenAI documentation. Public docs establish product/protocol semantics, not pixel values.
- **repo**: current CodexCore production or test evidence.
- **inference**: a bounded conclusion from named evidence, never presented as observed copy.

Exact English copy in the JSON is limited to short user-visible strings safely discoverable in bundle localization metadata. Copy can change independently of the protocol. Geometry uses CSS utility/token evidence where present; an `unknown` value means the bundle did not safely establish an exact pixel value.

## Architecture discovered

The official transcript uses a turn-level classifier and renderer registry, not a single central item switch. `todo-list` renders as a dedicated card, while `proposed-plan` and `plan-implementation` are suppressed in the ordinary block renderer and composed by the local-turn surface. Durable synthetic notices are split from tool activity. MCP typed content has its own adapter; MCP Apps use a lazy iframe/page boundary. This structure is the primary architectural acceptance constraint for #240.

Common visual vocabulary in the inspected renderer is: `text-size-chat` body text, `text-codex-description/80` secondary text, `text-default` and `font-medium` labels, `gap-0.5` within typed MCP blocks, `gap-2` in tooltip/list stacks, `icon-xs` activity icons, `rounded` card/chip primitives, warning color for high-risk denial, and polite atomic status regions for changing state. Exact per-record overrides are in the inventory.

## Widget/state matrix

| Family | Canonical trigger | Official behavior | CodexCore parity | Priority |
| --- | --- | --- | --- | --- |
| Todo | `todo-list` | Dedicated progress card; count summary; collapse/expand | Missing typed card | P0 |
| Proposed plan | `proposed-plan` | Turn-level plan summary; default collapsed after completion | Partial plan panel, transcript gap | P0 |
| Plan implementation | `plan-implementation` / implementation request | Suppressed as raw row; action starts implementation | Missing structured request/card | P0 |
| MCP typed blocks | text/image/audio/resource link/embedded resource | Type-specific rows, preview/open affordances, raw fallback | Generic MCP result | P0 |
| MCP App | structured app resource | Lazy app host with loading/error/persistent-entry states | Generic widget label only | P1 |
| Auto-review | `item/autoApprovalReview/*` | In-progress aggregation; denial/timeout retained; high-risk warning | Protocol known, transcript missing | P0 |
| Strict review/interruption | strict-review and repeated-denial events | Persistent notice; turn-ending explanation | Missing | P0 |
| Stream recovery | reconnect/overload/system error | Polite status, attempt/maximum or retry countdown, retry actions | Fragmentary connection state | P0 |
| History/turn recovery | history load failure, retryable turn | Scoped retry without transcript duplication | Partial retry projection | P0 |
| Writer/rollback safety | uncertain writer or rollback | Never blind replay; explicit retry/restore boundary | Canonical safeguards stronger than UI | P0 |
| Durable notices | model, reroute, personality, fork, worktree, remote task, hooks | Compact synthetic dividers/cards with navigation where applicable | Mixed/partial | P1 |
| Context and provenance | attachments, context, memory, sources, outputs | Typed chips/tooltips/end resources; lazy previews | Attachments partial; sources/memory missing | P1 |
| Navigation/actions | bookmarks, output badges, inline edit | Alt-arrow navigation, status badges, edit/fork/copy menus | Partial actions; no bookmarks/true edit | P1 |
| Rich rendering | KaTeX, Mermaid, visualizations | Lazy heavy renderers with fallback and bounded retention | Markdown only/limited visualization | P2 |
| Accessibility | streaming lifecycle and focus | polite atomic announcements; focus restoration; keyboard traversal | Labels exist; lifecycle incomplete | P0 |

## Acceptance order for issue #240

1. Add a typed renderer registry keyed by canonical item/synthetic-state identity. Preserve protocol facts in canonical state and expansion, bookmarks, focus, retry prompts, and preview retention in presentation state.
2. Ship todo/proposed-plan/plan-implementation and approval/recovery cards first. Reconcile streaming-to-complete in place; never emit duplicate rows.
3. Add typed MCP adapters with exhaustive unknown fallback. Keep image/audio/resource bytes out of eager transcript projection; previews and MCP Apps load on reveal and release according to bounded retention.
4. Add durable notices, typed attachments/context, citations, provenance, end resources, bookmarks, output badges, and true inline editing. Editing must retain raw user text/context and expose failure without destroying the original turn.
5. Add KaTeX, Mermaid, and visualization adapters behind lazy boundaries, with textual fallback, reduced-motion handling, and no hidden-host layout work.
6. Add VoiceOver lifecycle announcements and keyboard/focus tests. Announce semantic phase transitions once, not token deltas; restore focus after menus/dialogs and preserve transcript position.

Every record must pass fixture replay for loading, active, success, error, disabled, collapsed, and expanded states that apply; malformed/unknown payload tests; history/live reconciliation; VoiceOver labels/order; keyboard traversal; and a 1,085-item streaming performance run. Writer-conflict and ambiguous reconnect tests must prove there is no blind mutation replay. Hidden MCP/math/Mermaid/visualization hosts must do no layout/display work and retained previews must be bounded.

## Safe visual references

No screenshot is committed. The live app could not be unlocked automatically, and existing transcripts may contain personal or proprietary material. Future captures must use only synthetic content, crop to the widget, redact identifiers and paths, and store an annotation sidecar that names bundle version, state, scale, and evidence confidence. Static evidence and uncertainty are preferable to a fabricated visual.

## Machine-readable schema

The inventory root contains `schemaVersion`, `oracleVersion`, `capturedAt`, `bundle`, `publicSemantics`, and `records`. Each record requires:

`id`, `family`, `title`, `trigger`, `visual`, `copyVariants`, `states`, `actions`, `accessibility`, `performance`, `evidence`, `parity`, `acceptanceChecks`, and `fixtureRecipeIDs`.

Evidence entries require `kind` (`bundle`, `live`, `public`, `repo`, or `inference`), `location`, `claim`, and `confidence` (`high`, `medium`, or `low`). Bundle evidence additionally requires the asset SHA-256. Parity is one of `parity`, `partial`, `missing`, or `unknown`. The validator enforces these fields, unique IDs, evidence hashes, recipe coverage, redaction rules, and this page's `docs/index.md` route.
