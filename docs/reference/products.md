# Products and module boundaries

## CodexCore

Swift SDK with no SwiftUI or AppKit dependency, currently packaged for macOS 26+. Use it for custom clients, headless tools, alternate UI frameworks, and test harnesses on that platform.

Primary namespaces:

- `Client/`: facade, configuration, transport, leases, helpers
- `Session/`: ordered coordination and server requests
- `StateEngine/`: canonical models, reducer, observation
- `Protocol/` and `Generated/`: app-server wire contract
- `Parser/` and `Projection/`: reusable content interpretation

## CodexCoreUI

Reusable SwiftUI/AppKit presentation layer built on CodexCore. It does not create or own a hidden parallel runtime.

## codex-core-app

Native macOS reference host demonstrating end-to-end integration. Application-specific state belongs here rather than in the SDK or reusable UI.

## codex-run

Development demonstration, not a stable command-line product. It uses a hard-coded `todo.html` prompt, auto-approves command/file/permission requests, declines MCP elicitation, fails dynamic tools, and submits empty answers to user-input requests.
