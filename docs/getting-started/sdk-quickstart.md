# SDK quick start

Use `CodexCore` when your application owns presentation and policy.

## Connect and run one turn

```swift
import CodexCore
import Foundation

let cwd = FileManager.default.currentDirectoryPath
let codex = try await Codex(config: .init(cwd: cwd))

do {
    let thread = try await codex.startThread(.init(cwd: cwd))
    defer { Task { await thread.close() } }

    let input = CodexSchemaUserInput(.dictionary([
        "type": .string("text"),
        "text": .string("Explain the package structure without changing files."),
    ]))

    let terminal = try await thread.runTurn(.init(
        input: [input],
        threadID: thread.id.rawValue
    ))

    print(terminal.turn.status.rawValue)
} catch {
    print("Codex failed: \(error)")
}

await codex.close()
```

## Lifecycle rules

- Create one `Codex` per ordered app-server session.
- Hold a `CodexThreadLease` while a thread must remain subscribed and hydrated.
- Use `CodexTurnLease` for a specific composite thread/turn identity.
- Close thread leases and the Codex session explicitly.
- Present or resolve server requests; never hide approval policy inside the SDK.

Continue with [threads and turns](../sdk/threads-and-turns.md), [observing state](../sdk/observing-state.md), and [approvals and input](../sdk/approvals-and-input.md).
