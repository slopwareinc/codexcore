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
    public var retryTurnID: String?
    public var retryCursor: String?

    public init(
        phase: Phase = .idle,
        nextCursorByTurnID: [String: String] = [:],
        loadedItemCount: Int = 0,
        errorMessage: String? = nil,
        retryTurnID: String? = nil,
        retryCursor: String? = nil
    ) {
        self.phase = phase
        self.nextCursorByTurnID = nextCursorByTurnID
        self.loadedItemCount = loadedItemCount
        self.errorMessage = errorMessage
        self.retryTurnID = retryTurnID
        self.retryCursor = retryCursor
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
    public var transcriptV2: CodexTranscriptV2
    public var paginationRaw: CodexJSONValue?

    public init(
        snapshot: CodexThreadHistorySnapshot,
        hydration: CodexThreadHistoryHydrationResult,
        restoredChildThreadCount: Int = 0,
        paginationState: CodexThreadHistoryPaginationState = .idle,
        transcriptItemsV2: [CodexJSONValue] = [],
        transcriptV2: CodexTranscriptV2,
        paginationRaw: CodexJSONValue? = nil
    ) {
        self.snapshot = snapshot
        self.hydration = hydration
        self.restoredChildThreadCount = restoredChildThreadCount
        self.paginationState = paginationState
        self.transcriptItemsV2 = transcriptItemsV2
        self.transcriptV2 = transcriptV2
        self.paginationRaw = paginationRaw
    }

    public var messageCount: Int {
        transcriptV2.turns.isEmpty ? transcriptItemsV2.count : transcriptV2.turns.count
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
    private var protectionCounts: [String: Int] = [:]

    public init(capacity: Int = 20) {
        self.capacity = max(0, capacity)
    }

    public var count: Int {
        entries.count
    }

    public func isProtected(threadID: String) -> Bool {
        protectionCounts[threadID, default: 0] > 0
    }

    public mutating func result(for threadID: String) -> CodexThreadHistoryRestoreResult? {
        guard let result = entries[threadID] else { return nil }
        touch(threadID)
        return result
    }

    public mutating func store(_ result: CodexThreadHistoryRestoreResult, protected: Bool = false) {
        let threadID = result.hydration.parent.snapshot.id
        let shouldKeep = protected || isProtected(threadID: threadID)
        guard capacity > 0 || shouldKeep else {
            evictUnprotectedEntries()
            return
        }
        if protected {
            protect(threadID: threadID)
        }
        entries[threadID] = result
        touch(threadID)
        evictOverflow()
    }

    public mutating func protect(threadID: String) {
        protectionCounts[threadID, default: 0] += 1
        evictOverflow()
    }

    public mutating func unprotect(threadID: String) {
        let count = protectionCounts[threadID, default: 0]
        if count <= 1 { protectionCounts.removeValue(forKey: threadID) }
        else { protectionCounts[threadID] = count - 1 }
        evictOverflow()
    }

    public mutating func remove(threadID: String) {
        entries.removeValue(forKey: threadID)
        order.removeAll { $0 == threadID }
        protectionCounts.removeValue(forKey: threadID)
    }

    public mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        protectionCounts.removeAll()
    }

    private mutating func touch(_ threadID: String) {
        order.removeAll { $0 == threadID }
        order.append(threadID)
    }

    private mutating func evictOverflow() {
        while unprotectedEntryCount > capacity,
              let evicted = order.first(where: { !isProtected(threadID: $0) }) {
            order.removeAll { $0 == evicted }
            entries.removeValue(forKey: evicted)
        }
    }

    private var unprotectedEntryCount: Int {
        entries.keys.reduce(0) { count, threadID in
            count + (isProtected(threadID: threadID) ? 0 : 1)
        }
    }

    private mutating func evictUnprotectedEntries() {
        let protectedThreadIDs = Set(protectionCounts.keys)
        for threadID in Array(entries.keys) where !protectedThreadIDs.contains(threadID) {
            entries.removeValue(forKey: threadID)
        }
        order.removeAll { !protectedThreadIDs.contains($0) }
    }
}

public struct CodexThreadHistoryCacheProtectionLease: Sendable, Equatable {
    fileprivate let id: UInt64
    public let threadID: String
}

public struct CodexThreadHistoryCacheProtectionLeases: Sendable, Equatable {
    private var nextLeaseID: UInt64 = 0
    private var activeThreadIDsByLeaseID: [UInt64: String] = [:]

    public init() {}

    public var isEmpty: Bool {
        activeThreadIDsByLeaseID.isEmpty
    }

    public mutating func acquire(
        threadID: String,
        cache: inout CodexThreadHistoryCache
    ) -> CodexThreadHistoryCacheProtectionLease {
        let lease = CodexThreadHistoryCacheProtectionLease(id: nextLeaseID, threadID: threadID)
        nextLeaseID &+= 1
        activeThreadIDsByLeaseID[lease.id] = threadID
        cache.protect(threadID: threadID)
        return lease
    }

    @discardableResult
    public mutating func release(
        _ lease: CodexThreadHistoryCacheProtectionLease,
        cache: inout CodexThreadHistoryCache
    ) -> String? {
        guard let threadID = activeThreadIDsByLeaseID.removeValue(forKey: lease.id),
              threadID == lease.threadID else { return nil }
        cache.unprotect(threadID: threadID)
        return threadID
    }

    public mutating func releaseAll(cache: inout CodexThreadHistoryCache) {
        for threadID in activeThreadIDsByLeaseID.values {
            cache.unprotect(threadID: threadID)
        }
        activeThreadIDsByLeaseID.removeAll()
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
        result.paginationRaw = pagination.raw
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
        let transcriptTurns = Self.transcriptTurns(from: parentRaw)
        var reducer = CodexTranscriptReducerV2(threadID: hydration.parent.snapshot.id)
        reducer.restoreHistory(turns: transcriptTurns)
        let result = CodexThreadHistoryRestoreResult(
            snapshot: snapshot,
            hydration: hydration,
            restoredChildThreadCount: hydration.restoredChildThreadCount,
            transcriptItemsV2: transcriptTurns.flatMap { $0.items.map(\.rawValue) },
            transcriptV2: reducer.transcript
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

    private static func transcriptTurns(from raw: CodexJSONValue) -> [CodexSchemaTurn] {
        guard case .dictionary(let root) = raw else { return [] }
        let threadValue = root["thread"] ?? raw
        guard case .dictionary(let thread) = threadValue,
              case .array(let turns)? = thread["turns"] else { return [] }
        return turns.compactMap { try? $0.decode(CodexSchemaTurn.self) }
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

    public static func paginate(
        parentRaw: CodexJSONValue,
        retrying retryState: CodexThreadHistoryPaginationState? = nil,
        trace: CodexPerformanceTrace? = nil,
        loadPage: (String, String, String?) async throws -> CodexSchemaThreadItemsListResponse
    ) async -> (raw: CodexJSONValue, state: CodexThreadHistoryPaginationState) {
        guard case .dictionary(let response) = parentRaw else { return (parentRaw, .idle) }
        let wrapsThread = response["thread"] != nil
        guard case .dictionary(let thread) = wrapsThread ? response["thread"] : parentRaw,
              Self.string(thread["historyMode"]) == "paginated",
              let threadID = Self.string(thread["id"]),
              case .array(var turns)? = thread["turns"] else {
            return (parentRaw, .idle)
        }

        let span = trace?.begin("threadHistory.items.paginate", metadata: ["threadID": threadID])
        var loadedItemCount = retryState?.loadedItemCount ?? 0
        var nextCursorByTurnID: [String: String] = [:]
        var activeTurnID: String?
        var activeCursor: String?

        func responseValue() -> CodexJSONValue {
            var updatedThread = thread
            updatedThread["turns"] = .array(turns)
            var updatedResponse = response
            if wrapsThread { updatedResponse["thread"] = .dictionary(updatedThread) }
            else { updatedResponse = updatedThread }
            return .dictionary(updatedResponse)
        }

        let startIndex: Int
        if let retryTurnID = retryState?.retryTurnID,
           let index = turns.firstIndex(where: { value in
               guard case .dictionary(let turn) = value else { return false }
               return Self.string(turn["id"]) == retryTurnID
           }) {
            startIndex = index
        } else {
            startIndex = turns.startIndex
        }

        do {
            for turnIndex in turns.indices.dropFirst(startIndex) {
                guard case .dictionary(var turn) = turns[turnIndex],
                      let turnID = Self.string(turn["id"]) else { continue }
                activeTurnID = turnID
                var mergedItems: [CodexJSONValue]
                if case .array(let items)? = turn["items"] { mergedItems = items } else { mergedItems = [] }

                var cursor = turnID == retryState?.retryTurnID ? retryState?.retryCursor : nil
                var seenCursors: Set<String> = []
                if let cursor { seenCursors.insert(cursor) }
                repeat {
                    activeCursor = cursor
                    let page = try await loadPage(threadID, turnID, cursor)
                    mergedItems = mergePage(page.data.map(\.rawValue), into: mergedItems)
                    loadedItemCount += page.data.count
                    cursor = page.nextCursor
                    turn["items"] = .array(mergedItems)
                    turns[turnIndex] = .dictionary(turn)
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

                turn["itemsView"] = .string("full")
                turns[turnIndex] = .dictionary(turn)
            }
        } catch {
            let message = String(describing: error)
            span?.end(metadata: ["threadID": threadID, "outcome": "fallback", "error": message])
            let phase: CodexThreadHistoryPaginationState.Phase = isMethodUnavailable(error) ? .unavailable : .failed
            return (
                responseValue(),
                CodexThreadHistoryPaginationState(
                    phase: phase,
                    nextCursorByTurnID: nextCursorByTurnID,
                    loadedItemCount: loadedItemCount,
                    errorMessage: message,
                    retryTurnID: activeTurnID,
                    retryCursor: activeCursor
                )
            )
        }

        span?.end(metadata: ["threadID": threadID, "outcome": "success", "itemCount": "\(loadedItemCount)"])
        return (
            responseValue(),
            CodexThreadHistoryPaginationState(phase: .loaded, loadedItemCount: loadedItemCount)
        )
    }

    private static func mergePage(_ page: [CodexJSONValue], into existing: [CodexJSONValue]) -> [CodexJSONValue] {
        var result = existing
        for item in page {
            guard case .dictionary(let object) = item,
                  let id = string(object["id"]) else {
                result.append(item)
                continue
            }
            if let index = result.firstIndex(where: { existingItem in
                guard case .dictionary(let existingObject) = existingItem else { return false }
                return string(existingObject["id"]) == id
            }) {
                result[index] = item
            } else {
                result.append(item)
            }
        }
        return result
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
