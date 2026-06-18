import Foundation
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

    public static var defaultCommands: [CodexSlashCommand] {
        observedCommands
    }

    static let observedCommands: [CodexSlashCommand] = [
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
        from commands: [CodexSlashCommand] = CodexSlashCommand.defaultCommands,
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
