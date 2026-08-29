# Transcript renderer and recovery

CodexCoreUI projects the canonical replica through two typed seams:

- `CodexTranscriptEventRegistry` adapts canonical item and turn facts into
  structured cards, typed user context, memory citations, MCP content, hook
  activity, and recovery notices.
- `CodexTranscriptRendererRegistry` maps those semantic entries to renderer
  nodes. AppKit and SwiftUI can bind the same node without reparsing protocol
  JSON.
- `CodexTranscriptWidgetInventoryV1` is the checked-in coverage contract for
  every record in the official bundle audit. It keeps the audit's IDs out of
  generated protocol code while making missing adapters test-visible.

Protocol payloads remain in `CanonicalStateSnapshot`. Expansion, inline editing,
bookmarks, output badges, scroll position, and focus remain presentation state.
Unknown object content becomes a typed warning row and malformed values fail
closed; no raw JSON is rendered implicitly. MCP content is bounded and typed,
MCP App hosts are sandboxed/lazy with bounded preview retention, and hosts can
provide richer resource renderers at the existing adapter seam. Source
citations and generated output resources remain typed references with lazy
previews.

`CodexTranscriptRecoveryAdapter` and `CodexTranscriptRecoveryState` turn
reconnect, stream, overload, history, and writer-conflict failures into scoped
retryable notices. An indeterminate write must be verified before a turn retry;
rollback failure leaves canonical state untouched. `CodexTranscriptVoiceOverLifecycle`
coalesces semantic phase announcements (including tool-active, reconnecting,
interrupted, and recovered) and marks blocking safety failures assertive, so a
long transcript does not produce token-level announcement noise.
