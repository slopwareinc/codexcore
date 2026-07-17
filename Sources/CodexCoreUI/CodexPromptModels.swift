import Foundation
import CodexCore

public enum CodexApprovalPromptKind: String, Equatable, Sendable {
    case command
    case fileChange
    case permissions
    case execCommand
    case applyPatch

    public var displayName: String {
        switch self {
        case .command, .execCommand: return "Command"
        case .fileChange, .applyPatch: return "File change"
        case .permissions: return "Permissions"
        }
    }

    public var systemImage: String {
        switch self {
        case .command, .execCommand: return "terminal"
        case .fileChange, .applyPatch: return "doc.text"
        case .permissions: return "lock.open"
        }
    }
}

public extension CodexServerRequestKey {
    /// Stable display/cache identity. Runtime routing always uses the key itself.
    var presentationID: String {
        let kind: String
        switch requestID {
        case .integer: kind = "i"
        case .string: kind = "s"
        }
        return "request:\(connectionEpoch):\(kind):\(requestID.description)"
    }
}

/// What pressing send does while a turn is already running, mirroring the
/// official app's `Follow-up behavior: Queue / Steer` setting.
public enum CodexFollowUpBehavior: String, CaseIterable, Codable, Sendable, Identifiable {
    case steer
    case queue

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .steer: return "Steer"
        case .queue: return "Queue"
        }
    }

    public var detail: String {
        switch self {
        case .steer: return "Redirect the current turn immediately"
        case .queue: return "Send after the current turn completes"
        }
    }
}

public struct CodexApprovalPrompt: Identifiable, Equatable, Sendable {
    /// Exact JSON-RPC identity, including connection epoch and integer/string
    /// request-id type. This value is also the SwiftUI identity.
    public var id: CodexServerRequestKey
    public var method: String
    public var kind: CodexApprovalPromptKind
    public var title: String
    public var detail: String
    public var primaryValue: String?
    public var secondaryValue: String?
    public var cwd: String?
    public var reason: String?
    public var threadId: String?
    public var turnId: String?
    public var itemId: String?
    public var approvalId: String?
    public var environmentId: String?
    public var availableDecisions: [CodexCommandApprovalDecision]?
    public var commandActions: [CodexCommandAction]
    public var additionalPermissions: CodexJSONValue?
    public var networkApprovalContext: CodexNetworkApprovalContext?
    public var proposedExecpolicyAmendment: [String]?
    public var proposedNetworkPolicyAmendments: [CodexNetworkPolicyAmendment]
    public var createdAt: Date

    public init(
        id: CodexServerRequestKey,
        method: String,
        kind: CodexApprovalPromptKind,
        title: String,
        detail: String,
        primaryValue: String? = nil,
        secondaryValue: String? = nil,
        cwd: String? = nil,
        reason: String? = nil,
        threadId: String? = nil,
        turnId: String? = nil,
        itemId: String? = nil,
        approvalId: String? = nil,
        environmentId: String? = nil,
        availableDecisions: [CodexCommandApprovalDecision]? = nil,
        commandActions: [CodexCommandAction] = [],
        additionalPermissions: CodexJSONValue? = nil,
        networkApprovalContext: CodexNetworkApprovalContext? = nil,
        proposedExecpolicyAmendment: [String]? = nil,
        proposedNetworkPolicyAmendments: [CodexNetworkPolicyAmendment] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.method = method
        self.kind = kind
        self.title = title
        self.detail = detail
        self.primaryValue = primaryValue
        self.secondaryValue = secondaryValue
        self.cwd = cwd
        self.reason = reason
        self.threadId = threadId
        self.turnId = turnId
        self.itemId = itemId
        self.approvalId = approvalId
        self.environmentId = environmentId
        self.availableDecisions = availableDecisions
        self.commandActions = commandActions
        self.additionalPermissions = additionalPermissions
        self.networkApprovalContext = networkApprovalContext
        self.proposedExecpolicyAmendment = proposedExecpolicyAmendment
        self.proposedNetworkPolicyAmendments = proposedNetworkPolicyAmendments
        self.createdAt = createdAt
    }

    /// Projects only the typed, sanitized inbox representation. Raw request
    /// params and one-shot response values never cross this seam.
    public init?(inboxEntry entry: CodexServerRequestInboxEntry, createdAt: Date = Date()) {
        let snapshot = entry.ledgerSnapshot
        let scope = snapshot.scope
        switch entry.body {
        case .commandApproval(let request):
            let isLegacy = snapshot.kind == .legacyExecCommandApproval
            self.init(
                id: entry.key,
                method: snapshot.method,
                kind: isLegacy ? .execCommand : .command,
                title: "Approve command?",
                detail: request.reason ?? "Codex wants to run a command.",
                primaryValue: request.command,
                secondaryValue: request.cwd,
                cwd: request.cwd,
                reason: request.reason,
                threadId: scope.threadID,
                turnId: scope.turnID,
                itemId: scope.itemID,
                approvalId: snapshot.approvalCorrelation?.approvalID ?? request.callID,
                environmentId: request.environmentID,
                availableDecisions: request.availableDecisions,
                commandActions: request.commandActions,
                additionalPermissions: request.additionalPermissions,
                networkApprovalContext: request.networkApprovalContext,
                proposedExecpolicyAmendment: request.proposedExecpolicyAmendment,
                proposedNetworkPolicyAmendments: request.proposedNetworkPolicyAmendments,
                createdAt: createdAt
            )

        case .fileChangeApproval(let request):
            let isLegacy = snapshot.kind == .legacyApplyPatchApproval
            self.init(
                id: entry.key,
                method: snapshot.method,
                kind: isLegacy ? .applyPatch : .fileChange,
                title: isLegacy ? "Approve patch?" : "Approve file change?",
                detail: request.reason ?? (isLegacy
                    ? "Codex wants to apply file changes."
                    : "Codex wants permission to edit files."),
                primaryValue: request.fileChanges.map(Self.fileChangeSummary) ?? request.grantRoot,
                reason: request.reason,
                threadId: scope.threadID,
                turnId: scope.turnID,
                itemId: scope.itemID,
                approvalId: request.callID,
                createdAt: createdAt
            )

        case .permissionsApproval(let request):
            self.init(
                id: entry.key,
                method: snapshot.method,
                kind: .permissions,
                title: "Approve permissions?",
                detail: request.reason ?? "Codex wants broader permissions for this turn.",
                primaryValue: Self.permissionSummary(from: request.permissions),
                secondaryValue: request.cwd,
                cwd: request.cwd,
                reason: request.reason,
                threadId: scope.threadID,
                turnId: scope.turnID,
                itemId: scope.itemID,
                environmentId: request.environmentID,
                additionalPermissions: request.permissions,
                createdAt: createdAt
            )

        case .userInput, .mcpElicitation, .unsupported:
            return nil
        }
    }

    public var commandDecisions: [CodexCommandApprovalDecision] {
        guard kind == .command || kind == .execCommand else { return [] }
        return availableDecisions ?? [.accept, .acceptForSession, .decline, .cancel]
    }

    public var contextLines: [String] {
        var lines: [String] = []
        if let environmentId, !environmentId.isEmpty { lines.append("Environment: \(environmentId)") }
        if let networkApprovalContext {
            lines.append("Network: \(networkApprovalContext.protocol)://\(networkApprovalContext.host)")
        }
        if let additionalPermissions {
            lines.append("Requested permissions: \(Self.compactJSON(additionalPermissions))")
        }
        lines += commandActions.map { action in
            var detail = action.name ?? action.type
            if !action.command.isEmpty { detail += " · \(action.command)" }
            if let path = action.path { detail += " · \(path)" }
            if let query = action.query { detail += " · \(query)" }
            return "Action: \(detail)"
        }
        if let proposedExecpolicyAmendment, !proposedExecpolicyAmendment.isEmpty {
            lines.append("Command policy: \(proposedExecpolicyAmendment.joined(separator: " "))")
        }
        lines += proposedNetworkPolicyAmendments.map {
            "Network policy: \($0.action.rawValue.capitalized) \($0.host)"
        }
        if let approvalId, !approvalId.isEmpty { lines.append("Approval: \(approvalId)") }
        if let itemId, !itemId.isEmpty { lines.append("Item: \(itemId)") }
        return lines
    }

    public func label(for decision: CodexCommandApprovalDecision) -> String {
        switch decision {
        case .accept: return "Approve"
        case .acceptForSession: return "Approve for session"
        case .decline: return "Deny"
        case .cancel: return "Deny and stop"
        case .acceptWithExecpolicyAmendment(let amendment):
            let command = amendment.joined(separator: " ")
            return command.isEmpty ? "Approve and remember command" : "Approve and remember: \(command)"
        case .applyNetworkPolicyAmendment(let amendment):
            return amendment.action == .allow ? "Allow \(amendment.host)" : "Block \(amendment.host)"
        }
    }

    private static func permissionSummary(from value: CodexJSONValue) -> String? {
        switch value {
        case .dictionary(let object):
            let labels = object.keys.sorted()
            return labels.isEmpty ? nil : labels.joined(separator: ", ")
        case .array(let values):
            let labels = values.compactMap(stringValue)
            return labels.isEmpty ? nil : labels.joined(separator: ", ")
        case .string(let string):
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case .int, .double, .bool, .null:
            return stringValue(value)
        }
    }

    private static func fileChangeSummary<Value>(from changes: [String: Value]) -> String {
        let labels = changes.keys.sorted()
        return labels.isEmpty ? "Patch changes" : labels.prefix(4).joined(separator: ", ")
    }

    private static func compactJSON(_ value: CodexJSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else { return "requested" }
        return string
    }

    private static func stringValue(_ value: CodexJSONValue) -> String? {
        switch value {
        case .string(let string): return string
        case .int(let int): return String(int)
        case .double(let double): return String(double)
        case .bool(let bool): return String(bool)
        case .array(let values): return values.compactMap(stringValue).joined(separator: " ")
        case .dictionary, .null: return nil
        }
    }
}

public enum CodexInteractivePromptKind: String, Equatable, Sendable {
    case userInput
    case mcpElicitation

    public var displayName: String {
        switch self {
        case .userInput: return "Input"
        case .mcpElicitation: return "MCP request"
        }
    }

    public var systemImage: String {
        switch self {
        case .userInput: return "questionmark.bubble"
        case .mcpElicitation: return "puzzlepiece.extension"
        }
    }
}

public struct CodexInteractivePrompt: Identifiable, Equatable, Sendable {
    /// Exact JSON-RPC identity and SwiftUI identity.
    public var id: CodexServerRequestKey
    public var method: String
    public var kind: CodexInteractivePromptKind
    public var title: String
    public var detail: String
    public var serverName: String?
    public var threadId: String?
    public var turnId: String?
    public var itemId: String?
    public var questions: [CodexUserInputQuestion]
    public var autoResolutionMilliseconds: UInt64?
    /// Sanitized form shape used to build a response. URL authorization data
    /// and MCP metadata are deliberately never retained in presentation state.
    public var mcpElicitationMode: CodexMCPElicitationMode?
    public var createdAt: Date

    public init(
        id: CodexServerRequestKey,
        method: String,
        kind: CodexInteractivePromptKind,
        title: String,
        detail: String,
        serverName: String? = nil,
        threadId: String? = nil,
        turnId: String? = nil,
        itemId: String? = nil,
        questions: [CodexUserInputQuestion] = [],
        autoResolutionMilliseconds: UInt64? = nil,
        mcpElicitationMode: CodexMCPElicitationMode? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.method = method
        self.kind = kind
        self.title = title
        self.detail = detail
        self.serverName = serverName
        self.threadId = threadId
        self.turnId = turnId
        self.itemId = itemId
        self.questions = questions
        self.autoResolutionMilliseconds = autoResolutionMilliseconds
        self.mcpElicitationMode = mcpElicitationMode
        self.createdAt = createdAt
    }

    public init?(inboxEntry entry: CodexServerRequestInboxEntry, createdAt: Date = Date()) {
        let snapshot = entry.ledgerSnapshot
        let scope = snapshot.scope
        switch entry.body {
        case .userInput(let request):
            self.init(
                id: entry.key,
                method: snapshot.method,
                kind: .userInput,
                title: "Input needed",
                detail: request.questions.first?.question
                    ?? "Codex needs more information to continue.",
                threadId: scope.threadID,
                turnId: scope.turnID,
                itemId: scope.itemID,
                questions: request.questions,
                autoResolutionMilliseconds: request.autoResolutionMilliseconds,
                createdAt: createdAt
            )

        case .mcpElicitation(let request):
            let mode = Self.presentationSafe(request.mode)
            let supported = Self.isSupportedElicitationMode(mode)
            self.init(
                id: entry.key,
                method: snapshot.method,
                kind: .mcpElicitation,
                title: "\(request.serverName) request",
                detail: supported
                    ? request.message
                    : "\(request.message) This form contains unsupported fields and can only be declined.",
                serverName: request.serverName,
                threadId: scope.threadID,
                turnId: scope.turnID,
                itemId: scope.itemID,
                questions: Self.elicitationQuestions(from: mode),
                mcpElicitationMode: mode,
                createdAt: createdAt
            )

        case .commandApproval, .fileChangeApproval, .permissionsApproval, .unsupported:
            return nil
        }
    }

    public var canAcceptElicitation: Bool {
        kind == .mcpElicitation
            && mcpElicitationMode.map(Self.isSupportedElicitationMode) == true
    }

    public var requiresElicitationForm: Bool {
        kind == .mcpElicitation && !questions.isEmpty
    }

    public func isElicitationSubmissionValid(answers: [String: String]) -> Bool {
        guard canAcceptElicitation, let schema = elicitationSchema else { return false }
        guard case .array(let required)? = schema["required"] else { return true }
        return required.allSatisfy { value in
            guard case .string(let key) = value else { return false }
            return answers[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    /// Builds a one-shot validated user-input result. The returned value may
    /// contain secrets and must be sent directly to the session, never stored.
    public func userInputResult(answers: [String: String]) -> CodexJSONValue {
        CodexValidatedServerRequestResult.userInput(
            answers.mapValues { [$0] }
        ).jsonValue
    }

    /// Builds a one-shot MCP form response from the sanitized supported fields.
    public func elicitationResult(answers: [String: String]) -> CodexJSONValue {
        var content: [String: CodexJSONValue] = [:]
        if let schema = elicitationSchema,
           case .dictionary(let properties)? = schema["properties"] {
            for (key, answer) in answers where !answer.isEmpty {
                guard case .dictionary(let property)? = properties[key] else { continue }
                if Self.stringValue(property["type"]) == "boolean" {
                    content[key] = .bool(["true", "yes", "1"].contains(answer.lowercased()))
                } else {
                    content[key] = .string(answer)
                }
            }
        }
        return CodexValidatedServerRequestResult.mcpElicitation(
            action: .accept,
            content: .dictionary(content),
            metadata: nil
        ).jsonValue
    }

    public func acceptElicitationResult() -> CodexJSONValue {
        CodexValidatedServerRequestResult.mcpElicitation(
            action: .accept,
            content: .dictionary(["confirmed": .bool(true)]),
            metadata: nil
        ).jsonValue
    }

    public func declineResult() -> CodexJSONValue {
        switch kind {
        case .userInput:
            CodexValidatedServerRequestResult.userInput([:]).jsonValue
        case .mcpElicitation:
            CodexValidatedServerRequestResult.mcpElicitation(
                action: .decline,
                content: nil,
                metadata: nil
            ).jsonValue
        }
    }

    private var elicitationSchema: [String: CodexJSONValue]? {
        guard let mcpElicitationMode else { return nil }
        let schema: CodexJSONValue
        switch mcpElicitationMode {
        case .form(let value), .openAIForm(let value): schema = value
        case .url: return nil
        }
        guard case .dictionary(let object) = schema else { return nil }
        return object
    }

    private static func isSupportedElicitationMode(_ mode: CodexMCPElicitationMode) -> Bool {
        let schema: CodexJSONValue
        switch mode {
        case .form(let value), .openAIForm(let value): schema = value
        case .url: return false
        }
        guard case .dictionary(let object) = schema,
              case .dictionary(let properties)? = object["properties"] else { return true }
        return properties.values.allSatisfy { value in
            guard case .dictionary(let property) = value else { return false }
            return ["string", "boolean"].contains(stringValue(property["type"]))
        }
    }

    private static func elicitationQuestions(
        from mode: CodexMCPElicitationMode
    ) -> [CodexUserInputQuestion] {
        guard isSupportedElicitationMode(mode) else { return [] }
        let schemaValue: CodexJSONValue
        switch mode {
        case .form(let value), .openAIForm(let value): schemaValue = value
        case .url: return []
        }
        guard case .dictionary(let schema) = schemaValue,
              case .dictionary(let properties)? = schema["properties"] else { return [] }
        let required: Set<String>
        if case .array(let values)? = schema["required"] {
            required = Set(values.compactMap { value in
                guard case .string(let key) = value else { return nil }
                return key
            })
        } else {
            required = []
        }
        return properties.keys.sorted().compactMap { key in
            guard case .dictionary(let property)? = properties[key] else { return nil }
            let label = optionalString(property["title"]) ?? key
            let options: [CodexUserInputOption]
            if case .array(let values)? = property["enum"] {
                options = values.compactMap { value in
                    let label = stringValue(value)
                    return label.isEmpty ? nil : CodexUserInputOption(label: label)
                }
            } else if stringValue(property["type"]) == "boolean" {
                options = [CodexUserInputOption(label: "true"), CodexUserInputOption(label: "false")]
            } else {
                options = []
            }
            return CodexUserInputQuestion(
                id: key,
                question: optionalString(property["description"]) ?? label,
                header: required.contains(key) ? "\(label) (required)" : label,
                options: options
            )
        }
    }

    private static func presentationSafe(
        _ mode: CodexMCPElicitationMode
    ) -> CodexMCPElicitationMode {
        switch mode {
        case .form(let schema):
            return .form(requestedSchema: sanitizedSchema(schema))
        case .openAIForm(let schema):
            return .openAIForm(requestedSchema: sanitizedSchema(schema))
        case .url:
            return .url(elicitationID: "", url: "")
        }
    }

    private static func sanitizedSchema(_ value: CodexJSONValue) -> CodexJSONValue {
        guard case .dictionary(let schema) = value else { return .dictionary([:]) }
        var sanitized: [String: CodexJSONValue] = [:]
        if let type = schema["type"] { sanitized["type"] = type }
        if let required = schema["required"] { sanitized["required"] = required }
        if case .dictionary(let properties)? = schema["properties"] {
            sanitized["properties"] = .dictionary(properties.mapValues { value in
                guard case .dictionary(let property) = value else { return .dictionary([:]) }
                return .dictionary(property.filter {
                    ["type", "title", "description", "enum"].contains($0.key)
                })
            })
        }
        return .dictionary(sanitized)
    }

    private static func optionalString(_ value: CodexJSONValue?) -> String? {
        let string = stringValue(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }

    private static func stringValue(_ value: CodexJSONValue?) -> String {
        switch value {
        case .string(let string): return string
        case .int(let int): return String(int)
        case .double(let double): return String(double)
        case .bool(let bool): return String(bool)
        case .array(let values): return values.map(stringValue).joined(separator: " ")
        case .dictionary, .null, nil: return ""
        }
    }
}
