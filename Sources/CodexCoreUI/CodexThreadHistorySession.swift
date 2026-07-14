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
    public var transcriptV2: CodexTranscriptV2

    public init(
        snapshot: CodexThreadHistorySnapshot,
        hydration: CodexThreadHistoryHydrationResult,
        restoredChildThreadCount: Int = 0,
        paginationState: CodexThreadHistoryPaginationState = .idle,
        transcriptV2: CodexTranscriptV2
    ) {
        self.snapshot = snapshot
        self.hydration = hydration
        self.restoredChildThreadCount = restoredChildThreadCount
        self.paginationState = paginationState
        self.transcriptV2 = transcriptV2
    }

    public var restoredTurnCount: Int {
        transcriptV2.turns.count
    }

    public var activity: CodexActivity {
        let agentDetail = restoredChildThreadCount > 0 ? ", \(restoredChildThreadCount) agents restored" : ""
        return CodexActivity(
            kind: .notice,
            title: "Loaded transcript",
            detail: "\(restoredTurnCount) turns restored\(agentDetail)"
        )
    }
}

public struct CodexThreadHistoryCache: Sendable {
    private let capacity: Int
    private var entries: [String: CodexThreadHistoryRestoreResult] = [:]
    private var order: [String] = []
    private var nextLeaseID: UInt64 = 0
    private var protectedThreadIDByLeaseID: [UInt64: String] = [:]

    public init(capacity: Int = 20) {
        self.capacity = max(0, capacity)
    }

    public var count: Int {
        entries.count
    }

    public func isProtected(threadID: String) -> Bool {
        protectedThreadIDByLeaseID.values.contains(threadID)
    }

    public mutating func result(for threadID: String) -> CodexThreadHistoryRestoreResult? {
        guard let result = entries[threadID] else { return nil }
        touch(threadID)
        return result
    }

    public mutating func store(_ result: CodexThreadHistoryRestoreResult) {
        let threadID = result.hydration.parent.snapshot.id
        guard capacity > 0 || isProtected(threadID: threadID) else {
            evictUnprotectedEntries()
            return
        }
        entries[threadID] = result
        touch(threadID)
        evictOverflow()
    }

    package mutating func acquireProtection(threadID: String) -> CodexThreadHistoryCacheLease {
        let lease = CodexThreadHistoryCacheLease(id: nextLeaseID, threadID: threadID)
        nextLeaseID &+= 1
        protectedThreadIDByLeaseID[lease.id] = threadID
        return lease
    }

    package mutating func releaseProtection(_ lease: CodexThreadHistoryCacheLease) {
        guard protectedThreadIDByLeaseID[lease.id] == lease.threadID else { return }
        protectedThreadIDByLeaseID.removeValue(forKey: lease.id)
        evictOverflow()
    }

    public mutating func remove(threadID: String) {
        entries.removeValue(forKey: threadID)
        order.removeAll { $0 == threadID }
        protectedThreadIDByLeaseID = protectedThreadIDByLeaseID.filter { $0.value != threadID }
    }

    public mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        protectedThreadIDByLeaseID.removeAll()
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
        let protectedThreadIDs = Set(protectedThreadIDByLeaseID.values)
        for threadID in Array(entries.keys) where !protectedThreadIDs.contains(threadID) {
            entries.removeValue(forKey: threadID)
        }
        order.removeAll { !protectedThreadIDs.contains($0) }
    }
}

package struct CodexThreadHistoryCacheLease: Sendable, Equatable {
    fileprivate let id: UInt64
    package let threadID: String
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
        let transcriptTurns = Self.transcriptTurns(from: parentRaw)
        var reducer = CodexTranscriptReducerV2(threadID: hydration.parent.snapshot.id)
        reducer.restoreHistory(turns: transcriptTurns)
        let result = CodexThreadHistoryRestoreResult(
            snapshot: snapshot,
            hydration: hydration,
            restoredChildThreadCount: hydration.restoredChildThreadCount,
            transcriptV2: reducer.transcript
        )
        snapshotSpan?.end(metadata: metadata(for: result))
        return result
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

    static func paginate(
        parentRaw: CodexJSONValue,
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
        var loadedItemCount = 0
        var nextCursorByTurnID: [String: String] = [:]

        func responseValue() -> CodexJSONValue {
            var updatedThread = thread
            updatedThread["turns"] = .array(turns)
            var updatedResponse = response
            if wrapsThread { updatedResponse["thread"] = .dictionary(updatedThread) }
            else { updatedResponse = updatedThread }
            return .dictionary(updatedResponse)
        }

        do {
            for turnIndex in turns.indices {
                guard case .dictionary(var turn) = turns[turnIndex],
                      let turnID = Self.string(turn["id"]) else { continue }
                var mergedItems: [CodexJSONValue]
                if case .array(let items)? = turn["items"] { mergedItems = items } else { mergedItems = [] }

                var cursor: String?
                var seenCursors: Set<String> = []
                repeat {
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
                    errorMessage: message
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
            "itemCount": "\(result.hydration.parent.snapshot.turns.reduce(0) { $0 + $1.items.count })",
            "turnCount": "\(result.restoredTurnCount)",
            "restoredChildThreadCount": "\(result.restoredChildThreadCount)",
            "failedChildThreadCount": "\(result.hydration.failedChildThreadIDs.count)"
        ]
    }

    private static func errorType(_ error: Error) -> String {
        String(describing: type(of: error))
    }
}
