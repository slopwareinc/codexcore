import CodexCore
import Foundation

public struct CodexAgentItemUpdate: Equatable, Sendable {
    public var activityTitle: String
    public var activityDetail: String

    public init(activityTitle: String, activityDetail: String) {
        self.activityTitle = activityTitle
        self.activityDetail = activityDetail
    }
}

/// Pure presentation mapping for the agent panel.
///
/// It consumes canonical parent state plus already-projected child threads. It
/// never receives app-server notifications and owns no child protocol reducer.
public struct CodexAgentStateMapper: Sendable {
    public private(set) var lifecycleEvents: [CodexAgentLifecycleEvent] = []
    public private(set) var subagents: [CodexSubagentState] = []

    private var lifecycleEventIDs: [ItemKey: UUID] = [:]

    public init() {}

    public mutating func reset() {
        lifecycleEvents.removeAll(keepingCapacity: false)
        subagents.removeAll(keepingCapacity: false)
        lifecycleEventIDs.removeAll(keepingCapacity: false)
    }

    /// Rebuilds panel state from canonical identities. UUIDs used by SwiftUI
    /// rows remain stable for the lifetime of the mapper because they are keyed
    /// by the canonical composite item identity.
    @discardableResult
    public mutating func applyCanonicalSnapshot(
        _ parentSnapshot: CanonicalStateSnapshot,
        parentThreadID: ThreadID,
        projectedChildren: [CodexSubagentV2]
    ) -> Bool {
        let previousEvents = lifecycleEvents
        let previousSubagents = subagents
        lifecycleEvents = projectLifecycle(
            parentSnapshot,
            parentThreadID: parentThreadID,
            projectedChildren: projectedChildren
        )
        subagents = projectedChildren.map(Self.panelState)
        return previousEvents != lifecycleEvents || previousSubagents != subagents
    }
}

private extension CodexAgentStateMapper {
    mutating func projectLifecycle(
        _ snapshot: CanonicalStateSnapshot,
        parentThreadID: ThreadID,
        projectedChildren: [CodexSubagentV2]
    ) -> [CodexAgentLifecycleEvent] {
        let namesByThreadID = Dictionary(
            uniqueKeysWithValues: projectedChildren.map { ($0.threadID, $0.displayName) }
        )
        var events: [CodexAgentLifecycleEvent] = []
        var liveKeys: Set<ItemKey> = []

        let graph = CodexThreadGraphProjector.project(snapshot, hostID: "local")
        let root = CodexThreadGraphKey(hostID: "local", threadID: parentThreadID)
        let threadIDs = [parentThreadID] + graph.subagentDescendants(of: root).map(\.threadID)
        for threadID in threadIDs {
            for turn in snapshot.turns(in: threadID) {
                for item in snapshot.items(in: turn.key) {
                    guard item.kind == .collabAgentToolCall || item.kind == .subAgentActivity else {
                        continue
                    }
                    liveKeys.insert(item.key)
                    let id = lifecycleEventIDs[item.key] ?? UUID()
                    lifecycleEventIDs[item.key] = id
                    if let event = Self.lifecycleEvent(
                        id: id,
                        item: item,
                        namesByThreadID: namesByThreadID
                    ) {
                        events.append(event)
                    }
                }
            }
        }

        lifecycleEventIDs = lifecycleEventIDs.filter { liveKeys.contains($0.key) }
        return events
    }

    static func lifecycleEvent(
        id: UUID,
        item: CanonicalItem,
        namesByThreadID: [String: String]
    ) -> CodexAgentLifecycleEvent? {
        switch item.kind {
        case .collabAgentToolCall:
            let tool = item.payload.string("tool") ?? "update"
            let completed = item.authority == .completed
            let threadIDs = item.payload.stringArray("receiverThreadIds")
            let names = threadIDs.map { namesByThreadID[$0] ?? shortAgentName($0) }
            let status = lifecycleStatus(tool: tool, completed: completed, payload: item.payload)
            let messages = item.payload.object("agentsStates")?.values.compactMap {
                CodexJSONCoercion.dictionary(from: $0)?.string("message")
            } ?? []
            return CodexAgentLifecycleEvent(
                id: id,
                status: status,
                title: lifecycleTitle(
                    tool: tool,
                    completed: completed,
                    names: names
                ),
                detail: messages.isEmpty
                    ? item.key.itemID.rawValue
                    : messages.joined(separator: " · "),
                agentNames: names,
                createdAt: itemDate(item)
            )

        case .subAgentActivity:
            guard let threadID = item.payload.string("agentThreadId") else { return nil }
            let name = item.payload.string("agentPath")
                .flatMap(displayName(fromAgentPath:))
                ?? namesByThreadID[threadID]
                ?? shortAgentName(threadID)
            let kind = item.payload.string("kind") ?? "updated"
            let status: CodexAgentLifecycleEvent.Status = switch kind {
            case "started", "interacted": .running
            case "interrupted": .failed
            default: .running
            }
            let title = switch kind {
            case "started": "Started \(name)"
            case "interacted": "\(name) interacted"
            case "interrupted": "Interrupted \(name)"
            default: "Updated \(name)"
            }
            return CodexAgentLifecycleEvent(
                id: id,
                status: status,
                title: title,
                detail: item.key.itemID.rawValue,
                agentNames: [name],
                createdAt: itemDate(item)
            )

        default:
            return nil
        }
    }

    static func panelState(_ child: CodexSubagentV2) -> CodexSubagentState {
        CodexSubagentState(
            id: child.threadID,
            name: child.displayName,
            title: child.role == "default" ? "Subagent" : (child.role ?? "Subagent"),
            prompt: child.prompt ?? "Subagent task",
            status: child.panelStatus,
            transcript: child.transcript,
            createdAt: child.createdAt,
            completedAt: child.completedAt
        )
    }

    static func lifecycleStatus(
        tool: String,
        completed: Bool,
        payload: [String: CodexJSONValue]
    ) -> CodexAgentLifecycleEvent.Status {
        if tool == "closeAgent", completed { return .closed }
        let statuses = payload.object("agentsStates")?.values.compactMap {
            CodexJSONCoercion.dictionary(from: $0)?.string("status")?.lowercased()
        } ?? []
        if statuses.contains(where: {
            $0 == "interrupted" || $0 == "errored" || $0 == "notfound"
        }) { return .failed }
        if statuses.contains("shutdown") { return .closed }
        if completed, tool == "wait" { return .completed }
        if completed, tool == "spawnAgent" { return .running }
        return completed ? .completed : (tool == "spawnAgent" ? .spawning : .running)
    }

    static func lifecycleTitle(
        tool: String,
        completed: Bool,
        names: [String]
    ) -> String {
        let label: String
        if names.isEmpty { label = "subagents" }
        else if names.count == 1 { label = names[0] }
        else { label = "\(names.count) agents" }
        switch tool {
        case "spawnAgent": return completed ? "Created \(label)" : "Creating \(label)"
        case "sendInput": return completed ? "Messaged \(label)" : "Messaging \(label)"
        case "resumeAgent": return completed ? "Resumed \(label)" : "Resuming \(label)"
        case "wait": return completed ? "Finished waiting" : "Waiting for \(label)"
        case "closeAgent": return completed ? "Closed \(label)" : "Closing \(label)"
        default: return "Subagent update"
        }
    }

    static func itemDate(_ item: CanonicalItem) -> Date {
        let milliseconds = item.completedAt?.rawValue ?? item.startedAt?.rawValue
        return milliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
            ?? Date(timeIntervalSince1970: 0)
    }

    static func shortAgentName(_ id: String) -> String {
        "agent-\(id.split(separator: "-").first.map(String.init) ?? id)"
    }

    static func displayName(fromAgentPath path: String) -> String? {
        let component = path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "root" }
            .last
        guard let component else { return nil }
        let words = component
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.lowercased() }
        guard !words.isEmpty else { return nil }
        let normalized = words.joined(separator: " ")
        return normalized.prefix(1).uppercased() + normalized.dropFirst()
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
