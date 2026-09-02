# Sandboxed visualizations

CodexCore recognizes the official inline visualization directive emitted in an
assistant message:

```text
visualize{"path":"/absolute/output/root/render-probe.html"}
```

The reference app exposes `<codexHome>/visualizations` as an additional runtime
workspace root. A custom `CodexConfig.codexHome` therefore moves newly created
visualizations. Embedded hosts can instead pass one or more explicit
`visualizationRoots` to `CodexChatWorkspaceView`.

Detection is fact-only: an explicit visualization directive becomes a typed
transcript render item with its originating thread and turn identity. An HTML
file change by itself remains an ordinary file change. Visualizations never
become workspace tabs.

The host validates all paths after resolving symbolic links. Files must be
lowercase hyphenated `.html` fragments, remain under the workspace or an
explicit visualization root, be regular UTF-8 files, and stay at or below 5 MB.
The HTML runs inside a non-persistent WebKit view containing an inner iframe
with `sandbox="allow-scripts"`; top-level navigation, forms, embedded frames,
objects, and arbitrary network connections are blocked by navigation policy and
CSP. The transcript owns a retained frame coordinator: virtualized cells are
temporary anchors, so scrolling a visualization offscreen and back does not
recreate its document. Switching away from its source task unloads the frame.
The embedded fragment reports intrinsic height through a narrow host bridge;
height is clamped to 44–10,000 points and invalidates only that transcript row.

The implementation follows the installed official renderer's observable shape:
modern and legacy directive parsing, stable source identity, a 240-point initial
height, dynamic intrinsic height, a 5 MB renderer cap, wide-mode metadata, and a
separate retained frame owner. `window.openai.sendFollowUpMessage` crosses the
bridge only after host confirmation; iframe content never receives filesystem
access.

See the point-in-time [official visualization harness audit](../reference/official-visualization-harness.md)
for the bundle evidence and live control run.
