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

Detection is fact-only: directives and HTML file changes become typed thread
resources with their originating thread, turn, and item identities. Opening a
resource creates a durable workspace-tab request. Presentation state—loading,
fullscreen, retry, and frame retention—never enters canonical state.

The host validates all paths after resolving symbolic links. Files must be
lowercase hyphenated `.html` fragments, remain under the workspace or an
explicit visualization root, be regular UTF-8 files, and stay at or below 5 MB.
The HTML runs inside a non-persistent WebKit view containing an inner iframe
with `sandbox="allow-scripts"`; top-level navigation, forms, embedded frames,
objects, and arbitrary network connections are blocked by navigation policy and
CSP. Hidden frames are unloaded so they perform no layout, animation, timer, or
network work. A bounded LRU retains at most four frame sessions by default.

The implementation follows the installed official renderer's observable shape:
modern and legacy directive parsing, stable source identity, loading/error/retry
states, cross-thread origin retention, a 5 MB fragment cap, wide-mode metadata,
and a separate retained frame owner. The reference app intentionally uses a
host-controlled export action instead of granting untrusted iframe content
filesystem access.

See the point-in-time [official visualization harness audit](../reference/official-visualization-harness.md)
for the bundle evidence and live control run.
