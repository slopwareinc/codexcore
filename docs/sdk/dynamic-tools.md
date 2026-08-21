# Dynamic tools

Dynamic tools let a host register named tools and answer app-server calls at the
server-request seam. The Rust SDK owns typed declarations and handler dispatch;
the Swift facade currently retains its raw generated-schema wrapper.

## Rust declarations and handlers

The Rust SDK exposes the two declaration variants present in the pinned 0.148.0
schema: a standalone `function`, or a `namespace` containing function tools. A
standalone function does not carry a `namespace` field; namespacing is the
separate declaration variant.

Create declarations through `DynamicToolInputSchema`, register their handlers,
and pass the registry declarations directly to `thread/start`:

```rust
use codex_app_server_sdk::{
    Codex, DynamicToolCall, DynamicToolContent, DynamicToolFunction,
    DynamicToolInputSchema, DynamicToolRegistry, DynamicToolResult,
    StartThreadOptions,
};
use serde_json::json;

# async fn declare(
#     codex: &Codex,
# ) -> Result<DynamicToolRegistry, Box<dyn std::error::Error>> {
let input_schema = DynamicToolInputSchema::new(json!({
    "type": "object",
    "properties": { "id": { "type": "string" } },
    "required": ["id"],
    "additionalProperties": false
}))?;
let declaration = DynamicToolFunction::new(
    "record_lookup",
    "Look up a local project record",
    input_schema,
);

let mut registry = DynamicToolRegistry::new();
registry.register(
    declaration.into(),
    |call: DynamicToolCall| async move {
        let id = call.arguments["id"].as_str().unwrap_or_default();
        Ok(DynamicToolResult::success([DynamicToolContent::Text(
            format!("record {id}"),
        )]))
    },
)?;

let thread = codex
    .start_thread(StartThreadOptions {
        dynamic_tools: registry.declarations(),
        ..StartThreadOptions::default()
    })
    .await?;
# thread.close().await?;
# Ok(registry)
# }
```

`DynamicToolInputSchema::new` compiles the JSON Schema before registration.
Dispatch validates each call's arguments before invoking host code. HTTP and
file resolver features are disabled and the SDK installs an explicit rejecting
retriever, so input-schema validation cannot fetch remote resources or read
local schema files; use local `$defs`/`definitions` for reusable fragments.

Parse pending server requests through `codex-app-server-interaction`, then
dispatch only the dynamic-tool family:

```rust
use codex_app_server_client::AppServerClient;
use codex_app_server_interaction::{ServerRequestBody, parse_pending};
use codex_app_server_sdk::DynamicToolRegistry;

# async fn dispatch(
#     client: &AppServerClient,
#     registry: &DynamicToolRegistry,
# ) -> Result<(), Box<dyn std::error::Error>> {
for request in parse_pending(&client.snapshot().await?)? {
    if matches!(&request.body, ServerRequestBody::DynamicToolCall { .. }) {
        let reply = registry.dispatch(&request).await?;
        client
            .resolve_server_request(request.key, reply.into_resolution())
            .await?;
    }
}
# Ok(())
# }
```

Registry dispatch deliberately does not resolve the client request. Cancelling
or dropping a handler future leaves the exact epoch-qualified request pending,
so the host can retry it or apply another explicit policy. Handler errors are
owned diagnostics and are not automatically sent to the model.

Namespace registration uses one handler for all child functions. Match
`DynamicToolCall::tool` inside that handler; registry lookup always uses the
exact `(namespace, tool)` pair. Duplicate top-level declarations and duplicate
child names are rejected atomically.

## Swift declarations

### Declare a tool

```swift
let tool = CodexSchemaDynamicToolSpec(.dictionary([
    "type": .string("function"),
    "name": .string("record_lookup"),
    "description": .string("Look up a local project record"),
    "inputSchema": .dictionary([
        "type": .string("object"),
        "properties": .dictionary([
            "id": .dictionary(["type": .string("string")])
        ]),
        "required": .array([.string("id")])
    ])
]))

let thread = try await codex.startThread(.init(dynamicTools: [tool]))
```

### Return content

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
