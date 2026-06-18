import Foundation
import CodexCore

@MainActor
public final class CodexPromptEventSession {
    private var interactivePromptEventTask: Task<Void, Never>?

    public init() {}

    func startInteractivePromptEventListener(
        from bridge: CodexInteractivePromptBridge,
        onEvent: @escaping @MainActor (CodexInteractivePromptEvent) -> Void
    ) {
        interactivePromptEventTask?.cancel()
        interactivePromptEventTask = Task { @MainActor [bridge] in
            let events = await bridge.events()
            for await event in events {
                guard !Task.isCancelled else { return }
                onEvent(event)
            }
        }
    }

    public func consumeInteractivePromptEvents(
        _ events: AsyncStream<CodexInteractivePromptEvent>,
        onEvent: @escaping @MainActor (CodexInteractivePromptEvent) -> Void
    ) {
        interactivePromptEventTask?.cancel()
        interactivePromptEventTask = Task { @MainActor in
            for await event in events {
                guard !Task.isCancelled else { return }
                onEvent(event)
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
