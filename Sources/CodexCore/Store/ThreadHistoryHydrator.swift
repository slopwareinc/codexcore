import Foundation

public struct CodexHydratedThread: Sendable, Equatable {
    public var snapshot: CodexThreadSnapshot
    public var agentName: String?
    public var agentRole: String?

    public init(
        snapshot: CodexThreadSnapshot,
        agentName: String? = nil,
        agentRole: String? = nil
    ) {
        self.snapshot = snapshot
        self.agentName = agentName
        self.agentRole = agentRole
    }

    public var childThreadIDs: [String] {
        snapshot.childThreads.map(\.threadID)
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
    public static func load(
        threadID: String,
        using codex: Codex,
        trace: CodexPerformanceTrace? = nil
    ) async throws -> CodexThreadHistoryHydrationResult {
        let parentReadSpan = trace?.begin("threadHistory.parent.read", metadata: ["threadID": threadID])
        let parentRaw: CodexJSONValue
        do {
            parentRaw = try await readThreadRaw(threadID: threadID, using: codex)
            parentReadSpan?.end(metadata: ["outcome": "success"])
        } catch {
            parentReadSpan?.end(metadata: ["outcome": "failure", "error": errorType(error)])
            throw error
        }
        return await hydrate(parentRaw: parentRaw, trace: trace) { childThreadID in
            try await readThreadRaw(threadID: childThreadID, using: codex)
        }
    }

    public static func hydrate(
        parentRaw: CodexJSONValue,
        trace: CodexPerformanceTrace? = nil,
        loadChildThread: (String) async throws -> CodexJSONValue
    ) async -> CodexThreadHistoryHydrationResult {
        let parentDecodeSpan = trace?.begin("threadHistory.parent.decode")
        let parent = decode(raw: parentRaw)
        var parentMetadata = metrics(for: parent.snapshot)
        let childThreadIDs = uniqueThreadIDs(parent.childThreadIDs)
        parentMetadata["childThreadCount"] = "\(childThreadIDs.count)"
        parentDecodeSpan?.end(metadata: parentMetadata)

        var childThreads: [CodexHydratedThread] = []
        var failedChildThreadIDs: [String] = []

        let childrenSpan = trace?.begin(
            "threadHistory.children.total",
            metadata: ["childThreadCount": "\(childThreadIDs.count)"]
        )
        for (index, childThreadID) in childThreadIDs.enumerated() {
            let childMetadata = [
                "childIndex": "\(index + 1)",
                "childThreadCount": "\(childThreadIDs.count)",
                "threadID": childThreadID
            ]
            let childReadSpan = trace?.begin("threadHistory.child.read", metadata: childMetadata)
            do {
                let childRaw = try await loadChildThread(childThreadID)
                childReadSpan?.end(metadata: childMetadata.merging(["outcome": "success"]) { _, new in new })

                let childDecodeSpan = trace?.begin("threadHistory.child.decode", metadata: childMetadata)
                let child = decode(raw: childRaw, fallbackThreadID: childThreadID)
                var decodedMetadata = metrics(for: child.snapshot)
                decodedMetadata.merge(childMetadata) { _, new in new }
                decodedMetadata["outcome"] = "success"
                childDecodeSpan?.end(metadata: decodedMetadata)
                childThreads.append(child)
            } catch {
                childReadSpan?.end(metadata: childMetadata.merging([
                    "outcome": "failure",
                    "error": errorType(error)
                ]) { _, new in new })
                failedChildThreadIDs.append(childThreadID)
            }
        }
        childrenSpan?.end(metadata: [
            "childThreadCount": "\(childThreadIDs.count)",
            "failedChildThreadCount": "\(failedChildThreadIDs.count)",
            "restoredChildThreadCount": "\(childThreads.count)"
        ])

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
        var childReferences: [CodexChildThreadReference] = []

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
                childReferences.append(contentsOf: childThreadReferences(from: rawItem))

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
            sessionID: string(from: rawThread["sessionId"]),
            status: threadStatus(from: string(from: rawThread["status"])),
            cwd: string(from: rawThread["cwd"]) ?? "",
            model: string(from: rawThread["model"]) ?? "",
            turns: turns,
            childThreads: stableUniqueReferences(childReferences),
            updatedAt: updatedAt
        )

        return CodexHydratedThread(
            snapshot: snapshot,
            agentName: string(from: rawThread["agentNickname"]) ?? string(from: rawThread["name"]),
            agentRole: string(from: rawThread["agentRole"])
        )
    }

    private static func readThreadRaw(threadID: String, using codex: Codex) async throws -> CodexJSONValue {
        try CodexJSONValue(encoding: await codex.threadReadSchema(threadID, includeTurns: true))
    }

    private static func uniqueThreadIDs(_ threadIDs: [String]) -> [String] {
        var seenThreadIDs: Set<String> = []
        return threadIDs.filter { seenThreadIDs.insert($0).inserted }
    }

    private static func metrics(for snapshot: CodexThreadSnapshot) -> [String: String] {
        [
            "threadID": snapshot.id,
            "turnCount": "\(snapshot.turns.count)",
            "itemCount": "\(snapshot.turns.reduce(0) { $0 + $1.items.count })"
        ]
    }

    private static func errorType(_ error: Error) -> String {
        String(describing: type(of: error))
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

    private static func childThreadReferences(from rawItem: [String: CodexJSONValue]) -> [CodexChildThreadReference] {
        var references: [CodexChildThreadReference] = []
        let itemID = string(from: rawItem["id"])
        let prompt = string(from: rawItem["prompt"]) ?? string(from: rawItem["message"]) ?? string(from: rawItem["text"])
        for key in ["receiverThreadIds", "childThreadIds", "threadIds"] {
            references.append(contentsOf: stringArray(from: rawItem[key]).map {
                childThreadReference(threadID: $0, itemID: itemID, rawItem: rawItem, prompt: prompt)
            })
        }
        if let direct = string(from: rawItem["threadId"]) {
            references.append(childThreadReference(threadID: direct, itemID: itemID, rawItem: rawItem, prompt: prompt))
        }
        for key in ["thread", "source", "metadata", "agent", "subagent", "subAgent", "agents", "subagents", "subAgents", "children", "threads"] {
            references.append(contentsOf: nestedChildThreadReferences(from: rawItem[key], itemID: itemID, fallbackPrompt: prompt))
        }
        return references
    }

    private static func nestedChildThreadReferences(
        from value: CodexJSONValue?,
        itemID: String?,
        fallbackPrompt: String?
    ) -> [CodexChildThreadReference] {
        switch value {
        case .dictionary(let object):
            var references: [CodexChildThreadReference] = []
            if let id = string(from: object["threadId"]) ?? string(from: object["id"]) {
                references.append(childThreadReference(
                    threadID: id,
                    itemID: itemID,
                    rawItem: object,
                    prompt: string(from: object["prompt"]) ?? fallbackPrompt
                ))
            }
            references.append(contentsOf: childThreadReferences(from: object))
            return references
        case .array(let values):
            return values.flatMap { nestedChildThreadReferences(from: $0, itemID: itemID, fallbackPrompt: fallbackPrompt) }
        case .string(let string):
            return [CodexChildThreadReference(threadID: string, itemID: itemID, prompt: fallbackPrompt)]
        case .int, .double, .bool, .null, nil:
            return []
        }
    }

    private static func childThreadReference(
        threadID: String,
        itemID: String?,
        rawItem: [String: CodexJSONValue],
        prompt: String?
    ) -> CodexChildThreadReference {
        let state = childState(for: threadID, in: rawItem)
        let name = string(from: rawItem["name"])
            ?? string(from: rawItem["agentName"])
            ?? string(from: state?["name"])
            ?? string(from: state?["agentName"])
        return CodexChildThreadReference(
            threadID: threadID,
            itemID: itemID,
            name: name,
            title: string(from: rawItem["title"]) ?? name,
            prompt: prompt,
            status: string(from: state?["status"]) ?? string(from: state?["state"]) ?? string(from: rawItem["status"])
        )
    }

    private static func childState(
        for threadID: String,
        in rawItem: [String: CodexJSONValue]
    ) -> [String: CodexJSONValue]? {
        for key in ["agentsStates", "agentStates", "states"] {
            guard case .dictionary(let states)? = rawItem[key],
                  case .dictionary(let state)? = states[threadID] else {
                continue
            }
            return state
        }
        return nil
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

    private static func stableUniqueReferences(_ values: [CodexChildThreadReference]) -> [CodexChildThreadReference] {
        var seen: Set<String> = []
        return values.filter { !$0.threadID.isEmpty && seen.insert($0.threadID).inserted }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
