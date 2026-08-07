import Foundation

/// A request that the app can fulfill after its model has finished connecting.
///
/// The request deliberately contains values rather than app or model references.
/// This keeps launch parsing deterministic and safe to retain before the main
/// window and app-server are ready.
public enum CodexPendingOpenRequest: Equatable, Sendable {
    case launch
    case newChat(path: String?, prompt: String?)
    case thread(id: String)
    case project(path: String)
    case file(path: String)
    case folder(path: String)
    case skill(path: String)

    public var threadID: String? {
        guard case .thread(let id) = self else { return nil }
        return id
    }

    public var projectPath: String? {
        switch self {
        case .project(let path), .folder(let path): return path
        default: return nil
        }
    }

    public var filePath: String? {
        switch self {
        case .file(let path), .skill(let path): return path
        default: return nil
        }
    }
}

/// A small FIFO used by the app delegate/model boundary. Unsupported input is
/// rejected before it enters this queue.
public struct CodexPendingOpenRequestQueue: Equatable, Sendable {
    private var values: [CodexPendingOpenRequest] = []

    public init() {}

    public var count: Int { values.count }
    public var isEmpty: Bool { values.isEmpty }

    public mutating func append(_ request: CodexPendingOpenRequest) {
        values.append(request)
    }

    public mutating func drain() -> [CodexPendingOpenRequest] {
        defer { values.removeAll(keepingCapacity: true) }
        return values
    }
}

/// Parses the app's public `codex://` links without touching application state.
///
/// Supported routes intentionally stay small: launch/new-chat, existing thread,
/// and project selection. Query items, fragments, credentials, ports, and extra
/// path components are rejected rather than silently ignored.
public struct CodexDeepLinkRouter: Equatable, Sendable {
    public static let defaultScheme = "codex"

    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case unsupportedScheme(String?)
        case unsupportedRoute(String)
        case missingIdentifier(String)
        case malformedURL

        public var description: String {
            switch self {
            case .unsupportedScheme(let scheme):
                return "Unsupported deep-link scheme: \(scheme ?? "(missing)")"
            case .unsupportedRoute(let route):
                return "Unsupported Codex deep-link route: \(route)"
            case .missingIdentifier(let route):
                return "Missing identifier for Codex deep-link route: \(route)"
            case .malformedURL:
                return "Malformed Codex deep link"
            }
        }
    }

    public let scheme: String

    public init(scheme: String = Self.defaultScheme) {
        self.scheme = scheme.lowercased()
    }

    /// Returns a validated request represented by a `codex://` URL.
    public func request(for url: URL) throws -> CodexPendingOpenRequest {
        guard !url.isFileURL, url.scheme?.lowercased() == scheme else {
            throw Error.unsupportedScheme(url.scheme)
        }
        guard url.user == nil, url.password == nil, url.port == nil, url.fragment == nil else {
            throw Error.unsupportedRoute(url.absoluteString)
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            throw Error.unsupportedRoute(url.absoluteString)
        }

        let path = url.path
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let queryKeys = Set(queryItems.map(\.name))
        let query: [String: String] = Dictionary(
            queryItems.compactMap { item in
                guard let value = item.value, !value.isEmpty else { return nil }
                return (item.name, value)
            },
            uniquingKeysWith: { first, _ in first }
        )

        switch host {
        case "launch":
            guard path.isEmpty || path == "/", queryItems.isEmpty else {
                throw Error.unsupportedRoute(url.absoluteString)
            }
            return .launch
        case "new":
            guard path.isEmpty || path == "/",
                  queryKeys.isSubset(of: ["path", "prompt"]) else {
                throw Error.unsupportedRoute(url.absoluteString)
            }
            return .newChat(path: query["path"], prompt: query["prompt"])
        case "thread", "threads":
            guard queryItems.isEmpty else {
                throw Error.unsupportedRoute(url.absoluteString)
            }
            let identifier = try identifier(from: path, route: host, url: url)
            guard host != "threads" || identifier != "new" else {
                return .newChat(path: nil, prompt: nil)
            }
            return .thread(id: identifier)
        case "project":
            guard queryItems.isEmpty else {
                throw Error.unsupportedRoute(url.absoluteString)
            }
            let encodedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
            guard !encodedPath.isEmpty else {
                throw Error.missingIdentifier(host)
            }
            guard let projectPath = encodedPath.removingPercentEncoding,
                  !projectPath.isEmpty,
                  !projectPath.contains("\0"),
                  !projectPath.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
                throw Error.malformedURL
            }
            return .project(path: projectPath)
        default:
            throw Error.unsupportedRoute(host)
        }
    }

    /// Converts a Finder-opened file/folder into a validated request. Missing,
    /// non-regular, and non-directory URLs return `nil` and are ignored.
    public func request(forFileURL url: URL) -> CodexPendingOpenRequest? {
        guard url.isFileURL else { return nil }
        let normalized = url.standardizedFileURL
        guard !normalized.path.contains("\n"), !normalized.path.contains("\r") else { return nil }
        guard let values = try? normalized.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else {
            return nil
        }
        if values.isDirectory == true { return .folder(path: normalized.path) }
        guard values.isRegularFile == true else { return nil }
        if normalized.pathExtension.caseInsensitiveCompare("skill") == .orderedSame {
            return .skill(path: normalized.path)
        }
        return .file(path: normalized.path)
    }

    /// Parses mixed open-url/open-file input and drops unsupported values.
    public func requests(for urls: [URL]) -> [CodexPendingOpenRequest] {
        urls.compactMap { url in
            if url.isFileURL { return request(forFileURL: url) }
            return try? request(for: url)
        }
    }

    private func identifier(from path: String, route: String, url: URL) throws -> String {
        guard !path.isEmpty else { throw Error.missingIdentifier(route) }
        guard path.hasPrefix("/") else { throw Error.malformedURL }
        let encoded = String(path.dropFirst())
        guard !encoded.isEmpty else { throw Error.missingIdentifier(route) }
        guard !encoded.contains("/") else { throw Error.unsupportedRoute(url.absoluteString) }
        guard let identifier = encoded.removingPercentEncoding,
              !identifier.isEmpty,
              !identifier.contains("\0"),
              !identifier.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            throw Error.malformedURL
        }
        return identifier
    }

    public func route(_ url: URL) throws -> CodexPendingOpenRequest {
        try request(for: url)
    }

    public static func request(for url: URL) throws -> CodexPendingOpenRequest {
        try Self().request(for: url)
    }
}
