import Foundation

/// Coordinates the asynchronous work AppKit requires before accepting quit.
///
/// AppKit can ask the delegate more than once while a termination reply is
/// pending. The first request owns the disconnect operation; later requests
/// only join its reply list. This keeps the app-server close/reap path exactly
/// once per application lifetime.
@MainActor
final class CodexApplicationTerminationCoordinator {
    enum State: Equatable {
        case running
        case draining
        case completed
    }

    private(set) var state: State = .running
    private var pendingReplies: [@MainActor @Sendable () -> Void] = []

    func requestTermination(
        disconnect: @escaping @MainActor @Sendable () async -> Void,
        reply: @escaping @MainActor @Sendable () -> Void
    ) {
        if state == .completed {
            reply()
            return
        }

        pendingReplies.append(reply)
        guard state == .running else { return }
        state = .draining

        Task { @MainActor [weak self] in
            await disconnect()
            guard let self else { return }
            state = .completed
            let replies = pendingReplies
            pendingReplies.removeAll(keepingCapacity: false)
            for reply in replies {
                reply()
            }
        }
    }
}
