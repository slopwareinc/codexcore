import Foundation
import CodexCore

public struct CodexThreadHistoryPaginationState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case loading
        case loaded
        case unavailable
        case failed
    }

    public var phase: Phase
    public var nextCursorByTurnID: [String: String]
    public var loadedItemCount: Int
    public var errorMessage: String?

    public init(
        phase: Phase = .idle,
        nextCursorByTurnID: [String: String] = [:],
        loadedItemCount: Int = 0,
        errorMessage: String? = nil
    ) {
        self.phase = phase
        self.nextCursorByTurnID = nextCursorByTurnID
        self.loadedItemCount = loadedItemCount
        self.errorMessage = errorMessage
    }

    public var isLoading: Bool { phase == .loading }
    public var hasMore: Bool { !nextCursorByTurnID.isEmpty }

    public static let idle = CodexThreadHistoryPaginationState()
    public static let loading = CodexThreadHistoryPaginationState(phase: .loading)
}

public struct CodexThreadHistoryRestoreResult: Sendable {
    public var snapshot: CodexThreadHistorySnapshot
    public var hydration: CodexThreadHistoryHydrationResult
    public var restoredChildThreadCount: Int
    public var paginationState: CodexThreadHistoryPaginationState
    public var transcriptItemsV2: [CodexJSONValue]

    public init(
        snapshot: CodexThreadHistorySnapshot,
        hydration: CodexThreadHistoryHydrationResult,
        restoredChildThreadCount: Int = 0,
        paginationState: CodexThreadHistoryPaginationState = .idle,
        transcriptItemsV2: [CodexJSONValue] = []
    ) {
        self.snapshot = snapshot
        self.hydration = hydration
        self.restoredChildThreadCount = restoredChildThreadCount
        self.paginationState = paginationState
        self.transcriptItemsV2 = transcriptItemsV2
    }

    public var messageCount: Int {
        transcriptItemsV2.count
    }

    public var activity: CodexActivity {
        let agentDetail = restoredChildThreadCount > 0 ? ", \(restoredChildThreadCount) agents restored" : ""
        return CodexActivity(
            kind: .notice,
            title: "Loaded transcript",
            detail: "\(messageCount) messages restored\(agentDetail)"
        )
    }
}

public struct CodexThreadHistoryCache: Sendable {
    private let capacity: Int
    private var entries: [String: CodexThreadHistoryRestoreResult] = [:]
    private var order: [String] = []
    private var protectedThreadIDs: Set<String> = []

    public init(capacity: Int = 20) {
        self.capacity = max(0, capacity)
    }

    public var count: Int {
        entries.count
    }

    public func isProtected(threadID: String) -> Bool {
        protectedThreadIDs.contains(threadID)
    }

    public mutating func result(for threadID: String) -> CodexThreadHistoryRestoreResult? {
        guard let result = entries[threadID] else { return nil }
        touch(threadID)
        return result
    }

    public mutating func store(_ result: CodexThreadHistoryRestoreResult, protected: Bool = false) {
        let threadID = result.hydration.parent.snapshot.id
        let isProtected = protected || protectedThreadIDs.contains(threadID)
        guard capacity > 0 || isProtected else {
            evictUnprotectedEntries()
            return
        }
        if protected {
            protectedThreadIDs.insert(threadID)
        }
        entries[threadID] = result
        touch(threadID)
        evictOverflow()
    }

    public mutating func protect(threadID: String) {
        protectedThreadIDs.insert(threadID)
        evictOverflow()
    }

    public mutating func remove(threadID: String) {
        entries.removeValue(forKey: threadID)
        order.removeAll { $0 == threadID }
        protectedThreadIDs.remove(threadID)
    }

    public mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        protectedThreadIDs.removeAll()
    }

    private mutating func touch(_ threadID: String) {
        order.removeAll { $0 == threadID }
        order.append(threadID)
    }

    private mutating func evictOverflow() {
        while unprotectedEntryCount > capacity,
              let evicted = order.first(where: { !protectedThreadIDs.contains($0) }) {
            order.removeAll { $0 == evicted }
            entries.removeValue(forKey: evicted)
        }
    }

    private var unprotectedEntryCount: Int {
        entries.keys.reduce(0) { count, threadID in
            count + (protectedThreadIDs.contains(threadID) ? 0 : 1)
        }
    }

    private mutating func evictUnprotectedEntries() {
        for threadID in Array(entries.keys) where !protectedThreadIDs.contains(threadID) {
            entries.removeValue(forKey: threadID)
        }
        order.removeAll { !protectedThreadIDs.contains($0) }
    }
}

public enum CodexThreadHistorySession {
    public static func load(
        threadID: String,
        using codex: Codex,
        trace: CodexPerformanceTrace? = nil,
        activateParent: Bool = true
    ) async throws -> CodexThreadHistoryRestoreResult {
        let parentReadSpan = trace?.begin("threadHistory.parent.read", metadata: ["threadID": threadID])
        let parentRaw: CodexJSONValue
        do {
            parentRaw = try await readThreadRaw(threadID: threadID, using: codex)
            parentReadSpan?.end(metadata: ["outcome": "success"])
        } catch {
            parentReadSpan?.end(metadata: ["outcome": "failure", "error": errorType(error)])
            throw error
        }
        return await load(parentRaw: parentRaw, using: codex, trace: trace, activateParent: activateParent)
    }

    public static func load(
        parentRaw: CodexJSONValue,
        using codex: Codex,
        trace: CodexPerformanceTrace? = nil,
        activateParent: Bool = true
    ) async -> CodexThreadHistoryRestoreResult {
        let pagination = await paginatedParentRaw(parentRaw, using: codex, trace: trace)
        var result = await restore(parentRaw: pagination.raw, trace: trace) { childThreadID in
            try await readThreadRaw(threadID: childThreadID, using: codex)
        }
        result.paginationState = pagination.state
        return await hydrateStore(result, using: codex, trace: trace, activateParent: activateParent)
    }

    private static func hydrateStore(
        _ result: CodexThreadHistoryRestoreResult,
        using codex: Codex,
        trace: CodexPerformanceTrace?,
        activateParent: Bool
    ) async -> CodexThreadHistoryRestoreResult {
        let storeHydrateSpan = trace?.begin("threadHistory.store.hydrate", metadata: metadata(for: result))
        await MainActor.run {
            codex.store.hydrate(result.hydration, activateParent: activateParent)
        }
        storeHydrateSpan?.end(metadata: metadata(for: result).merging(["outcome": "success"]) { _, new in new })
        return result
    }

    public static func restore(
        parentRaw: CodexJSONValue,
        trace: CodexPerformanceTrace? = nil,
        loadChildThread: (String) async throws -> CodexJSONValue
    ) async -> CodexThreadHistoryRestoreResult {
        let hydration = await CodexThreadHistoryHydrator.hydrate(parentRaw: parentRaw, trace: trace, loadChildThread: loadChildThread)

        let snapshotSpan = trace?.begin("threadHistory.snapshot.project")
        let snapshot = CodexThreadHistorySnapshot(hydration: hydration)
        let result = CodexThreadHistoryRestoreResult(
            snapshot: snapshot,
            hydration: hydration,
            restoredChildThreadCount: hydration.restoredChildThreadCount,
            transcriptItemsV2: Self.transcriptItems(from: parentRaw)
        )
        snapshotSpan?.end(metadata: metadata(for: result))
        return result
    }

    private static func transcriptItems(from raw: CodexJSONValue) -> [CodexJSONValue] {
        guard case .dictionary(let root) = raw else { return [] }
        let threadValue = root["thread"] ?? raw
        guard case .dictionary(let thread) = threadValue,
              case .array(let turns)? = thread["turns"] else { return [] }
        return turns.flatMap { turn -> [CodexJSONValue] in
            guard case .dictionary(let object) = turn,
                  case .array(let items)? = object["items"] else { return [] }
            return items
        }
    }

    @discardableResult
    public static func apply(
        _ result: CodexThreadHistoryRestoreResult,
        mainChatSession: inout CodexMainChatSession,
        agentStateMapper: inout CodexAgentStateMapper,
        sideChatSession: inout CodexSideChatSession
    ) -> CodexActivity {
        mainChatSession.reset()
        agentStateMapper = result.snapshot.agentStateMapper
        sideChatSession.reset()
        return result.activity
    }

    private static func readThreadRaw(threadID: String, using codex: Codex) async throws -> CodexJSONValue {
        try CodexJSONValue(encoding: await codex.threadReadSchema(threadID, includeTurns: true))
    }

    private static func paginatedParentRaw(
        _ parentRaw: CodexJSONValue,
        using codex: Codex,
        trace: CodexPerformanceTrace?
    ) async -> (raw: CodexJSONValue, state: CodexThreadHistoryPaginationState) {
        await paginate(parentRaw: parentRaw, trace: trace) { threadID, turnID, cursor in
            try await codex.threadItemsList(
                threadId: threadID,
                turnId: turnID,
                cursor: cursor,
                limit: 100,
                sortDirection: .asc
            )
        }
    }

    static func paginate(
        parentRaw: CodexJSONValue,
        trace: CodexPerformanceTrace? = nil,
        loadPage: (String, String, String?) async throws -> CodexSchemaThreadItemsListResponse
    ) async -> (raw: CodexJSONValue, state: CodexThreadHistoryPaginationState) {
        guard case .dictionary(var response) = parentRaw else { return (parentRaw, .idle) }
        let wrapsThread = response["thread"] != nil
        guard case .dictionary(var thread) = wrapsThread ? response["thread"] : parentRaw,
              Self.string(thread["historyMode"]) == "paginated",
              let threadID = Self.string(thread["id"]),
              case .array(var turns)? = thread["turns"] else {
            return (parentRaw, .idle)
        }

        let span = trace?.begin("threadHistory.items.paginate", metadata: ["threadID": threadID])
        var loadedItemCount = 0
        var nextCursorByTurnID: [String: String] = [:]

        do {
            for turnIndex in turns.indices {
                guard case .dictionary(var turn) = turns[turnIndex],
                      let turnID = Self.string(turn["id"]) else { continue }
                let existingItems: [CodexJSONValue]
                if case .array(let items)? = turn["items"] { existingItems = items } else { existingItems = [] }

                var pagedItems: [CodexJSONValue] = []
                var cursor: String?
                var seenCursors: Set<String> = []
                repeat {
                    let page = try await loadPage(threadID, turnID, cursor)
                    pagedItems.append(contentsOf: page.data.map(\.rawValue))
                    loadedItemCount += page.data.count
                    cursor = page.nextCursor
                    if let cursor {
                        guard seenCursors.insert(cursor).inserted else {
                            throw CodexSDKError.invalidResponse(
                                method: CodexAppServerClientMethod.threadItemsList.rawValue,
                                value: .string("repeated cursor \(cursor)")
                            )
                        }
                        nextCursorByTurnID[turnID] = cursor
                    } else {
                        nextCursorByTurnID.removeValue(forKey: turnID)
                    }
                } while cursor != nil

                turn["items"] = .array(mergeItems(pagedItems, with: existingItems))
                turn["itemsView"] = .string("full")
                turns[turnIndex] = .dictionary(turn)
            }
        } catch {
            let message = String(describing: error)
            span?.end(metadata: ["threadID": threadID, "outcome": "fallback", "error": message])
            let phase: CodexThreadHistoryPaginationState.Phase = isMethodUnavailable(error) ? .unavailable : .failed
            return (
                parentRaw,
                CodexThreadHistoryPaginationState(
                    phase: phase,
                    nextCursorByTurnID: nextCursorByTurnID,
                    loadedItemCount: 0,
                    errorMessage: message
                )
            )
        }

        thread["turns"] = .array(turns)
        if wrapsThread { response["thread"] = .dictionary(thread) } else { response = thread }
        span?.end(metadata: ["threadID": threadID, "outcome": "success", "itemCount": "\(loadedItemCount)"])
        return (
            .dictionary(response),
            CodexThreadHistoryPaginationState(phase: .loaded, loadedItemCount: loadedItemCount)
        )
    }

    private static func mergeItems(_ pagedItems: [CodexJSONValue], with existingItems: [CodexJSONValue]) -> [CodexJSONValue] {
        var seenIDs: Set<String> = []
        return (pagedItems + existingItems).filter { item in
            guard case .dictionary(let object) = item, let id = string(object["id"]) else { return true }
            return seenIDs.insert(id).inserted
        }
    }

    private static func string(_ value: CodexJSONValue?) -> String? {
        guard case .string(let value)? = value else { return nil }
        return value
    }

    private static func isMethodUnavailable(_ error: Error) -> Bool {
        let description = String(describing: error).lowercased()
        return description.contains("method not found") || description.contains("-32601")
    }

    private static func metadata(for result: CodexThreadHistoryRestoreResult) -> [String: String] {
        [
            "threadID": result.hydration.parent.snapshot.id,
            "turnCount": "\(result.hydration.parent.snapshot.turns.count)",
            "itemCount": "\(result.hydration.parent.snapshot.turns.reduce(0) { $0 + $1.items.count })",
            "messageCount": "\(result.messageCount)",
            "restoredChildThreadCount": "\(result.restoredChildThreadCount)",
            "failedChildThreadCount": "\(result.hydration.failedChildThreadIDs.count)"
        ]
    }

    private static func errorType(_ error: Error) -> String {
        String(describing: type(of: error))
    }
}
