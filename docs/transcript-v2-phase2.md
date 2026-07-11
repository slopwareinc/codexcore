# Transcript V2 — Phase 2 brief (SwiftUI views)

Build the SwiftUI presentation layer for the Phase 1 model
(`Sources/CodexCoreUI/TranscriptV2/CodexTranscriptModelsV2.swift`), matching
the official presentation grammar in `docs/transcript-v2-spec.md`.

A previous session already drafted four view files in
`Sources/CodexCoreUI/TranscriptV2/` (untracked in git): CodexTranscriptViewV2,
CodexTurnViewV2, CodexWorkBlockViewV2, CodexWorkGroupViewV2. Review them,
keep what's good, fix or finish what isn't. Do NOT modify the reducer, the
model, the header synthesis, existing pipeline files, or existing public API.

## Deliverables

1. **CodexTranscriptViewV2** — thin scrolling list over `CodexTranscriptV2`:
   ForEach over turns, autoscroll-to-bottom on new content, an empty-state
   `ViewBuilder` slot, theming via the existing `CodexAgentTheme` environment
   (reuse its colors; see `CodexTheme.swift`).
2. **CodexTurnViewV2** — user bubble (right-aligned, timestamped) + work
   block + final answer rendered with the existing markdown content view
   (`CodexAssistantContentView` / `CodexMessageContentView` — reuse, do not
   rebuild markdown).
3. **CodexWorkBlockViewV2** — the centerpiece, official grammar exactly:
   - `.working`: header "Working for Ns" with a client-side stopwatch from
     turn start; narrative below; `liveTail` phrase as the last line with a
     subtle shimmer.
   - `.done`: collapsed-by-default disclosure "Worked for Xm Ys" (format
     `1m 8s`, no zero-padding) expanding to the full narrative.
   - `.failed`: failure message as a muted line.
   - Renders nothing at all when narrative is empty and liveTail is nil.
4. **Narrative rendering** inside the block:
   - `.prose` → secondary-color markdown paragraphs.
   - `.workGroup` → synthesized header line, lean one-line rows beneath
     (commands monospace with status glyph + duration; expandable disclosure
     for output/args on mcp and fileChange rows).
   - `.notice` → one muted line.
   - `.productToolCall` → a new public renderer slot
     `CodexProductToolRendererV2` wrapping
     `(CodexProductToolCallV2) -> AnyView?`, passed into
     CodexTranscriptViewV2, with a compact generic chip fallback
     (namespace · tool, status glyph).
5. **#Preview blocks** with hand-built sample data: live turn mid-work,
   completed collapsed turn, expanded narrative with prose + two work groups
   + a product tool call, failed turn.

## Definition of done

- Swift 6 clean; raw wire discriminants never appear in any visible string.
- `swift build` passes; `swift test` passes (the 5 `CodexTranscriptV2Tests`
  stay green; `CodexLiveTurnModelTests` failures are pre-existing on main —
  ignore them).
- Commit on branch `codex/transcript-v2` when green.
