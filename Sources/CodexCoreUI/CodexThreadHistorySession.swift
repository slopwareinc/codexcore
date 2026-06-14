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
    public static func load(threadID: String, using codex: Codex) async throws -> CodexThreadHistoryRestoreResult {
        let parentRaw = try await readThreadRaw(threadID: threadID, using: codex)
        let result = await restore(parentRaw: parentRaw) { childThreadID in
            try await readThreadRaw(threadID: childThreadID, using: codex)
        }
        await MainActor.run {
            codex.store.hydrate(result.hydration)
        }
        return result
    }

    public static func restore(
        parentRaw: CodexJSONValue,
        loadChildThread: (String) async throws -> CodexJSONValue
    ) async -> CodexThreadHistoryRestoreResult {
        let parent = CodexThreadHistoryHydrator.decode(raw: parentRaw)
        var snapshot = CodexThreadHistorySnapshot(parentRaw: parentRaw, parent: parent)
        var childThreads: [CodexHydratedThread] = []
        var failedChildThreadIDs: [String] = []
        var restoredCount = 0
        var seenThreadIDs: Set<String> = []

        for childThreadID in parent.childThreadIDs where seenThreadIDs.insert(childThreadID).inserted {
            do {
                let childRaw = try await loadChildThread(childThreadID)
                childThreads.append(CodexThreadHistoryHydrator.decode(raw: childRaw, fallbackThreadID: childThreadID))
                if snapshot.applyChildThread(raw: childRaw, threadID: childThreadID) {
                    restoredCount += 1
                }
            } catch {
                failedChildThreadIDs.append(childThreadID)
            }
        }

        return CodexThreadHistoryRestoreResult(
            snapshot: snapshot,
            hydration: CodexThreadHistoryHydrationResult(
                parent: parent,
                childThreads: childThreads,
                failedChildThreadIDs: failedChildThreadIDs
            ),
            restoredChildThreadCount: restoredCount
        )
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
        try await codex.rawRequest(
            method: CodexAppServerClientMethod.threadRead.rawValue,
            params: [
                "threadId": .string(threadID),
                "includeTurns": .bool(true)
            ]
        )
    }
}
