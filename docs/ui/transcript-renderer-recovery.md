# Transcript renderer and recovery

CodexCoreUI projects the canonical replica through two typed seams:

- `CodexTranscriptEventRegistry` adapts canonical item and turn facts into
  structured cards, typed user context, memory citations, MCP content, hook
  activity, and recovery notices.
- `CodexTranscriptRendererRegistry` maps those semantic entries to renderer
  nodes. AppKit and SwiftUI can bind the same node without reparsing protocol
  JSON.

Protocol payloads remain in `CanonicalStateSnapshot`. Expansion, inline editing,
bookmarks, output badges, scroll position, and focus remain presentation state.
Unknown or malformed content is omitted from the normal transcript rather than
shown as raw JSON. MCP content is bounded and typed; hosts can provide a richer
widget renderer at the existing product-tool seam.

`CodexTranscriptRecoveryAdapter` turns reconnect, stream, overload, history, and
writer-conflict failures into retryable notices. `CodexTranscriptVoiceOverLifecycle`
emits one stable announcement for turn start, meaningful streaming progress, and
terminal completion/failure so a long transcript does not produce announcement
noise.
