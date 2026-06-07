# CodexCore 🎵🐾

**CodexCore** is a high-performance, pure Swift SDK for OpenAI's `codex app-server`. The core target implements an event-driven, unidirectional state timeline engine in pure Swift with zero third-party dependencies. The optional **CodexCoreUI** target adds reusable SwiftUI chat components and Markdown rendering for apps that want a ready-made interface.

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
├── Examples/
│   └── CodexChatExample/              # Dock-visible SwiftUI chat example
└── Sources/
    ├── CodexCore/
    │   ├── Client/                    # Process transport and high-level SDK facade
    │   ├── Protocol/                  # Strongly-typed JSON-RPC schemas
    │   ├── Store/                     # Reducer, state, actions, and thread snapshots
    │   └── Projection/                # Timeline hydration and exploration merging
    └── CodexCoreUI/                   # Optional SwiftUI chat UI and Markdown views
```

---

## 🧪 How to Test It's Working

CodexCore includes a complete suite of unit tests located in `Tests/CodexCoreTests`. These tests cover:
1. **Strongly-Typed Parsing:** Validating the JSON-RPC decoders against standard server notifications.
2. **State Reducer Pipeline:** Simulating an active turn, stream deltas, and confirming that the thread snapshots update deterministically.
3. **Exploration Merging:** Ensuring multiple consecutive quiet background actions collapse into a single `.exploration` timeline row.
4. **Pruning/Retention:** Verifying that only the active and most recent turns retain heavy raw detailed structures.

### Running Tests
To verify the entire SDK, open your terminal inside `/Users/betterclever/Projects/slopware/CodexCore` and run:
```bash
swift test
```

---

## 🚀 How to Use CodexCore

The package exposes two library products:

1. `CodexCore` - dependency-free SDK, protocol types, transports, reducers, and high-level client APIs.
2. `CodexCoreUI` - optional SwiftUI chat surface built on top of `CodexCore`.

### 1. Link the Package

Add the local package dependency to your app's `Package.swift`:
```swift
dependencies: [
    .package(path: "../Projects/slopware/CodexCore")
],
targets: [
    .executableTarget(
        name: "YourApp",
        dependencies: [
            .product(name: "CodexCore", package: "CodexCore"),
            .product(name: "CodexCoreUI", package: "CodexCore")
        ]
    )
]
```

If you only need the SDK and not SwiftUI components, depend on `CodexCore` only.

### 2. Render a Reusable Chat Workspace

`CodexCoreUI` is data-driven: your app owns connection, auth, and thread lifecycle, then passes messages, activity, bindings, and action closures into `CodexChatWorkspaceView`.

```swift
import SwiftUI
import CodexCore
import CodexCoreUI

struct YourChatView: View {
    @State private var draft = ""
    @State private var messages: [CodexChatMessage] = []
    @State private var activities: [CodexActivity] = []

    var body: some View {
        CodexChatWorkspaceView(
            messages: messages,
            activities: activities,
            connectionState: .connected(server: "Codex"),
            workspacePath: FileManager.default.currentDirectoryPath,
            authLabel: "ChatGPT",
            isAuthenticated: true,
            isThreadReady: true,
            draft: $draft,
            isSending: false,
            canSend: !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            onSend: { /* start a Codex turn */ },
            onInterrupt: { /* interrupt active turn */ },
            onDisconnect: { /* close transport */ }
        )
    }
}
```

See `Examples/CodexChatExample` for a complete app that connects to the installed `codex` binary, inherits `~/.codex` auth through `CODEX_HOME`, starts a thread, streams assistant deltas as plain text, and renders final assistant messages with GitHub Flavored Markdown.

### 3. Run the SwiftUI Chat Example

```bash
swift run codex-chat-example
```

The example defaults to the installed Codex binary at `/Users/betterclever/.config/nvm/versions/node/v26.2.0/bin/codex`. Leave the field blank in the welcome screen to resolve `codex` from `PATH` instead.
