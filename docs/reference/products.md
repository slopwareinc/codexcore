# Products and module boundaries

## Rust workspace (experimental)

Portable Rust foundations for the App Server SDK and GPUI platform are under
`rust/`. The protocol, transport, canonical state, and presentation layers stay
independent of GPUI. `codex-gpui` consumes disposable presentation models and
provides an accessible virtualized transcript, exact-identity prompt cards,
a bounded native IME-aware composer, virtualized stored-task navigation, and a
compiling native example; it does not own an App Server session or application
lifecycle. See the
[Rust SDK and GPUI platform](../architecture/rust-gpui-platform.md) guide.

`codex-gpui-app` is the native reference-host bootstrap. It currently owns one
window, one SDK session, a real thread/turn lifecycle, safe default interaction
policy, approval routing, composer-driven turns/steering, deterministic quit,
stored-task navigation with mode-aware hydration and lease transfer, and the
GPUI/Tokio bridge. It is not yet the full CodexCore reference-app replacement.

`codex-app-server-client` is the current public runtime slice. It owns one
ordered local session, validates initialize metadata, correlates raw requests,
publishes revision invalidations, and retains exact pending server-request
identity. Start with the [Rust SDK quick start](../getting-started/rust-sdk-quickstart.md).

`codex-presentation` projects immutable canonical snapshots and typed pending
requests into framework-neutral transcript entries, semantic activities, host
policy overrides, unknown-item fallbacks, and blocking prompt models. GPUI must
consume these models rather than decode protocol payloads in render paths.

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
