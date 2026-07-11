import CodexCore
import Foundation

public enum CodexSubagentLiveStatusV2: Sendable, Equatable {
    case pending
    case working(since: Int64?)
    case completed(durationMs: Int?)
    case failed(message: String)
}

public struct CodexSubagentV2: Identifiable, Sendable {
    public var id: String { threadID }
    public let threadID: String
    public var agentPath: String?
    public var nickname: String?
    public var role: String?
    public var prompt: String?
    public var depth: Int
    public var parentThreadID: String?
    public var status: CodexSubagentLiveStatusV2
    public var reducer: CodexTranscriptReducerV2

    public var transcript: CodexTranscriptV2 { reducer.transcript }
    public var displayName: String {
        if let nickname, !nickname.isEmpty { return nickname }
        let raw = agentPath?.split(separator: "/").last.map(String.init) ?? "agent-\(threadID.split(separator: "-").first ?? Substring(threadID))"
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

extension CodexSubagentV2 {
    var legacyStatus: CodexSubagentState.Status {
        switch status {
        case .pending, .working: return .running
        case .completed: return .completed
        case .failed: return .failed
        }
    }
}

public struct CodexSubagentDiscoveryV2: Sendable, Equatable {
    public var threadID: String
    public var parentThreadID: String?
    public var agentPath: String?
}

public struct CodexSubagentStoreV2: Sendable {
    private var agentsByID: [String: CodexSubagentV2] = [:]

    public init() {}

    public var agents: [CodexSubagentV2] {
        agentsByID.values.sorted {
            let lhs = $0.agentPath ?? "~\($0.threadID)"
            let rhs = $1.agentPath ?? "~\($1.threadID)"
            return lhs == rhs ? $0.threadID < $1.threadID : lhs < rhs
        }
    }

    public var workingCount: Int {
        agents.reduce(0) { count, agent in
            switch agent.status { case .working, .pending: count + 1; default: count }
        }
    }

    public func agent(threadID: String) -> CodexSubagentV2? { agentsByID[threadID] }
    public func contains(threadID: String) -> Bool { agentsByID[threadID] != nil }

    @discardableResult
    public mutating func apply(method: String, params: CodexJSONValue) -> [CodexSubagentDiscoveryV2] {
        guard case .dictionary(let root) = params else { return [] }
        var discoveries: [CodexSubagentDiscoveryV2] = []
        if let item = object(root["item"]) {
            if item.string("type") == "collabAgentToolCall" {
                for id in strings(item["receiverThreadIds"]) {
                    if register(threadID: id, parentThreadID: root.string("threadId"), agentPath: nil, prompt: item.string("prompt")) {
                        discoveries.append(.init(threadID: id, parentThreadID: root.string("threadId"), agentPath: nil))
                    }
                }
                if root.string("method") == nil, item.string("status") == "completed" {
                    let tool = item.string("tool")
                    for id in strings(item["receiverThreadIds"]) where tool == "wait" || tool == "closeAgent" {
                        if let agent = agentsByID[id] {
                            switch agent.status {
                            case .pending, .working: agentsByID[id]?.status = .completed(durationMs: nil)
                            case .completed, .failed: break
                            }
                        }
                    }
                }
            } else if item.string("type") == "subAgentActivity", let id = item.string("agentThreadId") {
                let path = item.string("agentPath")
                if register(threadID: id, parentThreadID: root.string("threadId"), agentPath: path, prompt: item.string("prompt")) {
                    discoveries.append(.init(threadID: id, parentThreadID: root.string("threadId"), agentPath: path))
                } else if let path { agentsByID[id]?.agentPath = path; agentsByID[id]?.depth = Self.depth(path) }
            }
        }

        let eventThreadID = root.string("threadId") ?? object(root["turn"])?.string("threadId")
        if let eventThreadID, var agent = agentsByID[eventThreadID] {
            agent.reducer.apply(method: method, params: params)
            agent.status = Self.status(from: agent.reducer.transcript, fallback: agent.status)
            agentsByID[eventThreadID] = agent
        }
        return discoveries
    }

    @discardableResult
    public mutating func register(threadID: String, parentThreadID: String?, agentPath: String? = nil, prompt: String? = nil) -> Bool {
        guard agentsByID[threadID] == nil else { return false }
        agentsByID[threadID] = CodexSubagentV2(threadID: threadID, agentPath: agentPath, nickname: nil, role: nil, prompt: prompt, depth: agentPath.map(Self.depth) ?? 1, parentThreadID: parentThreadID, status: .pending, reducer: CodexTranscriptReducerV2(threadID: threadID))
        return true
    }

    public mutating func updateMetadata(threadID: String, nickname: String?, role: String?, prompt: String? = nil, agentPath: String?, depth: Int?, parentThreadID: String?) {
        if agentsByID[threadID] == nil { _ = register(threadID: threadID, parentThreadID: parentThreadID, agentPath: agentPath, prompt: prompt) }
        guard var agent = agentsByID[threadID] else { return }
        agent.nickname = nickname ?? agent.nickname; agent.role = role ?? agent.role
        agent.prompt = prompt ?? agent.prompt
        agent.agentPath = agentPath ?? agent.agentPath; agent.depth = depth ?? agentPath.map(Self.depth) ?? agent.depth
        agent.parentThreadID = parentThreadID ?? agent.parentThreadID; agentsByID[threadID] = agent
    }

    private static func depth(_ path: String) -> Int { max(0, path.split(separator: "/").count - 1) }
    private static func status(from transcript: CodexTranscriptV2, fallback: CodexSubagentLiveStatusV2) -> CodexSubagentLiveStatusV2 {
        guard let turn = transcript.turns.last else { return fallback }
        switch turn.status {
        case .working(let since): return .working(since: since)
        case .done(let duration): return .completed(durationMs: duration)
        case .failed(let message): return .failed(message: message)
        }
    }
}

private func object(_ value: CodexJSONValue?) -> [String: CodexJSONValue]? { guard case .dictionary(let object) = value else { return nil }; return object }
private func strings(_ value: CodexJSONValue?) -> [String] { guard case .array(let values) = value else { return [] }; return values.compactMap { if case .string(let value) = $0 { value } else { nil } } }
private extension Dictionary where Key == String, Value == CodexJSONValue { func string(_ key: String) -> String? { if case .string(let value) = self[key] { value } else { nil } } }
