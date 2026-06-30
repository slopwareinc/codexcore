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

public enum CodexThreadHistorySession {
    public static func load(
        threadID: String,
        using codex: Codex,
        trace: CodexPerformanceTrace? = nil
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
        return await load(parentRaw: parentRaw, using: codex, trace: trace)
    }

    public static func load(
        parentRaw: CodexJSONValue,
        using codex: Codex,
        trace: CodexPerformanceTrace? = nil
    ) async -> CodexThreadHistoryRestoreResult {
        let result = await restore(parentRaw: parentRaw, trace: trace) { childThreadID in
            try await readThreadRaw(threadID: childThreadID, using: codex)
        }
        return await hydrateStore(result, using: codex, trace: trace)
    }

    private static func hydrateStore(
        _ result: CodexThreadHistoryRestoreResult,
        using codex: Codex,
        trace: CodexPerformanceTrace?
    ) async -> CodexThreadHistoryRestoreResult {
        let storeHydrateSpan = trace?.begin("threadHistory.store.hydrate", metadata: metadata(for: result))
        await MainActor.run {
            codex.store.hydrate(result.hydration)
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
