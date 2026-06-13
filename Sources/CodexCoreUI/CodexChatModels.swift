import Foundation
import SwiftUI
import CodexCore

public enum CodexConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(server: String)
    case failed(String)

    public var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected(let server): return "Connected to \(server)"
        case .failed: return "Connection failed"
        }
    }
}

public enum CodexApprovalSelection: String, CaseIterable, Identifiable, Equatable, Sendable {
    case readOnly
    case askForApproval
    case approveForMe
    case fullAccess
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .readOnly: return "Read only"
        case .askForApproval: return "Ask for approval"
        case .approveForMe: return "Approve for me"
        case .fullAccess: return "Full access"
        case .custom: return "Custom (config.toml)"
        }
    }

    public var detail: String {
        switch self {
        case .readOnly:
            return "inspect files without making changes"
        case .askForApproval:
            return "always ask to edit external files and use the internet"
        case .approveForMe:
            return "only ask for potentially unsafe actions"
        case .fullAccess:
            return "unrestricted internet and files"
        case .custom:
            return "uses permissions defined in config"
        }
    }

    public var approvalMode: ApprovalMode {
        switch self {
        case .readOnly:
            return .denyAll
        case .askForApproval, .approveForMe, .fullAccess, .custom:
            return .autoReview
        }
    }

    public var sandbox: Sandbox {
        switch self {
        case .readOnly:
            return .readOnly
        case .askForApproval, .approveForMe, .custom:
            return .workspaceWrite
        case .fullAccess:
            return .fullAccess
        }
    }

    public var turnParameterOverrides: [String: CodexJSONValue] {
        switch self {
        case .askForApproval:
            return [
                "approvalPolicy": .string(AskForApproval.onRequest.rawValue),
                "approvalsReviewer": .string(ApprovalsReviewer.user.rawValue)
            ]
        case .readOnly, .approveForMe, .fullAccess, .custom:
            return [:]
        }
    }

    public var permissionProfileID: String? {
        switch self {
        case .readOnly: return ":read-only"
        case .askForApproval, .approveForMe: return ":workspace"
        case .fullAccess: return ":danger-full-access"
        case .custom: return nil
        }
    }

    public static let defaultOptions: [CodexApprovalSelection] = [
        .askForApproval,
        .approveForMe,
        .fullAccess,
        .custom
    ]

    public static func options(from profiles: [CodexPermissionProfileSummary]) -> [CodexApprovalSelection] {
        guard !profiles.isEmpty else { return defaultOptions }
        let ids = Set(profiles.map(\.id))
        var options: [CodexApprovalSelection] = []

        if ids.contains(":read-only") {
            options.append(.readOnly)
        }
        if ids.contains(":workspace") {
            options.append(contentsOf: [.askForApproval, .approveForMe])
        }
        if ids.contains(":danger-full-access") {
            options.append(.fullAccess)
        }

        options.append(.custom)
        return options.isEmpty ? defaultOptions : options
    }
}

public struct CodexPermissionProfileSummary: Identifiable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var detail: String?
    public var raw: CodexJSONValue

    public init(id: String, displayName: String, detail: String? = nil, raw: CodexJSONValue = .dictionary([:])) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
        self.raw = raw
    }

    public static func profiles(from value: CodexJSONValue) -> [CodexPermissionProfileSummary] {
        let rawProfiles: [CodexJSONValue]
        switch value {
        case .dictionary(let object):
            if case .array(let data)? = object["data"] {
                rawProfiles = data
            } else if case .array(let profiles)? = object["profiles"] {
                rawProfiles = profiles
            } else {
                rawProfiles = []
            }
        case .array(let values):
            rawProfiles = values
        case .string, .int, .double, .bool, .null:
            rawProfiles = []
        }

        return rawProfiles.compactMap(profile(from:))
    }

    private static func profile(from value: CodexJSONValue) -> CodexPermissionProfileSummary? {
        switch value {
        case .string(let id):
            return CodexPermissionProfileSummary(id: id, displayName: displayName(for: id), raw: value)
        case .dictionary(let object):
            guard let id = string(in: object, keys: ["id", "profileId", "name"]) else { return nil }
            let displayName = string(in: object, keys: ["displayName", "title", "name"]) ?? displayName(for: id)
            let detail = string(in: object, keys: ["description", "detail", "subtitle"])
            return CodexPermissionProfileSummary(id: id, displayName: displayName, detail: detail, raw: value)
        case .array, .int, .double, .bool, .null:
            return nil
        }
    }

    private static func displayName(for id: String) -> String {
        switch id {
        case ":read-only", "read-only": return "Read only"
        case ":workspace", "workspace", "workspace-write": return "Workspace"
        case ":danger-full-access", "danger-full-access": return "Full access"
        default:
            let trimmed = id.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return trimmed
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    private static func string(in object: [String: CodexJSONValue], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            switch value {
            case .string(let string):
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            case .int(let int): return String(int)
            case .double(let double): return String(double)
            case .bool(let bool): return String(bool)
            case .array, .dictionary, .null:
                continue
            }
        }
        return nil
    }
}

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

public struct CodexModelSelection: Identifiable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var modelIdentifier: String?
    public var detail: String?
    public var isDefault: Bool
    public var defaultReasoning: CodexReasoningSelection?
    public var supportedReasoning: [CodexReasoningSelection]

    public init(
        id: String,
        displayName: String,
        modelIdentifier: String? = nil,
        detail: String? = nil,
        isDefault: Bool = false,
        defaultReasoning: CodexReasoningSelection? = nil,
        supportedReasoning: [CodexReasoningSelection] = CodexReasoningSelection.defaultOptions
    ) {
        self.id = id
        self.displayName = displayName
        self.modelIdentifier = modelIdentifier
        self.detail = detail
        self.isDefault = isDefault
        self.defaultReasoning = defaultReasoning
        self.supportedReasoning = supportedReasoning
    }

    public static let appServerDefault = CodexModelSelection(
        id: "app-server-default",
        displayName: "Default",
        modelIdentifier: nil,
        detail: "default app-server model",
        isDefault: true,
        defaultReasoning: .medium
    )

    public static let defaultOptions: [CodexModelSelection] = [.appServerDefault]

    public static func options(from response: ModelListResponse) -> [CodexModelSelection] {
        let rawModels = response.data ?? response.models ?? []
        return rawModels.compactMap(option(from:))
    }

    private static func option(from value: CodexJSONValue) -> CodexModelSelection? {
        switch value {
        case .string(let model):
            return CodexModelSelection(id: model, displayName: model, modelIdentifier: model)
        case .dictionary(let object):
            let model = string(in: object, keys: ["model", "id", "name"])
            let id = string(in: object, keys: ["id", "model", "name"])
            guard let model, let id else { return nil }
            let displayName = string(in: object, keys: ["displayName", "name", "title"]) ?? model
            return CodexModelSelection(
                id: id,
                displayName: displayName,
                modelIdentifier: model,
                detail: string(in: object, keys: ["description", "subtitle"]),
                isDefault: bool(in: object, key: "isDefault") ?? false,
                defaultReasoning: reasoningSelection(from: string(in: object, keys: ["defaultReasoningEffort"])),
                supportedReasoning: supportedReasoningSelections(from: object["supportedReasoningEfforts"])
            )
        case .int, .double, .bool, .array, .null:
            return nil
        }
    }

    private static func string(in object: [String: CodexJSONValue], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            switch value {
            case .string(let string): return string
            case .int(let int): return String(int)
            case .double(let double): return String(double)
            case .bool(let bool): return String(bool)
            case .array, .dictionary, .null: continue
            }
        }
        return nil
    }

    private static func bool(in object: [String: CodexJSONValue], key: String) -> Bool? {
        switch object[key] {
        case .bool(let bool): return bool
        case .string(let string): return Bool(string)
        case .int(let int): return int != 0
        case .double(let double): return double != 0
        case .array, .dictionary, .null, nil: return nil
        }
    }

    private static func supportedReasoningSelections(from value: CodexJSONValue?) -> [CodexReasoningSelection] {
        guard case .array(let values)? = value else { return CodexReasoningSelection.defaultOptions }
        let selections = values.compactMap { value -> CodexReasoningSelection? in
            switch value {
            case .string(let raw):
                return reasoningSelection(from: raw)
            case .dictionary(let object):
                return reasoningSelection(from: string(in: object, keys: ["reasoningEffort", "id", "value"]))
            case .int, .double, .bool, .array, .null:
                return nil
            }
        }
        return selections.isEmpty ? CodexReasoningSelection.defaultOptions : selections
    }

    private static func reasoningSelection(from rawValue: String?) -> CodexReasoningSelection? {
        rawValue.flatMap(CodexReasoningSelection.init(appServerValue:))
    }
}

public enum CodexReasoningSelection: String, CaseIterable, Identifiable, Equatable, Sendable {
    case none
    case minimal
    case low
    case medium
    case high
    case extraHigh

    public var id: String { rawValue }

    public static let defaultOptions: [CodexReasoningSelection] = [.low, .medium, .high, .extraHigh]

    public init?(appServerValue: String) {
        switch appServerValue {
        case ReasoningEffort.none.rawValue:
            self = .none
        case ReasoningEffort.minimal.rawValue:
            self = .minimal
        case ReasoningEffort.low.rawValue:
            self = .low
        case ReasoningEffort.medium.rawValue:
            self = .medium
        case ReasoningEffort.high.rawValue:
            self = .high
        case ReasoningEffort.xhigh.rawValue:
            self = .extraHigh
        default:
            return nil
        }
    }

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .extraHigh: return "Extra High"
        }
    }

    public var effort: ReasoningEffort {
        switch self {
        case .none: return .none
        case .minimal: return .minimal
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        case .extraHigh: return .xhigh
        }
    }
}

public struct CodexCollaborationModeOption: Identifiable, Equatable, Sendable {
    public var id: String { mode }
    public var name: String
    public var mode: String
    public var modelIdentifier: String?
    public var reasoning: CodexReasoningSelection?
    public var raw: CodexJSONValue

    public init(
        name: String,
        mode: String,
        modelIdentifier: String? = nil,
        reasoning: CodexReasoningSelection? = nil,
        raw: CodexJSONValue = .dictionary([:])
    ) {
        self.name = name
        self.mode = mode
        self.modelIdentifier = modelIdentifier
        self.reasoning = reasoning
        self.raw = raw
    }

    public static let defaultMode = CodexCollaborationModeOption(name: "Default", mode: "default")
    public static let planMode = CodexCollaborationModeOption(name: "Plan", mode: "plan", reasoning: .medium)
    public static let defaultOptions: [CodexCollaborationModeOption] = [.planMode, .defaultMode]

    public var isPlanMode: Bool {
        mode.caseInsensitiveCompare("plan") == .orderedSame ||
            name.localizedCaseInsensitiveContains("plan")
    }

    public static func options(from value: CodexJSONValue) -> [CodexCollaborationModeOption] {
        let rawModes: [CodexJSONValue]
        switch value {
        case .dictionary(let object):
            if case .array(let data)? = object["data"] {
                rawModes = data
            } else if case .array(let modes)? = object["modes"] {
                rawModes = modes
            } else {
                rawModes = []
            }
        case .array(let values):
            rawModes = values
        case .string, .int, .double, .bool, .null:
            rawModes = []
        }

        let parsed = rawModes.compactMap(option(from:))
        return parsed.isEmpty ? defaultOptions : parsed
    }

    private static func option(from value: CodexJSONValue) -> CodexCollaborationModeOption? {
        switch value {
        case .string(let mode):
            return CodexCollaborationModeOption(name: displayName(for: mode), mode: mode, raw: value)
        case .dictionary(let object):
            guard let mode = string(in: object, keys: ["mode", "id", "value"]) else { return nil }
            let name = string(in: object, keys: ["name", "displayName", "title"]) ?? displayName(for: mode)
            let model = string(in: object, keys: ["model", "modelIdentifier"])
            let reasoning = string(in: object, keys: ["reasoning_effort", "reasoningEffort"])
                .flatMap(CodexReasoningSelection.init(appServerValue:))
            return CodexCollaborationModeOption(
                name: name,
                mode: mode,
                modelIdentifier: model,
                reasoning: reasoning,
                raw: value
            )
        case .array, .int, .double, .bool, .null:
            return nil
        }
    }

    private static func displayName(for mode: String) -> String {
        mode
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private static func string(in object: [String: CodexJSONValue], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            switch value {
            case .string(let string):
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            case .int(let int): return String(int)
            case .double(let double): return String(double)
            case .bool(let bool): return String(bool)
            case .array, .dictionary, .null:
                continue
            }
        }
        return nil
    }
}

public struct CodexSlashCommand: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var systemImage: String
    public var section: String
    public var scopeBadge: String?
    public var draftText: String?
    public var skillName: String?
    public var skillPath: String?

    public init(
        id: String,
        title: String,
        detail: String,
        systemImage: String,
        section: String = "Commands",
        scopeBadge: String? = nil,
        draftText: String? = nil,
        skillName: String? = nil,
        skillPath: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.section = section
        self.scopeBadge = scopeBadge
        self.draftText = draftText
        self.skillName = skillName
        self.skillPath = skillPath
    }

    public static let observedCommands: [CodexSlashCommand] = [
        CodexSlashCommand(
            id: "code-review",
            title: "Code review",
            detail: "Review the current changes",
            systemImage: "doc.text.magnifyingglass",
            draftText: "Review the current changes."
        ),
        CodexSlashCommand(
            id: "compact",
            title: "Compact",
            detail: "Compact the current thread context",
            systemImage: "rectangle.compress.vertical"
        ),
        CodexSlashCommand(
            id: "fast",
            title: "Fast",
            detail: "Switch to a faster response mode",
            systemImage: "bolt.fill"
        ),
        CodexSlashCommand(
            id: "feedback",
            title: "Feedback",
            detail: "Send feedback about this response",
            systemImage: "bubble.left.and.bubble.right",
            draftText: "I have feedback: "
        ),
        CodexSlashCommand(
            id: "fork",
            title: "Fork",
            detail: "Fork the conversation from here",
            systemImage: "arrow.triangle.branch"
        ),
        CodexSlashCommand(
            id: "goal",
            title: "Goal",
            detail: "Pursue a longer-running objective",
            systemImage: "target",
            draftText: "Pursue this goal: "
        ),
        CodexSlashCommand(
            id: "mcp",
            title: "MCP",
            detail: "Inspect configured MCP servers",
            systemImage: "server.rack"
        ),
        CodexSlashCommand(
            id: "model",
            title: "Model",
            detail: "Change model",
            systemImage: "sparkles"
        ),
        CodexSlashCommand(
            id: "personality",
            title: "Personality",
            detail: "Adjust response style",
            systemImage: "person.crop.circle",
            draftText: "Adjust response style: "
        ),
        CodexSlashCommand(
            id: "pet",
            title: "Pet",
            detail: "Show pet controls",
            systemImage: "pawprint"
        ),
        CodexSlashCommand(
            id: "plan",
            title: "Plan mode",
            detail: "Plan before editing",
            systemImage: "map",
            draftText: "Plan before making changes: "
        ),
        CodexSlashCommand(
            id: "reasoning",
            title: "Reasoning",
            detail: "Change reasoning effort",
            systemImage: "brain"
        ),
        CodexSlashCommand(
            id: "side",
            title: "Side",
            detail: "Open a side chat",
            systemImage: "rectangle.split.2x1"
        ),
        CodexSlashCommand(
            id: "status",
            title: "Status",
            detail: "Show current status",
            systemImage: "waveform.path.ecg"
        )
    ]

    public static func query(from draft: String) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        return String(trimmed.dropFirst())
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init) ?? ""
    }

    public static func filteredCommands(
        from commands: [CodexSlashCommand] = CodexSlashCommand.observedCommands,
        matching draft: String
    ) -> [CodexSlashCommand] {
        guard let query = query(from: draft), !query.isEmpty else { return commands }
        let needle = query.lowercased()

        let prefixMatches = commands.filter { command in
            command.id.lowercased().hasPrefix(needle) ||
                command.title.lowercased().hasPrefix(needle)
        }
        if !prefixMatches.isEmpty { return prefixMatches }

        let primaryMatches = commands.filter { command in
            command.id.lowercased().contains(needle) ||
                command.title.lowercased().contains(needle)
        }
        if !primaryMatches.isEmpty { return primaryMatches }

        return commands.filter { command in
            command.detail.lowercased().contains(needle)
        }
    }

    public static func skillCommands(from response: CodexJSONValue) -> [CodexSlashCommand] {
        guard case .dictionary(let object) = response,
              case .array(let entries)? = object["data"] else {
            return []
        }

        var seen: Set<String> = []
        var commands: [CodexSlashCommand] = []
        for entry in entries {
            guard case .dictionary(let entryObject) = entry,
                  case .array(let skills)? = entryObject["skills"] else {
                continue
            }

            for skill in skills {
                guard let command = skillCommand(from: skill) else { continue }
                let identity = command.skillPath ?? command.skillName ?? command.id
                guard seen.insert(identity).inserted else { continue }
                commands.append(command)
            }
        }
        return commands.sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func skillCommand(from value: CodexJSONValue) -> CodexSlashCommand? {
        guard case .dictionary(let object) = value,
              (bool(in: object, key: "enabled") ?? true),
              let name = string(in: object, keys: ["name"]),
              let path = string(in: object, keys: ["path"]) else {
            return nil
        }

        let interface = dictionary(in: object, key: "interface")
        let title = interface.flatMap { string(in: $0, keys: ["displayName"]) } ?? name
        let detail = interface.flatMap { string(in: $0, keys: ["shortDescription"]) } ??
            string(in: object, keys: ["shortDescription", "description"]) ??
            "Skill"
        let prompt = interface.flatMap { string(in: $0, keys: ["defaultPrompt"]) }?.nilIfBlank
        let scope = string(in: object, keys: ["scope"])

        return CodexSlashCommand(
            id: "skill:\(name)",
            title: title,
            detail: detail,
            systemImage: "hammer",
            section: "Skills",
            scopeBadge: scopeBadge(from: scope),
            draftText: prompt,
            skillName: name,
            skillPath: path
        )
    }

    private static func scopeBadge(from rawScope: String?) -> String? {
        switch rawScope {
        case "user": return "Personal"
        case "repo": return "Repo"
        case "system": return "System"
        case "admin": return "Admin"
        case .some(let value): return value.capitalized
        case nil: return nil
        }
    }

    private static func string(in object: [String: CodexJSONValue], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            switch value {
            case .string(let string): return string.nilIfBlank
            case .int(let int): return String(int)
            case .double(let double): return String(double)
            case .bool(let bool): return String(bool)
            case .array, .dictionary, .null: continue
            }
        }
        return nil
    }

    private static func bool(in object: [String: CodexJSONValue], key: String) -> Bool? {
        switch object[key] {
        case .bool(let bool): return bool
        case .string(let string): return Bool(string)
        case .int(let int): return int != 0
        case .double(let double): return double != 0
        case .array, .dictionary, .null, nil: return nil
        }
    }

    private static func dictionary(in object: [String: CodexJSONValue], key: String) -> [String: CodexJSONValue]? {
        guard case .dictionary(let dictionary)? = object[key] else { return nil }
        return dictionary
    }
}

public struct CodexChatActionHandlers {
    public var pinChat: (() -> Void)?
    public var renameChat: (() -> Void)?
    public var archiveChat: (() -> Void)?
    public var openSideChat: (() -> Void)?
    public var copyChat: (() -> Void)?
    public var forkChat: (() -> Void)?
    public var addAutomation: (() -> Void)?
    public var openInNewWindow: (() -> Void)?

    public init(
        pinChat: (() -> Void)? = nil,
        renameChat: (() -> Void)? = nil,
        archiveChat: (() -> Void)? = nil,
        openSideChat: (() -> Void)? = nil,
        copyChat: (() -> Void)? = nil,
        forkChat: (() -> Void)? = nil,
        addAutomation: (() -> Void)? = nil,
        openInNewWindow: (() -> Void)? = nil
    ) {
        self.pinChat = pinChat
        self.renameChat = renameChat
        self.archiveChat = archiveChat
        self.openSideChat = openSideChat
        self.copyChat = copyChat
        self.forkChat = forkChat
        self.addAutomation = addAutomation
        self.openInNewWindow = openInNewWindow
    }
}

public struct CodexThreadSummary: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var preview: String
    public var workspacePath: String?
    public var status: String?
    public var modelProvider: String?
    public var parentThreadID: String?
    public var isEphemeral: Bool
    public var createdAt: TimeInterval?
    public var updatedAt: TimeInterval?

    public init(
        id: String,
        title: String,
        preview: String = "",
        workspacePath: String? = nil,
        status: String? = nil,
        modelProvider: String? = nil,
        parentThreadID: String? = nil,
        isEphemeral: Bool = false,
        createdAt: TimeInterval? = nil,
        updatedAt: TimeInterval? = nil
    ) {
        self.id = id
        self.title = title
        self.preview = preview
        self.workspacePath = workspacePath
        self.status = status
        self.modelProvider = modelProvider
        self.parentThreadID = parentThreadID
        self.isEphemeral = isEphemeral
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init?(raw value: CodexJSONValue) {
        guard case .dictionary(let object) = value,
              let id = Self.string(in: object, keys: ["id"]) else {
            return nil
        }

        let name = Self.string(in: object, keys: ["name"])?.nilIfBlank
        let preview = Self.string(in: object, keys: ["preview"])?.nilIfBlank ?? ""
        self.init(
            id: id,
            title: name ?? preview.nilIfBlank ?? "Untitled chat",
            preview: preview,
            workspacePath: Self.string(in: object, keys: ["cwd"]),
            status: Self.status(from: object["status"]),
            modelProvider: Self.string(in: object, keys: ["modelProvider"]),
            parentThreadID: Self.string(in: object, keys: ["parentThreadId"]),
            isEphemeral: Self.bool(in: object, key: "ephemeral") ?? false,
            createdAt: Self.timeInterval(in: object, key: "createdAt"),
            updatedAt: Self.timeInterval(in: object, key: "updatedAt")
        )
    }

    public static func summaries(from response: CodexJSONValue) -> [CodexThreadSummary] {
        guard case .dictionary(let object) = response,
              case .array(let data)? = object["data"] else {
            return []
        }
        return data.compactMap(CodexThreadSummary.init(raw:))
    }

    public var detail: String {
        if !preview.isEmpty, preview != title { return preview }
        if let status, !status.isEmpty { return status }
        return workspacePath ?? id
    }

    private static func status(from value: CodexJSONValue?) -> String? {
        switch value {
        case .string(let status):
            return status
        case .dictionary(let object):
            return string(in: object, keys: ["type", "status", "state"])
        case .int, .double, .bool, .array, .null, nil:
            return nil
        }
    }

    private static func string(in object: [String: CodexJSONValue], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            switch value {
            case .string(let string): return string
            case .int(let int): return String(int)
            case .double(let double): return String(double)
            case .bool(let bool): return String(bool)
            case .array, .dictionary, .null: continue
            }
        }
        return nil
    }

    private static func bool(in object: [String: CodexJSONValue], key: String) -> Bool? {
        switch object[key] {
        case .bool(let bool): return bool
        case .string(let string): return Bool(string)
        case .int(let int): return int != 0
        case .double(let double): return double != 0
        case .array, .dictionary, .null, nil: return nil
        }
    }

    private static func timeInterval(in object: [String: CodexJSONValue], key: String) -> TimeInterval? {
        switch object[key] {
        case .int(let int): return TimeInterval(int)
        case .double(let double): return double
        case .string(let string): return TimeInterval(string)
        case .bool, .array, .dictionary, .null, nil: return nil
        }
    }
}

public struct CodexThreadSearchResult: Identifiable, Equatable, Sendable {
    public var thread: CodexThreadSummary
    public var snippet: String

    public var id: String { thread.id }

    public init(thread: CodexThreadSummary, snippet: String) {
        self.thread = thread
        self.snippet = snippet
    }

    public init?(raw value: CodexJSONValue) {
        guard case .dictionary(let object) = value,
              let threadValue = object["thread"],
              let thread = CodexThreadSummary(raw: threadValue) else {
            return nil
        }
        self.init(thread: thread, snippet: Self.string(from: object["snippet"]) ?? thread.detail)
    }

    public static func results(from response: CodexJSONValue) -> [CodexThreadSearchResult] {
        guard case .dictionary(let object) = response,
              case .array(let data)? = object["data"] else {
            return []
        }
        return data.compactMap(CodexThreadSearchResult.init(raw:))
    }

    private static func string(from value: CodexJSONValue?) -> String? {
        switch value {
        case .string(let string): return string.nilIfBlank
        case .int(let int): return String(int)
        case .double(let double): return String(double)
        case .bool(let bool): return String(bool)
        case .array, .dictionary, .null, nil: return nil
        }
    }
}

public struct CodexMCPServerStatus: Identifiable, Equatable, Sendable {
    public struct Entry: Identifiable, Equatable, Sendable {
        public var name: String
        public var title: String?
        public var detail: String?

        public var id: String { name }
        public var displayName: String { title?.nilIfBlank ?? name }

        public init(name: String, title: String? = nil, detail: String? = nil) {
            self.name = name
            self.title = title
            self.detail = detail
        }
    }

    public var name: String
    public var displayName: String
    public var version: String?
    public var detail: String?
    public var authStatus: String
    public var startupStatus: String?
    public var error: String?
    public var tools: [Entry]
    public var resources: [Entry]
    public var resourceTemplates: [Entry]

    public var id: String { name }

    public init(
        name: String,
        displayName: String? = nil,
        version: String? = nil,
        detail: String? = nil,
        authStatus: String = "unknown",
        startupStatus: String? = nil,
        error: String? = nil,
        tools: [Entry] = [],
        resources: [Entry] = [],
        resourceTemplates: [Entry] = []
    ) {
        self.name = name
        self.displayName = displayName?.nilIfBlank ?? name
        self.version = version
        self.detail = detail
        self.authStatus = authStatus
        self.startupStatus = startupStatus
        self.error = error
        self.tools = tools
        self.resources = resources
        self.resourceTemplates = resourceTemplates
    }

    public init?(raw value: CodexJSONValue) {
        guard case .dictionary(let object) = value,
              let name = Self.string(in: object, keys: ["name", "id", "serverName"])?.nilIfBlank else {
            return nil
        }

        let serverInfo = Self.dictionary(from: object["serverInfo"])
        let displayName = Self.string(in: serverInfo, keys: ["title", "name"])
            ?? Self.string(in: object, keys: ["title", "displayName"])
        let version = Self.string(in: serverInfo, keys: ["version"])
            ?? Self.string(in: object, keys: ["version"])
        let detail = Self.string(in: serverInfo, keys: ["description", "websiteUrl"])
            ?? Self.string(in: object, keys: ["description", "detail"])

        self.init(
            name: name,
            displayName: displayName,
            version: version,
            detail: detail,
            authStatus: Self.string(in: object, keys: ["authStatus", "auth", "authentication"]) ?? "unknown",
            startupStatus: Self.string(in: object, keys: ["status", "startupStatus", "state"]),
            error: Self.string(in: object, keys: ["error"]),
            tools: Self.entries(from: object["tools"]),
            resources: Self.entries(from: object["resources"]),
            resourceTemplates: Self.entries(from: object["resourceTemplates"])
        )
    }

    public static func statuses(from response: CodexJSONValue) -> [CodexMCPServerStatus] {
        switch response {
        case .dictionary(let object):
            if case .array(let data)? = object["data"] {
                return data.compactMap(CodexMCPServerStatus.init(raw:))
            }
            if case .array(let servers)? = object["servers"] {
                return servers.compactMap(CodexMCPServerStatus.init(raw:))
            }
            return CodexMCPServerStatus(raw: response).map { [$0] } ?? []
        case .array(let values):
            return values.compactMap(CodexMCPServerStatus.init(raw:))
        case .string, .int, .double, .bool, .null:
            return []
        }
    }

    public var authStatusLabel: String {
        switch authStatus {
        case "notLoggedIn": return "Not logged in"
        case "bearerToken": return "Bearer token"
        case "oAuth": return "OAuth"
        case "unsupported": return "Auth unsupported"
        default: return authStatus
        }
    }

    public var inventorySummary: String {
        let toolLabel = tools.count == 1 ? "1 tool" : "\(tools.count) tools"
        let resourceCount = resources.count + resourceTemplates.count
        let resourceLabel = resourceCount == 1 ? "1 resource" : "\(resourceCount) resources"
        return "\(toolLabel) · \(resourceLabel)"
    }

    public func applyingStartupStatus(_ status: String, error: String?) -> CodexMCPServerStatus {
        var copy = self
        copy.startupStatus = status
        copy.error = error
        return copy
    }

    private static func entries(from value: CodexJSONValue?) -> [Entry] {
        switch value {
        case .dictionary(let object):
            return object
                .map { key, value -> Entry in
                    if case .dictionary(let entryObject) = value {
                        return entry(from: entryObject, fallbackName: key)
                    }
                    return Entry(name: key, detail: string(from: value))
                }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .array(let values):
            return values.enumerated().compactMap { offset, value in
                guard case .dictionary(let object) = value else { return nil }
                return entry(from: object, fallbackName: "entry-\(offset)")
            }
        case .string, .int, .double, .bool, .null, nil:
            return []
        }
    }

    private static func entry(from object: [String: CodexJSONValue], fallbackName: String) -> Entry {
        let name = string(in: object, keys: ["name", "id", "uri", "uriTemplate"])?.nilIfBlank ?? fallbackName
        let title = string(in: object, keys: ["title"])
        let detail = string(in: object, keys: ["description", "uri", "uriTemplate", "mimeType"])
        return Entry(name: name, title: title, detail: detail)
    }

    private static func dictionary(from value: CodexJSONValue?) -> [String: CodexJSONValue] {
        guard case .dictionary(let object)? = value else { return [:] }
        return object
    }

    private static func string(in object: [String: CodexJSONValue], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key], let string = string(from: value)?.nilIfBlank else { continue }
            return string
        }
        return nil
    }

    private static func string(from value: CodexJSONValue?) -> String? {
        switch value {
        case .string(let string): return string
        case .int(let int): return String(int)
        case .double(let double): return String(double)
        case .bool(let bool): return String(bool)
        case .array, .dictionary, .null, nil: return nil
        }
    }
}

public struct CodexPluginSummary: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var displayName: String
    public var shortDescription: String?
    public var longDescription: String?
    public var marketplaceName: String
    public var marketplaceDisplayName: String
    public var marketplacePath: String?
    public var category: String?
    public var developerName: String?
    public var installed: Bool
    public var enabled: Bool
    public var installPolicy: String
    public var availability: String
    public var authPolicy: String
    public var sourceType: String?
    public var sourceDetail: String?
    public var localVersion: String?
    public var capabilities: [String]
    public var keywords: [String]

    public init(
        id: String,
        name: String,
        displayName: String? = nil,
        shortDescription: String? = nil,
        longDescription: String? = nil,
        marketplaceName: String,
        marketplaceDisplayName: String? = nil,
        marketplacePath: String? = nil,
        category: String? = nil,
        developerName: String? = nil,
        installed: Bool = false,
        enabled: Bool = false,
        installPolicy: String = "NOT_AVAILABLE",
        availability: String = "AVAILABLE",
        authPolicy: String = "ON_USE",
        sourceType: String? = nil,
        sourceDetail: String? = nil,
        localVersion: String? = nil,
        capabilities: [String] = [],
        keywords: [String] = []
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName?.nilIfBlank ?? name
        self.shortDescription = shortDescription
        self.longDescription = longDescription
        self.marketplaceName = marketplaceName
        self.marketplaceDisplayName = marketplaceDisplayName?.nilIfBlank ?? marketplaceName
        self.marketplacePath = marketplacePath
        self.category = category
        self.developerName = developerName
        self.installed = installed
        self.enabled = enabled
        self.installPolicy = installPolicy
        self.availability = availability
        self.authPolicy = authPolicy
        self.sourceType = sourceType
        self.sourceDetail = sourceDetail
        self.localVersion = localVersion
        self.capabilities = capabilities
        self.keywords = keywords
    }

    public init?(raw value: CodexJSONValue, marketplace: MarketplaceContext) {
        guard case .dictionary(let object) = value,
              let name = Self.string(in: object, keys: ["name"])?.nilIfBlank else {
            return nil
        }

        let pluginID = Self.string(in: object, keys: ["id"])?.nilIfBlank ?? name
        let interface = Self.dictionary(from: object["interface"])
        let source = Self.dictionary(from: object["source"])
        self.init(
            id: "\(marketplace.name):\(pluginID)",
            name: name,
            displayName: Self.string(in: interface, keys: ["displayName"]),
            shortDescription: Self.string(in: interface, keys: ["shortDescription"]),
            longDescription: Self.string(in: interface, keys: ["longDescription"]),
            marketplaceName: marketplace.name,
            marketplaceDisplayName: marketplace.displayName,
            marketplacePath: marketplace.path,
            category: Self.string(in: interface, keys: ["category"]),
            developerName: Self.string(in: interface, keys: ["developerName"]),
            installed: Self.bool(from: object["installed"]) ?? false,
            enabled: Self.bool(from: object["enabled"]) ?? false,
            installPolicy: Self.string(in: object, keys: ["installPolicy"]) ?? "NOT_AVAILABLE",
            availability: Self.string(in: object, keys: ["availability"]) ?? "AVAILABLE",
            authPolicy: Self.string(in: object, keys: ["authPolicy"]) ?? "ON_USE",
            sourceType: Self.string(in: source, keys: ["type"]),
            sourceDetail: Self.sourceDetail(from: source),
            localVersion: Self.string(in: object, keys: ["localVersion"]),
            capabilities: Self.stringArray(from: interface["capabilities"]),
            keywords: Self.stringArray(from: object["keywords"])
        )
    }

    public static func plugins(from response: CodexJSONValue) -> [CodexPluginSummary] {
        marketplaces(from: response)
            .flatMap { marketplace in
                marketplace.plugins.compactMap { CodexPluginSummary(raw: $0, marketplace: marketplace.context) }
            }
            .sorted { lhs, rhs in
                if lhs.installed != rhs.installed { return lhs.installed && !rhs.installed }
                if lhs.enabled != rhs.enabled { return lhs.enabled && !rhs.enabled }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    public static func loadErrorMessages(from response: CodexJSONValue) -> [String] {
        guard case .dictionary(let object) = response,
              case .array(let errors)? = object["marketplaceLoadErrors"] else {
            return []
        }
        return errors.compactMap { value in
            guard case .dictionary(let error) = value else { return nil }
            let path = string(in: error, keys: ["marketplacePath"])
            let message = string(in: error, keys: ["message"]) ?? "Unknown marketplace load error"
            return path.map { "\($0): \(message)" } ?? message
        }
    }

    public var statusLabel: String {
        if installed, enabled { return "Installed" }
        if installed { return "Installed, disabled" }
        if installPolicy == "AVAILABLE" { return "Available" }
        if installPolicy == "INSTALLED_BY_DEFAULT" { return "Default" }
        return "Unavailable"
    }

    public var sourceLabel: String {
        switch sourceType {
        case "local":
            return "Local"
        case "git":
            return "Git"
        case "remote":
            return "Remote"
        default:
            return sourceType?.nilIfBlank ?? marketplaceDisplayName
        }
    }

    public var detail: String {
        if let shortDescription, !shortDescription.isEmpty { return shortDescription }
        if let longDescription, !longDescription.isEmpty { return longDescription }
        if !capabilities.isEmpty { return capabilities.joined(separator: ", ") }
        return marketplaceDisplayName
    }

    public struct MarketplaceContext: Equatable, Sendable {
        public var name: String
        public var displayName: String
        public var path: String?
        fileprivate var plugins: [CodexJSONValue] = []

        public init(name: String, displayName: String? = nil, path: String? = nil) {
            self.name = name
            self.displayName = displayName?.nilIfBlank ?? name
            self.path = path
        }
    }

    private static func marketplaces(from response: CodexJSONValue) -> [(context: MarketplaceContext, plugins: [CodexJSONValue])] {
        guard case .dictionary(let object) = response,
              case .array(let marketplaces)? = object["marketplaces"] else {
            return []
        }

        return marketplaces.compactMap { value in
            guard case .dictionary(let marketplace) = value,
                  let name = string(in: marketplace, keys: ["name"])?.nilIfBlank else {
                return nil
            }
            let interface = dictionary(from: marketplace["interface"])
            let context = MarketplaceContext(
                name: name,
                displayName: string(in: interface, keys: ["displayName"]),
                path: string(in: marketplace, keys: ["path"])
            )
            let plugins: [CodexJSONValue]
            if case .array(let values)? = marketplace["plugins"] {
                plugins = values
            } else {
                plugins = []
            }
            return (context, plugins)
        }
    }

    private static func sourceDetail(from source: [String: CodexJSONValue]) -> String? {
        string(in: source, keys: ["path"])
            ?? string(in: source, keys: ["url"])
            ?? string(in: source, keys: ["refName"])
    }

    private static func dictionary(from value: CodexJSONValue?) -> [String: CodexJSONValue] {
        guard case .dictionary(let object)? = value else { return [:] }
        return object
    }

    private static func string(in object: [String: CodexJSONValue], keys: [String]) -> String? {
        for key in keys {
            guard let string = string(from: object[key])?.nilIfBlank else { continue }
            return string
        }
        return nil
    }

    private static func string(from value: CodexJSONValue?) -> String? {
        switch value {
        case .string(let string): return string
        case .int(let int): return String(int)
        case .double(let double): return String(double)
        case .bool(let bool): return String(bool)
        case .array, .dictionary, .null, nil: return nil
        }
    }

    private static func bool(from value: CodexJSONValue?) -> Bool? {
        switch value {
        case .bool(let bool): return bool
        case .string(let string): return Bool(string)
        case .int(let int): return int != 0
        case .double(let double): return double != 0
        case .array, .dictionary, .null, nil: return nil
        }
    }

    private static func stringArray(from value: CodexJSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap { string(from: $0)?.nilIfBlank }
    }
}

public struct CodexProjectSummary: Identifiable, Equatable, Sendable {
    public var workspacePath: String
    public var chatCount: Int
    public var updatedAt: TimeInterval?

    public var id: String { workspacePath }

    public init(workspacePath: String, chatCount: Int = 0, updatedAt: TimeInterval? = nil) {
        self.workspacePath = Self.normalizedPath(workspacePath)
        self.chatCount = chatCount
        self.updatedAt = updatedAt
    }

    public var displayName: String {
        let last = URL(fileURLWithPath: workspacePath).lastPathComponent.nilIfBlank
        return last ?? (workspacePath == "/" ? "/" : workspacePath)
    }

    public var detail: String {
        let count = chatCount == 1 ? "1 chat" : "\(chatCount) chats"
        return "\(shortPath) · \(count)"
    }

    public var shortPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if workspacePath == home { return "~" }
        if workspacePath.hasPrefix(home + "/") {
            return "~" + workspacePath.dropFirst(home.count)
        }
        return workspacePath
    }

    public static func projects(
        from summaries: [CodexThreadSummary],
        currentWorkspacePath: String
    ) -> [CodexProjectSummary] {
        let current = normalizedPath(currentWorkspacePath)
        var buckets: [String: (chatCount: Int, updatedAt: TimeInterval?)] = [:]

        for summary in summaries {
            guard let path = summary.workspacePath?.nilIfBlank else { continue }
            let normalized = normalizedPath(path)
            var bucket = buckets[normalized] ?? (chatCount: 0, updatedAt: nil)
            bucket.chatCount += 1
            if let updatedAt = summary.updatedAt, bucket.updatedAt.map({ updatedAt > $0 }) ?? true {
                bucket.updatedAt = updatedAt
            }
            buckets[normalized] = bucket
        }

        if buckets[current] == nil {
            buckets[current] = (chatCount: 0, updatedAt: nil)
        }

        return buckets.map { path, bucket in
            CodexProjectSummary(workspacePath: path, chatCount: bucket.chatCount, updatedAt: bucket.updatedAt)
        }
        .sorted { lhs, rhs in
            if lhs.workspacePath == current { return true }
            if rhs.workspacePath == current { return false }
            switch (lhs.updatedAt, rhs.updatedAt) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        }
    }

    public static func normalizedPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct CodexChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: String, Equatable, Sendable {
        case user = "You"
        case assistant = "Codex"
        case terminal = "Terminal"
        case fileChange = "File change"
        case plan = "Plan"
        case tool = "Tool"
        case notice = "Notice"
        case system = "System"
    }

    public struct CommandRun: Equatable, Sendable {
        public var itemID: String
        public var command: String
        public var cwd: String?
        public var output: String
        public var status: String
        public var exitCode: Int?
        public var isStreaming: Bool

        public init(
            itemID: String,
            command: String,
            cwd: String? = nil,
            output: String,
            status: String,
            exitCode: Int? = nil,
            isStreaming: Bool
        ) {
            self.itemID = itemID
            self.command = command
            self.cwd = cwd
            self.output = output
            self.status = status
            self.exitCode = exitCode
            self.isStreaming = isStreaming
        }
    }

    public struct FileChange: Equatable, Sendable {
        public var itemID: String
        public var path: String?
        public var kind: String
        public var diff: String
        public var output: String
        public var status: String
        public var isStreaming: Bool

        public init(
            itemID: String,
            path: String? = nil,
            kind: String = "update",
            diff: String = "",
            output: String = "",
            status: String = "active",
            isStreaming: Bool = false
        ) {
            self.itemID = itemID
            self.path = path
            self.kind = kind
            self.diff = diff
            self.output = output
            self.status = status
            self.isStreaming = isStreaming
        }

        public var displayPath: String {
            path?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "File changes"
        }

        public var changedFileCount: Int {
            guard !diff.isEmpty else { return path == nil ? 0 : 1 }
            let lines = diff.split(whereSeparator: \.isNewline)
            let gitHeaders = lines.compactMap { line -> String? in
                if line.hasPrefix("diff --git ") {
                    return String(line)
                }
                return nil
            }
            let fileHeaders = gitHeaders.isEmpty ? lines.compactMap { line -> String? in
                if line.hasPrefix("+++ ") {
                    let newPath = line.dropFirst(4)
                    return newPath == "/dev/null" ? nil : String(newPath)
                }
                return nil
            } : gitHeaders
            let count = Set(fileHeaders).count
            return max(path == nil ? 0 : 1, count)
        }

        public var addedLineCount: Int {
            diff.split(whereSeparator: \.isNewline).filter { line in
                line.hasPrefix("+") && !line.hasPrefix("+++")
            }.count
        }

        public var removedLineCount: Int {
            diff.split(whereSeparator: \.isNewline).filter { line in
                line.hasPrefix("-") && !line.hasPrefix("---")
            }.count
        }
    }

    public struct PlanUpdate: Equatable, Sendable {
        public struct Step: Equatable, Sendable {
            public var step: String
            public var status: String

            public init(step: String, status: String) {
                self.step = step
                self.status = status
            }

            public var displayStatus: String {
                status.replacingOccurrences(of: "_", with: " ")
            }

            public var isCompleted: Bool {
                status == "completed"
            }

            public var isActive: Bool {
                status == "inProgress" || status == "in_progress" || status == "active" || status == "running"
            }
        }

        public var itemID: String
        public var explanation: String?
        public var steps: [Step]
        public var text: String
        public var isStreaming: Bool

        public init(
            itemID: String,
            explanation: String? = nil,
            steps: [Step] = [],
            text: String = "",
            isStreaming: Bool = false
        ) {
            self.itemID = itemID
            self.explanation = explanation
            self.steps = steps
            self.text = text
            self.isStreaming = isStreaming
        }

        public var completedStepCount: Int {
            steps.filter(\.isCompleted).count
        }

        public var activeStepCount: Int {
            steps.filter(\.isActive).count
        }

        public var summary: String {
            if steps.isEmpty {
                return isStreaming ? "Planning" : "Plan"
            }
            if completedStepCount == steps.count {
                return "Completed \(steps.count)/\(steps.count)"
            }
            return "\(completedStepCount)/\(steps.count) complete"
        }

        public var copyText: String {
            var lines: [String] = []
            if let explanation, !explanation.isEmpty {
                lines.append(explanation)
            }
            if !steps.isEmpty {
                lines.append(contentsOf: steps.map { "- [\($0.displayStatus)] \($0.step)" })
            } else if !text.isEmpty {
                lines.append(text)
            }
            return lines.joined(separator: "\n")
        }
    }

    public struct ToolCall: Equatable, Sendable {
        public var itemID: String
        public var server: String?
        public var tool: String
        public var arguments: String
        public var status: String
        public var progress: [String]
        public var result: String
        public var error: String?
        public var durationMilliseconds: Int?
        public var isStreaming: Bool

        public init(
            itemID: String,
            server: String? = nil,
            tool: String,
            arguments: String = "",
            status: String = "inProgress",
            progress: [String] = [],
            result: String = "",
            error: String? = nil,
            durationMilliseconds: Int? = nil,
            isStreaming: Bool = false
        ) {
            self.itemID = itemID
            self.server = server
            self.tool = tool
            self.arguments = arguments
            self.status = status
            self.progress = progress
            self.result = result
            self.error = error
            self.durationMilliseconds = durationMilliseconds
            self.isStreaming = isStreaming
        }

        public var displayName: String {
            guard let server, !server.isEmpty else { return tool }
            return "\(server).\(tool)"
        }

        public var summary: String {
            if let error, !error.isEmpty { return error }
            if !result.isEmpty { return result }
            if let lastProgress = progress.last, !lastProgress.isEmpty { return lastProgress }
            return isStreaming ? "Calling tool" : status
        }

        public var copyText: String {
            var parts: [String] = []
            if !arguments.isEmpty { parts.append("Arguments:\n\(arguments)") }
            if !progress.isEmpty { parts.append("Progress:\n\(progress.joined(separator: "\n"))") }
            if !result.isEmpty { parts.append("Result:\n\(result)") }
            if let error, !error.isEmpty { parts.append("Error:\n\(error)") }
            return parts.joined(separator: "\n\n")
        }
    }

    public struct Notice: Equatable, Sendable {
        public enum Severity: String, Equatable, Sendable {
            case info
            case success
            case warning
            case danger
        }

        public var itemID: String
        public var kind: String
        public var title: String
        public var detail: String
        public var status: String?
        public var metadata: [String]
        public var severity: Severity
        public var isStreaming: Bool

        public init(
            itemID: String,
            kind: String,
            title: String,
            detail: String,
            status: String? = nil,
            metadata: [String] = [],
            severity: Severity = .info,
            isStreaming: Bool = false
        ) {
            self.itemID = itemID
            self.kind = kind
            self.title = title
            self.detail = detail
            self.status = status
            self.metadata = metadata
            self.severity = severity
            self.isStreaming = isStreaming
        }

        public var copyText: String {
            ([title, detail] + metadata).filter { !$0.isEmpty }.joined(separator: "\n")
        }

        public var statusLabel: String {
            if isStreaming { return "running" }
            return status?.replacingOccurrences(of: "_", with: " ") ?? severity.rawValue
        }
    }

    public let id: UUID
    public var role: Role
    public var text: String
    public var detail: String?
    public var isStreaming: Bool
    public var createdAt: Date
    public var renderBlocks: [AssistantRenderBlock]
    public var commandRun: CommandRun?
    public var fileChange: FileChange?
    public var planUpdate: PlanUpdate?
    public var toolCall: ToolCall?
    public var notice: Notice?

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        detail: String? = nil,
        isStreaming: Bool = false,
        createdAt: Date = Date(),
        parseContent: Bool = true,
        renderBlocks: [AssistantRenderBlock]? = nil,
        commandRun: CommandRun? = nil,
        fileChange: FileChange? = nil,
        planUpdate: PlanUpdate? = nil,
        toolCall: ToolCall? = nil,
        notice: Notice? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.detail = detail
        self.isStreaming = isStreaming
        self.createdAt = createdAt
        self.renderBlocks = renderBlocks ?? (parseContent ? Self.renderBlocks(for: text) : [.markdown(text)])
        self.commandRun = commandRun
        self.fileChange = fileChange
        self.planUpdate = planUpdate
        self.toolCall = toolCall
        self.notice = notice
    }

    public mutating func setText(_ text: String, parseContent: Bool = true) {
        self.text = text
        renderBlocks = parseContent ? Self.renderBlocks(for: text) : [.markdown(text)]
    }

    public mutating func appendStreamingText(_ delta: String) {
        text.append(delta)
    }

    public static func renderBlocks(for text: String) -> [AssistantRenderBlock] {
        MessageContentBridge.assistantRenderBlocks(text)
    }

    public static func fileChange(
        itemID: String,
        raw: [String: CodexJSONValue],
        fallbackStatus: String = "completed"
    ) -> FileChange? {
        let changes = fileUpdateChanges(from: raw["changes"])
        let changesDiff = changes.map(\.diff).filter { !$0.isEmpty }.joined(separator: "\n").nilIfBlank
        let path = string(from: raw["path"])
            ?? changes.first?.path
            ?? firstFileChangePath(from: raw["fileChanges"])
        let kind = string(from: raw["kind"])
            ?? changes.first?.kind
            ?? firstFileChangeKind(from: raw["fileChanges"])
            ?? string(from: raw["type"])
            ?? "update"
        let diff = string(from: raw["diff"])
            ?? string(from: raw["patch"])
            ?? string(from: raw["unified_diff"])
            ?? changesDiff
            ?? fileChangesDiff(from: raw["fileChanges"])
            ?? ""
        let output = string(from: raw["output"])
            ?? string(from: raw["delta"])
            ?? string(from: raw["aggregatedOutput"])
            ?? ""
        let status = string(from: raw["status"]) ?? fallbackStatus
        let isStreaming = status == "active" || status == "inProgress" || status == "running"

        guard path != nil || !diff.isEmpty || !output.isEmpty else { return nil }
        return FileChange(
            itemID: itemID,
            path: path,
            kind: kind,
            diff: diff,
            output: output,
            status: status,
            isStreaming: isStreaming
        )
    }

    public static func fileChange(
        itemID: String,
        path: String?,
        diff: String,
        kind: String = "update",
        output: String = "",
        status: String = "active",
        isStreaming: Bool = true
    ) -> FileChange {
        FileChange(
            itemID: itemID,
            path: path,
            kind: kind,
            diff: diff,
            output: output,
            status: status,
            isStreaming: isStreaming
        )
    }

    public static func planUpdate(
        itemID: String,
        raw: [String: CodexJSONValue],
        fallbackText: String = "",
        isStreaming: Bool = false
    ) -> PlanUpdate? {
        let explanation = string(from: raw["explanation"])
        let steps = planSteps(from: raw["plan"]) + planSteps(from: raw["steps"])
        let text = string(from: raw["delta"])
            ?? string(from: raw["text"])
            ?? string(from: raw["summary"])
            ?? fallbackText.nilIfBlank
            ?? ""
        guard explanation != nil || !steps.isEmpty || !text.isEmpty else { return nil }
        return PlanUpdate(
            itemID: itemID,
            explanation: explanation,
            steps: steps,
            text: text,
            isStreaming: isStreaming
        )
    }

    public static func planUpdate(
        itemID: String,
        text: String,
        isStreaming: Bool = true
    ) -> PlanUpdate {
        PlanUpdate(itemID: itemID, text: text, isStreaming: isStreaming)
    }

    public static func toolCall(
        itemID: String,
        raw: [String: CodexJSONValue],
        fallbackStatus: String = "inProgress"
    ) -> ToolCall? {
        let server = string(from: raw["server"])
            ?? string(from: raw["serverName"])
            ?? string(from: raw["mcpServer"])
        let tool = string(from: raw["tool"])
            ?? string(from: raw["toolName"])
            ?? string(from: raw["name"])
            ?? "Tool"
        let arguments = jsonText(from: raw["arguments"]) ?? ""
        let status = string(from: raw["status"]) ?? fallbackStatus
        let progress = progressMessages(from: raw)
        let result = resultText(from: raw["result"])
            ?? resultText(from: raw["output"])
            ?? resultText(from: raw["content"])
            ?? ""
        let error = errorText(from: raw["error"])
        let duration = int(from: raw["durationMs"]) ?? int(from: raw["durationMilliseconds"])
        let isStreaming = status == "inProgress" || status == "active" || status == "running"

        guard server != nil || tool != "Tool" || !arguments.isEmpty || !result.isEmpty || error != nil || !progress.isEmpty else {
            return nil
        }

        return ToolCall(
            itemID: itemID,
            server: server,
            tool: tool,
            arguments: arguments,
            status: status,
            progress: progress,
            result: result,
            error: error,
            durationMilliseconds: duration,
            isStreaming: isStreaming
        )
    }

    public static func toolCall(
        itemID: String,
        server: String?,
        tool: String,
        arguments: String = "",
        status: String = "inProgress",
        progress: [String] = [],
        result: String = "",
        error: String? = nil,
        durationMilliseconds: Int? = nil,
        isStreaming: Bool = true
    ) -> ToolCall {
        ToolCall(
            itemID: itemID,
            server: server,
            tool: tool,
            arguments: arguments,
            status: status,
            progress: progress,
            result: result,
            error: error,
            durationMilliseconds: durationMilliseconds,
            isStreaming: isStreaming
        )
    }

    public static func notice(
        itemID: String,
        method: CodexAppServerNotificationMethod,
        raw: [String: CodexJSONValue],
        isStreaming: Bool? = nil
    ) -> Notice? {
        switch method {
        case .modelRerouted:
            let fromModel = string(from: raw["fromModel"]) ?? "selected model"
            let toModel = string(from: raw["toModel"]) ?? "alternate model"
            let reason = string(from: raw["reason"])
            let detail = "\(fromModel) -> \(toModel)"
            return Notice(
                itemID: itemID,
                kind: method.rawValue,
                title: "Model rerouted",
                detail: detail,
                metadata: reason.map { ["Reason: \(humanize($0))"] } ?? [],
                severity: .warning,
                isStreaming: isStreaming ?? false
            )

        case .modelVerification:
            let verifications = stringArray(from: raw["verifications"]).map(humanize)
            let detail = verifications.isEmpty ? "Model verification updated" : verifications.joined(separator: ", ")
            return Notice(
                itemID: itemID,
                kind: method.rawValue,
                title: "Model verification",
                detail: detail,
                metadata: verifications.map { "Verified: \($0)" },
                severity: .info,
                isStreaming: isStreaming ?? false
            )

        case .warning:
            guard let message = string(from: raw["message"]) else { return nil }
            return Notice(
                itemID: itemID,
                kind: method.rawValue,
                title: "Warning",
                detail: message,
                severity: .warning,
                isStreaming: isStreaming ?? false
            )

        case .guardianWarning:
            guard let message = string(from: raw["message"]) else { return nil }
            return Notice(
                itemID: itemID,
                kind: method.rawValue,
                title: "Guardian warning",
                detail: message,
                severity: .danger,
                isStreaming: isStreaming ?? false
            )

        case .configWarning:
            guard let summary = string(from: raw["summary"]) else { return nil }
            var metadata: [String] = []
            if let details = string(from: raw["details"]) { metadata.append(details) }
            if let path = string(from: raw["path"]) { metadata.append("Config: \(path)") }
            if let range = textRangeSummary(from: raw["range"]) { metadata.append(range) }
            return Notice(
                itemID: itemID,
                kind: method.rawValue,
                title: "Config warning",
                detail: summary,
                metadata: metadata,
                severity: .warning,
                isStreaming: isStreaming ?? false
            )

        case .deprecationNotice:
            guard let summary = string(from: raw["summary"]) else { return nil }
            let details = string(from: raw["details"]).map { [$0] } ?? []
            return Notice(
                itemID: itemID,
                kind: method.rawValue,
                title: "Deprecation notice",
                detail: summary,
                metadata: details,
                severity: .warning,
                isStreaming: isStreaming ?? false
            )

        case .itemAutoApprovalReviewStarted, .itemAutoApprovalReviewCompleted:
            return approvalReviewNotice(
                itemID: itemID,
                method: method,
                raw: raw,
                isStreaming: isStreaming ?? (method == .itemAutoApprovalReviewStarted)
            )

        default:
            return nil
        }
    }

    public static func notice(
        itemID: String,
        kind: String,
        title: String,
        detail: String,
        status: String? = nil,
        metadata: [String] = [],
        severity: Notice.Severity = .info,
        isStreaming: Bool = false
    ) -> Notice {
        Notice(
            itemID: itemID,
            kind: kind,
            title: title,
            detail: detail,
            status: status,
            metadata: metadata,
            severity: severity,
            isStreaming: isStreaming
        )
    }

    private struct FileUpdateChange {
        var path: String?
        var kind: String?
        var diff: String
    }

    private static func approvalReviewNotice(
        itemID: String,
        method: CodexAppServerNotificationMethod,
        raw: [String: CodexJSONValue],
        isStreaming: Bool
    ) -> Notice? {
        guard let review = dictionary(from: raw["review"]),
              let status = string(from: review["status"]) else {
            return nil
        }

        let action = dictionary(from: raw["action"])
        let actionSummary = approvalActionSummary(from: action)
        let rationale = string(from: review["rationale"])
        let riskLevel = string(from: review["riskLevel"]).map(humanize)
        let targetItemID = string(from: raw["targetItemId"])
        let source = string(from: raw["decisionSource"]).map(humanize)
        let title: String
        switch status {
        case "approved":
            title = "Auto review approved"
        case "denied":
            title = "Auto review denied"
        case "timedOut":
            title = "Auto review timed out"
        case "aborted":
            title = "Auto review aborted"
        default:
            title = "Auto review"
        }

        var metadata: [String] = []
        if let rationale { metadata.append(rationale) }
        if let riskLevel { metadata.append("Risk: \(riskLevel)") }
        if let targetItemID { metadata.append("Target: \(targetItemID)") }
        if let source { metadata.append("Decision source: \(source)") }

        let duration = durationSummary(startedAtMs: int(from: raw["startedAtMs"]), completedAtMs: int(from: raw["completedAtMs"]))
        if let duration { metadata.append(duration) }

        return Notice(
            itemID: itemID,
            kind: method.rawValue,
            title: title,
            detail: actionSummary,
            status: status,
            metadata: metadata,
            severity: reviewSeverity(for: status),
            isStreaming: isStreaming
        )
    }

    private static func approvalActionSummary(from action: [String: CodexJSONValue]?) -> String {
        guard let action else { return "Reviewing requested action" }
        switch string(from: action["type"]) {
        case "command":
            return string(from: action["command"]) ?? "Reviewing command"
        case "execve":
            let argv = stringArray(from: action["argv"])
            if !argv.isEmpty { return argv.joined(separator: " ") }
            return string(from: action["program"]) ?? "Reviewing process execution"
        case "applyPatch":
            let files = stringArray(from: action["files"])
            return files.isEmpty ? "Reviewing patch" : "Reviewing patch: \(files.joined(separator: ", "))"
        case "networkAccess":
            let target = string(from: action["target"])
            let host = string(from: action["host"])
            let port = string(from: action["port"])
            let endpoint = [host, port].compactMap { $0 }.joined(separator: ":")
            return target ?? (endpoint.isEmpty ? "Reviewing network access" : "Reviewing network access: \(endpoint)")
        case "mcpToolCall":
            let server = string(from: action["server"])
            let tool = string(from: action["toolTitle"]) ?? string(from: action["toolName"])
            return [server, tool].compactMap { $0 }.joined(separator: ".").nilIfBlank ?? "Reviewing MCP tool call"
        case "requestPermissions":
            return string(from: action["reason"]) ?? "Reviewing permission request"
        case let type?:
            return "Reviewing \(humanize(type))"
        case nil:
            return "Reviewing requested action"
        }
    }

    private static func reviewSeverity(for status: String) -> Notice.Severity {
        switch status {
        case "approved":
            return .success
        case "denied", "timedOut", "aborted":
            return .danger
        default:
            return .info
        }
    }

    private static func durationSummary(startedAtMs: Int?, completedAtMs: Int?) -> String? {
        guard let startedAtMs, let completedAtMs, completedAtMs >= startedAtMs else { return nil }
        let duration = Double(completedAtMs - startedAtMs) / 1_000
        return String(format: "Duration: %.1fs", duration)
    }

    private static func stringArray(from value: CodexJSONValue?) -> [String] {
        switch value {
        case .array(let values):
            return values.compactMap(string(from:))
        case let value?:
            return string(from: value).map { [$0] } ?? []
        case nil:
            return []
        }
    }

    private static func dictionary(from value: CodexJSONValue?) -> [String: CodexJSONValue]? {
        guard case .dictionary(let object)? = value else { return nil }
        return object
    }

    private static func textRangeSummary(from value: CodexJSONValue?) -> String? {
        guard let range = dictionary(from: value),
              let start = dictionary(from: range["start"]),
              let line = string(from: start["line"]) else {
            return nil
        }
        if let column = string(from: start["column"]) {
            return "Location: \(line):\(column)"
        }
        return "Location: line \(line)"
    }

    private static func humanize(_ raw: String) -> String {
        let spaced = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        var result = ""
        for scalar in spaced.unicodeScalars {
            let string = String(scalar)
            if string.rangeOfCharacter(from: .uppercaseLetters) != nil, !result.isEmpty, result.last != " " {
                result.append(" ")
            }
            result.append(string)
        }
        return result
            .split(separator: " ")
            .joined(separator: " ")
            .lowercased()
    }

    private static func planSteps(from value: CodexJSONValue?) -> [PlanUpdate.Step] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap { value in
            guard case .dictionary(let object) = value else { return nil }
            guard let step = string(from: object["step"]) ?? string(from: object["text"]) ?? string(from: object["title"]) else {
                return nil
            }
            let status = string(from: object["status"]) ?? "pending"
            return PlanUpdate.Step(step: step, status: status)
        }
    }

    private static func progressMessages(from raw: [String: CodexJSONValue]) -> [String] {
        var messages: [String] = []
        for key in ["message", "progress", "progressMessage", "statusText"] {
            if let text = string(from: raw[key]), !text.isEmpty {
                messages.append(text)
            }
        }
        if case .array(let values)? = raw["progressMessages"] {
            messages.append(contentsOf: values.compactMap(string(from:)))
        }
        var seen: Set<String> = []
        return messages.filter { seen.insert($0).inserted }
    }

    private static func resultText(from value: CodexJSONValue?) -> String? {
        switch value {
        case .string(let string):
            return string.nilIfBlank
        case .array(let values):
            return values.compactMap(resultText(from:)).joined(separator: "\n").nilIfBlank
        case .dictionary(let object):
            if let content = resultText(from: object["content"]) {
                return content
            }
            if let structured = jsonText(from: object["structuredContent"]) {
                return structured
            }
            return string(from: object["text"])
                ?? string(from: object["message"])
                ?? jsonText(from: value)
        case .int, .double, .bool, .null, nil:
            return string(from: value)
        }
    }

    private static func errorText(from value: CodexJSONValue?) -> String? {
        switch value {
        case .dictionary(let object):
            return string(from: object["message"])
                ?? string(from: object["error"])
                ?? jsonText(from: value)
        case .string:
            return string(from: value)
        case .int, .double, .bool, .array, .null, nil:
            return nil
        }
    }

    private static func fileUpdateChanges(from value: CodexJSONValue?) -> [FileUpdateChange] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap { value in
            guard case .dictionary(let object) = value else { return nil }
            let path = string(from: object["path"])
            let diff = string(from: object["diff"]) ?? ""
            let kind = string(from: object["kind"])
                ?? string(from: object["type"])
                ?? string(from: nestedValue(object["kind"], key: "type"))
            guard path != nil || !diff.isEmpty else { return nil }
            return FileUpdateChange(path: path, kind: kind, diff: diff)
        }
    }

    private static func firstFileChangePath(from value: CodexJSONValue?) -> String? {
        guard case .dictionary(let object)? = value else { return nil }
        return object.keys.sorted().first
    }

    private static func firstFileChangeKind(from value: CodexJSONValue?) -> String? {
        guard case .dictionary(let object)? = value else { return nil }
        for key in object.keys.sorted() {
            guard case .dictionary(let change)? = object[key],
                  let kind = string(from: change["type"]) else { continue }
            return kind
        }
        return nil
    }

    private static func fileChangesDiff(from value: CodexJSONValue?) -> String? {
        guard case .dictionary(let object)? = value else { return nil }
        let chunks = object.keys.sorted().compactMap { path -> String? in
            guard case .dictionary(let change)? = object[path] else { return nil }
            if let diff = string(from: change["unified_diff"])?.nilIfBlank {
                return diff
            }
            if let content = string(from: change["content"])?.nilIfBlank,
               let type = string(from: change["type"])?.nilIfBlank {
                return syntheticDiff(path: path, type: type, content: content)
            }
            return nil
        }
        let diff = chunks.joined(separator: "\n")
        return diff.nilIfBlank
    }

    private static func syntheticDiff(path: String, type: String, content: String) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        switch type {
        case "delete":
            return (["--- a/\(path)", "+++ /dev/null"] + lines.map { "-\($0)" }).joined(separator: "\n")
        case "add":
            return (["--- /dev/null", "+++ b/\(path)"] + lines.map { "+\($0)" }).joined(separator: "\n")
        default:
            return content
        }
    }

    private static func nestedValue(_ value: CodexJSONValue?, key: String) -> CodexJSONValue? {
        guard case .dictionary(let object)? = value else { return nil }
        return object[key]
    }

    private static func string(from value: CodexJSONValue?) -> String? {
        switch value {
        case .string(let string): return string.nilIfBlank
        case .int(let int): return String(int)
        case .double(let double): return String(double)
        case .bool(let bool): return String(bool)
        case .array(let values):
            return values.compactMap(string(from:)).joined(separator: " ").nilIfBlank
        case .dictionary(let object):
            return string(from: object["type"])
                ?? string(from: object["message"])
                ?? string(from: object["text"])
        case .null, nil:
            return nil
        }
    }

    private static func int(from value: CodexJSONValue?) -> Int? {
        switch value {
        case .int(let int): return int
        case .double(let double): return Int(double)
        case .string(let string): return Int(string)
        case .bool, .array, .dictionary, .null, nil: return nil
        }
    }

    private static func jsonText(from value: CodexJSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .null:
            return nil
        case .string, .int, .double, .bool:
            return string(from: value)
        case .array, .dictionary:
            guard let data = try? JSONEncoder().encode(value),
                  let text = String(data: data, encoding: .utf8) else {
                return value.description.nilIfBlank
            }
            return text.nilIfBlank
        }
    }
}

public struct CodexThreadHistorySnapshot: Sendable {
    public var messages: [CodexChatMessage]
    public var agentStateMapper: CodexAgentStateMapper

    public init(messages: [CodexChatMessage] = [], agentStateMapper: CodexAgentStateMapper = CodexAgentStateMapper()) {
        self.messages = messages
        self.agentStateMapper = agentStateMapper
    }

    public init(raw response: CodexJSONValue) {
        var mapper = CodexAgentStateMapper()
        var messages: [CodexChatMessage] = []

        for turn in Self.turnObjects(from: response) {
            let fallbackDate = Self.date(from: turn["startedAt"]) ?? Date()
            guard case .array(let items)? = turn["items"] else { continue }

            for itemValue in items {
                guard case .dictionary(let object) = itemValue else { continue }
                let item = try? itemValue.decode(ThreadItem.self)
                let itemDate = Self.date(from: object["createdAt"])
                    ?? Self.date(from: object["startedAt"])
                    ?? Self.date(from: object["completedAt"])
                    ?? fallbackDate
                let type = Self.string(from: object["type"]) ?? item?.type ?? ""

                if let item, mapper.isSubagentItem(item) {
                    _ = mapper.itemCompleted(item)
                    continue
                }

                switch type {
                case "userMessage":
                    guard let text = Self.userMessageText(from: object), !text.isEmpty else { continue }
                    messages.append(CodexChatMessage(role: .user, text: text, createdAt: itemDate))
                case "agentMessage", "assistantMessage":
                    guard let text = Self.string(from: object["text"])?.nilIfBlank else { continue }
                    let phase = Self.string(from: object["phase"])
                    messages.append(CodexChatMessage(role: .assistant, text: text, detail: phase, createdAt: itemDate))
                    _ = mapper.assistantMessageCompleted(text)
                case "commandExecution":
                    guard let run = Self.commandRun(from: object, itemID: Self.string(from: object["id"]) ?? item?.id ?? UUID().uuidString) else {
                        continue
                    }
                    messages.append(CodexChatMessage(
                        role: .terminal,
                        text: run.output,
                        isStreaming: run.isStreaming,
                        createdAt: itemDate,
                        parseContent: false,
                        commandRun: run
                    ))
                case "fileChange", "patch":
                    let itemID = Self.string(from: object["id"]) ?? item?.id ?? UUID().uuidString
                    guard let change = CodexChatMessage.fileChange(itemID: itemID, raw: object) else {
                        continue
                    }
                    messages.append(CodexChatMessage(
                        role: .fileChange,
                        text: change.diff.isEmpty ? change.output : change.diff,
                        isStreaming: change.isStreaming,
                        createdAt: itemDate,
                        parseContent: false,
                        fileChange: change
                    ))
                case "plan":
                    let itemID = Self.string(from: object["id"]) ?? item?.id ?? UUID().uuidString
                    guard let plan = CodexChatMessage.planUpdate(itemID: itemID, raw: object, isStreaming: false) else {
                        continue
                    }
                    messages.append(CodexChatMessage(
                        role: .plan,
                        text: plan.copyText,
                        isStreaming: false,
                        createdAt: itemDate,
                        parseContent: false,
                        planUpdate: plan
                    ))
                case "mcpToolCall", "toolCall":
                    let itemID = Self.string(from: object["id"]) ?? item?.id ?? UUID().uuidString
                    guard let toolCall = CodexChatMessage.toolCall(itemID: itemID, raw: object, fallbackStatus: "completed") else {
                        continue
                    }
                    messages.append(CodexChatMessage(
                        role: .tool,
                        text: toolCall.copyText,
                        isStreaming: toolCall.isStreaming,
                        createdAt: itemDate,
                        parseContent: false,
                        toolCall: toolCall
                    ))
                default:
                    continue
                }
            }
        }

        self.init(messages: messages, agentStateMapper: mapper)
    }

    public var lifecycleEvents: [CodexAgentLifecycleEvent] {
        agentStateMapper.lifecycleEvents
    }

    public var sideChat: CodexSideChatState? {
        agentStateMapper.sideChat
    }

    public var subagents: [CodexSubagentState] {
        agentStateMapper.subagents
    }

    public var subagentThreadIDs: [String] {
        agentStateMapper.subagents.map(\.id)
    }

    @discardableResult
    public mutating func applyChildThread(raw response: CodexJSONValue, threadID explicitThreadID: String? = nil) -> Bool {
        guard let threadID = explicitThreadID ?? Self.threadID(from: response) else { return false }
        var didApply = false

        if let thread = Self.threadObject(from: response) {
            let name = Self.string(from: thread["agentNickname"]) ?? Self.string(from: thread["name"])
            let role = Self.string(from: thread["agentRole"])
            didApply = agentStateMapper.updateSubagentMetadata(id: threadID, name: name, role: role) || didApply
        }

        for turn in Self.turnObjects(from: response) {
            var sawItem = false
            guard case .array(let items)? = turn["items"] else { continue }
            for itemValue in items {
                guard let item = try? itemValue.decode(ThreadItem.self) else { continue }
                sawItem = true
                didApply = agentStateMapper.subagentItemCompleted(threadID: threadID, item: item) != nil || didApply
            }

            guard sawItem, Self.isFinishedTurnStatus(Self.string(from: turn["status"])) else { continue }
            didApply = agentStateMapper.subagentTurnCompleted(threadID: threadID, error: Self.turnErrorMessage(from: turn)) != nil || didApply
        }

        return didApply
    }

    private static func turnObjects(from response: CodexJSONValue) -> [[String: CodexJSONValue]] {
        if let thread = threadObject(from: response),
           case .array(let turns)? = thread["turns"] {
            return turns.compactMap { value in
                guard case .dictionary(let turn) = value else { return nil }
                return turn
            }
        }

        if case .dictionary(let object) = response {
            if case .array(let turns)? = object["turns"] {
                return turns.compactMap { value in
                    guard case .dictionary(let turn) = value else { return nil }
                    return turn
                }
            }
        }
        return []
    }

    private static func threadObject(from response: CodexJSONValue) -> [String: CodexJSONValue]? {
        guard case .dictionary(let object) = response else { return nil }
        if case .dictionary(let thread)? = object["thread"] { return thread }
        if object["turns"] != nil, object["id"] != nil { return object }
        return nil
    }

    private static func threadID(from response: CodexJSONValue) -> String? {
        if let thread = threadObject(from: response) {
            return string(from: thread["id"])
        }
        return nil
    }

    private static func userMessageText(from object: [String: CodexJSONValue]) -> String? {
        if let text = string(from: object["text"])?.nilIfBlank { return text }
        if let text = strings(in: object["content"]).joined(separator: "\n").nilIfBlank { return text }
        if let text = strings(in: object["input"]).joined(separator: "\n").nilIfBlank { return text }
        return nil
    }

    private static func commandRun(from object: [String: CodexJSONValue], itemID: String) -> CodexChatMessage.CommandRun? {
        let command = commandText(from: object["command"])
            ?? string(from: object["cmd"])
            ?? string(from: object["name"])
            ?? "Command"
        let output = string(from: object["aggregatedOutput"])
            ?? string(from: object["output"])
            ?? string(from: object["stdout"])
            ?? strings(in: object["outputs"]).joined(separator: "\n")
        let status = string(from: object["status"]) ?? "completed"
        let isStreaming = status == "active" || status == "inProgress" || status == "running"

        if output.isEmpty, command == "Command" { return nil }
        return CodexChatMessage.CommandRun(
            itemID: itemID,
            command: command,
            cwd: string(from: object["cwd"]),
            output: output,
            status: status,
            exitCode: int(from: object["exitCode"]),
            isStreaming: isStreaming
        )
    }

    private static func commandText(from value: CodexJSONValue?) -> String? {
        switch value {
        case .array(let values):
            let parts = values.compactMap(string(from:))
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        default:
            return string(from: value)
        }
    }

    private static func strings(in value: CodexJSONValue?) -> [String] {
        switch value {
        case .string(let string):
            return [string]
        case .int(let int):
            return [String(int)]
        case .double(let double):
            return [String(double)]
        case .bool(let bool):
            return [String(bool)]
        case .array(let values):
            return values.flatMap(strings(in:))
        case .dictionary(let object):
            if let text = string(from: object["text"]) { return [text] }
            if let value = string(from: object["value"]) { return [value] }
            return []
        case .null, nil:
            return []
        }
    }

    private static func string(from value: CodexJSONValue?) -> String? {
        switch value {
        case .string(let string): return string
        case .int(let int): return String(int)
        case .double(let double): return String(double)
        case .bool(let bool): return String(bool)
        case .array(let values): return values.compactMap(string(from:)).joined(separator: " ")
        case .dictionary(let object):
            return string(from: object["type"])
                ?? string(from: object["message"])
                ?? string(from: object["text"])
        case .null, nil: return nil
        }
    }

    private static func int(from value: CodexJSONValue?) -> Int? {
        switch value {
        case .int(let int): return int
        case .double(let double): return Int(double)
        case .string(let string): return Int(string)
        case .bool, .array, .dictionary, .null, nil: return nil
        }
    }

    private static func date(from value: CodexJSONValue?) -> Date? {
        let seconds: TimeInterval?
        switch value {
        case .int(let int): seconds = TimeInterval(int)
        case .double(let double): seconds = double
        case .string(let string): seconds = TimeInterval(string)
        case .bool, .array, .dictionary, .null, nil: seconds = nil
        }
        guard var seconds else { return nil }
        if seconds > 10_000_000_000 {
            seconds /= 1_000
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func isFinishedTurnStatus(_ status: String?) -> Bool {
        switch status?.lowercased() {
        case "completed", "failed", "interrupted", "cancelled", "canceled":
            return true
        default:
            return false
        }
    }

    private static func turnErrorMessage(from turn: [String: CodexJSONValue]) -> String? {
        guard let error = turn["error"] else { return nil }
        if case .null = error { return nil }
        return string(from: error)
    }
}

public struct CodexActivity: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case turn
        case tool
        case token
        case login
        case notice
    }

    public let id: UUID
    public var kind: Kind
    public var title: String
    public var detail: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        detail: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.createdAt = createdAt
    }
}

public struct CodexAgentLifecycleEvent: Identifiable, Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case spawning
        case running
        case completed
        case closed
        case failed
    }

    public let id: UUID
    public var status: Status
    public var title: String
    public var detail: String
    public var agentNames: [String]
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        status: Status,
        title: String,
        detail: String = "",
        agentNames: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.status = status
        self.title = title
        self.detail = detail
        self.agentNames = agentNames
        self.createdAt = createdAt
    }
}

public struct CodexSubagentState: Identifiable, Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case running
        case completed
        case closed
        case failed
    }

    public let id: String
    public var name: String
    public var title: String
    public var prompt: String
    public var status: Status
    public var messages: [CodexChatMessage]
    public var createdAt: Date
    public var completedAt: Date?

    public init(
        id: String? = nil,
        name: String,
        title: String,
        prompt: String,
        status: Status,
        messages: [CodexChatMessage] = [],
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id ?? "subagent-\(name.lowercased())"
        self.name = name
        self.title = title
        self.prompt = prompt
        self.status = status
        self.messages = messages
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

public extension CodexSubagentState {
    var isVisibleInFloatingSummary: Bool {
        status != .closed
    }

    var floatingSummaryTitle: String {
        switch status {
        case .running:
            return "\(name) is working"
        case .completed:
            return name
        case .failed:
            return "\(name) failed"
        case .closed:
            return name
        }
    }

    var floatingSummarySystemImage: String {
        switch status {
        case .running:
            return "person.crop.circle.badge.clock"
        case .completed:
            return "person.crop.circle.badge.checkmark"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .closed:
            return "person.crop.circle"
        }
    }
}

public struct CodexSideChatState: Identifiable, Equatable, Sendable {
    public static let defaultID = "side-chat"

    public let id: String
    public var title: String
    public var messages: [CodexChatMessage]
    public var createdAt: Date

    public init(
        id: String = Self.defaultID,
        title: String = "Side chat",
        messages: [CodexChatMessage] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
    }
}

public enum CodexAgentPanelTab: Identifiable, Equatable, Sendable {
    case sideChat(CodexSideChatState)
    case subagent(CodexSubagentState)

    public var id: String {
        switch self {
        case .sideChat(let sideChat): return sideChat.id
        case .subagent(let subagent): return subagent.id
        }
    }

    public var title: String {
        switch self {
        case .sideChat(let sideChat): return sideChat.title
        case .subagent(let subagent): return subagent.name
        }
    }

    public var messages: [CodexChatMessage] {
        switch self {
        case .sideChat(let sideChat): return sideChat.messages
        case .subagent(let subagent): return subagent.messages
        }
    }
}

public struct CodexAgentPanelState: Equatable, Sendable {
    public var isOpen: Bool
    public var selectedTabID: String?
    public var sideChat: CodexSideChatState?
    public var subagents: [CodexSubagentState]

    public init(
        isOpen: Bool = false,
        selectedTabID: String? = nil,
        sideChat: CodexSideChatState? = nil,
        subagents: [CodexSubagentState] = []
    ) {
        self.isOpen = isOpen
        self.selectedTabID = selectedTabID
        self.sideChat = sideChat
        self.subagents = subagents
    }

    public var tabs: [CodexAgentPanelTab] {
        var tabs: [CodexAgentPanelTab] = []
        if let sideChat { tabs.append(.sideChat(sideChat)) }
        tabs.append(contentsOf: subagents.map(CodexAgentPanelTab.subagent))
        return tabs
    }
}

public struct CodexPromptSuggestion: Identifiable, Equatable, Sendable {
    public var id: String { prompt }
    public var systemImage: String
    public var prompt: String
    public var detail: String?

    public init(systemImage: String, prompt: String, detail: String? = nil) {
        self.systemImage = systemImage
        self.prompt = prompt
        self.detail = detail
    }
}

extension CodexActivity.Kind {
    var systemImage: String {
        switch self {
        case .turn: return "arrow.triangle.2.circlepath"
        case .tool: return "wrench.and.screwdriver.fill"
        case .token: return "gauge.with.dots.needle.33percent"
        case .login: return "person.badge.key.fill"
        case .notice: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .turn: return CodexTheme.accent
        case .tool: return CodexTheme.tool
        case .token: return CodexTheme.success
        case .login: return CodexTheme.warning
        case .notice: return CodexTheme.tertiary
        }
    }
}
