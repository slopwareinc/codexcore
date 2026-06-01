# CodexCore 🎵🐾

**CodexCore** is a high-performance, pure Swift SDK for OpenAI's `codex app-server`. It implements an event-driven, unidirectional state timeline engine, written in pure Swift, using zero third-party dependencies.

Fusing **the speed of Swift** with the **process orchestration patterns of Rust** (as seen in the `dnakov/litter` mobile client core), CodexCore is built to act as the single source of truth for agentic loops, remote connections, and multi-turn conversation timelines.

---

## 🎯 What We Want to Achieve

1. **Standalone Portability:**
   Fully encapsulated Swift Package Manager (SPM) project that can be easily pushed to its own GitHub repository, maintaining clean separation of concerns.
2. **Multi-Transport Wire Protocol:**
   Modular transport layer (`CodexTransport`) supporting local subprocess execution (`Stdio`) as well as native WebSockets (`WebSocketTask`) to facilitate a future switch to web-based frontends (like Tauri).
3. **Resilient Connection Handling:**
   A robust, backoff-driven connection machine with an event buffer that tolerates connection dropouts and reconciles session turns upon reconnection.
4. **Strongly-Typed Protocol Mappings:**
   Comprehensive Swift mapping of OpenAI's official `codex-app-server-protocol` notifications, approvals, and user input structures.
5. **Deterministic State Reducer:**
   A centralized state store (`CodexCoreStore`) that processes actions and projects them into immutable snapshots, separating side-effects from UI rendering.
6. **Exploration Merging & Hydration:**
   A high-fidelity projection engine that strips protocol noise, merges consecutive quiet background actions (like repeated shell commands) into single expandable rows, and selectively prunes older detailed payloads to conserve memory.

---

## 🧩 Architectural Layout

```
CodexCore/
├── Package.swift
├── README.md
└── Sources/
    └── CodexCore/
        ├── Client/
        │   ├── Transport.swift             # Stdio, WebSockets, and SSH interfaces
        │   └── ReconnectionManager.swift   # Resilient backoffs and state recovery
        ├── Protocol/
        │   └── Protocol.swift              # Strongly-typed JSON-RPC schemas
        ├── Store/
        │   └── Store.swift                 # Reducer, State, Actions, and ThreadSnapshots
        └── Projection/
            └── Projection.swift            # Timeline hydration & exploration merging
```

---

## 🧪 How to Test It's Working

CodexCore includes a complete suite of unit tests located in `Tests/CodexCoreTests/CodexCoreTests.swift`. These tests cover:
1. **Strongly-Typed Parsing:** Validating the JSON-RPC decoders against standard server notifications.
2. **State Reducer Pipeline:** Simulating an active turn, stream deltas, and confirming that the thread snapshots update deterministically.
3. **Exploration Merging:** Ensuring multiple consecutive quiet background actions collapse into a single `.exploration` timeline row.
4. **Pruning/Retention:** Verifying that only the active and most recent turns retain heavy raw detailed structures.

### Running Tests
To verify the entire SDK, open your terminal inside `/Users/betterclever/projects/slopware/CodexCore` and run:
```bash
swift test
```

---

## 🚀 How to Use CodexCore in Walkable

Integrating **CodexCore** into Walkable is clean, modular, and standard:

### 1. Link CodexCore in Walkable's `Package.swift`
Add the local package dependency in Walkable's `Package.swift`:
```swift
dependencies: [
    .package(path: "../projects/slopware/CodexCore")
],
targets: [
    .executableTarget(
        name: "Walkable",
        dependencies: [
            .product(name: "CodexCore", package: "CodexCore"),
            // ...
        ]
    )
]
```

### 2. Connect the Timeline inside Walkable Views
Inside Walkable's UI, import CodexCore and subscribe to the core store:
```swift
import SwiftUI
import CodexCore

struct WalkableChatView: View {
    @State private var store = CodexCoreStore()

    var body: some View {
        ScrollView {
            VStack {
                ForEach(store.timelineItems) { item in
                    CodexCoreTimelineRow(item: item)
                }
            }
        }
    }
}
```
This isolates Walkable’s UI from direct process/JSON-RPC manipulation, keeping it highly maintainable and ready for future frontend transitions (like Tauri)!
