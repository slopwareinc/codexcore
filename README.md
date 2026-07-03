# CodexCore

Swift SDK, reusable SwiftUI app layer, and full native app for the Codex app-server stack.

![CodexCore overview](docs/codexcore-overview.svg)

## Products

| Product | What it is |
| --- | --- |
| `CodexCore` | Pure Swift SDK: client, transports, protocol types, store, projections, dynamic tools, and command sessions. |
| `CodexCoreUI` | Reusable SwiftUI app layer for using Codex as an intelligence layer inside a Swift app. |
| `codex-run` | Small executable for exercising the SDK. |
| `codex-core-app` | Full usable SwiftUI app demonstrating the modular Swift-native Codex stack. |

## Stack Vocabulary

- Codex app-server is the harness.
- CodexCore is the Swift SDK for Codex app-server.
- CodexCoreUI is the reusable app layer for using Codex as an intelligence layer in a Swift app.
- CodexCoreApp is a full usable app made to demonstrate the modular Swift-native Codex stack.

## Install

```swift
dependencies: [
    .package(url: "https://github.com/slopwareinc/codexcore.git", from: "0.2.0")
]
```

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "CodexCore", package: "CodexCore"),
        .product(name: "CodexCoreUI", package: "CodexCore")
    ]
)
```

Use only `CodexCore` if you do not need SwiftUI.

## Quick Start

```swift
import CodexCore

let codex = try await Codex(config: CodexConfig(
    cwd: FileManager.default.currentDirectoryPath,
    approvalPolicy: .ask
))

let thread = try await codex.threadStart()
let result = try await thread.run("Summarize this project.")

print(result.finalResponse ?? "")
await codex.close()
```

## SwiftUI Workspace

```swift
import SwiftUI
import CodexCoreUI

CodexChatWorkspaceView(
    messages: messages,
    lifecycleEvents: lifecycleEvents,
    sideChat: sideChat,
    subagents: subagents,
    activities: activities,
    connectionState: .connected(server: "Codex"),
    workspacePath: workspacePath,
    draft: $draft,
    isSending: isSending,
    canSend: canSend,
    onSend: send,
    onInterrupt: interrupt,
    onDisconnect: disconnect
)
.codexAgentTheme(.officialDark)
```

## Run Locally

```bash
swift build
swift test
swift run codex-core-app
```

`CodexConfig` inherits auth through `CODEX_HOME=~/.codex` by default. Override `CODEX_BINARY`, `CODEX_BIN`, `CODEX_APP_BUNDLE`, or `codexBinaryPath` when using a custom Codex runtime.

## Requirements

- Swift 6
- macOS 26+ or iOS 17+
- Codex runtime installed locally for live app use
