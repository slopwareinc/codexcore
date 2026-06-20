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
}
