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
    /// Configuration enablement, when explicitly reported. Runtime status alone does not imply it.
    public var enabled: Bool?
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
        enabled: Bool? = nil,
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
        self.enabled = enabled
        self.startupStatus = startupStatus
        self.error = error
        self.tools = tools
        self.resources = resources
        self.resourceTemplates = resourceTemplates
    }

    public init?(raw value: CodexJSONValue) {
        guard case .dictionary(let object) = value,
              let name = Self.string(in: object, keys: ["name"])?.nilIfBlank,
              let authStatus = Self.string(in: object, keys: ["authStatus"])?.nilIfBlank,
              case .dictionary(let tools)? = object["tools"],
              case .array(let resources)? = object["resources"],
              case .array(let resourceTemplates)? = object["resourceTemplates"] else {
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
            authStatus: authStatus,
            enabled: Self.bool(in: object, keys: ["enabled", "isEnabled"]),
            startupStatus: Self.string(in: object, keys: ["status", "startupStatus", "state"]),
            error: Self.string(in: object, keys: ["error"]),
            tools: Self.entries(from: .dictionary(tools)),
            resources: Self.entries(from: .array(resources)),
            resourceTemplates: Self.entries(from: .array(resourceTemplates))
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

    private static func bool(in object: [String: CodexJSONValue], keys: [String]) -> Bool? {
        for key in keys {
            switch object[key] {
            case .bool(let value): return value
            case .string(let value): if let parsed = Bool(value) { return parsed }
            case .int(let value): return value != 0
            case .double(let value): return value != 0
            default: continue
            }
        }
        return nil
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
    public var runtimeName: String?
    public var runtimeEnabled: Bool?
    public var runtimeCallable: Bool?

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

    public static func join(
        catalog: [CodexSchemaAppInfo],
        installed: [CodexSchemaInstalledApp]
    ) -> [CodexAppSummary] {
        let installedByID = Dictionary(installed.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let catalogIDs = Set(catalog.map(\.id))
        let catalogRecords = catalog.map { CodexAppSummary(catalog: $0, installed: installedByID[$0.id]) }
        let installedOnlyRecords = installed
            .filter { !catalogIDs.contains($0.id) }
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
        return catalogRecords + installedOnlyRecords
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

public struct CodexMarketplaceSummary: Identifiable, Equatable, Sendable {
    public var name: String
    public var displayName: String
    public var path: String?
    public var pluginCount: Int

    public var id: String { name }

    public init(name: String, displayName: String? = nil, path: String? = nil, pluginCount: Int) {
        self.name = name
        self.displayName = displayName?.nilIfBlank ?? name
        self.path = path?.nilIfBlank
        self.pluginCount = pluginCount
    }

    /// Returns only marketplaces explicitly reported by `plugin/list`. Missing or
    /// malformed entries stay unknown; filesystem and cache paths are never inferred.
    public static func marketplaces(from response: CodexJSONValue) -> [CodexMarketplaceSummary] {
        guard case .dictionary(let object) = response,
              case .array(let values)? = object["marketplaces"] else { return [] }
        return values.compactMap { value in
            guard case .dictionary(let marketplace) = value,
                  let name = CodexJSONCoercion.flatString(from: marketplace["name"])?.nilIfBlank,
                  case .array(let plugins)? = marketplace["plugins"] else { return nil }
            let interface: [String: CodexJSONValue]
            if case .dictionary(let fields)? = marketplace["interface"] { interface = fields } else { interface = [:] }
            let displayName = CodexJSONCoercion.flatString(from: interface["displayName"])?.nilIfBlank
            let path = CodexJSONCoercion.flatString(from: marketplace["path"])?.nilIfBlank
            return CodexMarketplaceSummary(name: name, displayName: displayName, path: path, pluginCount: plugins.count)
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
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
    public var installPolicySource: String?
    public var availability: String?
    public var disabledReason: String?
    public var authPolicy: String
    public var sourceType: String?
    public var sourceDetail: String?
    public var localVersion: String?
    public var version: String?
    public var remotePluginID: String?
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
        installPolicySource: String? = nil,
        availability: String? = nil,
        disabledReason: String? = nil,
        authPolicy: String = "ON_USE",
        sourceType: String? = nil,
        sourceDetail: String? = nil,
        localVersion: String? = nil,
        version: String? = nil,
        remotePluginID: String? = nil,
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
        self.installPolicySource = installPolicySource
        self.availability = availability
        self.disabledReason = disabledReason
        self.authPolicy = authPolicy
        self.sourceType = sourceType
        self.sourceDetail = sourceDetail
        self.localVersion = localVersion
        self.version = version
        self.remotePluginID = remotePluginID
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
              let pluginID = Self.string(in: object, keys: ["id"])?.nilIfBlank,
              let installed = Self.bool(from: object["installed"]),
              let enabled = Self.bool(from: object["enabled"]),
              let installPolicy = Self.string(in: object, keys: ["installPolicy"])?.nilIfBlank,
              let authPolicy = Self.string(in: object, keys: ["authPolicy"])?.nilIfBlank,
              let rawSource = object["source"], rawSource != .null else {
            return nil
        }

        let interface = Self.dictionary(from: object["interface"])
        let source = Self.dictionary(from: rawSource)
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
            installPolicySource: Self.string(in: object, keys: ["installPolicySource"]),
            availability: Self.string(in: object, keys: ["availability"]),
            disabledReason: Self.string(in: object, keys: ["disabledReason"]),
            authPolicy: authPolicy,
            sourceType: Self.string(in: source, keys: ["type"]),
            sourceDetail: Self.sourceDetail(from: source),
            localVersion: Self.string(in: object, keys: ["localVersion"]),
            version: Self.string(in: object, keys: ["version"]),
            remotePluginID: Self.string(in: object, keys: ["remotePluginId"]),
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
        return marketplaces(from: response)
            .flatMap { marketplace in
                marketplace.plugins.compactMap { CodexPluginSummary(raw: $0, marketplace: marketplace.context) }
            }
            .map { plugin in
                var plugin = plugin
                plugin.isFeatured = featuredIDs.contains(plugin.protocolID)
                    || featuredIDs.contains(plugin.id)
                    || featuredIDs.contains(plugin.name)
                return plugin
            }
            .sorted { lhs, rhs in
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
        availability == "DISABLED_BY_ADMIN"
    }

    public var isInstalledByAdmin: Bool {
        sourceType?.lowercased() == "remote"
            && installed
            && installPolicy == "INSTALLED_BY_DEFAULT"
    }

    public var canInstall: Bool {
        !installed && installPolicy == "AVAILABLE" && !isAdminDisabled
    }

    public var canUninstall: Bool {
        installed && !isInstalledByAdmin && !isAdminDisabled
    }

    public var statusLabel: String {
        if isAdminDisabled { return "Disabled by admin" }
        if installed, enabled { return "Enabled" }
        if installed { return "Disabled" }
        if installPolicy == "AVAILABLE" { return "Available" }
        if installPolicy == "INSTALLED_BY_DEFAULT" { return "Installed by admin" }
        return "Unavailable"
    }

    public var stateLabels: [String] {
        var labels: [String] = []
        if installed { labels.append("Installed") }
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

    /// The official client only exposes an enabled switch for locally managed
    /// plugins. Account-backed remote plugins are installed/removed as a unit
    /// and appear with a status checkmark in Manage.
    public var supportsEnabledToggle: Bool {
        guard installed, !isAdminDisabled else { return false }
        return sourceType?.lowercased() != "remote"
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
    public var iconSmall: String?
    public var iconLarge: String?
    public var brandColor: String?
    public var dependencies: [String]

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
        iconSmall: String? = nil,
        iconLarge: String? = nil,
        brandColor: String? = nil,
        dependencies: [String] = []
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
        self.iconSmall = iconSmall
        self.iconLarge = iconLarge
        self.brandColor = brandColor
        self.dependencies = dependencies
    }

    public init?(raw value: CodexJSONValue, cwd: String? = nil) {
        guard case .dictionary(let object) = value,
              let name = Self.string(in: object, keys: ["name"])?.nilIfBlank,
              let path = Self.string(in: object, keys: ["path"])?.nilIfBlank,
              let enabled = CodexJSONCoercion.bool(in: object, key: "enabled") else {
            return nil
        }
        let interface = Self.dictionary(in: object, key: "interface")
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
            iconSmall: interface.flatMap { Self.string(in: $0, keys: ["iconSmall"]) },
            iconLarge: interface.flatMap { Self.string(in: $0, keys: ["iconLarge"]) },
            brandColor: interface.flatMap { Self.string(in: $0, keys: ["brandColor"]) },
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
        return entries.flatMap { entry -> [String] in
            guard case .dictionary(let fields) = entry,
                  case .array(let errors)? = fields["errors"] else { return [] }
            let cwd = string(in: fields, keys: ["cwd"])
            return errors.compactMap { error in
                guard case .dictionary(let details) = error,
                      let message = string(in: details, keys: ["message"])?.nilIfBlank else { return nil }
                let path = string(in: details, keys: ["path"])?.nilIfBlank ?? cwd?.nilIfBlank
                return path.map { "\($0): \(message)" } ?? message
            }
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
        guard case .dictionary(let object)? = value,
              case .array(let tools)? = object["tools"] else { return [] }
        return tools.compactMap { tool in
            guard case .dictionary(let fields) = tool else { return nil }
            let type = string(in: fields, keys: ["type"])
            let value = string(in: fields, keys: ["value", "command", "url"])
            switch (type, value) {
            case let (.some(type), .some(value)): return "\(type): \(value)"
            case let (.some(type), nil): return type
            case let (nil, .some(value)): return value
            case (nil, nil): return nil
            }
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
    case uninstallSkill(CodexSkillActionTarget)
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
        self.name = app.name
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
    func uninstallSkill(_ target: CodexSkillActionTarget) async -> CodexPluginActionOutcome
    func setAppEnabled(_ target: CodexAppActionTarget, enabled: Bool) async -> CodexPluginActionOutcome
    func addMarketplace(source: String) async -> CodexPluginActionOutcome
    func upgradeMarketplace(_ target: CodexMarketplaceActionTarget) async -> CodexPluginActionOutcome
    func removeMarketplace(_ target: CodexMarketplaceActionTarget) async -> CodexPluginActionOutcome
}

public extension CodexPluginCatalogActionProvider {
    func setAppEnabled(_ target: CodexAppActionTarget, enabled: Bool) async -> CodexPluginActionOutcome {
        CodexPluginActionOutcome(
            activity: .init(title: "App action unsupported", detail: "This provider does not implement local app execution settings."),
            didSucceed: false
        )
    }

    func addMarketplace(source: String) async -> CodexPluginActionOutcome { unsupportedMarketplaceMutation() }
    func upgradeMarketplace(_ target: CodexMarketplaceActionTarget) async -> CodexPluginActionOutcome { unsupportedMarketplaceMutation() }
    func removeMarketplace(_ target: CodexMarketplaceActionTarget) async -> CodexPluginActionOutcome { unsupportedMarketplaceMutation() }

    private func unsupportedMarketplaceMutation() -> CodexPluginActionOutcome {
        CodexPluginActionOutcome(
            activity: .init(title: "Marketplace action unsupported", detail: "This provider does not implement marketplace management."),
            didSucceed: false
        )
    }
}

/// Pure request construction keeps the plugin control plane inspectable and
/// testable without coupling UI state to generated protocol representations.
public enum CodexPluginProtocolMutation {
    public static func readParams(for plugin: CodexPluginSummary) -> CodexSchemaPluginReadParams {
        CodexSchemaPluginReadParams(
            marketplacePath: plugin.marketplacePath.map { CodexAppServerSchemaValue(.string($0)) },
            pluginName: plugin.name,
            remoteMarketplaceName: plugin.marketplacePath == nil ? plugin.marketplaceName : nil
        )
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
        enabled: Bool
    ) -> CodexSchemaConfigBatchWriteParams {
        CodexSchemaConfigBatchWriteParams(
            edits: [
                CodexSchemaConfigEdit(
                    keyPath: "plugins.\(target.id).enabled",
                    mergeStrategy: .upsert,
                    value: .bool(enabled)
                )
            ],
            reloadUserConfig: true
        )
    }

    public static func appEnabledParams(for target: CodexAppActionTarget, enabled: Bool) -> CodexSchemaConfigBatchWriteParams {
        CodexSchemaConfigBatchWriteParams(
            edits: [
                CodexSchemaConfigEdit(
                    keyPath: "apps.\(target.id).enabled",
                    mergeStrategy: .upsert,
                    value: .bool(enabled)
                )
            ],
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

    public static func marketplaceAddParams(source: String) -> CodexSchemaMarketplaceAddParams {
        CodexSchemaMarketplaceAddParams(source: source)
    }

    public static func marketplaceUpgradeParams(for target: CodexMarketplaceActionTarget) -> CodexSchemaMarketplaceUpgradeParams {
        CodexSchemaMarketplaceUpgradeParams(marketplaceName: target.name)
    }

    public static func marketplaceRemoveParams(for target: CodexMarketplaceActionTarget) -> CodexSchemaMarketplaceRemoveParams {
        CodexSchemaMarketplaceRemoveParams(marketplaceName: target.name)
    }

    @available(*, deprecated, message: "Codex does not expose a skill-uninstall operation; do not substitute filesystem deletion.")
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
        case .uninstallSkill(let target):
            return await provider.uninstallSkill(target)
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
            _ = try await codex.configBatchWrite(
                CodexPluginProtocolMutation.pluginEnabledParams(for: target, enabled: enabled)
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
            _ = try await codex.configBatchWrite(CodexPluginProtocolMutation.appEnabledParams(for: target, enabled: enabled))
            return CodexPluginActionOutcome(
                activity: .init(title: "Updated \(target.name)", detail: enabled ? "Enabled local execution" : "Disabled local execution"),
                didSucceed: true,
                shouldRefresh: true
            )
        } catch {
            return failure("Couldn’t update \(target.name)", error: error)
        }
    }

    public func uninstallSkill(_ target: CodexSkillActionTarget) async -> CodexPluginActionOutcome {
        CodexPluginActionOutcome(
            activity: .init(
                title: "Skill removal unavailable",
                detail: "Codex does not expose a generated skill-uninstall operation. Remove \(target.displayName) with its owning package or filesystem workflow."
            ),
            didSucceed: false
        )
    }

    public func addMarketplace(source: String) async -> CodexPluginActionOutcome {
        do {
            let response = try await codex.marketplaceAdd(CodexPluginProtocolMutation.marketplaceAddParams(source: source))
            return success(response.alreadyAdded ? "Marketplace already registered" : "Added marketplace", detail: response.marketplaceName)
        } catch {
            return failure("Couldn’t add marketplace", error: error)
        }
    }

    public func upgradeMarketplace(_ target: CodexMarketplaceActionTarget) async -> CodexPluginActionOutcome {
        do {
            let response = try await codex.marketplaceUpgrade(CodexPluginProtocolMutation.marketplaceUpgradeParams(for: target))
            if let error = response.errors.first(where: { $0.marketplaceName == target.name }) {
                return CodexPluginActionOutcome(activity: .init(title: "Couldn’t upgrade \(target.displayName)", detail: error.message), didSucceed: false)
            }
            guard response.selectedMarketplaces.contains(target.name) else {
                return CodexPluginActionOutcome(
                    activity: .init(
                        title: "Upgrade status unknown for \(target.displayName)",
                        detail: "Codex did not confirm that this marketplace was selected."
                    ),
                    didSucceed: false
                )
            }
            return success("Upgraded \(target.displayName)", detail: target.name)
        } catch {
            return failure("Couldn’t upgrade \(target.displayName)", error: error)
        }
    }

    public func removeMarketplace(_ target: CodexMarketplaceActionTarget) async -> CodexPluginActionOutcome {
        do {
            _ = try await codex.marketplaceRemove(CodexPluginProtocolMutation.marketplaceRemoveParams(for: target))
            return success("Removed \(target.displayName)", detail: target.name)
        } catch {
            return failure("Couldn’t remove \(target.displayName)", error: error)
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
            (plugin.version ?? plugin.localVersion).map { "Version: \($0)" },
            "Marketplace: \(plugin.marketplaceDisplayName)"
        ].compactMap { $0 }
        self.legalLinks = [
            plugin.websiteURL.map { "Website: \($0)" },
            plugin.privacyPolicyURL.map { "Privacy: \($0)" },
            plugin.termsOfServiceURL.map { "Terms: \($0)" }
        ].compactMap { $0 }
        self.canInstall = plugin.canInstall
        self.canUninstall = plugin.canUninstall
        self.canToggleEnabled = plugin.supportsEnabledToggle
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
        self.canUninstall = false
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

public struct CodexPluginRouteState: Equatable, Sendable {
    public var plugins: [CodexPluginSummary]
    public var marketplaces: [CodexMarketplaceSummary]
    public var apps: [CodexAppSummary]
    public var skills: [CodexSkillSummary]
    public var mcpServers: [CodexMCPServerStatus]
    public var primaryTab: CodexPluginRoutePrimaryTab
    public var manageTab: CodexPluginManageTab
    public var searchQuery: String
    public var filter: CodexPluginCatalogFilter
    public var selectedPluginID: String?
    public var selectedSkillID: String?
    public var launcherTarget: CodexComposerPluginLauncher?

    public init(
        plugins: [CodexPluginSummary],
        marketplaces: [CodexMarketplaceSummary] = [],
        apps: [CodexAppSummary] = [],
        skills: [CodexSkillSummary] = [],
        mcpServers: [CodexMCPServerStatus] = [],
        primaryTab: CodexPluginRoutePrimaryTab = .marketplace,
        manageTab: CodexPluginManageTab = .plugins,
        searchQuery: String = "",
        filter: CodexPluginCatalogFilter = .all,
        selectedPluginID: String? = nil,
        selectedSkillID: String? = nil,
        launcherTarget: CodexComposerPluginLauncher? = nil
    ) {
        self.plugins = plugins
        self.marketplaces = marketplaces
        self.apps = apps
        self.skills = skills
        self.mcpServers = mcpServers
        self.primaryTab = primaryTab
        self.manageTab = manageTab
        self.searchQuery = searchQuery
        self.filter = filter
        self.selectedPluginID = selectedPluginID
        self.selectedSkillID = selectedSkillID
        self.launcherTarget = launcherTarget
    }

    public var manageCounts: [CodexPluginManageCount] {
        [
            CodexPluginManageCount(tab: .plugins, count: plugins.filter(\.installed).count),
            CodexPluginManageCount(tab: .apps, count: managedApps.count),
            CodexPluginManageCount(tab: .mcps, count: mcpServers.count),
            CodexPluginManageCount(tab: .skills, count: skills.count),
            CodexPluginManageCount(tab: .marketplace, count: marketplaces.count)
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

    public var featuredPlugins: [CodexPluginSummary] {
        let featured = marketplacePlugins.filter(\.isFeatured)
        return filtered(featured.isEmpty ? Array(marketplacePlugins.prefix(2)) : featured)
    }

    public var visiblePlugins: [CodexPluginSummary] {
        filtered(pluginsForCurrentTab)
    }

    public var visibleApps: [CodexAppSummary] {
        let needle = normalizedSearch
        guard !needle.isEmpty else { return managedApps }
        return managedApps.filter { app in
            [
                app.name,
                app.description ?? "",
                app.runtimeName ?? "",
                app.distributionChannel ?? "",
                app.pluginDisplayNames?.joined(separator: " ") ?? ""
            ].contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    public var visibleSkills: [CodexSkillSummary] {
        let needle = normalizedSearch
        guard !needle.isEmpty else { return skills }
        return skills.filter { skill in
            [skill.name, skill.displayName, skill.detail, skill.description, skill.path, skill.scopeLabel]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    public var visibleMCPServers: [CodexMCPServerStatus] {
        let needle = normalizedSearch
        guard !needle.isEmpty else { return mcpServers }
        return mcpServers.filter { server in
            [server.name, server.displayName, server.detail ?? "", server.inventorySummary]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    public var visibleMarketplaces: [CodexMarketplaceSummary] {
        let needle = normalizedSearch
        guard !needle.isEmpty else { return marketplaces }
        return marketplaces.filter { marketplace in
            [marketplace.name, marketplace.displayName, marketplace.path ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    public var selectedDetail: CodexPluginRouteDetail? {
        if primaryTab == .skills {
            let skill = skills.first { $0.id == selectedSkillID } ?? visibleSkills.first ?? skills.first
            return skill.map(CodexPluginRouteDetail.init(skill:))
        }
        if primaryTab == .manage, manageTab == .mcps {
            return visibleMCPServers.first.map(CodexPluginRouteDetail.init(mcpServer:))
        }
        if let selectedPluginID,
           let plugin = plugins.first(where: { $0.id == selectedPluginID }) {
            return CodexPluginRouteDetail(plugin: plugin)
        }
        if let launcherTarget,
           let plugin = matchedPlugin(for: launcherTarget) {
            return CodexPluginRouteDetail(plugin: plugin)
        }
        let plugin = visiblePlugins.first
            ?? plugins.first { $0.displayName.localizedCaseInsensitiveContains("Browser") }
            ?? plugins.first
        return plugin.map(CodexPluginRouteDetail.init(plugin:)) ?? launcherTarget?.fallbackDetail
    }

    private var managedApps: [CodexAppSummary] {
        apps.filter { $0.isAccessible == true || $0.isInstalled }
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
                return []
            case .mcps:
                return []
            case .skills, .marketplace:
                return []
            }
        }
    }

    private var normalizedSearch: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func filtered(_ plugins: [CodexPluginSummary]) -> [CodexPluginSummary] {
        // Marketplace source filters do not apply to the installed inventory.
        // Leaking "By OpenAI" into Manage produced non-zero tab counts with an
        // empty list for local and workspace plugins.
        let plugins = primaryTab == .marketplace ? plugins.filter(matchesFilter) : plugins
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

    private func matchesFilter(_ plugin: CodexPluginSummary) -> Bool {
        switch filter {
        case .all:
            return true
        case .openAI:
            return plugin.developerName?.localizedCaseInsensitiveContains("OpenAI") == true
                || plugin.marketplaceName.localizedCaseInsensitiveContains("openai")
        case .workspace:
            return plugin.sourceType == "local" && plugin.sourceDetail?.contains("/.codex/") != true
        case .personal:
            return plugin.sourceType == "local" || plugin.marketplaceName.localizedCaseInsensitiveContains("personal")
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
