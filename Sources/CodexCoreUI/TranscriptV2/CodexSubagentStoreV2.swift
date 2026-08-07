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
        // Native UI derives child labels from the agent path when present
        // (for example `/root/tiny_test` -> `Tiny test`), then falls back to
        // the nickname for detached/index-only threads.
        let raw = agentPath?.split(separator: "/").last.map(String.init)
            ?? (nickname?.isEmpty == false ? nickname : nil)
            ?? "agent-\(threadID.split(separator: "-").first ?? Substring(threadID))"
        let normalized = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.lowercased() }
            .joined(separator: " ")
        return normalized.prefix(1).uppercased() + normalized.dropFirst()
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

private extension CodexSubagentLiveStatusV2 {
    var isActive: Bool {
        switch self {
        case .pending, .working: true
        case .completed, .closed, .failed: false
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

/// The small child-thread slice needed by MainActor lifecycle presentation.
///
/// The latest turn follows canonical `turnOrder` exactly and is resolved with
/// one dictionary lookup. Transcript projection still receives the full
/// immutable snapshot off-main.
struct CodexSubagentChildSnapshotSummary: Sendable, Equatable {
    var threadID: ThreadID
    var metadata: CanonicalThreadMetadata
    var threadStatus: CanonicalThreadStatus
    var latestTurn: CanonicalTurn?

    init?(
        snapshot: CanonicalStateSnapshot,
        threadID: ThreadID
    ) {
        guard let thread = snapshot.threads[threadID] else { return nil }
        let latestTurn = thread.turnOrder.last.flatMap { turnID in
            snapshot.turns[TurnKey(threadID: threadID, turnID: turnID)]
        }

        self.threadID = threadID
        self.metadata = thread.metadata
        self.threadStatus = thread.status
        self.latestTurn = latestTurn
    }
}

extension CodexSubagentStoreV2 {
    /// Pure hydration check used from the detached child-projection operation.
    static func isTerminalAndHydrated(
        _ snapshot: CanonicalStateSnapshot,
        summary: CodexSubagentChildSnapshotSummary
    ) -> Bool {
        guard let thread = snapshot.threads[summary.threadID] else { return false }
        let latestTurn = summary.latestTurn
        guard let latestTurn, latestTurn.status.isTerminal else { return false }
        if thread.history.turnsCoverage == .full {
            let earlierMaterializedTurnsAreFull = thread.turnOrder.dropLast().allSatisfy {
                guard let turn = snapshot.turns[
                    TurnKey(threadID: thread.id, turnID: $0)
                ] else {
                    // `CanonicalStateSnapshot.turns(in:)` omitted absent turns;
                    // keep that established hydration behavior in the detached
                    // completion calculation.
                    return true
                }
                return turn.itemsCoverage == .full
            }
            return earlierMaterializedTurnsAreFull
                && latestTurn.itemsCoverage == .full
        }
        // Live child threads can be complete before they have ever needed a
        // history resume. An authoritative terminal turn is already sufficient.
        return latestTurn.itemsConsistency == .authoritative
            && latestTurn.itemsCoverage == .full
    }
}

/// Lightweight child identity and lifecycle state.
///
/// Parent snapshots only discover children and update collaboration lifecycle.
/// The production coordinator overlays its sole selected transcript without
/// retaining child presentations here. `applyChildSnapshot` remains a standalone
/// value API for hosts that render `CodexSubagentsPanelV2` directly.
public struct CodexSubagentStoreV2: Sendable {
    private struct IndexedMetadata: Sendable {
        var nickname: String?
        var role: String?
        var path: String?
        var parentThreadID: String?
    }

    private var agentsByID: [String: CodexSubagentV2] = [:]
    private var discoveriesByID: [String: CodexSubagentDiscoveryV2] = [:]
    // Thread-list metadata can arrive before the parent snapshot establishes
    // the relationship. Cache it so the first lightweight child discovery can
    // publish its friendly name/status without opening the child transcript.
    private var indexedMetadataByID: [String: IndexedMetadata] = [:]

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
            case .working: count + 1
            case .pending, .completed, .closed, .failed: count
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
                    let prompt = item.payload.string("tool") == "spawnAgent"
                        ? item.payload.string("prompt")
                        : discoveriesByID[id]?.prompt
                    let discovery = CodexSubagentDiscoveryV2(
                        threadID: id,
                        parentThreadID: parentThreadID.rawValue,
                        agentPath: path,
                        prompt: prompt
                    )
                    _ = register(discovery)
                    applyIndexedMetadataIfAvailable(
                        id: id,
                        fallbackParentThreadID: parentThreadID.rawValue
                    )
                    currentDiscoveries[id] = discoveriesByID[id] ?? discovery
                }
                let states = item.payload.object("agentsStates")
                registerAgentStateIDs(states, parentThreadID: parentThreadID)
                if let states {
                    for id in states.keys {
                        let discovery = CodexSubagentDiscoveryV2(
                            threadID: id,
                            parentThreadID: parentThreadID.rawValue,
                            agentPath: discoveriesByID[id]?.agentPath,
                            prompt: discoveriesByID[id]?.prompt
                        )
                        currentDiscoveries[id] = discoveriesByID[id] ?? discovery
                    }
                }
                applyCollaborationToolState(
                    item.payload,
                    receiverThreadIDs: ids
                )
                applyAgentStatePayload(states)
                if item.payload.string("tool") == "wait",
                   item.payload.string("status")?.lowercased() == "completed"
                {
                    applyCompletedWaitState(receiverThreadIDs: ids)
                }
                if item.payload.string("tool") == "closeAgent",
                   item.authority == .completed,
                   item.payload.string("status")?.lowercased() == "completed"
                {
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
                applyIndexedMetadataIfAvailable(
                    id: id,
                    fallbackParentThreadID: parentThreadID.rawValue
                )
                currentDiscoveries[id] = discoveriesByID[id] ?? discovery
                applySubagentActivityState(item.payload, threadID: id)

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
        for summary in index.threads {
            let id = summary.id.rawValue
            indexedMetadataByID[id] = IndexedMetadata(
                nickname: summary.agentNickname,
                role: summary.agentRole,
                path: summary.agentPath,
                parentThreadID: summary.parentThreadID?.rawValue
            )
            let knownChild = discoveriesByID[id]?.parentThreadID == parentThreadID.rawValue
                || agentsByID[id]?.parentThreadID == parentThreadID.rawValue
            guard summary.parentThreadID == parentThreadID || knownChild else { continue }
            let discovery = CodexSubagentDiscoveryV2(
                threadID: id,
                parentThreadID: parentThreadID.rawValue,
                agentPath: summary.agentPath,
                prompt: discoveriesByID[id]?.prompt
            )
            _ = register(discovery)
            currentDiscoveries.append(discoveriesByID[id] ?? discovery)
            updateMetadata(
                threadID: id,
                nickname: summary.agentNickname,
                role: summary.agentRole,
                prompt: nil,
                agentPath: summary.agentPath,
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
        guard let summary = CodexSubagentChildSnapshotSummary(
            snapshot: snapshot,
            threadID: threadID
        ), applyChildSnapshotMetadata(summary) else {
            return false
        }
        let result: CodexCanonicalTranscriptProjectionResult
        do {
            result = try Self.projectChildSnapshot(
                snapshot,
                threadID: threadID,
                previous: nil
            )
        } catch {
            return false
        }
        agentsByID[threadID.rawValue]?.transcript = result.presentation.transcript
        return true
    }

    /// Applies only the inexpensive identity and lifecycle portion of a child
    /// snapshot. The coordinator performs transcript projection off-main and
    /// owns the selected transcript outside this metadata store.
    @discardableResult
    mutating func applyChildSnapshotMetadata(
        _ summary: CodexSubagentChildSnapshotSummary
    ) -> Bool {
        applyChildSnapshotMetadataReportingChanges(summary) != nil
    }

    /// Returns nil only when the child cannot be materialized; otherwise the
    /// value reports whether visible identity or lifecycle metadata changed.
    mutating func applyChildSnapshotMetadataReportingChanges(
        _ summary: CodexSubagentChildSnapshotSummary
    ) -> Bool? {
        let threadID = summary.threadID
        let id = threadID.rawValue
        if agentsByID[id] == nil {
            _ = register(.init(
                threadID: id,
                parentThreadID: summary.metadata.parentThreadID?.rawValue,
                agentPath: summary.metadata.agentPathFromSource
            ))
        }
        guard var agent = agentsByID[id] else { return nil }
        let previous = agent

        agent.nickname = summary.metadata.agentNickname
            ?? summary.metadata.agentNicknameFromSource
            ?? agent.nickname
        agent.role = summary.metadata.agentRole
            ?? summary.metadata.agentRoleFromSource
            ?? agent.role
        agent.agentPath = summary.metadata.agentPathFromSource ?? agent.agentPath
        agent.parentThreadID =
            summary.metadata.parentThreadID?.rawValue ?? agent.parentThreadID
        agent.depth = agent.agentPath.map(Self.depth) ?? agent.depth
        if !Self.isClosed(agent.status) {
            agent.status = Self.status(
                threadStatus: summary.threadStatus,
                latestTurn: summary.latestTurn,
                fallback: agent.status
            )
        }
        if let createdAt = summary.metadata.createdAt?.rawValue {
            agent.createdAt = Date(timeIntervalSince1970: TimeInterval(createdAt))
        }
        agent.completedAt = summary.latestTurn?.completedAt.map {
            Date(timeIntervalSince1970: TimeInterval($0.rawValue))
        }
        agentsByID[id] = agent
        return previous.agentPath != agent.agentPath
            || previous.nickname != agent.nickname
            || previous.role != agent.role
            || previous.depth != agent.depth
            || previous.parentThreadID != agent.parentThreadID
            || previous.status != agent.status
            || previous.createdAt != agent.createdAt
            || previous.completedAt != agent.completedAt
    }

    static func projectChildSnapshot(
        _ snapshot: CanonicalStateSnapshot,
        threadID: ThreadID,
        previous: CodexCanonicalTranscriptPresentation?
    ) throws -> CodexCanonicalTranscriptProjectionResult {
        let projector = CodexCanonicalTranscriptProjector()
        do {
            return try projector.project(
                snapshot: snapshot,
                threadID: threadID,
                previous: previous
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CodexCanonicalTranscriptProjectionError {
            switch error {
            case .staleSourceRevision, .staleRequestRevision:
                break
            }
            try Task.checkCancellation()
            return try projector.project(
                snapshot: snapshot,
                threadID: threadID,
                previous: nil
            )
        }
    }

    static func projectSelectedChildSnapshot(
        _ snapshot: CanonicalStateSnapshot,
        threadID: ThreadID,
        previous: CodexCanonicalTranscriptPresentation?,
        excludingTurnIDs excludedTurnIDs: Set<TurnID> = [],
        displayCostLimit: Int
    ) throws -> CodexSelectedChildProjectionOutput {
        let projector = CodexCanonicalTranscriptProjector()
        do {
            return try projector.projectSelectedChild(
                snapshot: snapshot,
                threadID: threadID,
                previous: previous,
                excludingTurnIDs: excludedTurnIDs,
                displayCostLimit: displayCostLimit
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CodexCanonicalTranscriptProjectionError {
            switch error {
            case .staleSourceRevision, .staleRequestRevision:
                break
            }
            try Task.checkCancellation()
            return try projector.projectSelectedChild(
                snapshot: snapshot,
                threadID: threadID,
                previous: nil,
                excludingTurnIDs: excludedTurnIDs,
                displayCostLimit: displayCostLimit
            )
        }
    }

    /// Drops only transcript presentation. Identity and lifecycle metadata stay
    /// available for lightweight panels.
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
        indexedMetadataByID.removeValue(forKey: threadID.rawValue)
    }

    public mutating func removeAll() {
        agentsByID.removeAll(keepingCapacity: false)
        discoveriesByID.removeAll(keepingCapacity: false)
        indexedMetadataByID.removeAll(keepingCapacity: false)
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

    private mutating func applyIndexedMetadataIfAvailable(
        id: String,
        fallbackParentThreadID: String
    ) {
        guard let metadata = indexedMetadataByID[id] else { return }
        updateMetadata(
            threadID: id,
            nickname: metadata.nickname,
            role: metadata.role,
            prompt: nil,
            agentPath: metadata.path,
            parentThreadID: metadata.parentThreadID ?? fallbackParentThreadID
        )
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

    mutating func registerAgentStateIDs(
        _ states: [String: CodexJSONValue]?,
        parentThreadID: ThreadID
    ) {
        guard let states else { return }
        for id in states.keys where agentsByID[id] == nil {
            _ = register(.init(
                threadID: id,
                parentThreadID: parentThreadID.rawValue
            ))
        }
    }

    mutating func applyAgentStatePayload(_ states: [String: CodexJSONValue]?) {
        guard let states else { return }
        for (id, rawState) in states {
            guard let state = CodexJSONCoercion.dictionary(from: rawState),
                  let rawStatus = state.string("status")?.lowercased(),
                  agentsByID[id] != nil else { continue }
            switch rawStatus {
            case "pendinginit", "pending", "waiting":
                agentsByID[id]?.status = .pending
            case "completed", "done", "interrupted", "shutdown":
                // The official renderer treats interrupted/shutdown child
                // states as terminal "done" status. A closeAgent completion
                // is kept distinct and applied by the caller below.
                agentsByID[id]?.status = .completed(durationMs: nil)
            case "failed", "error", "errored", "notfound":
                agentsByID[id]?.status = .failed(
                    message: state.string("message") ?? "Subagent failed"
                )
            case "closed":
                agentsByID[id]?.status = .closed
            case "running", "working":
                agentsByID[id]?.status = .working(since: nil)
            default:
                break
            }
        }
    }

    mutating func applyCollaborationToolState(
        _ payload: [String: CodexJSONValue],
        receiverThreadIDs: [String]
    ) {
        let tool = payload.string("tool") ?? ""
        let status = payload.string("status")?.lowercased()
        let ids = receiverThreadIDs.isEmpty
            && tool == "wait"
            && status == "completed"
            ? Array(agentsByID.keys)
            : receiverThreadIDs

        if ["spawnAgent", "sendInput", "resumeAgent"].contains(tool) {
            for id in ids where agentsByID[id] != nil {
                if status == "failed" {
                    agentsByID[id]?.status = .failed(
                        message: payload.string("message") ?? "Subagent operation failed"
                    )
                } else {
                    agentsByID[id]?.status = .working(since: nil)
                }
            }
        }
    }

    mutating func applyCompletedWaitState(receiverThreadIDs: [String]) {
        let ids = receiverThreadIDs.isEmpty
            ? Array(agentsByID.keys)
            : receiverThreadIDs
        for id in ids where agentsByID[id]?.status.isActive == true {
            agentsByID[id]?.status = .completed(durationMs: nil)
        }
    }

    mutating func applySubagentActivityState(
        _ payload: [String: CodexJSONValue],
        threadID: String
    ) {
        guard agentsByID[threadID] != nil else { return }
        switch payload.string("kind")?.lowercased() {
        case "started", "interacted":
            agentsByID[threadID]?.status = .working(since: nil)
        case "interrupted":
            // Official activity projection renders interruption as terminal
            // done; a canonical child failure still wins when its snapshot is
            // later hydrated.
            agentsByID[threadID]?.status = .completed(durationMs: nil)
        default:
            break
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
        threadStatus: CanonicalThreadStatus,
        latestTurn: CanonicalTurn?,
        fallback: CodexSubagentLiveStatusV2
    ) -> CodexSubagentLiveStatusV2 {
        guard let turn = latestTurn else {
            return threadStatus.isActive ? .working(since: nil) : fallback
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
            return threadStatus.isActive ? .working(since: turn.startedAt?.rawValue) : fallback
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
