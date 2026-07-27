# Custom tool cards

Use a product renderer for non-blocking dynamic-tool progress. MCP calls use their generic presentation; blocking questions belong in the server-request prompt flow.

CodexCoreUI already renders unowned dynamic tools as compact, humanized activity
rows. Use a product renderer only when the tool needs a richer interactive
surface. For an activity line that evolves across multiple tool calls, or when
the host must suppress the default item renderer, use
[activity presentation](live-activity.md). A product tool renderer only changes
the view for one dynamic-tool item; it does not coalesce different canonical
item identities.

```swift
let renderer = CodexProductToolRendererV2 { call in
    guard call.namespace == "catalog" else { return nil }
    return AnyView(MyCatalogProgressCard(call: call)) // host-defined view
}

CodexTranscriptViewV2(
    presentationStore: presentationStore,
    productToolRenderer: renderer
) {
    MyEmptyTranscriptView() // host-defined view
}
```

`CodexProductToolCallV2` exposes `tool` and `namespace`. The renderer is injectable into `CodexTranscriptViewV2`, not the workspace convenience view. Return `nil` for calls your host does not own; CodexCoreUI uses its generic presentation.

Renderer rules:

- treat tool arguments and output as untrusted data;
- keep stable identity for a logical call as its state changes;
- avoid expensive parsing on the scroll path;
- provide a useful accessibility label;
- preserve generic copy/debug access when practical.
