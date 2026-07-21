# Dynamic tools

Dynamic tools let a host register named tools and answer app-server calls at the server-request seam. In the current facade, the generated tool spec is a raw schema wrapper; tool names are strings.

## Declare a tool

```swift
let tool = CodexSchemaDynamicToolSpec(.dictionary([
    "name": .string("record_lookup"),
    "description": .string("Look up a local project record"),
    "inputSchema": .dictionary([
        "type": .string("object"),
        "properties": .dictionary([
            "id": .dictionary(["type": .string("string")])
        ]),
        "required": .array([.string("id")])
    ]),
    "namespace": .string("example")
]))

let thread = try await codex.startThread(.init(dynamicTools: [tool]))
```

## Return content

`CodexDynamicToolResultContent` supports:

- `.inputText(String)`
- `.inputImage(String)`
- `.inputAudio(String)`

The SDK validates the text/image/audio wire shape, not URL schemes or fetchability. Enforce any URL contract in the host and keep secrets out of result text and logs.

Dynamic-tool execution and transcript rendering are separate concerns. Use [custom tool cards](../ui/custom-tool-cards.md) for non-blocking product-specific presentation.
