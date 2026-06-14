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
    public var id: String
    public var method: String
    public var kind: CodexApprovalPromptKind
    public var title: String
    public var detail: String
    public var primaryValue: String?
    public var secondaryValue: String?
    public var cwd: String?
    public var reason: String?
    public var createdAt: Date
    public var rawParams: [String: CodexJSONValue]

    public init(
        id: String,
        method: String,
        kind: CodexApprovalPromptKind,
        title: String,
        detail: String,
        primaryValue: String? = nil,
        secondaryValue: String? = nil,
        cwd: String? = nil,
        reason: String? = nil,
        createdAt: Date = Date(),
        rawParams: [String: CodexJSONValue] = [:]
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
        self.createdAt = createdAt
        self.rawParams = rawParams
    }

    /// Builds a prompt from a typed store approval request (the `.ask` policy
    /// flow). The prompt id matches `CodexApprovalRequest.id`, so it can be
    /// passed straight to `Codex.respondToApproval(id:decision:)`.
    public init(request: CodexApprovalRequest, createdAt: Date = Date()) {
        let kind: CodexApprovalPromptKind
        let title: String
        let fallbackDetail: String
        var primaryValue: String?
        switch request.kind {
        case .command:
            kind = .command
            title = "Approve command?"
            fallbackDetail = "Codex wants to run a command."
            primaryValue = request.command
        case .fileChange:
            kind = .fileChange
            title = "Approve file change?"
            fallbackDetail = "Codex wants permission to edit files."
            primaryValue = request.path ?? request.grantRoot ?? request.command
        case .permissions:
            kind = .permissions
            title = "Approve permissions?"
            fallbackDetail = "Codex wants broader permissions for this turn."
        }

        self.init(
            id: request.id,
            method: CodexAppServerServerRequestMethod.itemCommandExecutionRequestApproval.rawValue,
            kind: kind,
            title: title,
            detail: request.reason ?? fallbackDetail,
            primaryValue: primaryValue,
            secondaryValue: request.cwd,
            cwd: request.cwd,
            reason: request.reason,
            createdAt: createdAt
        )
    }

    public init?(serverRequest: JSONRPCServerRequest, createdAt: Date = Date()) {
        guard let method = CodexAppServerServerRequestMethod(rawValue: serverRequest.method) else {
            return nil
        }

        let params = serverRequest.params
        let id = "\(serverRequest.method):\(serverRequest.id.description)"
        let reason = Self.string(in: params, keys: ["reason", "message"])
        let cwd = Self.string(in: params, keys: ["cwd", "workingDirectory"])

        switch method {
        case .itemCommandExecutionRequestApproval:
            let command = Self.commandString(from: params["command"])
                ?? Self.commandString(from: params["parsedCmd"])
            self.init(
                id: id,
                method: serverRequest.method,
                kind: .command,
                title: "Approve command?",
                detail: reason ?? "Codex wants to run a command.",
                primaryValue: command,
                secondaryValue: cwd,
                cwd: cwd,
                reason: reason,
                createdAt: createdAt,
                rawParams: params
            )
        case .itemFileChangeRequestApproval:
            let path = Self.string(in: params, keys: ["path", "filePath", "grantRoot"])
            self.init(
                id: id,
                method: serverRequest.method,
                kind: .fileChange,
                title: "Approve file change?",
                detail: reason ?? "Codex wants permission to edit files.",
                primaryValue: path,
                secondaryValue: cwd,
                cwd: cwd,
                reason: reason,
                createdAt: createdAt,
                rawParams: params
            )
        case .itemPermissionsRequestApproval:
            self.init(
                id: id,
                method: serverRequest.method,
                kind: .permissions,
                title: "Approve permissions?",
                detail: reason ?? "Codex wants broader permissions for this turn.",
                primaryValue: Self.permissionSummary(from: params["permissions"]),
                secondaryValue: cwd,
                cwd: cwd,
                reason: reason,
                createdAt: createdAt,
                rawParams: params
            )
        case .execCommandApproval:
            let command = Self.commandString(from: params["command"])
                ?? Self.commandString(from: params["parsedCmd"])
            self.init(
                id: id,
                method: serverRequest.method,
                kind: .execCommand,
                title: "Approve command?",
                detail: reason ?? "Codex wants to run a command.",
                primaryValue: command,
                secondaryValue: cwd,
                cwd: cwd,
                reason: reason,
                createdAt: createdAt,
                rawParams: params
            )
        case .applyPatchApproval:
            self.init(
                id: id,
                method: serverRequest.method,
                kind: .applyPatch,
                title: "Approve patch?",
                detail: reason ?? "Codex wants to apply file changes.",
                primaryValue: Self.fileChangeSummary(from: params["fileChanges"]),
                secondaryValue: cwd,
                cwd: cwd,
                reason: reason,
                createdAt: createdAt,
                rawParams: params
            )
        default:
            return nil
        }
    }

    public func response(approved: Bool) -> CodexJSONValue {
        switch kind {
        case .command, .fileChange:
            return .dictionary(["decision": .string(approved ? "accept" : "decline")])
        case .permissions:
            let permissions: CodexJSONValue
            if approved, let requested = rawParams["permissions"] {
                permissions = requested
            } else {
                permissions = .dictionary([:])
            }
            return .dictionary([
                "permissions": permissions,
                "scope": .string("turn")
            ])
        case .execCommand, .applyPatch:
            return .dictionary(["decision": .string(approved ? "approved" : "denied")])
        }
    }

    private static func string(in object: [String: CodexJSONValue], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key], let string = stringValue(value) else { continue }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
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

    private static func commandString(from value: CodexJSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let command):
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .array(let values):
            let command = values.compactMap(stringValue).joined(separator: " ")
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .dictionary, .int, .double, .bool, .null:
            return stringValue(value)
        }
    }

    private static func permissionSummary(from value: CodexJSONValue?) -> String? {
        guard let value else { return nil }
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

    private static func fileChangeSummary(from value: CodexJSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .dictionary(let object):
            let labels = object.keys.sorted()
            return labels.isEmpty ? "Patch changes" : labels.prefix(4).joined(separator: ", ")
        case .array(let values):
            return "\(values.count) file changes"
        case .string(let string):
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case .int, .double, .bool, .null:
            return stringValue(value)
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
    public var id: String
    public var method: String
    public var kind: CodexInteractivePromptKind
    public var title: String
    public var detail: String
    public var serverName: String?
    public var questions: [CodexUserInputQuestion]
    public var createdAt: Date
    public var rawParams: [String: CodexJSONValue]

    public init(
        id: String,
        method: String,
        kind: CodexInteractivePromptKind,
        title: String,
        detail: String,
        serverName: String? = nil,
        questions: [CodexUserInputQuestion] = [],
        createdAt: Date = Date(),
        rawParams: [String: CodexJSONValue] = [:]
    ) {
        self.id = id
        self.method = method
        self.kind = kind
        self.title = title
        self.detail = detail
        self.serverName = serverName
        self.questions = questions
        self.createdAt = createdAt
        self.rawParams = rawParams
    }

    /// Builds a prompt from a typed store user-input request (the `.ask`
    /// policy flow). The prompt id matches `CodexUserInputRequest.id`, so it
    /// can be passed straight to `Codex.respondToUserInput(id:answers:)`.
    public init(request: CodexUserInputRequest, createdAt: Date = Date()) {
        self.init(
            id: request.id,
            method: CodexAppServerServerRequestMethod.itemToolRequestUserInput.rawValue,
            kind: .userInput,
            title: "Input needed",
            detail: request.questions.first?.question ?? "Codex needs more information to continue.",
            questions: request.questions,
            createdAt: createdAt
        )
    }

    public init?(serverRequest: JSONRPCServerRequest, createdAt: Date = Date()) {
        guard let method = CodexAppServerServerRequestMethod(rawValue: serverRequest.method) else {
            return nil
        }

        let params = serverRequest.params
        let id = "\(serverRequest.method):\(serverRequest.id.description)"

        switch method {
        case .itemToolRequestUserInput:
            let questions = Self.userInputQuestions(from: params["questions"])
            let firstQuestion = questions.first?.question
            self.init(
                id: id,
                method: serverRequest.method,
                kind: .userInput,
                title: "Input needed",
                detail: firstQuestion ?? "Codex needs more information to continue.",
                questions: questions,
                createdAt: createdAt,
                rawParams: params
            )
        case .mcpServerElicitationRequest:
            let serverName = Self.string(in: params, keys: ["serverName", "server"])
            let request = Self.dictionaryValue(params["request"])
            let message = request.flatMap { Self.string(in: $0, keys: ["message", "prompt"]) }
                ?? Self.string(in: params, keys: ["message", "prompt"])
            let title: String
            if let serverName, !serverName.isEmpty {
                title = "\(serverName) request"
            } else {
                title = "MCP request"
            }
            self.init(
                id: id,
                method: serverRequest.method,
                kind: .mcpElicitation,
                title: title,
                detail: message ?? "An MCP server is requesting input.",
                serverName: serverName,
                createdAt: createdAt,
                rawParams: params
            )
        default:
            return nil
        }
    }

    public func userInputResponse(answers: [String: CodexJSONValue]) -> CodexJSONValue {
        .dictionary(["answers": .dictionary(answers)])
    }

    public func userInputResponse(answers: [String: String]) -> CodexJSONValue {
        userInputResponse(answers: answers.mapValues(CodexJSONValue.string))
    }

    public func acceptElicitationResponse(
        content: CodexJSONValue = .dictionary(["confirmed": .bool(true)]),
        meta: CodexJSONValue = .null
    ) -> CodexJSONValue {
        .dictionary([
            "action": .string("accept"),
            "content": content,
            "_meta": meta
        ])
    }

    public func declineResponse() -> CodexJSONValue {
        switch kind {
        case .userInput:
            return userInputResponse(answers: [:] as [String: CodexJSONValue])
        case .mcpElicitation:
            return .dictionary([
                "action": .string("decline"),
                "content": .null,
                "_meta": .null
            ])
        }
    }

    private static func userInputQuestions(from value: CodexJSONValue?) -> [CodexUserInputQuestion] {
        guard case .array(let rawQuestions)? = value else { return [] }
        return rawQuestions.compactMap { rawQuestion in
            guard case .dictionary(let question) = rawQuestion else { return nil }
            let id = stringValue(question["id"])
            let text = stringValue(question["question"])
            guard !id.isEmpty, !text.isEmpty else { return nil }

            let options: [CodexUserInputOption]
            if case .array(let rawOptions)? = question["options"] {
                options = rawOptions.compactMap { rawOption in
                    guard case .dictionary(let option) = rawOption else { return nil }
                    let label = stringValue(option["label"])
                    guard !label.isEmpty else { return nil }
                    return CodexUserInputOption(label: label, description: optionalString(option["description"]))
                }
            } else {
                options = []
            }

            return CodexUserInputQuestion(
                id: id,
                question: text,
                header: optionalString(question["header"]),
                isSecret: boolValue(question["isSecret"]),
                isOtherAllowed: boolValue(question["isOther"]),
                options: options
            )
        }
    }

    private static func string(in object: [String: CodexJSONValue], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            let trimmed = stringValue(value).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
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

    private static func boolValue(_ value: CodexJSONValue?) -> Bool {
        switch value {
        case .bool(let bool): return bool
        case .string(let string): return Bool(string) ?? false
        case .int(let int): return int != 0
        case .double(let double): return double != 0
        case .array, .dictionary, .null, nil: return false
        }
    }

    private static func dictionaryValue(_ value: CodexJSONValue?) -> [String: CodexJSONValue]? {
        if case .dictionary(let object)? = value { return object }
        return nil
    }
}
