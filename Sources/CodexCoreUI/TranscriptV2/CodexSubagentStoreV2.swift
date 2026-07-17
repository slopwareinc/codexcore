import CodexCore
import Foundation

public enum CodexSubagentLiveStatusV2: Sendable, Equatable {
    case pending
    case working(since: Int64?)
    case completed(durationMs: Int?)
    case closed
    case failed(message: String)
}

/// Disposable UI projection for one child app-server thread.
///
/// The canonical session remains the only protocol truth. In particular this
/// value stores a projected transcript, never a reducer or raw event buffer.
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
    public var transcript: CodexTranscriptV2
    public var createdAt: Date
    public var completedAt: Date?

    public init(
        threadID: String,
        agentPath: String? = nil,
        nickname: String? = nil,
        role: String? = nil,
        prompt: String? = nil,
        depth: Int = 1,
        parentThreadID: String? = nil,
        status: CodexSubagentLiveStatusV2 = .pending,
        transcript: CodexTranscriptV2 = .init(),
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.threadID = threadID
        self.agentPath = agentPath
        self.nickname = nickname
        self.role = role
        self.prompt = prompt
        self.depth = depth
        self.parentThreadID = parentThreadID
        self.status = status
        self.transcript = transcript
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    public var displayName: String {
        if let nickname, !nickname.isEmpty { return nickname }
        let raw = agentPath?.split(separator: "/").last.map(String.init)
            ?? "agent-\(threadID.split(separator: "-").first ?? Substring(threadID))"
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

extension CodexSubagentV2 {
    var panelStatus: CodexSubagentState.Status {
        switch status {
        case .pending, .working: .running
        case .completed: .completed
        case .closed: .closed
        case .failed: .failed
        }
    }
}

public struct CodexSubagentDiscoveryV2: Sendable, Equatable {
    public var threadID: String
    public var parentThreadID: String?
    public var agentPath: String?
    public var prompt: String?

    public init(
        threadID: String,
        parentThreadID: String? = nil,
        agentPath: String? = nil,
        prompt: String? = nil
    ) {
        self.threadID = threadID
        self.parentThreadID = parentThreadID
        self.agentPath = agentPath
        self.prompt = prompt
    }
}

/// A rebuildable child-thread projection cache.
///
/// Parent snapshots only discover children and update collaboration lifecycle.
/// Child transcript content is accepted exclusively from that child's scoped
/// canonical snapshot, normally while a `CodexThreadLease` is held by
/// `CodexSubagentPresentationCoordinator`.
public struct CodexSubagentStoreV2: Sendable {
    private var agentsByID: [String: CodexSubagentV2] = [:]
    private var discoveriesByID: [String: CodexSubagentDiscoveryV2] = [:]
    private let projector = CodexCanonicalTranscriptProjector()

    public init() {}

    public var agents: [CodexSubagentV2] {
        agentsByID.values.sorted {
            let lhs = $0.agentPath ?? "~\($0.threadID)"
            let rhs = $1.agentPath ?? "~\($1.threadID)"
            return lhs == rhs ? $0.threadID < $1.threadID : lhs < rhs
        }
    }

    public var threadIDs: [ThreadID] {
        agents.map { ThreadID($0.threadID) }
    }

    public var workingCount: Int {
        agents.reduce(0) { count, agent in
            switch agent.status {
            case .working, .pending: count + 1
            case .completed, .closed, .failed: count
            }
        }
    }

    public func agent(threadID: String) -> CodexSubagentV2? { agentsByID[threadID] }
    public func contains(threadID: String) -> Bool { agentsByID[threadID] != nil }

    /// Discovers direct children from parent collaboration items. This works at
    /// the exact frame that announces a child, before thread metadata arrives.
    @discardableResult
    public mutating func applyParentSnapshot(
        _ snapshot: CanonicalStateSnapshot,
        parentThreadID: ThreadID
    ) -> [CodexSubagentDiscoveryV2] {
        var currentDiscoveries: [String: CodexSubagentDiscoveryV2] = [:]
        var closeStates: [String: CodexSubagentLiveStatusV2] = [:]

        for item in orderedItems(snapshot, threadID: parentThreadID) {
            switch item.kind {
            case .collabAgentToolCall:
                let ids = item.payload.stringArray("receiverThreadIds")
                for id in ids {
                    let path = discoveriesByID[id]?.agentPath
                    let prompt = item.payload.string("prompt") ?? discoveriesByID[id]?.prompt
                    let discovery = CodexSubagentDiscoveryV2(
                        threadID: id,
                        parentThreadID: parentThreadID.rawValue,
                        agentPath: path,
                        prompt: prompt
                    )
                    _ = register(discovery)
                    currentDiscoveries[id] = discoveriesByID[id] ?? discovery
                }
                applyAgentStatePayload(item.payload.object("agentsStates"))
                if item.payload.string("tool") == "closeAgent", item.authority == .completed {
                    for id in ids { closeStates[id] = .closed }
                }

            case .subAgentActivity:
                guard let id = item.payload.string("agentThreadId") else { continue }
                let path = item.payload.string("agentPath")
                let discovery = CodexSubagentDiscoveryV2(
                    threadID: id,
                    parentThreadID: parentThreadID.rawValue,
                    agentPath: path,
                    prompt: discoveriesByID[id]?.prompt
                )
                _ = register(discovery)
                currentDiscoveries[id] = discoveriesByID[id] ?? discovery

            default:
                continue
            }
        }

        for (id, status) in closeStates { agentsByID[id]?.status = status }
        return currentDiscoveries.values.sorted { $0.threadID < $1.threadID }
    }

    /// Adds relationship and identity facts from the lightweight canonical
    /// thread index without copying any child turns or items.
    @discardableResult
    public mutating func applyThreadIndex(
        _ index: CanonicalThreadIndexSnapshot,
        parentThreadID: ThreadID
    ) -> [CodexSubagentDiscoveryV2] {
        var currentDiscoveries: [CodexSubagentDiscoveryV2] = []
        for summary in index.threads where summary.parentThreadID == parentThreadID {
            let id = summary.id.rawValue
            let discovery = CodexSubagentDiscoveryV2(
                threadID: id,
                parentThreadID: parentThreadID.rawValue,
                agentPath: summary.path,
                prompt: discoveriesByID[id]?.prompt
            )
            _ = register(discovery)
            currentDiscoveries.append(discoveriesByID[id] ?? discovery)
            updateMetadata(
                threadID: id,
                nickname: summary.agentNickname,
                role: summary.agentRole,
                prompt: nil,
                agentPath: summary.path,
                parentThreadID: parentThreadID.rawValue
            )
            if let status = Self.status(from: summary),
               !Self.isClosed(agentsByID[id]?.status) {
                agentsByID[id]?.status = status
            }
        }
        return currentDiscoveries.sorted { $0.threadID < $1.threadID }
    }

    /// Projects one child's exact scoped canonical snapshot. No parent event is
    /// replayed into this method and no transcript data is synthesized.
    @discardableResult
    public mutating func applyChildSnapshot(
        _ snapshot: CanonicalStateSnapshot,
        threadID: ThreadID
    ) -> Bool {
        let id = threadID.rawValue
        guard let thread = snapshot.threads[threadID] else { return false }
        if agentsByID[id] == nil {
            _ = register(.init(
                threadID: id,
                parentThreadID: thread.metadata.parentThreadID?.rawValue,
                agentPath: thread.metadata.path
            ))
        }
        guard var agent = agentsByID[id] else { return false }

        agent.nickname = thread.metadata.agentNickname ?? agent.nickname
        agent.role = thread.metadata.agentRole ?? agent.role
        agent.agentPath = thread.metadata.path ?? agent.agentPath
        agent.parentThreadID = thread.metadata.parentThreadID?.rawValue ?? agent.parentThreadID
        agent.depth = agent.agentPath.map(Self.depth) ?? agent.depth
        if !Self.isClosed(agent.status) {
            agent.status = Self.status(
                thread: thread,
                turns: snapshot.turns(in: threadID),
                fallback: agent.status
            )
        }
        agent.transcript = projector.rebuild(
            snapshot: snapshot,
            threadID: threadID
        ).presentation.transcript
        if let createdAt = thread.metadata.createdAt?.rawValue {
            agent.createdAt = Date(timeIntervalSince1970: TimeInterval(createdAt))
        }
        agent.completedAt = snapshot.turns(in: threadID).last?.completedAt.map {
            Date(timeIntervalSince1970: TimeInterval($0.rawValue))
        }
        agentsByID[id] = agent
        return true
    }

    /// Drops only the heavy transcript projection. Identity and live status stay
    /// available for the overview and can be rehydrated by reacquiring a lease.
    public mutating func evictTranscript(threadID: ThreadID) {
        agentsByID[threadID.rawValue]?.transcript = .init()
    }

    public mutating func updateStatus(
        threadID: ThreadID,
        status: CodexSubagentLiveStatusV2
    ) {
        agentsByID[threadID.rawValue]?.status = status
    }

    public mutating func remove(threadID: ThreadID) {
        agentsByID.removeValue(forKey: threadID.rawValue)
        discoveriesByID.removeValue(forKey: threadID.rawValue)
    }

    public mutating func removeAll() {
        agentsByID.removeAll(keepingCapacity: false)
        discoveriesByID.removeAll(keepingCapacity: false)
    }

    public mutating func updateMetadata(
        threadID: String,
        nickname: String?,
        role: String?,
        prompt: String? = nil,
        agentPath: String?,
        parentThreadID: String?
    ) {
        if agentsByID[threadID] == nil {
            _ = register(.init(
                threadID: threadID,
                parentThreadID: parentThreadID,
                agentPath: agentPath,
                prompt: prompt
            ))
        }
        guard var agent = agentsByID[threadID] else { return }
        agent.nickname = nickname ?? agent.nickname
        agent.role = role ?? agent.role
        agent.prompt = prompt ?? agent.prompt
        agent.agentPath = agentPath ?? agent.agentPath
        agent.depth = agentPath.map(Self.depth) ?? agent.depth
        agent.parentThreadID = parentThreadID ?? agent.parentThreadID
        agentsByID[threadID] = agent
    }
}

private extension CodexSubagentStoreV2 {
    mutating func register(_ discovery: CodexSubagentDiscoveryV2) -> Bool {
        let id = discovery.threadID
        let isNew = agentsByID[id] == nil
        let prior = discoveriesByID[id]
        let merged = CodexSubagentDiscoveryV2(
            threadID: id,
            parentThreadID: discovery.parentThreadID ?? prior?.parentThreadID,
            agentPath: discovery.agentPath ?? prior?.agentPath,
            prompt: discovery.prompt ?? prior?.prompt
        )
        discoveriesByID[id] = merged

        if var agent = agentsByID[id] {
            agent.parentThreadID = merged.parentThreadID ?? agent.parentThreadID
            agent.agentPath = merged.agentPath ?? agent.agentPath
            agent.prompt = merged.prompt ?? agent.prompt
            agent.depth = agent.agentPath.map(Self.depth) ?? agent.depth
            agentsByID[id] = agent
        } else {
            agentsByID[id] = CodexSubagentV2(
                threadID: id,
                agentPath: merged.agentPath,
                prompt: merged.prompt,
                depth: merged.agentPath.map(Self.depth) ?? 1,
                parentThreadID: merged.parentThreadID
            )
        }
        return isNew
    }

    mutating func applyAgentStatePayload(_ states: [String: CodexJSONValue]?) {
        guard let states else { return }
        for (id, rawState) in states {
            guard let state = CodexJSONCoercion.dictionary(from: rawState),
                  let rawStatus = state.string("status")?.lowercased(),
                  agentsByID[id] != nil else { continue }
            switch rawStatus {
            case "completed", "done":
                agentsByID[id]?.status = .completed(durationMs: nil)
            case "failed", "error":
                agentsByID[id]?.status = .failed(
                    message: state.string("message") ?? "Subagent failed"
                )
            case "closed", "shutdown":
                agentsByID[id]?.status = .closed
            case "running", "working":
                agentsByID[id]?.status = .working(since: nil)
            default:
                break
            }
        }
    }

    func orderedItems(
        _ snapshot: CanonicalStateSnapshot,
        threadID: ThreadID
    ) -> [CanonicalItem] {
        snapshot.turns(in: threadID).flatMap { snapshot.items(in: $0.key) }
    }

    static func status(
        from summary: CanonicalThreadIndexSummary
    ) -> CodexSubagentLiveStatusV2? {
        if summary.status.isActive || summary.latestTurnStatus == .inProgress {
            return .working(since: nil)
        }
        switch summary.latestTurnStatus {
        case .completed: return .completed(durationMs: nil)
        case .failed: return .failed(message: "Subagent failed")
        case .interrupted: return .failed(message: "Subagent interrupted")
        case .inProgress: return .working(since: nil)
        case .unknown, nil: return nil
        }
    }

    static func status(
        thread: CanonicalThread,
        turns: [CanonicalTurn],
        fallback: CodexSubagentLiveStatusV2
    ) -> CodexSubagentLiveStatusV2 {
        guard let turn = turns.last else {
            return thread.status.isActive ? .working(since: nil) : fallback
        }
        switch turn.status {
        case .inProgress:
            return .working(since: turn.startedAt?.rawValue)
        case .completed:
            return .completed(durationMs: turn.duration.map { Int(clamping: $0.rawValue) })
        case .failed:
            return .failed(message: turn.error?.message ?? "Subagent failed")
        case .interrupted:
            return .failed(message: turn.error?.message ?? "Subagent interrupted")
        case .unknown:
            return thread.status.isActive ? .working(since: turn.startedAt?.rawValue) : fallback
        }
    }

    static func depth(_ path: String) -> Int {
        max(1, path.split(separator: "/").count - 1)
    }

    static func isClosed(_ status: CodexSubagentLiveStatusV2?) -> Bool {
        guard case .closed? = status else { return false }
        return true
    }
}

private extension Dictionary where Key == String, Value == CodexJSONValue {
    func string(_ key: String) -> String? {
        CodexJSONCoercion.flatString(from: self[key])
    }

    func object(_ key: String) -> [String: CodexJSONValue]? {
        CodexJSONCoercion.dictionary(from: self[key])
    }

    func stringArray(_ key: String) -> [String] {
        CodexJSONCoercion.stringArray(in: self, key: key)
    }
}
