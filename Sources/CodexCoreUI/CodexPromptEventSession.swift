import Foundation
import CodexCore

@MainActor
public final class CodexPromptEventSession {
    private var approvalEventTask: Task<Void, Never>?
    private var interactivePromptEventTask: Task<Void, Never>?

    public init() {}

    deinit {
        approvalEventTask?.cancel()
        interactivePromptEventTask?.cancel()
    }

    public func startApprovalStoreMirror(
        from codex: Codex,
        intervalNanoseconds: UInt64 = 200_000_000,
        onSync: @escaping @MainActor ([CodexApprovalRequest], CodexUserInputRequest?) -> Void
    ) {
        startApprovalSnapshotMirror(
            intervalNanoseconds: intervalNanoseconds,
            snapshot: {
                (
                    approvalRequests: codex.store.pendingApprovals,
                    userInput: codex.store.pendingUserInput
                )
            },
            onSync: onSync
        )
    }

    public func startApprovalSnapshotMirror(
        intervalNanoseconds: UInt64 = 200_000_000,
        snapshot: @escaping @MainActor () -> (approvalRequests: [CodexApprovalRequest], userInput: CodexUserInputRequest?),
        onSync: @escaping @MainActor ([CodexApprovalRequest], CodexUserInputRequest?) -> Void
    ) {
        approvalEventTask?.cancel()
        approvalEventTask = Task { @MainActor in
            while !Task.isCancelled {
                let state = snapshot()
                onSync(state.approvalRequests, state.userInput)
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
            }
        }
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

    public func cancelApprovalStoreMirror() {
        approvalEventTask?.cancel()
        approvalEventTask = nil
    }

    public func cancelInteractivePromptEvents() {
        interactivePromptEventTask?.cancel()
        interactivePromptEventTask = nil
    }

    public func reset() {
        cancelApprovalStoreMirror()
        cancelInteractivePromptEvents()
    }
}
