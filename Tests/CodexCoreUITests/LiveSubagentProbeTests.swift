import XCTest
import CodexCore
@testable import CodexCoreUI

final class LiveSubagentProbeTests: XCTestCase {
    func testRealAppServerSubagentNotifications() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_REAL_SUBAGENT_PROBE"] == "1" else {
            throw XCTSkip("Set CODEX_REAL_SUBAGENT_PROBE=1 to run the live subagent app-server probe.")
        }

        let config = CodexConfig(
            cwd: FileManager.default.currentDirectoryPath,
            environment: ["CODEX_HOME": defaultCodexHome()],
            clientName: "codex_swift_live_subagent_probe",
            clientTitle: "Codex Swift Live Subagent Probe",
            clientVersion: "1.0.0"
        )
        let codex = try await Codex(config: config)
        defer { Task { await codex.close() } }

        let modes = try? await codex.rawRequest(method: "collaborationMode/list", params: [:])
        print("LIVE_SUBAGENT_PROBE binary=\((try? Codex.resolveCodexBinary(config: config).path) ?? "auto-resolved")")
        print("LIVE_SUBAGENT_PROBE collaborationMode/list=\(modes?.description ?? "nil")")

        let thread = try await codex.threadStart(
            approvalMode: .autoReview,
            cwd: FileManager.default.currentDirectoryPath,
            sandbox: .workspaceWrite
        )

        let prompt = "Use real Codex side chats or subagents if this app-server supports them. Run two delegated subagents in parallel: one should run a script that prints 1 through 3, the other should run a script that prints 20 through 22. Report both outputs after the side agents finish."
        let handle = try await thread.turn(
            [.text(prompt)],
            approvalMode: .autoReview,
            cwd: FileManager.default.currentDirectoryPath,
            sandbox: .workspaceWrite
        )

        let recorder = LiveSubagentProbeRecorder()
        let globalTask = Task {
            for await notification in codex.notifications() {
                await recorder.apply(notification, source: .global)
            }
        }
        defer { globalTask.cancel() }

        for await notification in handle.stream() {
            await recorder.apply(notification, source: .parentTurn)
        }

        try? await Task.sleep(nanoseconds: 500_000_000)
        globalTask.cancel()
        let snapshot = await recorder.snapshot()

        print("LIVE_SUBAGENT_PROBE methods=\(snapshot.methods)")
        print("LIVE_SUBAGENT_PROBE itemTypes=\(snapshot.itemTypes)")
        print("LIVE_SUBAGENT_PROBE childThreadIDs=\(snapshot.childThreadIDs.sorted())")
        print("LIVE_SUBAGENT_PROBE childTranscriptUpdateCount=\(snapshot.childTranscriptUpdateCount)")
        print("LIVE_SUBAGENT_PROBE assistantText=\(snapshot.assistantText)")
        print("LIVE_SUBAGENT_PROBE mappedLifecycle=\(snapshot.mapper.lifecycleEvents)")
        print("LIVE_SUBAGENT_PROBE mappedSubagents=\(snapshot.mapper.subagents)")

        XCTAssertFalse(snapshot.methods.isEmpty)
        XCTAssertTrue(snapshot.methods.contains { $0.contains(CodexAppServerNotificationMethod.turnCompleted.rawValue) }, "Real app-server stream did not deliver turn/completed. See LIVE_SUBAGENT_PROBE output.")
        XCTAssertTrue(snapshot.itemTypes.contains { $0.contains("collabAgentToolCall") }, "Real app-server stream did not emit collabAgentToolCall items. See LIVE_SUBAGENT_PROBE output.")
        XCTAssertGreaterThanOrEqual(snapshot.mapper.subagents.count, 2, "Real app-server stream did not produce two mappable subagents. See LIVE_SUBAGENT_PROBE output.")
        XCTAssertGreaterThan(snapshot.childTranscriptUpdateCount, 0, "Real app-server stream did not route any live child-thread transcript events. See LIVE_SUBAGENT_PROBE output.")
        XCTAssertFalse(snapshot.mapper.subagents.contains { $0.status == .running }, "Real app-server mapping left a subagent running after turn completion. See LIVE_SUBAGENT_PROBE output.")
        XCTAssertTrue(snapshot.mapper.subagents.contains { $0.messages.contains { $0.text.contains("1\n2\n3") } })
        XCTAssertTrue(snapshot.mapper.subagents.contains { $0.messages.contains { $0.text.contains("20\n21\n22") } })
    }
}

private enum LiveSubagentProbeSource: String, Sendable {
    case parentTurn
    case global
}

private struct LiveSubagentProbeSnapshot: Sendable {
    var mapper: CodexAgentStateMapper
    var methods: [String]
    var itemTypes: [String]
    var childThreadIDs: Set<String>
    var childTranscriptUpdateCount: Int
    var assistantText: String
}

private actor LiveSubagentProbeRecorder {
    private var mapper = CodexAgentStateMapper()
    private var methods: [String] = []
    private var itemTypes: [String] = []
    private var childThreadIDs: Set<String> = []
    private var childTranscriptUpdateCount = 0
    private var assistantText = ""

    func apply(_ notification: CodexNotification, source: LiveSubagentProbeSource) {
        methods.append("\(source.rawValue):\(notification.method)")
        switch notification.payload {
        case .itemStarted(let payload):
            itemTypes.append("\(source.rawValue):started:\(payload.item.type)")
            print("LIVE_SUBAGENT_PROBE \(source.rawValue) itemStarted thread=\(payload.threadId) type=\(payload.item.type) raw=\(payload.item.raw)")
            if source == .parentTurn, mapper.isSubagentItem(payload.item) {
                mapper.itemStarted(payload.item)
            } else if mapper.subagentItemStarted(threadID: payload.threadId, item: payload.item) != nil, payload.item.type != "turnStarted" {
                childTranscriptUpdateCount += payload.item.type == "agentMessage" || payload.item.type == "assistantMessage" ? 0 : 1
            }
        case .itemCompleted(let payload):
            itemTypes.append("\(source.rawValue):completed:\(payload.item.type)")
            print("LIVE_SUBAGENT_PROBE \(source.rawValue) itemCompleted thread=\(payload.threadId) type=\(payload.item.type) raw=\(payload.item.raw)")
            if source == .parentTurn, mapper.isSubagentItem(payload.item) {
                mapper.itemCompleted(payload.item)
            } else if mapper.subagentItemCompleted(threadID: payload.threadId, item: payload.item) != nil {
                childTranscriptUpdateCount += 1
            }
            if source == .parentTurn,
               payload.item.type == "agentMessage" || payload.item.type == "assistantMessage",
               let text = payload.item.text {
                mapper.assistantMessageCompleted(text)
            }
        case .agentMessageDelta(let delta):
            assistantText += delta.delta
            if source == .parentTurn {
                _ = mapper.messageDelta(delta.delta, itemID: delta.itemId)
            } else if mapper.subagentMessageDelta(delta.delta, threadID: delta.threadId, itemID: delta.itemId) {
                childTranscriptUpdateCount += 1
            }
        case .turnStarted(let payload):
            guard source == .global, let threadID = payload.threadId else { break }
            _ = mapper.subagentTurnStarted(threadID: threadID)
        case .turnCompleted(let payload):
            if source == .global {
                _ = mapper.subagentTurnCompleted(threadID: payload.threadId, error: payload.turn.error?.message)
            }
        case .known(let method, let params):
            print("LIVE_SUBAGENT_PROBE \(source.rawValue) known method=\(method.rawValue) params=\(params)")
            applyKnown(method, params: params, source: source)
        case .unknown(let method, let params):
            print("LIVE_SUBAGENT_PROBE \(source.rawValue) unknown method=\(method) params=\(params)")
            if let known = CodexAppServerNotificationMethod(rawValue: method) {
                applyKnown(known, params: params, source: source)
            }
        default:
            break
        }
    }

    func snapshot() -> LiveSubagentProbeSnapshot {
        LiveSubagentProbeSnapshot(
            mapper: mapper,
            methods: methods,
            itemTypes: itemTypes,
            childThreadIDs: childThreadIDs,
            childTranscriptUpdateCount: childTranscriptUpdateCount,
            assistantText: assistantText
        )
    }

    private func applyKnown(_ method: CodexAppServerNotificationMethod, params: [String: CodexJSONValue], source: LiveSubagentProbeSource) {
        switch method {
        case .threadStarted:
            guard let thread = probeDictionaryValue(params["thread"]),
                  probeStringValue(thread["parentThreadId"]) != nil,
                  let threadID = probeStringValue(thread["id"]) else {
                return
            }
            childThreadIDs.insert(threadID)
            _ = mapper.updateSubagentMetadata(
                id: threadID,
                name: probeStringValue(thread["agentNickname"]) ?? probeStringValue(thread["name"]),
                role: probeStringValue(thread["agentRole"])
            )
        case .itemCommandExecutionOutputDelta where source == .global:
            guard let threadID = probeThreadID(from: params),
                  let itemID = probeStringValue(params["itemId"]),
                  let delta = probeStringValue(params["delta"]),
                  mapper.subagentCommandOutputDelta(delta, threadID: threadID, itemID: itemID) else {
                return
            }
            childTranscriptUpdateCount += 1
        case .itemCommandExecutionTerminalInteraction where source == .global:
            guard let threadID = probeThreadID(from: params),
                  let itemID = probeStringValue(params["itemId"]),
                  let stdin = probeStringValue(params["stdin"]),
                  !stdin.isEmpty,
                  mapper.subagentCommandOutputDelta("\n$ \(stdin)", threadID: threadID, itemID: itemID) else {
                return
            }
            childTranscriptUpdateCount += 1
        case .turnCompleted where source == .global:
            guard let threadID = probeThreadID(from: params) else { return }
            _ = mapper.subagentTurnCompleted(threadID: threadID, error: probeTurnErrorMessage(from: params))
        default:
            break
        }
    }
}

private func probeThreadID(from params: [String: CodexJSONValue]) -> String? {
    if let direct = probeStringValue(params["threadId"]) { return direct }
    if let thread = probeDictionaryValue(params["thread"]), let nested = probeStringValue(thread["id"]) { return nested }
    return nil
}

private func probeTurnErrorMessage(from params: [String: CodexJSONValue]) -> String? {
    if let turn = probeDictionaryValue(params["turn"]) {
        if let error = probeDictionaryValue(turn["error"]) {
            return probeStringValue(error["message"]) ?? probeStringValue(error["raw"])
        }
        if let error = probeStringValue(turn["error"]) { return error }
    }
    if let error = probeDictionaryValue(params["error"]) {
        return probeStringValue(error["message"]) ?? probeStringValue(error["raw"])
    }
    return probeStringValue(params["error"])
}

private func probeStringValue(_ value: CodexJSONValue?) -> String? {
    switch value {
    case .string(let string): return string
    case .int(let int): return String(int)
    case .double(let double): return String(double)
    case .bool(let bool): return String(bool)
    case .array(let values): return values.compactMap(probeStringValue).joined(separator: " ")
    case .dictionary, .null, nil: return nil
    }
}

private func probeDictionaryValue(_ value: CodexJSONValue?) -> [String: CodexJSONValue]? {
    if case .dictionary(let object)? = value { return object }
    return nil
}
