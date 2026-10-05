import Foundation
import CodexCore

/// Catalog discovery for older history that predates persisted MCP app descriptors.
public struct CodexMCPAppCatalogResource: Sendable, Equatable {
    public let server: String
    public let tool: String
    public let resourceURI: String
    public let displayMode: CodexMCPAppDescriptor.DisplayMode

    public init(server: String, tool: String, resourceURI: String, displayMode: CodexMCPAppDescriptor.DisplayMode = .inline) {
        self.server = server; self.tool = tool; self.resourceURI = resourceURI; self.displayMode = displayMode
    }

    public static func catalog(from servers: [CodexMCPServerStatus]) -> [Self] {
        servers.flatMap { server in
            server.tools.compactMap { tool in
                tool.mcpAppResourceURI.map { .init(server: server.name, tool: tool.name, resourceURI: $0,
                                                 displayMode: tool.mcpAppDisplayMode ?? .inline) }
            }
        }
    }
}

/// The persisted MCP app descriptor and the tool-call scope that owns it.
/// Resource reads use the original call so app-server can select the original account.
public struct CodexMCPAppDescriptor: Identifiable, Equatable, Sendable {
    public enum DisplayMode: String, Sendable, Equatable { case inline, fullscreen }
    public var id: String { "\(threadID):\(originCallID):\(resourceURI)" }
    public let threadID: String
    public let originCallID: String
    public let server: String
    public let tool: String
    public let appName: String
    public let resourceURI: String
    public let preferredDisplayMode: DisplayMode
    public let connectorID: String?
    public let linkID: String?
    public let hasExplicitAccountScope: Bool
    public let arguments: CodexJSONValue?
    public let result: CodexJSONValue?
    public let revision: UInt64

    public init(threadID: String, originCallID: String, server: String, tool: String, appName: String,
                resourceURI: String, preferredDisplayMode: DisplayMode = .inline,
                connectorID: String? = nil, linkID: String? = nil,
                hasExplicitAccountScope: Bool? = nil, arguments: CodexJSONValue? = nil,
                result: CodexJSONValue? = nil, revision: UInt64 = 0) {
        self.threadID = threadID; self.originCallID = originCallID; self.server = server
        self.tool = tool; self.appName = appName; self.resourceURI = resourceURI
        self.preferredDisplayMode = preferredDisplayMode
        self.connectorID = connectorID; self.linkID = linkID
        self.hasExplicitAccountScope = hasExplicitAccountScope ?? (linkID != nil)
        self.arguments = arguments; self.result = result
        self.revision = revision
    }

    static func project(item: CanonicalItem, appName: String) -> Self? {
        let ui = item.payload["mcpAppUi"]?.objectValue
        let context = item.payload["appContext"]?.objectValue
        let resultMetadata = item.payload["result"]?.objectValue?["_meta"]?.objectValue
        let uri = ui?["resourceUri"]?.stringValue
            ?? item.payload["mcpAppResourceUri"]?.stringValue
            ?? context?["resourceUri"]?.stringValue
            ?? resultMetadata?["ui"]?.objectValue?["resourceUri"]?.stringValue
            ?? resultMetadata?["ui/resourceUri"]?.stringValue
        guard let uri, !uri.isEmpty, let server = item.payload["server"]?.stringValue else { return nil }
        return .init(threadID: item.key.threadID.rawValue, originCallID: item.key.itemID.rawValue,
                     server: server, tool: item.payload["tool"]?.stringValue ?? "Tool", appName: appName,
                     resourceURI: uri,
                     preferredDisplayMode: DisplayMode(rawValue: ui?["preferredModelDisplayMode"]?.stringValue ?? "") ?? .inline,
                     connectorID: context?["connectorId"]?.stringValue, linkID: context?["linkId"]?.stringValue,
                     hasExplicitAccountScope: context?["linkId"] == .null || context?["linkId"]?.stringValue != nil,
                     arguments: item.payload["arguments"], result: item.payload["result"], revision: item.lastChangedRevision.rawValue)
    }

    func resourceRequest(uri: String? = nil) -> CodexIntegrationControlPlaneRequest {
        .mcpResourceRead(.init(connectorID: hasExplicitAccountScope ? nil : connectorID, originCallID: originCallID, server: server,
                              target: hasExplicitAccountScope ? connectorID.map { .init(connectorID: $0, linkID: linkID) } : nil,
                              threadID: threadID, uri: uri ?? resourceURI))
    }

    static func discover(row: CodexMCPToolCallRowV2, threadID: String, catalog: [CodexMCPAppCatalogResource]) -> Self? {
        guard let resource = catalog.first(where: { $0.server == row.server && $0.tool == row.tool }) else { return nil }
        let context = row.appContext?.objectValue
        return .init(threadID: threadID, originCallID: row.id, server: row.server, tool: row.tool, appName: row.appName,
                     resourceURI: resource.resourceURI, preferredDisplayMode: resource.displayMode,
                     connectorID: context?["connectorId"]?.stringValue, linkID: context?["linkId"]?.stringValue,
                     hasExplicitAccountScope: context?["linkId"] == .null || context?["linkId"]?.stringValue != nil,
                     arguments: row.arguments, result: row.result)
    }
}

extension CodexJSONValue {
    fileprivate var stringValue: String? { if case .string(let value) = self { value } else { nil } }
}
