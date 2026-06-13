import Foundation

// MARK: - Approval Decisions & Policy

/// A user's decision for an escalated server request, matching the v2
/// `CommandExecutionApprovalDecision` / `FileChangeApprovalDecision` wire values.
public enum CodexApprovalDecision: String, Codable, Sendable, Equatable, CaseIterable {
    /// Approve this request once.
    case accept
    /// Approve this request and matching requests for the rest of the session.
    case acceptForSession
    /// Deny this request; the agent continues the turn.
    case decline
    /// Deny this request and interrupt the turn.
    case cancel

    /// The equivalent wire value for the legacy v1 `ReviewDecision` used by
    /// `execCommandApproval` and `applyPatchApproval`.
    var v1ReviewDecision: String {
        switch self {
        case .accept: return "approved"
        case .acceptForSession: return "approved_for_session"
        case .decline: return "denied"
        case .cancel: return "abort"
        }
    }

    public var isApproval: Bool {
        self == .accept || self == .acceptForSession
    }
}

/// How the SDK answers escalated server requests (approvals and user-input
/// questions) when the host has not installed a custom `serverRequestHandler`.
public enum CodexApprovalPolicy: Sendable, Equatable {
    /// Approve every escalated request immediately. This preserves the historic
    /// SDK behavior and suits trusted/headless automation. Prefer shaping the
    /// policy server-side via `ApprovalMode` on `threadStart` so the server
    /// only escalates what you intend to allow.
    case autoApprove
    /// Decline every escalated request immediately.
    case autoDecline
    /// Publish the request to the store (`pendingApprovals` / `pendingUserInput`)
    /// and suspend the JSON-RPC reply until the host resolves it via
    /// `resolveApproval(requestId:decision:)` / `resolveUserInput(requestId:answers:)`.
    case ask
}

/// Answers for an `item/tool/requestUserInput` server request, keyed by
/// question id. Each question can carry multiple answer strings.
public typealias CodexUserInputAnswers = [String: [String]]
