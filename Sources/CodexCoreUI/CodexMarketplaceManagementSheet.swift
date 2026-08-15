import CodexCore

public struct CodexMarketplaceSummary: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var displayName: String
    public var path: String?
    public var localVersion: String?
    public var availableVersion: String?
    public var pluginCount: Int

    public init(
        name: String,
        displayName: String? = nil,
        path: String? = nil,
        localVersion: String? = nil,
        availableVersion: String? = nil,
        pluginCount: Int = 0
    ) {
        self.name = name
        self.displayName = displayName?.nilIfBlank ?? name
        self.path = path
        self.localVersion = localVersion
        self.availableVersion = availableVersion
        self.pluginCount = pluginCount
    }

    public var hasKnownUpdate: Bool {
        guard let localVersion, let availableVersion else { return false }
        return localVersion.compare(availableVersion, options: .numeric) == .orderedAscending
    }

    public static func summaries(from plugins: [CodexPluginSummary]) -> [CodexMarketplaceSummary] {
        Dictionary(grouping: plugins, by: \.marketplaceName).compactMap { name, plugins in
            guard let first = plugins.first else { return nil }
            let local = plugins.compactMap(\.localVersion).max { $0.compare($1, options: .numeric) == .orderedAscending }
            let available = plugins.compactMap(\.availableVersion).max { $0.compare($1, options: .numeric) == .orderedAscending }
            return .init(
                name: name,
                displayName: first.marketplaceDisplayName,
                path: first.marketplacePath,
                localVersion: local,
                availableVersion: available,
                pluginCount: plugins.count
            )
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public static func summaries(from response: CodexJSONValue) -> [CodexMarketplaceSummary] {
        guard case .dictionary(let object) = response,
              case .array(let values)? = object["marketplaces"] else { return [] }
        return values.compactMap { value in
            guard case .dictionary(let marketplace) = value,
                  let name = CodexJSONCoercion.flatString(from: marketplace["name"])?.nilIfBlank else {
                return nil
            }
            let interface: [String: CodexJSONValue]
            if case .dictionary(let value)? = marketplace["interface"] { interface = value }
            else { interface = [:] }
            guard case .array(let plugins)? = marketplace["plugins"] else { return nil }
            return CodexMarketplaceSummary(
                name: name,
                displayName: CodexJSONCoercion.flatString(from: interface["displayName"])?.nilIfBlank ?? name,
                path: CodexJSONCoercion.flatString(from: marketplace["path"])?.nilIfBlank,
                localVersion: CodexJSONCoercion.flatString(from: marketplace["localVersion"])?.nilIfBlank,
                availableVersion: CodexJSONCoercion.flatString(from: marketplace["availableVersion"])?.nilIfBlank,
                pluginCount: plugins.count
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public static func marketplaces(from response: CodexJSONValue) -> [CodexMarketplaceSummary] {
        summaries(from: response)
    }
}
