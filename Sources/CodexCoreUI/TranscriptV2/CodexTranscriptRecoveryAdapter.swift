import CodexCore
import Foundation

/// Adapts session-level recovery into the same typed notice used by turn
/// projection. Session lifecycle remains canonical/runtime state; this adapter
/// merely gives a selected transcript a deterministic explanation.
public enum CodexTranscriptRecoveryAdapter {
    public static func notice(
        for lifecycle: CodexSessionLifecycle,
        threadID: String? = nil
    ) -> CodexTranscriptRecoveryNoticeV2? {
        let scope = threadID.map { ":\($0)" } ?? ""
        switch lifecycle {
        case .reconnecting(_, let attempt):
            return .init(
                id: "session-reconnecting\(scope)",
                kind: .reconnecting(attempt: max(1, attempt)),
                message: "Reconnecting to Codex (attempt \(max(1, attempt)))",
                canRetry: false,
                scope: threadID.map { "thread:\($0)" } ?? "session",
                attempt: max(1, attempt)
            )
        case .failed(let error):
            return .init(
                id: "session-failed\(scope)",
                kind: .streamFailure,
                message: "Codex connection failed: \(bounded(error))",
                canRetry: true,
                scope: threadID.map { "thread:\($0)" } ?? "session",
                isTerminal: true,
                retryLabel: "Retry connection"
            )
        case .connecting, .initializing, .ready, .stopped, .closing:
            return nil
        }
    }

    public static func notice(
        for error: CodexSessionError,
        threadID: String? = nil
    ) -> CodexTranscriptRecoveryNoticeV2? {
        let scope = threadID.map { ":\($0)" } ?? ""
        switch error {
        case .historyReconciliationFailed(_, let message):
            return .init(
                id: "history-retry\(scope)",
                kind: .historyRetry,
                message: "History could not be restored: \(bounded(message))",
                canRetry: true,
                scope: threadID.map { "thread:\($0)" } ?? "history",
                retryLabel: "Retry history"
            )
        case .connectionLost(_, let message), .connectionFailed(let message):
            return .init(
                id: "stream-failure\(scope)",
                kind: .streamFailure,
                message: "Connection lost: \(bounded(message))",
                canRetry: true,
                scope: threadID.map { "thread:\($0)" } ?? "session",
                retryLabel: "Retry turn"
            )
        case .stateCommitFailed(let message):
            return .init(
                id: "writer-conflict\(scope)",
                kind: .writerConflict,
                message: "Thread state was not written: \(bounded(message))",
                canRetry: true,
                scope: threadID.map { "thread:\($0)" } ?? "thread",
                retryLabel: "Verify"
            )
        case .unsupportedThreadOperation, .notReady, .closed,
             .protocolViolation, .codexHomePreparationFailed,
             .codexHomeMismatch, .handshakeBufferOverflow, .requestIdentifierExhausted,
             .unknownServerRequest, .anonymousLoginAlreadyInProgress,
             .loginCancellationNotFound, .loginCancellationDidNotCancel:
            return nil
        }
    }

    private static func bounded(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 240 else { return trimmed }
        return String(trimmed.prefix(240)) + "…"
    }
}
