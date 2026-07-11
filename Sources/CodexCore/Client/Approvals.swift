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

    public var isApproval: Bool {
        self == .accept || self == .acceptForSession
    }
}

/// The full wire decision union accepted by
/// `item/commandExecution/requestApproval`. File-change and permissions
/// approvals continue to use ``CodexApprovalDecision``.
public enum CodexCommandApprovalDecision: Sendable, Equatable, Codable {
    case accept
    case acceptForSession
    case acceptWithExecpolicyAmendment([String])
    case applyNetworkPolicyAmendment(CodexNetworkPolicyAmendment)
    case decline
    case cancel

    public init(_ decision: CodexApprovalDecision) {
        switch decision {
        case .accept: self = .accept
        case .acceptForSession: self = .acceptForSession
        case .decline: self = .decline
        case .cancel: self = .cancel
        }
    }

    public var isApproval: Bool {
        switch self {
        case .accept, .acceptForSession, .acceptWithExecpolicyAmendment, .applyNetworkPolicyAmendment:
            return true
        case .decline, .cancel:
            return false
        }
    }

    public var jsonValue: CodexJSONValue {
        switch self {
        case .accept:
            return .string("accept")
        case .acceptForSession:
            return .string("acceptForSession")
        case .decline:
            return .string("decline")
        case .cancel:
            return .string("cancel")
        case .acceptWithExecpolicyAmendment(let amendment):
            return .dictionary([
                "acceptWithExecpolicyAmendment": .dictionary([
                    "execpolicy_amendment": .array(amendment.map(CodexJSONValue.string))
                ])
            ])
        case .applyNetworkPolicyAmendment(let amendment):
            return .dictionary([
                "applyNetworkPolicyAmendment": .dictionary([
                    "network_policy_amendment": amendment.jsonValue
                ])
            ])
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try CodexJSONValue(from: decoder)
        guard let decision = Self(jsonValue: value) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unsupported command approval decision: \(value)"
            ))
        }
        self = decision
    }

    public func encode(to encoder: Encoder) throws {
        try jsonValue.encode(to: encoder)
    }

    public init?(jsonValue: CodexJSONValue) {
        switch jsonValue {
        case .string("accept"):
            self = .accept
        case .string("acceptForSession"):
            self = .acceptForSession
        case .string("decline"):
            self = .decline
        case .string("cancel"):
            self = .cancel
        case .dictionary(let outer):
            if case .dictionary(let payload)? = outer["acceptWithExecpolicyAmendment"],
               case .array(let values)? = payload["execpolicy_amendment"] {
                let amendment: [String] = values.compactMap { value in
                    guard case .string(let string) = value else { return nil }
                    return string
                }
                guard amendment.count == values.count else { return nil }
                self = .acceptWithExecpolicyAmendment(amendment)
            } else if case .dictionary(let payload)? = outer["applyNetworkPolicyAmendment"],
                      let amendment = CodexNetworkPolicyAmendment(
                        jsonValue: payload["network_policy_amendment"]
                      ) {
                self = .applyNetworkPolicyAmendment(amendment)
            } else {
                return nil
            }
        default:
            return nil
        }
    }
}

public enum CodexNetworkPolicyRuleAction: String, Codable, Sendable, Equatable {
    case allow
    case deny
}

public struct CodexNetworkPolicyAmendment: Codable, Sendable, Equatable {
    public var action: CodexNetworkPolicyRuleAction
    public var host: String

    public init(action: CodexNetworkPolicyRuleAction, host: String) {
        self.action = action
        self.host = host
    }

    public var jsonValue: CodexJSONValue {
        .dictionary(["action": .string(action.rawValue), "host": .string(host)])
    }

    init?(jsonValue: CodexJSONValue?) {
        guard case .dictionary(let object)? = jsonValue,
              case .string(let rawAction)? = object["action"],
              let action = CodexNetworkPolicyRuleAction(rawValue: rawAction),
              case .string(let host)? = object["host"] else { return nil }
        self.init(action: action, host: host)
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
    /// Publish the request to the store (`pendingApprovals` / `pendingUserInputs`)
    /// and suspend the JSON-RPC reply until the host resolves it via
    /// `resolveApproval(requestId:decision:)` / `resolveUserInput(requestId:answers:)`.
    case ask
}

/// Answers for an `item/tool/requestUserInput` server request, keyed by
/// question id. Each question can carry multiple answer strings.
public typealias CodexUserInputAnswers = [String: [String]]
