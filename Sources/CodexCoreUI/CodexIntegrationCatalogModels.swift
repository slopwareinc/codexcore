import Foundation
import CodexCore

public struct CodexMCPServerStatus: Identifiable, Equatable, Sendable {
    public struct Entry: Identifiable, Equatable, Sendable {
        public var name: String
        public var title: String?
        public var detail: String?
        public var inputSchema: CodexJSONValue?
        public var parameters: [String]
        public var readOnlyHint: Bool?
        public var idempotentHint: Bool?
        public var destructiveHint: Bool?
        public var openWorldHint: Bool?
        public var approvalMode: CodexMCPToolApprovalMode?

        public var id: String { name }
        public var displayName: String { title?.nilIfBlank ?? name }

        public init(
            name: String,
            title: String? = nil,
            detail: String? = nil,
            inputSchema: CodexJSONValue? = nil,
            parameters: [String] = [],
            readOnlyHint: Bool? = nil,
            idempotentHint: Bool? = nil,
            destructiveHint: Bool? = nil,
            openWorldHint: Bool? = nil,
            approvalMode: CodexMCPToolApprovalMode? = nil
        ) {
            self.name = name
            self.title = title
            self.detail = detail
            self.inputSchema = inputSchema
            self.parameters = parameters
            self.readOnlyHint = readOnlyHint
            self.idempotentHint = idempotentHint
            self.destructiveHint = destructiveHint
            self.openWorldHint = openWorldHint
            self.approvalMode = approvalMode
        }
    }

    public var name: String
    public var displayName: String
    public var version: String?
    public var pluginID: String?
    public var detail: String?
    public var authStatus: String
    public var enabled: Bool?
    public var startupState: CodexSchemaMCPServerStartupState?
    public var error: String?
    public var failureReason: CodexSchemaMCPServerStartupFailureReason?
    public var enabledTools: [String]?
    public var disabledTools: [String]
    public var defaultToolsApprovalMode: CodexMCPToolApprovalMode?
    public var tools: [Entry]
    public var resources: [Entry]
    public var resourceTemplates: [Entry]

    public var id: String { name }

    public init(
        name: String,
        displayName: String? = nil,
        version: String? = nil,
        pluginID: String? = nil,
        detail: String? = nil,
        authStatus: String = "unknown",
        enabled: Bool? = true,
        startupStatus: String? = nil,
        error: String? = nil,
        failureReason: CodexSchemaMCPServerStartupFailureReason? = nil,
        enabledTools: [String]? = nil,
        disabledTools: [String] = [],
        defaultToolsApprovalMode: CodexMCPToolApprovalMode? = nil,
        tools: [Entry] = [],
        resources: [Entry] = [],
        resourceTemplates: [Entry] = []
    ) {
        self.name = name
        self.displayName = displayName?.nilIfBlank ?? name
        self.version = version
        self.pluginID = pluginID
        self.detail = detail
        self.authStatus = authStatus
        self.enabled = enabled
        self.startupState = startupStatus.flatMap(CodexSchemaMCPServerStartupState.init(rawValue:))
        self.error = error
        self.failureReason = failureReason
        self.enabledTools = enabledTools
        self.disabledTools = disabledTools
        self.defaultToolsApprovalMode = defaultToolsApprovalMode
        self.tools = tools
        self.resources = resources
        self.resourceTemplates = resourceTemplates
    }

    public init?(raw value: CodexJSONValue) {
        guard case .dictionary(let object) = value,
              let name = Self.string(in: object, keys: ["name", "id", "serverName"])?.nilIfBlank,
              object["tools"] != nil,
              object["resources"] != nil,
              object["resourceTemplates"] != nil else {
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
            pluginID: Self.string(in: object, keys: ["pluginId"]),
            detail: detail,
            authStatus: Self.string(in: object, keys: ["authStatus", "auth", "authentication"]) ?? "unknown",
            enabled: CodexJSONCoercion.bool(in: object, key: "enabled"),
            startupStatus: Self.string(in: object, keys: ["status", "startupStatus", "state"]),
            error: Self.string(in: object, keys: ["error"]),
            failureReason: Self.string(in: object, keys: ["failureReason"])
                .flatMap(CodexSchemaMCPServerStartupFailureReason.init(rawValue:)),
            enabledTools: Self.strings(from: object["enabled_tools"] ?? object["enabledTools"]),
            disabledTools: Self.strings(from: object["disabled_tools"] ?? object["disabledTools"]) ?? [],
            defaultToolsApprovalMode: Self.string(
                in: object,
                keys: ["default_tools_approval_mode", "defaultToolsApprovalMode"]
            ).flatMap(CodexMCPToolApprovalMode.init(rawValue:)),
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

    public var startupStatus: String? {
        get { startupState?.rawValue }
        set { startupState = newValue.flatMap(CodexSchemaMCPServerStartupState.init(rawValue:)) }
    }

    public var inventorySummary: String {
        let toolLabel = tools.count == 1 ? "1 tool" : "\(tools.count) tools"
        let resourceCount = resources.count + resourceTemplates.count
        let resourceLabel = resourceCount == 1 ? "1 resource" : "\(resourceCount) resources"
        return "\(toolLabel) · \(resourceLabel)"
    }

    public var ownershipLabel: String {
        pluginID.map { "Provided by plugin \($0)" } ?? "Configured directly"
    }

    public func applyingStartupStatus(
        _ status: CodexSchemaMCPServerStartupState,
        error: String?,
        failureReason: CodexSchemaMCPServerStartupFailureReason? = nil
    ) -> CodexMCPServerStatus {
        var copy = self
        copy.startupState = status
        copy.error = error
        copy.failureReason = failureReason
        return copy
    }


    public func applyingStartupStatus(_ status: String, error: String?) -> CodexMCPServerStatus {
        applyingStartupStatus(
            CodexSchemaMCPServerStartupState(rawValue: status) ?? .unrecognized(status),
            error: error
        )
    }

    private static func entries(from value: CodexJSONValue?) -> [Entry] {
        switch value {
        case .dictionary(let object):
            return object
                .map { key, value -> Entry in
                    if case .dictionary(let entryObject) = value {
                        return entry(from: entryObject, fallbackName: key)
                    }
                    return Entry(name: key, detail: CodexJSONCoercion.flatString(from: value))
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
        let inputSchema = object["inputSchema"] ?? object["input_schema"]
        let annotations = dictionary(from: object["annotations"])
        let toolConfig = dictionary(from: object["config"])
        return Entry(
            name: name,
            title: title,
            detail: detail,
            inputSchema: inputSchema,
            parameters: parameterNames(from: inputSchema),
            readOnlyHint: bool(in: annotations, keys: ["readOnlyHint", "read_only_hint"]),
            idempotentHint: bool(in: annotations, keys: ["idempotentHint", "idempotent_hint"]),
            destructiveHint: bool(in: annotations, keys: ["destructiveHint", "destructive_hint"]),
            openWorldHint: bool(in: annotations, keys: ["openWorldHint", "open_world_hint"]),
            approvalMode: string(in: toolConfig, keys: ["approval_mode", "approvalMode"])
                .flatMap(CodexMCPToolApprovalMode.init(rawValue:))
        )
    }

    private static func dictionary(from value: CodexJSONValue?) -> [String: CodexJSONValue] {
        guard case .dictionary(let object)? = value else { return [:] }
        return object
    }

    private static func string(in object: [String: CodexJSONValue], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key], let string = CodexJSONCoercion.flatString(from: value)?.nilIfBlank else { continue }
            return string
        }
        return nil
    }

    private static func strings(from value: CodexJSONValue?) -> [String]? {
        guard case .array(let values)? = value else { return nil }
        return values.compactMap(CodexJSONCoercion.flatString(from:))
    }

    private static func bool(in object: [String: CodexJSONValue], keys: [String]) -> Bool? {
        for key in keys {
            if let value = CodexJSONCoercion.bool(in: object, key: key) { return value }
        }
        return nil
    }

    private static func parameterNames(from value: CodexJSONValue?) -> [String] {
        guard case .dictionary(let schema)? = value,
              case .dictionary(let properties)? = schema["properties"] else { return [] }
        let required = Set(strings(from: schema["required"]) ?? [])
        return properties.keys.sorted().map { required.contains($0) ? "\($0) *" : $0 }
    }
}

public enum CodexMCPToolApprovalMode: String, CaseIterable, Equatable, Sendable {
    case auto
    case prompt
    case writes
    case approve
}

public struct CodexMCPServerConfiguration: Equatable, Sendable {
    public enum Transport: String, CaseIterable, Equatable, Sendable {
        case stdio
        case streamableHTTP
    }

    public var name: String
    public var enabled: Bool
    public var transport: Transport
    public var command: String
    public var arguments: [String]
    public var workingDirectory: String?
    public var environment: [String: String]
    public var environmentPassthrough: [String]
    public var url: String
    public var bearerTokenEnvironmentVariable: String?
    public var httpHeaders: [String: String]
    public var environmentHTTPHeaders: [String: String]
    public var startupTimeoutSeconds: Double?
    public var toolTimeoutSeconds: Double?
    public var enabledTools: [String]?
    public var disabledTools: [String]
    public var defaultToolsApprovalMode: CodexMCPToolApprovalMode?
    public var toolApprovalModes: [String: CodexMCPToolApprovalMode]

    public init(
        name: String,
        enabled: Bool = true,
        transport: Transport = .stdio,
        command: String = "",
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        environmentPassthrough: [String] = [],
        url: String = "",
        bearerTokenEnvironmentVariable: String? = nil,
        httpHeaders: [String: String] = [:],
        environmentHTTPHeaders: [String: String] = [:],
        startupTimeoutSeconds: Double? = nil,
        toolTimeoutSeconds: Double? = nil,
        enabledTools: [String]? = nil,
        disabledTools: [String] = [],
        defaultToolsApprovalMode: CodexMCPToolApprovalMode? = nil,
        toolApprovalModes: [String: CodexMCPToolApprovalMode] = [:]
    ) {
        self.name = name
        self.enabled = enabled
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.environmentPassthrough = environmentPassthrough
        self.url = url
        self.bearerTokenEnvironmentVariable = bearerTokenEnvironmentVariable
        self.httpHeaders = httpHeaders
        self.environmentHTTPHeaders = environmentHTTPHeaders
        self.startupTimeoutSeconds = startupTimeoutSeconds
        self.toolTimeoutSeconds = toolTimeoutSeconds
        self.enabledTools = enabledTools
        self.disabledTools = disabledTools
        self.defaultToolsApprovalMode = defaultToolsApprovalMode
        self.toolApprovalModes = toolApprovalModes
    }

    public var configValue: CodexJSONValue {
        var object: [String: CodexJSONValue] = ["enabled": .bool(enabled)]
        switch transport {
        case .stdio:
            object["command"] = .string(command)
            if !arguments.isEmpty { object["args"] = .array(arguments.map(CodexJSONValue.string)) }
            if let workingDirectory = workingDirectory?.nilIfBlank { object["cwd"] = .string(workingDirectory) }
            if !environment.isEmpty { object["env"] = .dictionary(environment.mapValues(CodexJSONValue.string)) }
            if !environmentPassthrough.isEmpty {
                object["env_vars"] = .array(environmentPassthrough.map(CodexJSONValue.string))
            }
        case .streamableHTTP:
            object["url"] = .string(url)
            if let bearerTokenEnvironmentVariable = bearerTokenEnvironmentVariable?.nilIfBlank {
                object["bearer_token_env_var"] = .string(bearerTokenEnvironmentVariable)
            }
            if !httpHeaders.isEmpty { object["http_headers"] = .dictionary(httpHeaders.mapValues(CodexJSONValue.string)) }
            if !environmentHTTPHeaders.isEmpty {
                object["env_http_headers"] = .dictionary(environmentHTTPHeaders.mapValues(CodexJSONValue.string))
            }
        }
        if let startupTimeoutSeconds { object["startup_timeout_sec"] = .double(startupTimeoutSeconds) }
        if let toolTimeoutSeconds { object["tool_timeout_sec"] = .double(toolTimeoutSeconds) }
        if let enabledTools { object["enabled_tools"] = .array(enabledTools.map(CodexJSONValue.string)) }
        if !disabledTools.isEmpty { object["disabled_tools"] = .array(disabledTools.map(CodexJSONValue.string)) }
        if let defaultToolsApprovalMode {
            object["default_tools_approval_mode"] = .string(defaultToolsApprovalMode.rawValue)
        }
        if !toolApprovalModes.isEmpty {
            object["tools"] = .dictionary(toolApprovalModes.mapValues {
                .dictionary(["approval_mode": .string($0.rawValue)])
            })
        }
        return .dictionary(object)
    }
}

public struct CodexHookSummary: Identifiable, Equatable, Sendable {
    public static let productEvents: [CodexSchemaHookEventName] = [
        .preToolUse, .permissionRequest, .postToolUse, .preCompact, .postCompact,
        .sessionStart, .sessionEnd, .userPromptSubmit, .subagentStart, .subagentStop,
    ]

    public var id: String
    public var cwd: String
    public var event: CodexSchemaHookEventName
    public var matcher: String?
    public var source: CodexSchemaHookSource
    public var sourcePath: String
    public var trustStatus: CodexSchemaHookTrustStatus
    public var enabled: Bool
    public var managed: Bool
    public var handlerType: CodexSchemaHookHandlerType
    public var command: String?
    public var statusMessage: String?

    public init(
        id: String,
        cwd: String,
        event: CodexSchemaHookEventName,
        matcher: String? = nil,
        source: CodexSchemaHookSource,
        sourcePath: String,
        trustStatus: CodexSchemaHookTrustStatus,
        enabled: Bool,
        managed: Bool,
        handlerType: CodexSchemaHookHandlerType,
        command: String? = nil,
        statusMessage: String? = nil
    ) {
        self.id = id
        self.cwd = cwd
        self.event = event
        self.matcher = matcher
        self.source = source
        self.sourcePath = sourcePath
        self.trustStatus = trustStatus
        self.enabled = enabled
        self.managed = managed
        self.handlerType = handlerType
        self.command = command
        self.statusMessage = statusMessage
    }

    public var sourceLabel: String {
        if managed || source == .mdm || source == .cloudManagedConfig || source == .legacyManagedConfigMdm {
            return "Managed"
        }
        switch source {
        case .plugin: return "Plugin"
        case .project: return "Project"
        default: return "Config"
        }
    }

    public var trustLabel: String { trustStatus.rawValue.capitalized }

    public var eventLabel: String {
        switch event {
        case .preToolUse: "PreToolUse"
        case .permissionRequest: "PermissionRequest"
        case .postToolUse: "PostToolUse"
        case .preCompact: "PreCompact"
        case .postCompact: "PostCompact"
        case .sessionStart: "SessionStart"
        case .sessionEnd: "SessionEnd"
        case .userPromptSubmit: "UserPromptSubmit"
        case .subagentStart: "SubagentStart"
        case .subagentStop: "SubagentStop"
        case .stop: "Stop"
        case .unrecognized(let value): value
        }
    }
}

public struct CodexHooksCatalog: Equatable, Sendable {
    public var hooks: [CodexHookSummary]
    public var warnings: [String]
    public var errors: [String]

    public init(hooks: [CodexHookSummary] = [], warnings: [String] = [], errors: [String] = []) {
        self.hooks = hooks
        self.warnings = warnings
        self.errors = errors
    }

    public init(raw response: CodexJSONValue) {
        guard case .dictionary(let object) = response,
              case .array(let entries)? = object["data"] else {
            self.init()
            return
        }
        var hooks: [CodexHookSummary] = []
        var warnings: [String] = []
        var errors: [String] = []
        for entry in entries {
            guard case .dictionary(let entryObject) = entry else { continue }
            let cwd = CodexJSONCoercion.flatString(from: entryObject["cwd"]) ?? ""
            if case .array(let values)? = entryObject["warnings"] {
                warnings += values.compactMap(CodexJSONCoercion.flatString(from:))
            }
            if case .array(let values)? = entryObject["errors"] {
                errors += values.compactMap { value in
                    guard case .dictionary(let error) = value else { return nil }
                    let path = CodexJSONCoercion.flatString(from: error["path"])
                    let message = CodexJSONCoercion.flatString(from: error["message"])
                    return [path, message].compactMap { $0?.nilIfBlank }.joined(separator: ": ").nilIfBlank
                }
            }
            guard case .array(let values)? = entryObject["hooks"] else { continue }
            hooks += values.compactMap { value in
                guard case .dictionary(let hook) = value,
                      let key = CodexJSONCoercion.flatString(from: hook["key"]),
                      let eventRaw = CodexJSONCoercion.flatString(from: hook["eventName"]),
                      let event = CodexSchemaHookEventName(rawValue: eventRaw),
                      let sourceRaw = CodexJSONCoercion.flatString(from: hook["source"]),
                      let source = CodexSchemaHookSource(rawValue: sourceRaw),
                      let trustRaw = CodexJSONCoercion.flatString(from: hook["trustStatus"]),
                      let trust = CodexSchemaHookTrustStatus(rawValue: trustRaw),
                      let handlerRaw = CodexJSONCoercion.flatString(from: hook["handlerType"]),
                      let handler = CodexSchemaHookHandlerType(rawValue: handlerRaw) else { return nil }
                return CodexHookSummary(
                    id: "\(cwd):\(key)",
                    cwd: cwd,
                    event: event,
                    matcher: CodexJSONCoercion.flatString(from: hook["matcher"]),
                    source: source,
                    sourcePath: CodexJSONCoercion.flatString(from: hook["sourcePath"]) ?? "",
                    trustStatus: trust,
                    enabled: CodexJSONCoercion.bool(in: hook, key: "enabled") ?? false,
                    managed: CodexJSONCoercion.bool(in: hook, key: "isManaged") ?? false,
                    handlerType: handler,
                    command: CodexJSONCoercion.flatString(from: hook["command"]),
                    statusMessage: CodexJSONCoercion.flatString(from: hook["statusMessage"])
                )
            }
        }
        self.init(
            hooks: hooks.sorted { ($0.event.rawValue, $0.id) < ($1.event.rawValue, $1.id) },
            warnings: warnings,
            errors: errors
        )
    }
}

public struct CodexPluginIconReference: Equatable, Hashable, Sendable {
    public var logo: String?
    public var logoDark: String?
    public var composerIcon: String?

    public init(logo: String? = nil, logoDark: String? = nil, composerIcon: String? = nil) {
        self.logo = logo?.nilIfBlank
        self.logoDark = logoDark?.nilIfBlank
        self.composerIcon = composerIcon?.nilIfBlank
    }

    public var isEmpty: Bool { logo == nil && logoDark == nil && composerIcon == nil }

    public func url(prefersDark: Bool) -> URL? {
        let values = prefersDark ? [logoDark, logo, composerIcon] : [logo, logoDark, composerIcon]
        for value in values.compactMap({ $0 }) {
            if let url = URL(string: value), url.scheme != nil { return url }
            return URL(fileURLWithPath: value)
        }
        return nil
    }
}

public struct CodexPluginReadDetail: Identifiable, Equatable, Sendable {
    public var id: String
    public var description: String?
    public var appNames: [String]
    public var appTemplateNames: [String]
    public var mcpServerNames: [String]
    public var skillNames: [String]
    public var hookNames: [String]
    public var scheduledTaskNames: [String]
    public var shareURL: String?

    public init(id: String, detail: CodexSchemaPluginDetail) {
        self.id = id
        self.description = detail.description?.nilIfBlank
        self.appNames = detail.apps.map(\.name)
        self.appTemplateNames = detail.appTemplates.map(\.name)
        self.mcpServerNames = detail.mcpServers
        self.skillNames = detail.skills.map { $0.interface?.displayName?.nilIfBlank ?? $0.name }
        self.hookNames = detail.hooks.map { "\($0.eventName.rawValue): \($0.key)" }
        self.scheduledTaskNames = detail.scheduledTasks?.map(\.name) ?? []
        self.shareURL = detail.shareUrl?.nilIfBlank
    }
}

public struct CodexPluginSummary: Identifiable, Equatable, Sendable {
    public var id: String
    public var protocolID: String
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
    public var availability: String?
    public var protocolDisabledReason: String?
    public var eligiblePlanTypes: [String]
    public var installedAt: TimeInterval?
    public var authPolicy: String
    public var sourceType: String?
    public var sourceDetail: String?
    public var localVersion: String?
    public var availableVersion: String?
    public var defaultPrompt: String?
    public var websiteURL: String?
    public var privacyPolicyURL: String?
    public var termsOfServiceURL: String?
    public var icon: CodexPluginIconReference
    public var capabilities: [String]
    public var keywords: [String]
    public var isFeatured: Bool

    public init(
        id: String,
        protocolID: String? = nil,
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
        availability: String? = nil,
        protocolDisabledReason: String? = nil,
        eligiblePlanTypes: [String] = [],
        installedAt: TimeInterval? = nil,
        authPolicy: String = "ON_USE",
        sourceType: String? = nil,
        sourceDetail: String? = nil,
        localVersion: String? = nil,
        availableVersion: String? = nil,
        defaultPrompt: String? = nil,
        websiteURL: String? = nil,
        privacyPolicyURL: String? = nil,
        termsOfServiceURL: String? = nil,
        icon: CodexPluginIconReference = .init(),
        capabilities: [String] = [],
        keywords: [String] = [],
        isFeatured: Bool = false
    ) {
        self.id = id
        self.protocolID = protocolID?.nilIfBlank ?? id
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
        self.protocolDisabledReason = protocolDisabledReason
        self.eligiblePlanTypes = eligiblePlanTypes
        self.installedAt = installedAt
        self.authPolicy = authPolicy
        self.sourceType = sourceType
        self.sourceDetail = sourceDetail
        self.localVersion = localVersion
        self.availableVersion = availableVersion
        self.defaultPrompt = defaultPrompt
        self.websiteURL = websiteURL
        self.privacyPolicyURL = privacyPolicyURL
        self.termsOfServiceURL = termsOfServiceURL
        self.icon = icon
        self.capabilities = capabilities
        self.keywords = keywords
        self.isFeatured = isFeatured
    }

    public init?(raw value: CodexJSONValue, marketplace: MarketplaceContext) {
        guard case .dictionary(let object) = value,
              let name = Self.string(in: object, keys: ["name"])?.nilIfBlank,
              let installed = Self.bool(from: object["installed"]),
              let enabled = Self.bool(from: object["enabled"]),
              let installPolicy = Self.string(in: object, keys: ["installPolicy"]),
              let authPolicy = Self.string(in: object, keys: ["authPolicy"]) else {
            return nil
        }

        let pluginID = Self.string(in: object, keys: ["id"])?.nilIfBlank ?? name
        let interface = Self.dictionary(from: object["interface"])
        let source = Self.dictionary(from: object["source"])
        let sourcePath = Self.string(in: source, keys: ["path"])
        self.init(
            id: "\(marketplace.name):\(pluginID)",
            protocolID: pluginID,
            name: name,
            displayName: Self.string(in: interface, keys: ["displayName"]),
            shortDescription: Self.string(in: interface, keys: ["shortDescription"]),
            longDescription: Self.string(in: interface, keys: ["longDescription"]),
            marketplaceName: marketplace.name,
            marketplaceDisplayName: marketplace.displayName,
            marketplacePath: marketplace.path,
            category: Self.string(in: interface, keys: ["category"]),
            developerName: Self.string(in: interface, keys: ["developerName"]),
            installed: installed,
            enabled: enabled,
            installPolicy: installPolicy,
            availability: Self.string(in: object, keys: ["availability"]),
            protocolDisabledReason: Self.string(in: object, keys: ["disabledReason"]),
            eligiblePlanTypes: Self.stringArray(from: object["eligiblePlanTypes"]),
            installedAt: object["installedAt"].flatMap(CodexJSONCoercion.flatString(from:)).flatMap(TimeInterval.init),
            authPolicy: authPolicy,
            sourceType: Self.string(in: source, keys: ["type"]),
            sourceDetail: Self.sourceDetail(from: source),
            localVersion: Self.string(in: object, keys: ["localVersion"]),
            availableVersion: Self.string(in: object, keys: ["version"]),
            defaultPrompt: Self.prompt(from: interface["defaultPrompt"]),
            websiteURL: Self.string(in: interface, keys: ["websiteUrl"]),
            privacyPolicyURL: Self.string(in: interface, keys: ["privacyPolicyUrl"]),
            termsOfServiceURL: Self.string(in: interface, keys: ["termsOfServiceUrl"]),
            icon: CodexPluginIconReference(
                logo: Self.resolvedAsset(
                    Self.string(in: interface, keys: ["logoUrl", "logo"]),
                    pluginSourcePath: sourcePath
                ),
                logoDark: Self.resolvedAsset(
                    Self.string(in: interface, keys: ["logoUrlDark", "logoDark"]),
                    pluginSourcePath: sourcePath
                ),
                composerIcon: Self.resolvedAsset(
                    Self.string(in: interface, keys: ["composerIconUrl", "composerIcon"]),
                    pluginSourcePath: sourcePath
                )
            ),
            capabilities: Self.stringArray(from: interface["capabilities"]),
            keywords: Self.stringArray(from: object["keywords"])
        )
    }

    public static func plugins(from response: CodexJSONValue) -> [CodexPluginSummary] {
        let featuredIDs = featuredPluginIDs(from: response)
        let marketplaceEntries = marketplaces(from: response)
        var plugins: [CodexPluginSummary] = []
        plugins.reserveCapacity(marketplaceEntries.reduce(0) { $0 + $1.plugins.count })
        for marketplace in marketplaceEntries {
            for rawPlugin in marketplace.plugins {
                guard var plugin = CodexPluginSummary(raw: rawPlugin, marketplace: marketplace.context) else {
                    continue
                }
                plugin.isFeatured = featuredIDs.contains(plugin.protocolID)
                    || featuredIDs.contains(plugin.id)
                    || featuredIDs.contains(plugin.name)
                plugins.append(plugin)
            }
        }
        return plugins.sorted { lhs, rhs in
            if lhs.installed != rhs.installed { return lhs.installed && !rhs.installed }
            if lhs.enabled != rhs.enabled { return lhs.enabled && !rhs.enabled }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private static func featuredPluginIDs(from response: CodexJSONValue) -> Set<String> {
        guard case .dictionary(let object) = response,
              case .array(let values)? = object["featuredPluginIds"] else { return [] }
        return Set(values.compactMap { CodexJSONCoercion.flatString(from: $0)?.nilIfBlank })
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

    public var isAdminDisabled: Bool {
        availability == "DISABLED_BY_ADMIN" || protocolDisabledReason == "disabled_by_admin"
    }

    public var disabledReason: String? {
        switch protocolDisabledReason {
        case "disabled_by_admin": return "Access is turned off by your admin."
        case "plan_not_eligible": return "This plugin is not available on your plan."
        case "required_app_unavailable": return "A required app is unavailable."
        case "unknown": return "This plugin is unavailable."
        case .some(let value): return value.replacingOccurrences(of: "_", with: " ").capitalized
        case nil: return isAdminDisabled ? "Access is turned off by your admin." : nil
        }
    }

    public var isProtocolDisabled: Bool { disabledReason != nil }

    public var isInstalledByAdmin: Bool {
        sourceType?.lowercased() == "remote" && installed && installPolicy == "INSTALLED_BY_DEFAULT"
    }

    public var canInstall: Bool { !installed && installPolicy == "AVAILABLE" && !isProtocolDisabled }
    public var canUninstall: Bool { installed && !isInstalledByAdmin && !isProtocolDisabled }

    public var statusLabel: String {
        if isAdminDisabled { return "Disabled by admin" }
        if protocolDisabledReason == "plan_not_eligible" { return "Unavailable on your plan" }
        if protocolDisabledReason == "required_app_unavailable" { return "Required app unavailable" }
        if isProtocolDisabled { return "Unavailable" }
        if installed, enabled { return "Enabled" }
        if installed { return "Disabled" }
        if installPolicy == "AVAILABLE" { return "Available" }
        if installPolicy == "INSTALLED_BY_DEFAULT" { return "Default" }
        return "Unavailable"
    }

    public var stateLabels: [String] {
        var labels = installed ? ["Installed"] : []
        labels.append(statusLabel)
        if isInstalledByAdmin, !labels.contains("Installed by admin") {
            labels.append("Installed by admin")
        } else if sourceType?.lowercased() == "remote" {
            labels.append("Remote")
        }
        return labels
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

    /// Manage mode treats enabled state as distinct from installation state for
    /// every installed plugin, including curated and account-backed plugins.
    public var supportsEnabledToggle: Bool { installed && !isProtocolDisabled }

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
            guard case .array(let plugins)? = marketplace["plugins"] else { return nil }
            return (context, plugins)
        }
    }

    private static func sourceDetail(from source: [String: CodexJSONValue]) -> String? {
        string(in: source, keys: ["path"])
            ?? string(in: source, keys: ["url"])
            ?? string(in: source, keys: ["refName"])
    }

    /// App-server currently publishes absolute local paths and signed remote URLs. Resolving
    /// relative paths as well keeps older/local marketplace manifests usable without making
    /// the view layer guess which plugin directory owns an asset.
    private static func resolvedAsset(_ value: String?, pluginSourcePath: String?) -> String? {
        guard let value = value?.nilIfBlank else { return nil }
        if let url = URL(string: value), url.scheme != nil { return value }
        if value.hasPrefix("/") { return value }
        guard let pluginSourcePath = pluginSourcePath?.nilIfBlank else { return value }
        return URL(fileURLWithPath: pluginSourcePath, isDirectory: true)
            .appendingPathComponent(value)
            .standardizedFileURL
            .path
    }

    private static func dictionary(from value: CodexJSONValue?) -> [String: CodexJSONValue] {
        guard case .dictionary(let object)? = value else { return [:] }
        return object
    }

    private static func string(in object: [String: CodexJSONValue], keys: [String]) -> String? {
        for key in keys {
            guard let string = CodexJSONCoercion.flatString(from: object[key])?.nilIfBlank else { continue }
            return string
        }
        return nil
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
        return values.compactMap { CodexJSONCoercion.flatString(from: $0)?.nilIfBlank }
    }

    private static func prompt(from value: CodexJSONValue?) -> String? {
        switch value {
        case .string(let prompt):
            return prompt.nilIfBlank
        case .array(let values):
            return values
                .compactMap { CodexJSONCoercion.flatString(from: $0)?.nilIfBlank }
                .joined(separator: "\n")
                .nilIfBlank
        case .dictionary, .int, .double, .bool, .null, nil:
            return nil
        }
    }
}

public struct CodexAppSummary: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var description: String?
    public var distributionChannel: String?
    public var installURL: String?
    public var isAccessible: Bool?
    public var isEnabled: Bool?
    public var labels: [String: String]?
    public var logoURL: String?
    public var logoURLDark: String?
    public var pluginDisplayNames: [String]?
    public var isInstalled: Bool
    public var runtimeEnabled: Bool?
    public var runtimeCallable: Bool?
    public var displayName: String
    public var detail: String
    public var developerName: String?
    public var category: String?
    public var enabled: Bool
    public var callable: Bool
    public var runtimeName: String?
    public var icon: CodexPluginIconReference

    public init(
        id: String,
        displayName: String,
        detail: String = "App",
        developerName: String? = nil,
        category: String? = nil,
        enabled: Bool = true,
        callable: Bool = true,
        runtimeName: String? = nil,
        icon: CodexPluginIconReference = .init()
    ) {
        self.id = id
        self.name = displayName
        self.description = detail
        self.distributionChannel = nil
        self.installURL = nil
        self.isAccessible = true
        self.isEnabled = enabled
        self.labels = nil
        self.logoURL = icon.logo
        self.logoURLDark = icon.logoDark
        self.pluginDisplayNames = nil
        self.isInstalled = true
        self.runtimeEnabled = enabled
        self.runtimeCallable = callable
        self.displayName = displayName
        self.detail = detail
        self.developerName = developerName
        self.category = category
        self.enabled = enabled
        self.callable = callable
        self.runtimeName = runtimeName
        self.icon = icon
    }

    public init(
        id: String,
        name: String,
        description: String? = nil,
        distributionChannel: String? = nil,
        installURL: String? = nil,
        isAccessible: Bool? = nil,
        isEnabled: Bool? = nil,
        labels: [String: String]? = nil,
        logoURL: String? = nil,
        logoURLDark: String? = nil,
        pluginDisplayNames: [String]? = nil,
        isInstalled: Bool = false,
        runtimeName: String? = nil,
        runtimeEnabled: Bool? = nil,
        runtimeCallable: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.distributionChannel = distributionChannel
        self.installURL = installURL
        self.isAccessible = isAccessible
        self.isEnabled = isEnabled
        self.labels = labels
        self.logoURL = logoURL
        self.logoURLDark = logoURLDark
        self.pluginDisplayNames = pluginDisplayNames
        self.isInstalled = isInstalled
        self.runtimeName = runtimeName
        self.runtimeEnabled = runtimeEnabled
        self.runtimeCallable = runtimeCallable
        self.displayName = name
        self.detail = description?.nilIfBlank ?? "App"
        self.developerName = nil
        self.category = nil
        self.enabled = runtimeEnabled ?? isEnabled ?? true
        self.callable = runtimeCallable ?? true
        self.icon = .init(logo: logoURL, logoDark: logoURLDark)
    }

    public init(catalog: CodexSchemaAppInfo, installed: CodexSchemaInstalledApp?) {
        self.init(
            id: catalog.id,
            name: catalog.name,
            description: catalog.description,
            distributionChannel: catalog.distributionChannel,
            installURL: catalog.installUrl,
            isAccessible: catalog.isAccessible,
            isEnabled: catalog.isEnabled,
            labels: catalog.labels,
            logoURL: catalog.logoUrl,
            logoURLDark: catalog.logoUrlDark,
            pluginDisplayNames: catalog.pluginDisplayNames,
            isInstalled: installed != nil,
            runtimeName: installed?.runtimeName,
            runtimeEnabled: installed?.enabled,
            runtimeCallable: installed?.callable
        )
    }

    public static func join(catalog: [CodexSchemaAppInfo], installed: [CodexSchemaInstalledApp]) -> [CodexAppSummary] {
        var installedByID = Dictionary<String, CodexSchemaInstalledApp>(minimumCapacity: installed.count)
        for app in installed {
            // Keep the existing last-record-wins behavior for duplicate runtime IDs.
            installedByID[app.id] = app
        }
        var catalogIDs = Set<String>(minimumCapacity: catalog.count)
        for app in catalog {
            catalogIDs.insert(app.id)
        }
        return catalog.map { CodexAppSummary(catalog: $0, installed: installedByID[$0.id]) }
            + installedByID.values
                .filter { !catalogIDs.contains($0.id) }
                .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
                .map { app in
                    CodexAppSummary(
                        id: app.id,
                        name: app.runtimeName?.nilIfBlank ?? app.id,
                        isInstalled: true,
                        runtimeName: app.runtimeName,
                        runtimeEnabled: app.enabled,
                        runtimeCallable: app.callable
                    )
                }
    }

    /// The official surface treats accessible entries from `app/list` as the
    /// installed Manage inventory. `app/installed` only supplements runtime
    /// metadata when it is available.
    public static func apps(
        listResponse: CodexJSONValue?,
        installedResponse: CodexJSONValue?
    ) -> [CodexAppSummary] {
        let installedByID = Dictionary(uniqueKeysWithValues:
            dictionaries(in: installedResponse, key: "apps").compactMap { object -> (String, [String: CodexJSONValue])? in
                guard let id = string(in: object, keys: ["id"]) else { return nil }
                return (id, object)
            }
        )

        return dictionaries(in: listResponse, key: "data").compactMap { metadata in
            guard let id = string(in: metadata, keys: ["id"]),
                  bool(in: metadata, keys: ["isAccessible"]) == true else { return nil }
            let installed = installedByID[id] ?? [:]
            let branding = dictionary(from: metadata["branding"])
            return CodexAppSummary(
                id: id,
                displayName: string(in: metadata, keys: ["name"]) ?? id,
                detail: string(in: metadata, keys: ["description"]) ?? "App",
                developerName: string(in: branding, keys: ["developer"]),
                category: string(in: branding, keys: ["category"]),
                enabled: bool(in: metadata, keys: ["isEnabled", "enabled"])
                    ?? bool(in: installed, keys: ["enabled"])
                    ?? true,
                callable: bool(in: installed, keys: ["callable"]) ?? true,
                runtimeName: string(in: installed, keys: ["runtimeName"]),
                icon: .init(
                    logo: string(in: metadata, keys: ["logoUrl"]),
                    logoDark: string(in: metadata, keys: ["logoUrlDark"])
                )
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public static func enabledParams(id: String, enabled: Bool) -> CodexSchemaConfigBatchWriteParams {
        CodexSchemaConfigBatchWriteParams(
            edits: [
                CodexSchemaConfigEdit(
                    keyPath: "apps.\(id).enabled",
                    mergeStrategy: .upsert,
                    value: .bool(enabled)
                )
            ],
            reloadUserConfig: true
        )
    }

    private static func dictionaries(in response: CodexJSONValue?, key: String) -> [[String: CodexJSONValue]] {
        guard case .dictionary(let object)? = response,
              case .array(let values)? = object[key] else { return [] }
        return values.compactMap { value in
            guard case .dictionary(let dictionary) = value else { return nil }
            return dictionary
        }
    }

    private static func dictionary(from value: CodexJSONValue?) -> [String: CodexJSONValue] {
        guard case .dictionary(let object)? = value else { return [:] }
        return object
    }

    private static func string(in object: [String: CodexJSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = CodexJSONCoercion.flatString(from: object[key])?.nilIfBlank { return value }
        }
        return nil
    }

    private static func bool(in object: [String: CodexJSONValue], keys: [String]) -> Bool? {
        for key in keys {
            if let value = CodexJSONCoercion.bool(in: object, key: key) { return value }
        }
        return nil
    }
}

public struct CodexSkillSummary: Identifiable, Equatable, Sendable {
    public var name: String
    public var displayName: String
    public var detail: String
    public var description: String
    public var path: String
    public var cwd: String?
    public var scope: String?
    public var enabled: Bool
    public var defaultPrompt: String?
    public var dependencies: [String]
    public var allowedTools: [String]
    public var disablesModelInvocation: Bool
    public var icon: CodexPluginIconReference
    public var remoteMarketplaceName: String?
    public var remotePluginID: String?

    public var iconSmall: String? { icon.logo }
    public var iconLarge: String? { icon.logoDark ?? icon.logo }

    public var id: String { "\(cwd ?? "")\0\(path)" }

    public init(
        name: String,
        displayName: String? = nil,
        detail: String? = nil,
        description: String = "",
        path: String,
        cwd: String? = nil,
        scope: String? = nil,
        enabled: Bool = true,
        defaultPrompt: String? = nil,
        dependencies: [String] = [],
        allowedTools: [String] = [],
        disablesModelInvocation: Bool = false,
        icon: CodexPluginIconReference = .init(),
        remoteMarketplaceName: String? = nil,
        remotePluginID: String? = nil
    ) {
        self.name = name
        self.displayName = displayName?.nilIfBlank ?? name
        self.detail = detail?.nilIfBlank ?? description.nilIfBlank ?? "Skill"
        self.description = description
        self.path = path
        self.cwd = cwd
        self.scope = scope
        self.enabled = enabled
        self.defaultPrompt = defaultPrompt
        self.dependencies = dependencies
        self.allowedTools = allowedTools
        self.disablesModelInvocation = disablesModelInvocation
        self.icon = icon
        self.remoteMarketplaceName = remoteMarketplaceName
        self.remotePluginID = remotePluginID
    }

    public init?(raw value: CodexJSONValue, cwd: String? = nil) {
        guard case .dictionary(let object) = value,
              let name = Self.string(in: object, keys: ["name"])?.nilIfBlank,
              let path = Self.string(in: object, keys: ["path"])?.nilIfBlank,
              let enabled = CodexJSONCoercion.bool(in: object, key: "enabled") else {
            return nil
        }
        let interface = Self.dictionary(in: object, key: "interface")
        let iconSmall = interface.flatMap { Self.string(in: $0, keys: ["iconSmallUrl", "icon_small_url", "iconSmall"]) }
        let iconLarge = interface.flatMap { Self.string(in: $0, keys: ["iconLargeUrl", "icon_large_url", "iconLarge"]) }
        self.init(
            name: name,
            displayName: interface.flatMap { Self.string(in: $0, keys: ["displayName"]) },
            detail: interface.flatMap { Self.string(in: $0, keys: ["shortDescription"]) } ?? Self.string(in: object, keys: ["shortDescription"]),
            description: Self.string(in: object, keys: ["description"]) ?? "",
            path: path,
            cwd: cwd,
            scope: Self.string(in: object, keys: ["scope"]),
            enabled: enabled,
            defaultPrompt: interface.flatMap { Self.prompt(from: $0["defaultPrompt"]) },
            dependencies: Self.dependencies(from: object["dependencies"]),
            allowedTools: Self.stringList(from: object["allowed-tools"] ?? object["allowed_tools"] ?? object["allowedTools"]),
            disablesModelInvocation: Self.bool(
                from: object["disable-model-invocation"] ?? object["disable_model_invocation"] ?? object["disableModelInvocation"]
            ) ?? false,
            icon: .init(logo: iconSmall ?? iconLarge, logoDark: iconLarge),
            remoteMarketplaceName: Self.string(in: object, keys: ["remoteMarketplaceName"]),
            remotePluginID: Self.string(in: object, keys: ["remotePluginId", "remotePluginID"])
        )
    }

    public static func skills(from response: CodexJSONValue) -> [CodexSkillSummary] {
        guard case .dictionary(let object) = response,
              case .array(let entries)? = object["data"] else {
            return []
        }
        var seen: Set<String> = []
        var summaries: [CodexSkillSummary] = []
        for entry in entries {
            guard case .dictionary(let entryObject) = entry,
                  case .array(let skills)? = entryObject["skills"] else {
                continue
            }
            let cwd = Self.string(in: entryObject, keys: ["cwd"])
            for value in skills {
                guard let summary = CodexSkillSummary(raw: value, cwd: cwd),
                      seen.insert(summary.id).inserted else {
                    continue
                }
                summaries.append(summary)
            }
        }
        return summaries.sorted { lhs, rhs in
            if lhs.enabled != rhs.enabled { return lhs.enabled && !rhs.enabled }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    public static func loadErrorMessages(from response: CodexJSONValue) -> [String] {
        guard case .dictionary(let object) = response,
              case .array(let entries)? = object["data"] else { return [] }
        var messages: [String] = []
        for entry in entries {
            guard case .dictionary(let fields) = entry,
                  case .array(let errors)? = fields["errors"] else { continue }
            let cwd = Self.string(in: fields, keys: ["cwd"])
            for error in errors {
                guard case .dictionary(let details) = error,
                      let message = Self.string(in: details, keys: ["message"])?.nilIfBlank else { continue }
                let path = Self.string(in: details, keys: ["path"])?.nilIfBlank ?? cwd?.nilIfBlank
                messages.append(path.map { "\($0): \(message)" } ?? message)
            }
        }
        return messages
    }

    public var scopeLabel: String {
        switch scope {
        case "user": return "Personal"
        case "repo": return "Repo"
        case "system": return "System"
        case "admin": return "Admin"
        case .some(let value): return value.capitalized
        case nil: return "Skill"
        }
    }

    public var statusLabel: String {
        enabled ? "Enabled" : "Disabled"
    }

    private static func dictionary(in object: [String: CodexJSONValue], key: String) -> [String: CodexJSONValue]? {
        guard case .dictionary(let dictionary)? = object[key] else { return nil }
        return dictionary
    }

    private static func string(in object: [String: CodexJSONValue], keys: [String]) -> String? {
        for key in keys {
            guard let string = CodexJSONCoercion.flatString(from: object[key])?.nilIfBlank else { continue }
            return string
        }
        return nil
    }

    private static func prompt(from value: CodexJSONValue?) -> String? {
        switch value {
        case .string(let prompt):
            return prompt.nilIfBlank
        case .array(let values):
            return values
                .compactMap { CodexJSONCoercion.flatString(from: $0)?.nilIfBlank }
                .joined(separator: "\n")
                .nilIfBlank
        case .dictionary, .int, .double, .bool, .null, nil:
            return nil
        }
    }

    private static func dependencies(from value: CodexJSONValue?) -> [String] {
        guard case .dictionary(let object)? = value else { return [] }
        var dependencies: [String] = []
        if case .array(let tools)? = object["tools"] {
            dependencies += tools.compactMap { tool in
                guard case .dictionary(let fields) = tool,
                      let type = string(in: fields, keys: ["type"]),
                      let value = string(in: fields, keys: ["value"]) else {
                    return nil
                }
                return "\(type): \(value)"
            }
        }
        dependencies += object.compactMap { key, value in
            guard key != "tools", bool(from: value) ?? false else { return nil }
            return key
        }
        return dependencies.sorted()
    }

    private static func stringList(from value: CodexJSONValue?) -> [String] {
        switch value {
        case .array(let values):
            return values.compactMap(CodexJSONCoercion.flatString(from:))
        case .string(let value):
            return value.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        case .dictionary, .int, .double, .bool, .null, nil:
            return []
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
}

public struct CodexSkillDocument: Equatable, Sendable {
    public var body: String
    public var allowedTools: [String]
    public var disablesModelInvocation: Bool

    public init(contents: String) {
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n"),
              let end = normalized.dropFirst(4).range(of: "\n---\n") else {
            self.body = normalized
            self.allowedTools = []
            self.disablesModelInvocation = false
            return
        }
        let frontmatter = String(normalized[normalized.index(normalized.startIndex, offsetBy: 4)..<end.lowerBound])
        self.body = String(normalized[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        var fields: [String: String] = [:]
        for line in frontmatter.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 { fields[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        let allowed = fields["allowed-tools"] ?? fields["allowed_tools"] ?? ""
        self.allowedTools = allowed
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]\"'"))
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .filter { !$0.isEmpty }
        self.disablesModelInvocation = Bool(fields["disable-model-invocation"] ?? "") ?? false
    }
}

public enum CodexPluginRoutePrimaryTab: String, CaseIterable, Equatable, Sendable {
    case marketplace
    case skills
    case manage

    public var title: String {
        switch self {
        case .marketplace: return "Marketplace"
        case .skills: return "Skills"
        case .manage: return "Manage"
        }
    }
}

public enum CodexPluginCatalogFilter: String, CaseIterable, Equatable, Sendable {
    case all
    case openAI
    case workspace
    case personal

    public var title: String {
        switch self {
        case .all: return "All"
        case .openAI: return "By OpenAI"
        case .workspace: return "By your workspace"
        case .personal: return "Personal"
        }
    }
}

public enum CodexPluginManageTab: String, CaseIterable, Equatable, Sendable {
    case plugins
    case apps
    case mcps
    case skills
    case marketplace

    public var title: String {
        switch self {
        case .plugins: return "Plugins"
        case .apps: return "Apps"
        case .mcps: return "MCPs"
        case .skills: return "Skills"
        case .marketplace: return "Marketplace"
        }
    }
}

public struct CodexPluginManageCount: Identifiable, Equatable, Sendable {
    public var tab: CodexPluginManageTab
    public var count: Int

    public var id: CodexPluginManageTab { tab }

    public init(tab: CodexPluginManageTab, count: Int) {
        self.tab = tab
        self.count = count
    }
}

public enum CodexPluginRouteAction: Equatable, Sendable {
    case installPlugin(CodexPluginActionTarget)
    case uninstallPlugin(CodexPluginActionTarget)
    case setPluginEnabled(CodexPluginActionTarget, enabled: Bool)
    case setSkillEnabled(CodexSkillActionTarget, enabled: Bool)
    case setAppEnabled(CodexAppActionTarget, enabled: Bool)
    case addMarketplace(source: String)
    case upgradeMarketplace(CodexMarketplaceActionTarget)
    case removeMarketplace(CodexMarketplaceActionTarget)
    case tryInChat(prompt: String)
}

public struct CodexAppActionTarget: Equatable, Sendable {
    public var id: String
    public var name: String

    public init(app: CodexAppSummary) {
        self.id = app.id
        self.name = app.displayName
    }
}

public struct CodexMarketplaceActionTarget: Equatable, Sendable {
    public var name: String
    public var displayName: String

    public init(marketplace: CodexMarketplaceSummary) {
        self.name = marketplace.name
        self.displayName = marketplace.displayName
    }
}

public struct CodexPluginActionTarget: Equatable, Sendable {
    public var id: String
    public var name: String
    public var displayName: String
    public var marketplaceName: String
    public var marketplacePath: String?

    public init(plugin: CodexPluginSummary) {
        self.id = plugin.protocolID
        self.name = plugin.name
        self.displayName = plugin.displayName
        self.marketplaceName = plugin.marketplaceName
        self.marketplacePath = plugin.marketplacePath
    }
}

public struct CodexSkillActionTarget: Equatable, Sendable {
    public var name: String
    public var displayName: String
    public var path: String
    public var scope: String?

    public init(skill: CodexSkillSummary) {
        self.name = skill.name
        self.displayName = skill.displayName
        self.path = skill.path
        self.scope = skill.scope
    }
}

public struct CodexPluginActionOutcome: Equatable, Sendable {
    public var activity: CodexIntegrationCatalogActivity
    public var didSucceed: Bool
    public var shouldRefresh: Bool
    public var draftPrompt: String?

    public init(
        activity: CodexIntegrationCatalogActivity,
        didSucceed: Bool = true,
        shouldRefresh: Bool = false,
        draftPrompt: String? = nil
    ) {
        self.activity = activity
        self.didSucceed = didSucceed
        self.shouldRefresh = shouldRefresh
        self.draftPrompt = draftPrompt
    }
}

public protocol CodexPluginCatalogActionProvider: Sendable {
    func installPlugin(_ target: CodexPluginActionTarget) async -> CodexPluginActionOutcome
    func uninstallPlugin(_ target: CodexPluginActionTarget) async -> CodexPluginActionOutcome
    func setPluginEnabled(_ target: CodexPluginActionTarget, enabled: Bool) async -> CodexPluginActionOutcome
    func setSkillEnabled(_ target: CodexSkillActionTarget, enabled: Bool) async -> CodexPluginActionOutcome
    func setAppEnabled(_ target: CodexAppActionTarget, enabled: Bool) async -> CodexPluginActionOutcome
    func addMarketplace(source: String) async -> CodexPluginActionOutcome
    func upgradeMarketplace(_ target: CodexMarketplaceActionTarget) async -> CodexPluginActionOutcome
    func removeMarketplace(_ target: CodexMarketplaceActionTarget) async -> CodexPluginActionOutcome
}

public extension CodexPluginCatalogActionProvider {
    func setAppEnabled(_ target: CodexAppActionTarget, enabled: Bool) async -> CodexPluginActionOutcome {
        .init(activity: .init(title: "App action unsupported", detail: "This provider does not implement local app execution settings."), didSucceed: false)
    }
    func addMarketplace(source: String) async -> CodexPluginActionOutcome { unsupportedMarketplaceMutation() }
    func upgradeMarketplace(_ target: CodexMarketplaceActionTarget) async -> CodexPluginActionOutcome { unsupportedMarketplaceMutation() }
    func removeMarketplace(_ target: CodexMarketplaceActionTarget) async -> CodexPluginActionOutcome { unsupportedMarketplaceMutation() }

    private func unsupportedMarketplaceMutation() -> CodexPluginActionOutcome {
        .init(activity: .init(title: "Marketplace action unsupported", detail: "This provider does not implement marketplace management."), didSucceed: false)
    }
}

/// Pure request construction keeps the plugin control plane inspectable and
/// testable without coupling UI state to generated protocol representations.
public enum CodexPluginProtocolMutation {
    public struct ConfigWriteTarget: Equatable, Sendable {
        public var filePath: String
        public var expectedVersion: String

        public init(filePath: String, expectedVersion: String) {
            self.filePath = filePath
            self.expectedVersion = expectedVersion
        }
    }

    public static func userConfigTarget(from response: CodexSchemaConfigReadResponse) -> ConfigWriteTarget? {
        response.layers?.compactMap { layer -> ConfigWriteTarget? in
            guard case .dictionary(let source) = layer.name.rawValue,
                  source["type"] == .string("user"),
                  case .string(let filePath) = source["file"] else { return nil }
            return ConfigWriteTarget(filePath: filePath, expectedVersion: layer.version)
        }.last
    }
    public static func configuredPluginEnabled(from response: CodexSchemaConfigReadResponse) -> [String: Bool] {
        guard let layer = response.layers?.last(where: {
            $0.name.rawValue.objectValue?["type"] == .string("user")
        }), let plugins = layer.config.objectValue?["plugins"]?.objectValue else { return [:] }
        return plugins.reduce(into: [:]) { result, entry in
            guard case .bool(let enabled) = entry.value.objectValue?["enabled"] else { return }
            result[entry.key] = enabled
        }
    }

    public static func readParams(for plugin: CodexPluginSummary) -> CodexSchemaPluginReadParams {
        CodexSchemaPluginReadParams(
            marketplacePath: plugin.marketplacePath.map { CodexAppServerSchemaValue(.string($0)) },
            pluginName: plugin.name,
            remoteMarketplaceName: plugin.marketplacePath == nil ? plugin.marketplaceName : nil
        )
    }

    public static func appEnabledParams(
        for target: CodexAppActionTarget,
        enabled: Bool,
        configTarget: ConfigWriteTarget? = nil
    ) -> CodexSchemaConfigBatchWriteParams {
        CodexSchemaConfigBatchWriteParams(
            edits: [.init(keyPath: "apps.\(target.id).enabled", mergeStrategy: .upsert, value: .bool(enabled))],
            expectedVersion: configTarget?.expectedVersion,
            filePath: configTarget?.filePath,
            reloadUserConfig: true
        )
    }

    public static func marketplaceAddParams(source: String) -> CodexSchemaMarketplaceAddParams {
        .init(source: source)
    }

    public static func marketplaceUpgradeParams(for target: CodexMarketplaceActionTarget) -> CodexSchemaMarketplaceUpgradeParams {
        .init(marketplaceName: target.name)
    }

    public static func marketplaceRemoveParams(for target: CodexMarketplaceActionTarget) -> CodexSchemaMarketplaceRemoveParams {
        .init(marketplaceName: target.name)
    }
    public static func installParams(for target: CodexPluginActionTarget) -> CodexSchemaPluginInstallParams {
        CodexSchemaPluginInstallParams(
            marketplacePath: target.marketplacePath.map { CodexAppServerSchemaValue(.string($0)) },
            pluginName: target.name,
            remoteMarketplaceName: target.marketplacePath == nil ? target.marketplaceName : nil
        )
    }

    public static func uninstallParams(for target: CodexPluginActionTarget) -> CodexSchemaPluginUninstallParams {
        CodexSchemaPluginUninstallParams(pluginID: target.id)
    }

    public static func pluginEnabledParams(
        for target: CodexPluginActionTarget,
        enabled: Bool,
        configTarget: ConfigWriteTarget? = nil
    ) -> CodexSchemaConfigBatchWriteParams {
        CodexSchemaConfigBatchWriteParams(
            edits: [
                CodexSchemaConfigEdit(
                    keyPath: "plugins.\(target.id).enabled",
                    mergeStrategy: .upsert,
                    value: .bool(enabled)
                )
            ],
            expectedVersion: configTarget?.expectedVersion,
            filePath: configTarget?.filePath,
            reloadUserConfig: true
        )
    }

    public static func skillEnabledParams(
        for target: CodexSkillActionTarget,
        enabled: Bool
    ) -> CodexSchemaSkillsConfigWriteParams {
        if target.name.contains(":") {
            return CodexSchemaSkillsConfigWriteParams(
                enabled: enabled,
                name: target.name
            )
        }
        return CodexSchemaSkillsConfigWriteParams(
            enabled: enabled,
            path: CodexAppServerSchemaValue(.string(target.path))
        )
    }

    public static func skillUninstallParams(for target: CodexSkillActionTarget) -> CodexSchemaFSRemoveParams {
        let directory = URL(fileURLWithPath: target.path).deletingLastPathComponent().path
        return CodexSchemaFSRemoveParams(
            path: CodexAppServerSchemaValue(.string(directory)),
            recursive: true
        )
    }
}

public enum CodexPluginCatalogActionSession {
    public static func perform(
        _ action: CodexPluginRouteAction,
        provider: any CodexPluginCatalogActionProvider
    ) async -> CodexPluginActionOutcome {
        switch action {
        case .installPlugin(let target):
            return await provider.installPlugin(target)
        case .uninstallPlugin(let target):
            return await provider.uninstallPlugin(target)
        case .setPluginEnabled(let target, let enabled):
            return await provider.setPluginEnabled(target, enabled: enabled)
        case .setSkillEnabled(let target, let enabled):
            return await provider.setSkillEnabled(target, enabled: enabled)
        case .setAppEnabled(let target, let enabled):
            return await provider.setAppEnabled(target, enabled: enabled)
        case .addMarketplace(let source):
            return await provider.addMarketplace(source: source)
        case .upgradeMarketplace(let target):
            return await provider.upgradeMarketplace(target)
        case .removeMarketplace(let target):
            return await provider.removeMarketplace(target)
        case .tryInChat(let prompt):
            return CodexPluginActionOutcome(
                activity: CodexIntegrationCatalogActivity(title: "Prepared plugin prompt", detail: prompt),
                draftPrompt: prompt
            )
        }
    }
}

/// Protocol-backed plugin and skill mutations. MCP management intentionally stays
/// outside this adapter so hosts can evolve the MCP control plane independently.
public struct CodexAppServerPluginCatalogActionProvider: CodexPluginCatalogActionProvider {
    public let codex: Codex

    public init(codex: Codex) {
        self.codex = codex
    }

    public func installPlugin(_ target: CodexPluginActionTarget) async -> CodexPluginActionOutcome {
        do {
            _ = try await codex.pluginInstall(CodexPluginProtocolMutation.installParams(for: target))
            return success("Added \(target.displayName)", detail: target.name)
        } catch {
            return failure("Couldn’t add \(target.displayName)", error: error)
        }
    }

    public func uninstallPlugin(_ target: CodexPluginActionTarget) async -> CodexPluginActionOutcome {
        do {
            _ = try await codex.pluginUninstall(CodexPluginProtocolMutation.uninstallParams(for: target))
            return success("Removed \(target.displayName)", detail: target.name)
        } catch {
            return failure("Couldn’t remove \(target.displayName)", error: error)
        }
    }

    public func setPluginEnabled(_ target: CodexPluginActionTarget, enabled: Bool) async -> CodexPluginActionOutcome {
        do {
            let config = try await codex.configRead(.init(includeLayers: true))
            _ = try await codex.configBatchWrite(
                CodexPluginProtocolMutation.pluginEnabledParams(
                    for: target,
                    enabled: enabled,
                    configTarget: CodexPluginProtocolMutation.userConfigTarget(from: config)
                )
            )
            return success(
                "Updated \(target.displayName)",
                detail: "\(enabled ? "Enabled" : "Disabled") \(target.displayName)"
            )
        } catch {
            return failure("Couldn’t update \(target.displayName)", error: error)
        }
    }

    public func setSkillEnabled(_ target: CodexSkillActionTarget, enabled: Bool) async -> CodexPluginActionOutcome {
        do {
            let response = try await codex.skillsConfigWrite(
                CodexPluginProtocolMutation.skillEnabledParams(for: target, enabled: enabled)
            )
            return success(
                "Updated \(target.displayName)",
                detail: "\(response.effectiveEnabled ? "Enabled" : "Disabled") \(target.displayName)"
            )
        } catch {
            return failure("Couldn’t update \(target.displayName)", error: error)
        }
    }

    public func setAppEnabled(_ target: CodexAppActionTarget, enabled: Bool) async -> CodexPluginActionOutcome {
        do {
            let config = try await codex.configRead(.init(includeLayers: true))
            _ = try await codex.configBatchWrite(CodexPluginProtocolMutation.appEnabledParams(
                for: target,
                enabled: enabled,
                configTarget: CodexPluginProtocolMutation.userConfigTarget(from: config)
            ))
            return success("Updated \(target.name)", detail: enabled ? "Enabled local execution" : "Disabled local execution")
        } catch {
            return failure("Couldn’t update \(target.name)", error: error)
        }
    }

    public func addMarketplace(source: String) async -> CodexPluginActionOutcome {
        do {
            let response = try await codex.marketplaceAdd(.init(source: source))
            return success(response.alreadyAdded ? "Marketplace already registered" : "Added marketplace", detail: response.marketplaceName)
        } catch {
            return failure("Couldn’t add marketplace", error: error)
        }
    }

    public func upgradeMarketplace(_ target: CodexMarketplaceActionTarget) async -> CodexPluginActionOutcome {
        do {
            let response = try await codex.marketplaceUpgrade(.init(marketplaceName: target.name))
            if let error = response.errors.first(where: { $0.marketplaceName == target.name }) {
                return .init(activity: .init(title: "Couldn’t upgrade \(target.displayName)", detail: error.message), didSucceed: false)
            }
            return success("Upgraded \(target.displayName)", detail: target.name)
        } catch {
            return failure("Couldn’t upgrade \(target.displayName)", error: error)
        }
    }

    public func removeMarketplace(_ target: CodexMarketplaceActionTarget) async -> CodexPluginActionOutcome {
        do {
            _ = try await codex.marketplaceRemove(.init(marketplaceName: target.name))
            return success("Removed \(target.displayName)", detail: target.name)
        } catch {
            return failure("Couldn’t remove \(target.displayName)", error: error)
        }
    }

    public func uninstallSkill(_ target: CodexSkillActionTarget) async -> CodexPluginActionOutcome {
        guard target.scope == "user" else {
            return CodexPluginActionOutcome(activity: .init(
                title: "Can’t uninstall \(target.displayName)",
                detail: "Only personal skills can be uninstalled from this surface."
            ), didSucceed: false)
        }
        do {
            _ = try await codex.remove(CodexPluginProtocolMutation.skillUninstallParams(for: target))
            return success("Uninstalled \(target.displayName)", detail: target.path)
        } catch {
            return failure("Couldn’t uninstall \(target.displayName)", error: error)
        }
    }

    private func success(_ title: String, detail: String) -> CodexPluginActionOutcome {
        CodexPluginActionOutcome(
            activity: CodexIntegrationCatalogActivity(title: title, detail: detail),
            shouldRefresh: true
        )
    }

    private func failure(_ title: String, error: Error) -> CodexPluginActionOutcome {
        CodexPluginActionOutcome(
            activity: CodexIntegrationCatalogActivity(title: title, detail: error.localizedDescription),
            didSucceed: false
        )
    }
}

public struct CodexPluginRouteDetail: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case plugin(CodexPluginActionTarget)
        case skill(CodexSkillActionTarget)
        case mcp(String)
        case boundary(String)
    }

    public var kind: Kind
    public var title: String
    public var detail: String
    public var description: String
    public var statusLabel: String
    public var prompt: String?
    public var capabilities: [String]
    public var metadata: [String]
    public var legalLinks: [String]
    public var canInstall: Bool
    public var canUninstall: Bool
    public var canToggleEnabled: Bool
    public var isEnabled: Bool
    public var boundaryActionTitle: String?
    public var icon: CodexPluginIconReference?

    public var tryInChatAction: CodexPluginRouteAction? {
        prompt.map { .tryInChat(prompt: $0) }
    }

    public var primaryAction: CodexPluginRouteAction? {
        switch kind {
        case .plugin(let target):
            if canInstall { return .installPlugin(target) }
            if canUninstall { return .uninstallPlugin(target) }
            return nil
        case .skill(let target):
            guard canToggleEnabled else { return nil }
            return .setSkillEnabled(target, enabled: !isEnabled)
        case .mcp, .boundary:
            return nil
        }
    }

    public init(
        kind: Kind,
        title: String,
        detail: String,
        description: String,
        statusLabel: String,
        prompt: String?,
        capabilities: [String],
        metadata: [String],
        legalLinks: [String],
        canInstall: Bool,
        canUninstall: Bool,
        canToggleEnabled: Bool,
        isEnabled: Bool,
        boundaryActionTitle: String? = nil,
        icon: CodexPluginIconReference? = nil
    ) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.description = description
        self.statusLabel = statusLabel
        self.prompt = prompt
        self.capabilities = capabilities
        self.metadata = metadata
        self.legalLinks = legalLinks
        self.canInstall = canInstall
        self.canUninstall = canUninstall
        self.canToggleEnabled = canToggleEnabled
        self.isEnabled = isEnabled
        self.boundaryActionTitle = boundaryActionTitle
        self.icon = icon
    }

    public init(plugin: CodexPluginSummary) {
        let target = CodexPluginActionTarget(plugin: plugin)
        self.kind = .plugin(target)
        self.title = plugin.displayName
        self.detail = plugin.detail
        self.description = plugin.longDescription?.nilIfBlank ?? plugin.shortDescription?.nilIfBlank ?? plugin.detail
        self.statusLabel = plugin.statusLabel
        self.prompt = plugin.defaultPrompt
        self.capabilities = plugin.capabilities
        self.metadata = [
            plugin.developerName.map { "Developer: \($0)" },
            plugin.category.map { "Category: \($0)" },
            plugin.localVersion.map { "Version: \($0)" },
            "Marketplace: \(plugin.marketplaceDisplayName)"
        ].compactMap { $0 }
        self.legalLinks = [
            plugin.websiteURL.map { "Website: \($0)" },
            plugin.privacyPolicyURL.map { "Privacy: \($0)" },
            plugin.termsOfServiceURL.map { "Terms: \($0)" }
        ].compactMap { $0 }
        self.canInstall = !plugin.installed && plugin.installPolicy == "AVAILABLE"
        self.canUninstall = plugin.installed && plugin.installPolicy != "INSTALLED_BY_DEFAULT"
        self.canToggleEnabled = plugin.installed
        self.isEnabled = plugin.enabled
        self.boundaryActionTitle = nil
        self.icon = plugin.icon.isEmpty ? nil : plugin.icon
    }

    public init(skill: CodexSkillSummary) {
        let target = CodexSkillActionTarget(skill: skill)
        self.kind = .skill(target)
        self.title = skill.displayName
        self.detail = skill.detail
        self.description = skill.description.nilIfBlank ?? skill.detail
        self.statusLabel = skill.statusLabel
        self.prompt = skill.defaultPrompt
        self.capabilities = skill.dependencies.isEmpty ? ["skill"] : skill.dependencies
        self.metadata = [
            "Scope: \(skill.scopeLabel)",
            "Path: \(skill.path)"
        ]
        self.legalLinks = []
        self.canInstall = false
        self.canUninstall = skill.scope == "user"
        self.canToggleEnabled = true
        self.isEnabled = skill.enabled
        self.boundaryActionTitle = nil
        self.icon = nil
    }

    public init(mcpServer: CodexMCPServerStatus) {
        self.kind = .mcp(mcpServer.id)
        self.title = mcpServer.displayName
        self.detail = mcpServer.detail?.nilIfBlank ?? mcpServer.inventorySummary
        self.description = mcpServer.error?.nilIfBlank ?? "This server exposes \(mcpServer.inventorySummary) to Codex."
        self.statusLabel = mcpServer.startupStatus?.nilIfBlank ?? mcpServer.authStatusLabel
        self.prompt = nil
        self.capabilities = [
            "\(mcpServer.tools.count) tools",
            "\(mcpServer.resources.count) resources",
            "\(mcpServer.resourceTemplates.count) resource templates"
        ]
        self.metadata = [
            "Server: \(mcpServer.name)",
            mcpServer.version.map { "Version: \($0)" },
            "Authentication: \(mcpServer.authStatusLabel)"
        ].compactMap { $0 }
        self.legalLinks = []
        self.canInstall = false
        self.canUninstall = false
        self.canToggleEnabled = false
        self.isEnabled = mcpServer.error == nil
        self.boundaryActionTitle = nil
        self.icon = nil
    }

    public static func boundary(
        id: String,
        title: String,
        detail: String,
        description: String,
        statusLabel: String,
        prompt: String? = nil,
        capabilities: [String] = [],
        metadata: [String] = [],
        legalLinks: [String] = [],
        boundaryActionTitle: String? = nil
    ) -> CodexPluginRouteDetail {
        CodexPluginRouteDetail(
            kind: .boundary(id),
            title: title,
            detail: detail,
            description: description,
            statusLabel: statusLabel,
            prompt: prompt,
            capabilities: capabilities,
            metadata: metadata,
            legalLinks: legalLinks,
            canInstall: false,
            canUninstall: false,
            canToggleEnabled: false,
            isEnabled: false,
            boundaryActionTitle: boundaryActionTitle
        )
    }
}
