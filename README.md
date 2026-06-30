# CodexCore

Swift SDK and SwiftUI components for apps built on the Codex app-server.

![CodexCore overview](docs/codexcore-overview.svg)

## Products

| Product | What it is |
| --- | --- |
| `CodexCore` | Pure Swift SDK: client, transports, protocol types, store, projections, dynamic tools, and command sessions. |
| `CodexCoreUI` | Optional SwiftUI workspace, transcript cards, themes, prompt state, side chat, and subagent UI. |
| `codex-run` | Small executable for exercising the SDK. |
| `codex-chat-example` | Complete SwiftUI example app. |

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
swift run codex-chat-example
```

`CodexConfig` inherits auth through `CODEX_HOME=~/.codex` by default. Override `CODEX_BINARY`, `CODEX_BIN`, `CODEX_APP_BUNDLE`, or `codexBinaryPath` when using a custom Codex runtime.

## Requirements

- Swift 6
- macOS 26+ or iOS 17+
- Codex runtime installed locally for live app use
