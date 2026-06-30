import Foundation
import CodexCore

public struct CodexThreadHistoryRestoreResult: Sendable {
    public var snapshot: CodexThreadHistorySnapshot
    public var hydration: CodexThreadHistoryHydrationResult
    public var restoredChildThreadCount: Int

    public init(
        snapshot: CodexThreadHistorySnapshot,
        hydration: CodexThreadHistoryHydrationResult,
        restoredChildThreadCount: Int = 0
    ) {
        self.snapshot = snapshot
        self.hydration = hydration
        self.restoredChildThreadCount = restoredChildThreadCount
    }

    public var messageCount: Int {
        snapshot.messages.count
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
        let result = await restore(parentRaw: parentRaw, trace: trace) { childThreadID in
            try await readThreadRaw(threadID: childThreadID, using: codex)
        }
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
            restoredChildThreadCount: hydration.restoredChildThreadCount
        )
        snapshotSpan?.end(metadata: metadata(for: result))
        return result
    }

    @discardableResult
    public static func apply(
        _ result: CodexThreadHistoryRestoreResult,
        mainChatSession: inout CodexMainChatSession,
        agentStateMapper: inout CodexAgentStateMapper,
        sideChatSession: inout CodexSideChatSession
    ) -> CodexActivity {
        mainChatSession.resetTranscript(messages: result.snapshot.messages)
        agentStateMapper = result.snapshot.agentStateMapper
        sideChatSession.reset()
        return result.activity
    }

    private static func readThreadRaw(threadID: String, using codex: Codex) async throws -> CodexJSONValue {
        try CodexJSONValue(encoding: await codex.threadReadSchema(threadID, includeTurns: true))
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
