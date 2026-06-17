import Foundation
import CodexCore

@MainActor
public final class CodexPromptEventSession {
    private var interactivePromptEventTask: Task<Void, Never>?

    public init() {}

    deinit {
        interactivePromptEventTask?.cancel()
    }

    public func startInteractivePromptEventListener(
        from bridge: CodexInteractivePromptBridge,
        onEvent: @escaping @MainActor (CodexInteractivePromptEvent) -> Void
    ) {
        interactivePromptEventTask?.cancel()
        interactivePromptEventTask = Task { [bridge] in
            let events = await bridge.events()
            for await event in events {
                guard !Task.isCancelled else { return }
                await MainActor.run { onEvent(event) }
            }
        }
    }

    public func consumeInteractivePromptEvents(
        _ events: AsyncStream<CodexInteractivePromptEvent>,
        onEvent: @escaping @MainActor (CodexInteractivePromptEvent) -> Void
    ) {
        interactivePromptEventTask?.cancel()
        interactivePromptEventTask = Task {
            for await event in events {
                guard !Task.isCancelled else { return }
                await MainActor.run { onEvent(event) }
            }
        }
    }

    public func cancelInteractivePromptEvents() {
        interactivePromptEventTask?.cancel()
        interactivePromptEventTask = nil
    }

    public func reset() {
        cancelInteractivePromptEvents()
    }
}
