import Foundation
import CodexCore

public struct CodexThreadHistoryRestoreResult: Sendable {
    public var snapshot: CodexThreadHistorySnapshot
    public var restoredChildThreadCount: Int

    public init(snapshot: CodexThreadHistorySnapshot, restoredChildThreadCount: Int = 0) {
        self.snapshot = snapshot
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
        return await restore(parentRaw: parentRaw) { childThreadID in
            try await readThreadRaw(threadID: childThreadID, using: codex)
        }
    }

    public static func restore(
        parentRaw: CodexJSONValue,
        loadChildThread: (String) async throws -> CodexJSONValue
    ) async -> CodexThreadHistoryRestoreResult {
        var snapshot = CodexThreadHistorySnapshot(raw: parentRaw)
        var restoredCount = 0
        var seenThreadIDs: Set<String> = []

        for childThreadID in snapshot.subagentThreadIDs where seenThreadIDs.insert(childThreadID).inserted {
            do {
                let childRaw = try await loadChildThread(childThreadID)
                if snapshot.applyChildThread(raw: childRaw, threadID: childThreadID) {
                    restoredCount += 1
                }
            } catch {
                continue
            }
        }

        return CodexThreadHistoryRestoreResult(snapshot: snapshot, restoredChildThreadCount: restoredCount)
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
