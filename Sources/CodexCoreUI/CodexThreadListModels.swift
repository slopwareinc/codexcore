import Foundation
import CodexCore

public struct CodexThreadSummary: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var preview: String
    public var workspacePath: String?
    public var status: String?
    public var modelProvider: String?
    public var threadSource: String?
    public var parentThreadID: String?
    public var isEphemeral: Bool
    public var createdAt: TimeInterval?
    public var updatedAt: TimeInterval?
    public var recencyAt: TimeInterval?
    public var sectionID: String?
    public var sectionName: String?
    public var sectionIcon: String?
    public var sectionColor: String?
    public var sectionEnteredAt: TimeInterval?

    public init(
        id: String,
        title: String,
        preview: String = "",
        workspacePath: String? = nil,
        status: String? = nil,
        modelProvider: String? = nil,
        threadSource: String? = nil,
        parentThreadID: String? = nil,
        isEphemeral: Bool = false,
        createdAt: TimeInterval? = nil,
        updatedAt: TimeInterval? = nil,
        recencyAt: TimeInterval? = nil,
        sectionID: String? = nil,
        sectionName: String? = nil,
        sectionIcon: String? = nil,
        sectionColor: String? = nil,
        sectionEnteredAt: TimeInterval? = nil
    ) {
        self.id = id
        self.title = title
        self.preview = preview
        self.workspacePath = workspacePath
        self.status = status
        self.modelProvider = modelProvider
        self.threadSource = threadSource
        self.parentThreadID = parentThreadID
        self.isEphemeral = isEphemeral
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.recencyAt = recencyAt
        self.sectionID = sectionID
        self.sectionName = sectionName
        self.sectionIcon = sectionIcon
        self.sectionColor = sectionColor
        self.sectionEnteredAt = sectionEnteredAt
    }

    /// Adapts the generated app-server fact into the small summary used by
    /// presentation projections. This keeps wire fields canonical while
    /// avoiding a second, hand-maintained thread model in the sidebar.
    public init(schema: CodexSchemaThread) {
        let cwd: String?
        if case .string(let value) = schema.cwd.rawValue {
            cwd = value
        } else {
            cwd = nil
        }
        let section = schema.section
        let status: String? = {
            guard case .dictionary(let object) = schema.status.rawValue else { return nil }
            for key in ["type", "status", "state"] {
                if case .string(let value)? = object[key] { return value }
            }
            return nil
        }()
        let threadSource: String? = {
            guard case .string(let value) = schema.threadSource?.rawValue else { return nil }
            return value
        }()
        let sectionAppearance = section?.appearance
        self.init(
            id: schema.id,
            title: schema.name?.nilIfBlank ?? schema.preview.nilIfBlank ?? "Untitled chat",
            preview: schema.preview,
            workspacePath: cwd,
            status: status,
            modelProvider: schema.modelProvider,
            threadSource: threadSource,
            parentThreadID: schema.parentThreadID,
            isEphemeral: schema.ephemeral,
            createdAt: TimeInterval(schema.createdAt),
            updatedAt: TimeInterval(schema.updatedAt),
            recencyAt: schema.recencyAt.map(TimeInterval.init),
            sectionID: section?.id,
            sectionName: section?.name,
            sectionIcon: sectionAppearance?.icon,
            sectionColor: sectionAppearance?.color,
            sectionEnteredAt: schema.sectionEnteredAt.map(TimeInterval.init)
        )
    }

    public init?(raw value: CodexJSONValue) {
        guard case .dictionary(let object) = value,
              let id = Self.string(in: object, keys: ["id"]) else {
            return nil
        }

        let name = Self.string(in: object, keys: ["name"])?.nilIfBlank
        let preview = Self.string(in: object, keys: ["preview"])?.nilIfBlank ?? ""
        let section = Self.dictionary(from: object["section"])
        let sectionAppearance = Self.dictionary(from: section["appearance"])
        self.init(
            id: id,
            title: name ?? preview.nilIfBlank ?? "Untitled chat",
            preview: preview,
            workspacePath: Self.string(in: object, keys: ["cwd"]),
            status: Self.status(from: object["status"]),
            modelProvider: Self.string(in: object, keys: ["modelProvider"]),
            threadSource: Self.string(in: object, keys: ["threadSource"]),
            parentThreadID: Self.string(in: object, keys: ["parentThreadId"]),
            isEphemeral: CodexJSONCoercion.bool(in: object, key: "ephemeral") ?? false,
            createdAt: Self.timeInterval(in: object, key: "createdAt"),
            updatedAt: Self.timeInterval(in: object, key: "updatedAt"),
            recencyAt: Self.timeInterval(in: object, key: "recencyAt"),
            sectionID: Self.string(in: section, keys: ["id"]),
            sectionName: Self.string(in: section, keys: ["name"]),
            sectionIcon: Self.string(in: sectionAppearance, keys: ["icon"]),
            sectionColor: Self.string(in: sectionAppearance, keys: ["color"]),
            sectionEnteredAt: Self.timeInterval(in: object, key: "sectionEnteredAt")
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

    private static func dictionary(from value: CodexJSONValue?) -> [String: CodexJSONValue] {
        guard case .dictionary(let object) = value else { return [:] }
        return object
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

public struct CodexProjectSummary: Identifiable, Equatable, Sendable {
    public var workspacePath: String
    public var sourceFolders: [String]
    public var chatCount: Int
    public var updatedAt: TimeInterval?
    public var customDisplayName: String?
    public var serverID: String?
    public var serverName: String?
    public var serverPosition: Int?

    public var id: String { workspacePath }

    public init(
        workspacePath: String,
        sourceFolders: [String] = [],
        chatCount: Int = 0,
        updatedAt: TimeInterval? = nil,
        customDisplayName: String? = nil,
        serverID: String? = nil,
        serverName: String? = nil,
        serverPosition: Int? = nil
    ) {
        let primary = Self.normalizedPath(workspacePath)
        self.workspacePath = primary
        self.sourceFolders = Self.normalizedSourceFolders(
            sourceFolders.isEmpty ? [primary] : sourceFolders,
            primary: primary
        )
        self.chatCount = chatCount
        self.updatedAt = updatedAt
        self.customDisplayName = customDisplayName?.nilIfBlank
        self.serverID = serverID?.nilIfBlank
        self.serverName = serverName?.nilIfBlank
        self.serverPosition = serverPosition
    }

    /// Adapts an authoritative project/list response. Local aliases and
    /// visibility are applied later by the sidebar projection, never written
    /// back into this server fact.
    public init(schema: CodexSchemaProject) {
        let roots = schema.roots.compactMap { root -> String? in
            guard case .string(let value) = root.path.rawValue else { return nil }
            return value
        }
        let primary = roots.first ?? schema.id
        self.init(
            workspacePath: primary,
            sourceFolders: roots,
            updatedAt: TimeInterval(schema.updatedAt),
            serverID: schema.id,
            serverName: schema.name,
            serverPosition: schema.position
        )
    }

    public var displayName: String {
        if let customDisplayName { return customDisplayName }
        if let serverName { return serverName }
        let last = URL(fileURLWithPath: workspacePath).lastPathComponent.nilIfBlank
        return last ?? (workspacePath == "/" ? "/" : workspacePath)
    }

    public var detail: String {
        let count = chatCount == 1 ? "1 chat" : "\(chatCount) chats"
        return "\(shortPath) · \(count)"
    }

    public var shortPath: String {
        CodexPathFormatter.abbreviatingHome(workspacePath)
    }

    public var additionalSourceFolderCount: Int {
        max(0, sourceFolders.count - 1)
    }

    public func contains(workspacePath path: String) -> Bool {
        sourceFolders.contains(Self.normalizedPath(path))
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
            if let recencyAt = summary.recencyAt ?? summary.updatedAt ?? summary.createdAt,
               bucket.updatedAt.map({ recencyAt > $0 }) ?? true {
                bucket.updatedAt = recencyAt
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
            let nameComparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
            return lhs.workspacePath.localizedCaseInsensitiveCompare(rhs.workspacePath) == .orderedAscending
        }
    }

    public static func normalizedPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    public static func normalizedSourceFolders(
        _ paths: [String],
        primary: String? = nil
    ) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        result.reserveCapacity(paths.count + (primary == nil ? 0 : 1))
        if let primary {
            let normalizedPrimary = normalizedPath(primary)
            seen.insert(normalizedPrimary)
            result.append(normalizedPrimary)
        }
        for path in paths {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = normalizedPath(trimmed)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result
    }
}
