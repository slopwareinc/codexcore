import Foundation

/// Scope of a recovery action. A history retry must never submit a turn, and a
/// turn retry must never replay an indeterminate writer mutation.
public enum CodexTranscriptRecoveryScope: String, Sendable, Equatable {
    case session
    case history
    case turn
    case thread
}

public enum CodexTranscriptRecoveryPhase: Sendable, Equatable {
    case idle
    case reconnecting(attempt: Int, maximumAttempts: Int?)
    case awaitingVerification
    case retryingHistory
    case retryingTurn
    case recovered
    case failed
}

/// Presentation-independent guard for reconnect/history/turn recovery. It is
/// deliberately conservative: an uncertain write can be verified or rolled
/// back, but it can never be replayed implicitly after a connection loss.
public struct CodexTranscriptRecoveryState: Sendable, Equatable {
    public private(set) var phase: CodexTranscriptRecoveryPhase
    public private(set) var scope: CodexTranscriptRecoveryScope
    public private(set) var mutationReplayAllowed: Bool
    public private(set) var originalRequestID: String?
    public private(set) var message: String?

    public init(
        phase: CodexTranscriptRecoveryPhase = .idle,
        scope: CodexTranscriptRecoveryScope = .session,
        mutationReplayAllowed: Bool = false,
        originalRequestID: String? = nil,
        message: String? = nil
    ) {
        self.phase = phase
        self.scope = scope
        self.mutationReplayAllowed = mutationReplayAllowed
        self.originalRequestID = originalRequestID
        self.message = message
    }

    public var canRetryHistory: Bool {
        guard scope == .history else { return false }
        switch phase {
        case .failed, .reconnecting: return true
        default: return false
        }
    }

    public var canRetryTurn: Bool {
        scope == .turn && phase == .failed && mutationReplayAllowed
    }

    public func notice(id: String = "recovery-state") -> CodexTranscriptRecoveryNoticeV2? {
        let resolvedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolvedMessage, !resolvedMessage.isEmpty else { return nil }
        let kind: CodexTranscriptRecoveryKindV2
        let canRetry: Bool
        switch phase {
        case .reconnecting(let attempt, _):
            kind = .reconnecting(attempt: attempt); canRetry = false
        case .retryingHistory: kind = .historyRetry; canRetry = false
        case .retryingTurn: kind = .turnRetry; canRetry = false
        case .awaitingVerification: kind = .writerConflict; canRetry = false
        case .failed: kind = scope == .thread ? .writerConflict : (scope == .history ? .historyRetry : .turnRetry); canRetry = scope != .thread || mutationReplayAllowed
        case .recovered: return nil
        case .idle: return nil
        }
        return .init(
            id: id,
            kind: kind,
            message: resolvedMessage,
            canRetry: canRetry,
            scope: scope.rawValue,
            isTerminal: phase == .failed,
            retryLabel: canRetry ? "Retry" : nil
        )
    }

    public mutating func beginReconnect(
        attempt: Int,
        maximumAttempts: Int? = nil,
        scope: CodexTranscriptRecoveryScope = .session
    ) {
        phase = .reconnecting(attempt: max(1, attempt), maximumAttempts: maximumAttempts.map { max(1, $0) })
        self.scope = scope
        mutationReplayAllowed = false
        message = "Reconnecting"
    }

    public mutating func markWriteUncertain(requestID: String, message: String? = nil) {
        phase = .awaitingVerification
        scope = .thread
        mutationReplayAllowed = false
        originalRequestID = requestID
        self.message = message ?? "Task creation is not yet confirmed. Do not submit it again while Codex checks its outcome."
    }

    public mutating func verifyWriteSucceeded() {
        phase = .recovered
        mutationReplayAllowed = false
        message = "Write verified"
    }

    public mutating func verifyWriteFailed(_ message: String? = nil) {
        phase = .failed
        mutationReplayAllowed = false
        self.message = message ?? "Write outcome could not be verified"
    }

    public mutating func beginHistoryRetry() -> Bool {
        guard phase != .awaitingVerification else { return false }
        phase = .retryingHistory
        scope = .history
        mutationReplayAllowed = false
        message = "Retrying history"
        return true
    }

    public mutating func beginTurnRetry(requestID: String) -> Bool {
        // Explicit verification is required before a request that might have
        // reached the server can be sent again.
        guard mutationReplayAllowed, phase == .failed else { return false }
        phase = .retryingTurn
        scope = .turn
        originalRequestID = requestID
        message = "Retrying this turn"
        return true
    }

    public mutating func authorizeTurnRetry() {
        guard phase == .failed || phase == .awaitingVerification else { return }
        if phase == .awaitingVerification { phase = .failed }
        mutationReplayAllowed = true
        scope = .turn
    }

    public mutating func markRecovered() {
        phase = .recovered
        mutationReplayAllowed = false
        message = "Recovered"
    }

    public mutating func markFailed(_ message: String) {
        phase = .failed
        mutationReplayAllowed = false
        self.message = message
    }
}
