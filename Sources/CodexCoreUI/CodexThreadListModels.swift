import Foundation
import CodexCore

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
    public var recencyAt: TimeInterval?

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
        updatedAt: TimeInterval? = nil,
        recencyAt: TimeInterval? = nil
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
        self.recencyAt = recencyAt
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
            isEphemeral: CodexJSONCoercion.bool(in: object, key: "ephemeral") ?? false,
            createdAt: Self.timeInterval(in: object, key: "createdAt"),
            updatedAt: Self.timeInterval(in: object, key: "updatedAt"),
            recencyAt: Self.timeInterval(in: object, key: "recencyAt")
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
        CodexPathFormatter.abbreviatingHome(workspacePath)
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
