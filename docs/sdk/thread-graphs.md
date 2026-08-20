# Recursive thread graphs

`CodexThreadGraphProjector` derives a durable, host-qualified graph from one
immutable `CanonicalStateSnapshot`. The canonical session remains the only
protocol reducer.

```swift
let graph = await CodexThreadGraphService(codex: codex).snapshot()
let root = CodexThreadGraphKey(hostID: "local", threadID: thread.id)
let descendants = graph.descendants(of: root)
```

Nodes use `CodexThreadGraphKey(hostID:threadID:)`, so identical thread IDs on
different app-server hosts never collide. Edges reconcile collaboration items,
`parentThreadID`, and fork metadata. Discovery is breadth-first, deterministic,
and cycle safe. A child announced before its thread is loaded remains as a
partial node and is enriched when metadata arrives.

## Lifecycle and actions

`CodexCollabAgentLifecycle` preserves the exact server values:
`pendingInit`, `running`, `completed`, `interrupted`, `shutdown`, `errored`, and
`notFound`. Unknown future values are lossless. Collaboration actions use the
composite `ItemKey`, so started and completed forms update one stable identity.

`CodexThreadGraphService` provides host-level equivalents for operations the
public app-server protocol supports:

- `sendMessage` resumes a thread and starts a turn.
- `fork` carries conversation history into a local or same-worktree context.
- `wait` returns terminal turn status, result text, and errors.
- `interruptRecursively` discovers descendants and interrupts leaf-first.
- `setArchivedRecursively` archives leaf-first and unarchives root-first,
  returning partial failures rather than hiding them.

The reference app exposes these through Voice task tools alongside status
inspection. `wait_threads` accepts at most eight tasks and a 120-second timeout.

Independent task-to-task communication is deliberately not a parent/child graph
edge. Pass the calling task as `source` to retain provenance in the destination:

```swift
try await graphService.sendMessage(
    to: destination,
    prompt: "Report your current status.",
    source: coordinator
)
```

CodexCore encodes the official `<codex_delegation>` envelope. Canonical transcript
projection displays only its inner prompt and exposes the source task separately
for navigation. Ordinary user prompts remain unchanged.

## Protocol limitation

`spawnAgent`, `sendInput`, `resumeAgent`, `wait`, and `closeAgent` are
model-internal collaboration tool calls represented by transcript items. In the
app-server protocol pinned by `Tools/UPSTREAM_VERSION`, they are not callable
RPC methods. `requireCallable(_:)` therefore returns a typed
`unsupportedCollaborationAction` error. Thread-level message, resume, wait,
interrupt, fork, and archive APIs must not be described as invoking those
internal tools.

The protocol fork RPC can preserve local and existing-worktree context. Creating
a new worktree or cloud task requires host provisioning outside CodexCore; the
reference Voice bridge rejects those contexts instead of silently running them
locally.

Side chats are ephemeral forks. Their transcript remains owned by a selected
thread lease and their graph identity comes from fork metadata; they do not
create a second reducer or replay child events into the parent.

## Rust presentation projection

The experimental Rust platform exposes the same framework-neutral projection
from `codex-presentation`. It consumes only an immutable canonical snapshot and
does not create another reducer or subscribe to protocol events:

```rust
use codex_presentation::{ThreadGraphKey, ThreadGraphProjector};

let graph = ThreadGraphProjector::project(state, "local");
let root = ThreadGraphKey::new("local", thread_id.clone());
let descendants = graph.descendants(&root);
```

Receiver IDs, agent paths and nicknames remain exact; unknown future lifecycle
and collaboration-tool values are retained by their lossless enum variants.
