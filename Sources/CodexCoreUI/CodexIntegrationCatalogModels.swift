import Foundation
import CodexCore

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
        return Entry(name: name, title: title, detail: detail)
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
    public var logoPath: String?
    public var logoDarkPath: String?
    public var logoURL: String?
    public var logoDarkURL: String?
    public var installed: Bool
    public var enabled: Bool
    public var installPolicy: String
    public var availability: String
    public var authPolicy: String
    public var sourceType: String?
    public var sourceDetail: String?
    public var localVersion: String?
    public var defaultPrompt: String?
    public var websiteURL: String?
    public var privacyPolicyURL: String?
    public var termsOfServiceURL: String?
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
        logoPath: String? = nil,
        logoDarkPath: String? = nil,
        logoURL: String? = nil,
        logoDarkURL: String? = nil,
        installed: Bool = false,
        enabled: Bool = false,
        installPolicy: String = "NOT_AVAILABLE",
        availability: String = "AVAILABLE",
        authPolicy: String = "ON_USE",
        sourceType: String? = nil,
        sourceDetail: String? = nil,
        localVersion: String? = nil,
        defaultPrompt: String? = nil,
        websiteURL: String? = nil,
        privacyPolicyURL: String? = nil,
        termsOfServiceURL: String? = nil,
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
        self.logoPath = logoPath
        self.logoDarkPath = logoDarkPath
        self.logoURL = logoURL
        self.logoDarkURL = logoDarkURL
        self.installed = installed
        self.enabled = enabled
        self.installPolicy = installPolicy
        self.availability = availability
        self.authPolicy = authPolicy
        self.sourceType = sourceType
        self.sourceDetail = sourceDetail
        self.localVersion = localVersion
        self.defaultPrompt = defaultPrompt
        self.websiteURL = websiteURL
        self.privacyPolicyURL = privacyPolicyURL
        self.termsOfServiceURL = termsOfServiceURL
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
            logoPath: Self.string(in: interface, keys: ["logo"]),
            logoDarkPath: Self.string(in: interface, keys: ["logoDark"]),
            logoURL: Self.string(in: interface, keys: ["logoUrl"]),
            logoDarkURL: Self.string(in: interface, keys: ["logoUrlDark"]),
            installed: Self.bool(from: object["installed"]) ?? false,
            enabled: Self.bool(from: object["enabled"]) ?? false,
            installPolicy: Self.string(in: object, keys: ["installPolicy"]) ?? "NOT_AVAILABLE",
            availability: Self.string(in: object, keys: ["availability"]) ?? "AVAILABLE",
            authPolicy: Self.string(in: object, keys: ["authPolicy"]) ?? "ON_USE",
            sourceType: Self.string(in: source, keys: ["type"]),
            sourceDetail: Self.sourceDetail(from: source),
            localVersion: Self.string(in: object, keys: ["localVersion"]),
            defaultPrompt: Self.prompt(from: interface["defaultPrompt"]),
            websiteURL: Self.string(in: interface, keys: ["websiteUrl"]),
            privacyPolicyURL: Self.string(in: interface, keys: ["privacyPolicyUrl"]),
            termsOfServiceURL: Self.string(in: interface, keys: ["termsOfServiceUrl"]),
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

public struct CodexSkillSummary: Identifiable, Equatable, Sendable {
    public var name: String
    public var displayName: String
    public var detail: String
    public var description: String
    public var path: String
    public var scope: String?
    public var enabled: Bool
    public var defaultPrompt: String?
    public var dependencies: [String]

    public var id: String { path }

    public init(
        name: String,
        displayName: String? = nil,
        detail: String? = nil,
        description: String = "",
        path: String,
        scope: String? = nil,
        enabled: Bool = true,
        defaultPrompt: String? = nil,
        dependencies: [String] = []
    ) {
        self.name = name
        self.displayName = displayName?.nilIfBlank ?? name
        self.detail = detail?.nilIfBlank ?? description.nilIfBlank ?? "Skill"
        self.description = description
        self.path = path
        self.scope = scope
        self.enabled = enabled
        self.defaultPrompt = defaultPrompt
        self.dependencies = dependencies
    }

    public init?(raw value: CodexJSONValue) {
        guard case .dictionary(let object) = value,
              let name = Self.string(in: object, keys: ["name"])?.nilIfBlank,
              let path = Self.string(in: object, keys: ["path"])?.nilIfBlank else {
            return nil
        }
        let interface = Self.dictionary(in: object, key: "interface")
        self.init(
            name: name,
            displayName: interface.flatMap { Self.string(in: $0, keys: ["displayName"]) },
            detail: interface.flatMap { Self.string(in: $0, keys: ["shortDescription"]) } ?? Self.string(in: object, keys: ["shortDescription"]),
            description: Self.string(in: object, keys: ["description"]) ?? "",
            path: path,
            scope: Self.string(in: object, keys: ["scope"]),
            enabled: CodexJSONCoercion.bool(in: object, key: "enabled") ?? true,
            defaultPrompt: interface.flatMap { Self.prompt(from: $0["defaultPrompt"]) },
            dependencies: Self.dependencies(from: object["dependencies"])
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
            for value in skills {
                guard let summary = CodexSkillSummary(raw: value),
                      seen.insert(summary.path).inserted else {
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
        return object.compactMap { key, value in
            guard bool(from: value) ?? false else { return nil }
            return key
        }.sorted()
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

public enum CodexPluginBrowseScope: String, CaseIterable, Equatable, Sendable {
    case openAI
    case workspace
    case personal

    public var title: String {
        switch self {
        case .openAI: "By OpenAI"
        case .workspace: "By your workspace"
        case .personal: "Personal"
        }
    }
}

public struct CodexPluginCatalogSection: Identifiable, Equatable, Sendable {
    public var title: String
    public var plugins: [CodexPluginSummary]

    public var id: String { title }

    public init(title: String, plugins: [CodexPluginSummary]) {
        self.title = title
        self.plugins = plugins
    }
}

public struct CodexSkillCatalogSection: Identifiable, Equatable, Sendable {
    public var title: String
    public var skills: [CodexSkillSummary]

    public var id: String { title }

    public init(title: String, skills: [CodexSkillSummary]) {
        self.title = title
        self.skills = skills
    }
}

public enum CodexPluginManageTab: String, CaseIterable, Equatable, Sendable {
    case plugins
    case apps
    case mcps
    case skills

    public var title: String {
        switch self {
        case .plugins: return "Plugins"
        case .apps: return "Apps"
        case .mcps: return "MCPs"
        case .skills: return "Skills"
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

public struct CodexPluginCategoryCard: Identifiable, Equatable, Sendable {
    public var title: String
    public var count: Int
    public var detail: String

    public var id: String { title }

    public init(title: String, count: Int, detail: String) {
        self.title = title
        self.count = count
        self.detail = detail
    }
}

public enum CodexPluginRouteAction: Equatable, Sendable {
    case installPlugin(CodexPluginActionTarget)
    case uninstallPlugin(CodexPluginActionTarget)
    case setPluginEnabled(CodexPluginActionTarget, enabled: Bool)
    case setSkillEnabled(CodexSkillActionTarget, enabled: Bool)
    case tryInChat(prompt: String)
}

public struct CodexPluginActionTarget: Equatable, Sendable {
    public var id: String
    public var name: String
    public var displayName: String
    public var marketplaceName: String
    public var marketplacePath: String?

    public init(plugin: CodexPluginSummary) {
        self.id = plugin.id
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

    public init(skill: CodexSkillSummary) {
        self.name = skill.name
        self.displayName = skill.displayName
        self.path = skill.path
    }
}

public struct CodexPluginActionOutcome: Equatable, Sendable {
    public var activity: CodexIntegrationCatalogActivity
    public var shouldRefresh: Bool
    public var draftPrompt: String?

    public init(activity: CodexIntegrationCatalogActivity, shouldRefresh: Bool = false, draftPrompt: String? = nil) {
        self.activity = activity
        self.shouldRefresh = shouldRefresh
        self.draftPrompt = draftPrompt
    }
}

public protocol CodexPluginCatalogActionProvider: Sendable {
    func installPlugin(_ target: CodexPluginActionTarget) async -> CodexPluginActionOutcome
    func uninstallPlugin(_ target: CodexPluginActionTarget) async -> CodexPluginActionOutcome
    func setPluginEnabled(_ target: CodexPluginActionTarget, enabled: Bool) async -> CodexPluginActionOutcome
    func setSkillEnabled(_ target: CodexSkillActionTarget, enabled: Bool) async -> CodexPluginActionOutcome
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
        case .tryInChat(let prompt):
            return CodexPluginActionOutcome(
                activity: CodexIntegrationCatalogActivity(title: "Prepared plugin prompt", detail: prompt),
                draftPrompt: prompt
            )
        }
    }
}

public struct CodexUnsupportedPluginCatalogActionProvider: CodexPluginCatalogActionProvider {
    public init() {}

    public func installPlugin(_ target: CodexPluginActionTarget) async -> CodexPluginActionOutcome {
        unavailable("\(target.displayName) install is not wired in this build")
    }

    public func uninstallPlugin(_ target: CodexPluginActionTarget) async -> CodexPluginActionOutcome {
        unavailable("\(target.displayName) uninstall is not wired in this build")
    }

    public func setPluginEnabled(_ target: CodexPluginActionTarget, enabled: Bool) async -> CodexPluginActionOutcome {
        unavailable("\(target.displayName) enable toggle is not wired in this build")
    }

    public func setSkillEnabled(_ target: CodexSkillActionTarget, enabled: Bool) async -> CodexPluginActionOutcome {
        unavailable("\(target.displayName) skill toggle is not wired in this build")
    }

    private func unavailable(_ detail: String) -> CodexPluginActionOutcome {
        CodexPluginActionOutcome(activity: CodexIntegrationCatalogActivity(title: "Plugin action unavailable", detail: detail))
    }
}

public struct CodexPluginRouteDetail: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case plugin(CodexPluginActionTarget)
        case skill(CodexSkillActionTarget)
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
        case .boundary:
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
        boundaryActionTitle: String? = nil
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
        self.canUninstall = false
        self.canToggleEnabled = true
        self.isEnabled = skill.enabled
        self.boundaryActionTitle = nil
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

public struct CodexPluginRouteState: Equatable, Sendable {
    public var plugins: [CodexPluginSummary]
    public var skills: [CodexSkillSummary]
    public var mcpServers: [CodexMCPServerStatus]
    public var primaryTab: CodexPluginRoutePrimaryTab
    public var manageTab: CodexPluginManageTab
    public var browseScope: CodexPluginBrowseScope
    public var searchQuery: String
    public var selectedPluginID: String?
    public var selectedSkillID: String?
    public var launcherTarget: CodexComposerPluginLauncher?

    public init(
        plugins: [CodexPluginSummary],
        skills: [CodexSkillSummary] = [],
        mcpServers: [CodexMCPServerStatus] = [],
        primaryTab: CodexPluginRoutePrimaryTab = .marketplace,
        manageTab: CodexPluginManageTab = .plugins,
        browseScope: CodexPluginBrowseScope = .openAI,
        searchQuery: String = "",
        selectedPluginID: String? = nil,
        selectedSkillID: String? = nil,
        launcherTarget: CodexComposerPluginLauncher? = nil
    ) {
        self.plugins = plugins
        self.skills = skills
        self.mcpServers = mcpServers
        self.primaryTab = primaryTab
        self.manageTab = manageTab
        self.browseScope = browseScope
        self.searchQuery = searchQuery
        self.selectedPluginID = selectedPluginID
        self.selectedSkillID = selectedSkillID
        self.launcherTarget = launcherTarget
    }

    public var manageCounts: [CodexPluginManageCount] {
        [
            CodexPluginManageCount(tab: .plugins, count: plugins.filter(\.installed).count),
            CodexPluginManageCount(tab: .apps, count: plugins.filter { $0.capabilityMatches("apps") || $0.capabilityMatches("app") }.count),
            CodexPluginManageCount(tab: .mcps, count: mcpServers.count + plugins.filter { $0.capabilityMatches("mcp") }.count),
            CodexPluginManageCount(tab: .skills, count: skills.count)
        ]
    }

    public var categoryCards: [CodexPluginCategoryCard] {
        let buckets = Dictionary(grouping: marketplacePlugins) { plugin in
            plugin.category?.nilIfBlank ?? plugin.sourceLabel
        }
        return buckets.map { title, plugins in
            CodexPluginCategoryCard(
                title: title,
                count: plugins.count,
                detail: plugins.map(\.displayName).prefix(3).joined(separator: ", ")
            )
        }
        .sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    public var marketplaceSections: [CodexPluginCatalogSection] {
        let scoped = filtered(marketplacePlugins.filter(matchesBrowseScope))
        let installed = scoped.filter(\.installed)
        let available = scoped.filter { !$0.installed }
        var sections: [CodexPluginCatalogSection] = []
        if !installed.isEmpty {
            sections.append(.init(title: "Installed", plugins: installed))
        }
        let buckets = Dictionary(grouping: available) { plugin in
            plugin.category?.nilIfBlank ?? (plugin.developerName == "OpenAI" ? "Featured" : plugin.sourceLabel)
        }
        sections += buckets.map { title, plugins in
            .init(
                title: title,
                plugins: plugins.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            )
        }
        .sorted { lhs, rhs in
            if lhs.title == "Featured" { return true }
            if rhs.title == "Featured" { return false }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        return sections
    }

    public var skillSections: [CodexSkillCatalogSection] {
        let groups = Dictionary(grouping: visibleSkills) { skill in
            skill.scope == "repo" ? "Workspace" : skill.scopeLabel
        }
        return groups.map { title, skills in
            CodexSkillCatalogSection(title: title, skills: skills)
        }
        .sorted { lhs, rhs in
            let order = ["Personal", "Workspace", "System"]
            let left = order.firstIndex(of: lhs.title) ?? order.count
            let right = order.firstIndex(of: rhs.title) ?? order.count
            if left != right { return left < right }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    public var visiblePlugins: [CodexPluginSummary] {
        filtered(pluginsForCurrentTab)
    }

    public var visibleSkills: [CodexSkillSummary] {
        let needle = normalizedSearch
        guard !needle.isEmpty else { return skills }
        return skills.filter { skill in
            [skill.name, skill.displayName, skill.detail, skill.description, skill.path, skill.scopeLabel]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    public var selectedDetail: CodexPluginRouteDetail? {
        if primaryTab == .skills {
            let skill = skills.first { $0.id == selectedSkillID } ?? visibleSkills.first ?? skills.first
            return skill.map(CodexPluginRouteDetail.init(skill:))
        }
        if let launcherTarget,
           let plugin = matchedPlugin(for: launcherTarget) {
            return CodexPluginRouteDetail(plugin: plugin)
        }
        let plugin = plugins.first { $0.id == selectedPluginID }
            ?? visiblePlugins.first
            ?? plugins.first { $0.displayName.localizedCaseInsensitiveContains("Browser") }
            ?? plugins.first
        return plugin.map(CodexPluginRouteDetail.init(plugin:)) ?? launcherTarget?.fallbackDetail
    }

    private var marketplacePlugins: [CodexPluginSummary] {
        plugins
    }

    private var pluginsForCurrentTab: [CodexPluginSummary] {
        switch primaryTab {
        case .marketplace:
            return marketplacePlugins
        case .skills:
            return []
        case .manage:
            switch manageTab {
            case .plugins:
                return plugins.filter(\.installed)
            case .apps:
                return plugins.filter { $0.capabilityMatches("apps") || $0.capabilityMatches("app") }
            case .mcps:
                return plugins.filter { $0.capabilityMatches("mcp") }
            case .skills:
                return []
            }
        }
    }

    private var normalizedSearch: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matchesBrowseScope(_ plugin: CodexPluginSummary) -> Bool {
        switch browseScope {
        case .openAI:
            return plugin.developerName?.localizedCaseInsensitiveCompare("OpenAI") == .orderedSame
                || plugin.sourceType == "remote"
                || (plugin.developerName == nil && plugin.sourceType == nil)
        case .workspace:
            return plugin.sourceType == "git"
                || plugin.marketplaceName.localizedCaseInsensitiveContains("workspace")
        case .personal:
            return plugin.sourceType == "local"
                || plugin.marketplaceName.localizedCaseInsensitiveContains("personal")
        }
    }

    private func filtered(_ plugins: [CodexPluginSummary]) -> [CodexPluginSummary] {
        let needle = normalizedSearch
        guard !needle.isEmpty else { return plugins }
        return plugins.filter { plugin in
            [
                plugin.name,
                plugin.displayName,
                plugin.detail,
                plugin.marketplaceDisplayName,
                plugin.category ?? "",
                plugin.developerName ?? "",
                plugin.capabilities.joined(separator: " "),
                plugin.keywords.joined(separator: " ")
            ].contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private func matchedPlugin(for target: CodexComposerPluginLauncher) -> CodexPluginSummary? {
        let preferred = target.preferredPluginNames.map { $0.lowercased() }
        return plugins.first { plugin in
            let candidates = [
                plugin.name.lowercased(),
                plugin.displayName.lowercased(),
                plugin.id.lowercased()
            ]
            return preferred.contains { preferredName in
                candidates.contains { candidate in
                    candidate == preferredName || candidate.contains(preferredName)
                }
            }
        }
    }
}

private extension CodexPluginSummary {
    func capabilityMatches(_ needle: String) -> Bool {
        capabilities.contains { capability in
            capability.localizedCaseInsensitiveContains(needle)
        }
    }
}
