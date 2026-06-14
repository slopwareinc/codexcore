import Foundation

public struct CodexHydratedThread: Sendable, Equatable {
    public var snapshot: CodexThreadSnapshot
    public var agentName: String?
    public var agentRole: String?
    public var childThreadIDs: [String]

    public init(
        snapshot: CodexThreadSnapshot,
        agentName: String? = nil,
        agentRole: String? = nil,
        childThreadIDs: [String] = []
    ) {
        self.snapshot = snapshot
        self.agentName = agentName
        self.agentRole = agentRole
        self.childThreadIDs = childThreadIDs
    }
}

public struct CodexThreadHistoryHydrationResult: Sendable, Equatable {
    public var parent: CodexHydratedThread
    public var childThreads: [CodexHydratedThread]
    public var failedChildThreadIDs: [String]

    public init(
        parent: CodexHydratedThread,
        childThreads: [CodexHydratedThread] = [],
        failedChildThreadIDs: [String] = []
    ) {
        self.parent = parent
        self.childThreads = childThreads
        self.failedChildThreadIDs = failedChildThreadIDs
    }

    public var restoredChildThreadCount: Int {
        childThreads.count
    }
}

public enum CodexThreadHistoryHydrator {
    public static func load(threadID: String, using codex: Codex) async throws -> CodexThreadHistoryHydrationResult {
        let parentRaw = try await readThreadRaw(threadID: threadID, using: codex)
        return await hydrate(parentRaw: parentRaw) { childThreadID in
            try await readThreadRaw(threadID: childThreadID, using: codex)
        }
    }

    public static func hydrate(
        parentRaw: CodexJSONValue,
        loadChildThread: (String) async throws -> CodexJSONValue
    ) async -> CodexThreadHistoryHydrationResult {
        let parent = decode(raw: parentRaw)
        var childThreads: [CodexHydratedThread] = []
        var failedChildThreadIDs: [String] = []
        var seenThreadIDs: Set<String> = []

        for childThreadID in parent.childThreadIDs where seenThreadIDs.insert(childThreadID).inserted {
            do {
                childThreads.append(decode(raw: try await loadChildThread(childThreadID), fallbackThreadID: childThreadID))
            } catch {
                failedChildThreadIDs.append(childThreadID)
            }
        }

        return CodexThreadHistoryHydrationResult(
            parent: parent,
            childThreads: childThreads,
            failedChildThreadIDs: failedChildThreadIDs
        )
    }

    public static func decode(raw response: CodexJSONValue, fallbackThreadID: String? = nil) -> CodexHydratedThread {
        let rawThread = threadObject(from: response) ?? [:]
        let threadID = string(from: rawThread["id"]) ?? fallbackThreadID ?? UUID().uuidString
        var turns: [CodexTurnSnapshot] = []
        var childThreadIDs: [String] = []

        for rawTurn in turnObjects(from: response) {
            var turn = turnSnapshot(from: rawTurn)
            guard case .array(let rawItems)? = rawTurn["items"] else {
                if shouldKeep(turn) {
                    turns.append(turn)
                }
                continue
            }

            for rawItemValue in rawItems {
                guard case .dictionary(let rawItem) = rawItemValue else { continue }
                childThreadIDs.append(contentsOf: extractedChildThreadIDs(from: rawItem))

                guard let item = try? rawItemValue.decode(CodexServerItem.self) else { continue }
                if item.type == "plan" {
                    if let plan = CodexTimelineItemMapper.turnPlan(from: item.raw) {
                        turn.plan = plan.plan.isEmpty ? nil : plan.plan
                        turn.planExplanation = plan.explanation
                    }
                    continue
                }
                guard isTranscriptItemType(item.type) else { continue }

                let itemDate = date(from: rawItem["createdAt"])
                    ?? date(from: rawItem["startedAt"])
                    ?? date(from: rawItem["completedAt"])
                    ?? turn.startedAt
                turn.items.append(CodexTimelineItemMapper.timelineItem(for: item, createdAt: itemDate))
                if let detail = CodexTimelineItemMapper.detail(for: item) {
                    turn.itemDetails[item.id] = detail
                }
            }

            if shouldKeep(turn) {
                turns.append(turn)
            }
        }

        let updatedAt = turns.compactMap(\.completedAt).last
            ?? turns.last?.startedAt
            ?? date(from: rawThread["updatedAt"])
            ?? Date()
        let snapshot = CodexThreadSnapshot(
            id: threadID,
            sessionID: string(from: rawThread["sessionId"]) ?? string(from: rawThread["sessionID"]),
            status: threadStatus(from: string(from: rawThread["status"])),
            cwd: string(from: rawThread["cwd"]) ?? "",
            model: string(from: rawThread["model"]) ?? "",
            turns: turns,
            updatedAt: updatedAt
        )

        return CodexHydratedThread(
            snapshot: snapshot,
            agentName: string(from: rawThread["agentNickname"]) ?? string(from: rawThread["name"]),
            agentRole: string(from: rawThread["agentRole"]),
            childThreadIDs: stableUnique(childThreadIDs)
        )
    }

    private static func readThreadRaw(threadID: String, using codex: Codex) async throws -> CodexJSONValue {
        try await codex.rawRequest(
            method: CodexAppServerClientMethod.threadRead.rawValue,
            params: [
                "threadId": .string(threadID),
                "includeTurns": .bool(true)
            ]
        )
    }

    private static func turnObjects(from response: CodexJSONValue) -> [[String: CodexJSONValue]] {
        if let thread = threadObject(from: response),
           case .array(let turns)? = thread["turns"] {
            return dictionaries(from: turns)
        }

        if case .dictionary(let object) = response,
           case .array(let turns)? = object["turns"] {
            return dictionaries(from: turns)
        }
        return []
    }

    private static func threadObject(from response: CodexJSONValue) -> [String: CodexJSONValue]? {
        guard case .dictionary(let object) = response else { return nil }
        if case .dictionary(let thread)? = object["thread"] { return thread }
        if object["turns"] != nil, object["id"] != nil { return object }
        return nil
    }

    private static func dictionaries(from values: [CodexJSONValue]) -> [[String: CodexJSONValue]] {
        values.compactMap { value in
            guard case .dictionary(let object) = value else { return nil }
            return object
        }
    }

    private static func turnSnapshot(from raw: [String: CodexJSONValue]) -> CodexTurnSnapshot {
        let startedAt = date(from: raw["startedAt"]) ?? Date()
        return CodexTurnSnapshot(
            id: string(from: raw["id"]) ?? UUID().uuidString,
            status: turnStatus(from: string(from: raw["status"])),
            error: turnErrorMessage(from: raw),
            startedAt: startedAt,
            completedAt: date(from: raw["completedAt"]),
            diff: string(from: raw["diff"])
        )
    }

    private static func shouldKeep(_ turn: CodexTurnSnapshot) -> Bool {
        !turn.items.isEmpty || turn.plan != nil || turn.diff != nil
    }

    private static func isTranscriptItemType(_ type: String) -> Bool {
        switch type {
        case "userMessage", "agentMessage", "assistantMessage", "commandExecution", "fileChange", "patch", "mcpToolCall", "toolCall":
            return true
        default:
            return false
        }
    }

    private static func threadStatus(from rawStatus: String?) -> CodexThreadStatus {
        switch rawStatus?.lowercased() {
        case "active", "running": return .active
        case "waiting": return .waiting
        case "completed": return .completed
        case "failed": return .failed
        default: return .idle
        }
    }

    private static func turnStatus(from rawStatus: String?) -> CodexTurnStatus {
        switch rawStatus?.lowercased() {
        case "failed": return .failed
        case "completed", "interrupted", "cancelled", "canceled": return .completed
        default: return .running
        }
    }

    private static func turnErrorMessage(from turn: [String: CodexJSONValue]) -> String? {
        guard let error = turn["error"] else { return nil }
        if case .null = error { return nil }
        return string(from: error)
    }

    private static func date(from value: CodexJSONValue?) -> Date? {
        let seconds: TimeInterval?
        switch value {
        case .int(let int): seconds = TimeInterval(int)
        case .double(let double): seconds = double
        case .string(let string): seconds = TimeInterval(string)
        case .bool, .array, .dictionary, .null, nil: seconds = nil
        }
        guard var seconds else { return nil }
        if seconds > 10_000_000_000 {
            seconds /= 1_000
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func extractedChildThreadIDs(from rawItem: [String: CodexJSONValue]) -> [String] {
        var ids: [String] = []
        for key in ["receiverThreadIds", "receiverThreadIDs", "childThreadIds", "childThreadIDs", "threadIds", "threadIDs"] {
            ids.append(contentsOf: stringArray(from: rawItem[key]))
        }
        if let direct = string(from: rawItem["threadId"]) ?? string(from: rawItem["threadID"]) {
            ids.append(direct)
        }
        ids.append(contentsOf: nestedThreadIDs(from: rawItem["thread"]))
        ids.append(contentsOf: nestedThreadIDs(from: rawItem["source"]))
        ids.append(contentsOf: nestedThreadIDs(from: rawItem["metadata"]))
        ids.append(contentsOf: nestedThreadIDs(from: rawItem["agent"]))
        ids.append(contentsOf: nestedThreadIDs(from: rawItem["subagent"]))
        ids.append(contentsOf: nestedThreadIDs(from: rawItem["subAgent"]))
        ids.append(contentsOf: nestedThreadIDs(from: rawItem["agents"]))
        ids.append(contentsOf: nestedThreadIDs(from: rawItem["subagents"]))
        ids.append(contentsOf: nestedThreadIDs(from: rawItem["subAgents"]))
        ids.append(contentsOf: nestedThreadIDs(from: rawItem["children"]))
        ids.append(contentsOf: nestedThreadIDs(from: rawItem["threads"]))
        return ids
    }

    private static func nestedThreadIDs(from value: CodexJSONValue?) -> [String] {
        switch value {
        case .dictionary(let object):
            var ids: [String] = []
            if let id = string(from: object["threadId"]) ?? string(from: object["threadID"]) ?? string(from: object["id"]) {
                ids.append(id)
            }
            ids.append(contentsOf: extractedChildThreadIDs(from: object))
            return ids
        case .array(let values):
            return values.flatMap(nestedThreadIDs(from:))
        case .string(let string):
            return [string]
        case .int, .double, .bool, .null, nil:
            return []
        }
    }

    private static func stringArray(from value: CodexJSONValue?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap { string(from: $0) }
    }

    private static func string(from value: CodexJSONValue?) -> String? {
        switch value {
        case .string(let string): return string
        case .int(let int): return String(int)
        case .double(let double): return String(double)
        case .bool(let bool): return String(bool)
        case .dictionary(let object):
            return string(from: object["message"])
                ?? string(from: object["text"])
                ?? string(from: object["value"])
                ?? string(from: object["id"])
        case .array(let values):
            return values.compactMap { string(from: $0) }.joined(separator: "\n").nilIfEmpty
        case .null, nil:
            return nil
        }
    }

    private static func stableUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
