# Products and module boundaries

## Rust workspace (experimental)

Portable Rust foundations for the App Server SDK and GPUI platform are under
`rust/`. The protocol, transport, canonical state, and presentation layers stay
independent of GPUI; the future `codex-gpui` product consumes those layers as a
controlled native component framework. See the
[Rust SDK and GPUI platform](../architecture/rust-gpui-platform.md) guide.

`codex-app-server-client` is the current public runtime slice. It owns one
ordered local session, validates initialize metadata, correlates raw requests,
publishes revision invalidations, and retains exact pending server-request
identity. Start with the [Rust SDK quick start](../getting-started/rust-sdk-quickstart.md).

The Rust products are not yet a stable replacement for the supported Swift SDK
or reference app. Capability claims must remain tied to compiling code and the
parity audit.

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
