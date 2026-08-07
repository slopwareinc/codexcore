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

## Thread tools and subagents

The reference app exposes thread-management tools in the `codex_app` namespace for
ordinary threads and Voice threads. These are peer-task operations such as
`create_thread`, `list_threads`, `read_thread`, `send_message_to_thread`, and
`wait_threads`. They create or coordinate top-level Codex tasks; they are not the
native subagent protocol.

Realtime Voice adds its Voice-only lifecycle tools separately. In particular,
`end_realtime_voice_call` must not be registered on a normal text thread.

Native subagents are selected by the app-server's multi-agent runtime. The current
reference host starts normal and Voice turns with `multiAgentMode` set to
`explicitRequestOnly`, leaving the runtime to choose the model's supported
orchestration version. Some models advertise multi-agent v2, while GPT-5.6-Luna
advertises v1; v1 and v2 have different transcript item shapes, but both are
represented by the canonical collaboration/subagent projections. A model version
must not be emulated by exposing `codex_app.create_thread` as a substitute for
native delegation.
