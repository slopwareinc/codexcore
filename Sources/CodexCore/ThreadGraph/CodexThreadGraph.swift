import Foundation

/// Stable identity for a thread across multiplexed app-server hosts.
public struct CodexThreadGraphKey: Hashable, Codable, Sendable, Comparable, CustomStringConvertible
{
    public let hostID: String
    public let threadID: ThreadID

    public init(hostID: String, threadID: ThreadID) {
        self.hostID = hostID
        self.threadID = threadID
    }

    public var description: String { "\(hostID):\(threadID.rawValue)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.hostID, lhs.threadID) < (rhs.hostID, rhs.threadID)
    }
}

public enum CodexThreadGraphKind: String, Codable, Sendable, Hashable {
    case topLevel
    case collabChild
    case sideChat
    case fork
    case worktree
    case cloud
    case unknown
}

/// Exact `CollabAgentStatus` value. Unknown future values remain lossless.
public enum CodexCollabAgentLifecycle: Sendable, Hashable, Codable, Comparable {
    case pendingInit
    case running
    case interrupted
    case completed
    case errored
    case shutdown
    case notFound
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "pendingInit": self = .pendingInit
        case "running": self = .running
        case "interrupted": self = .interrupted
        case "completed": self = .completed
        case "errored": self = .errored
        case "shutdown": self = .shutdown
        case "notFound": self = .notFound
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .pendingInit: "pendingInit"
        case .running: "running"
        case .interrupted: "interrupted"
        case .completed: "completed"
        case .errored: "errored"
        case .shutdown: "shutdown"
        case .notFound: "notFound"
        case .unknown(let value): value
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .interrupted, .completed, .errored, .shutdown, .notFound: true
        case .pendingInit, .running, .unknown: false
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public init(from decoder: Decoder) throws { self.init(rawValue: try String(from: decoder)) }
    public func encode(to encoder: Encoder) throws { try rawValue.encode(to: encoder) }
}

public enum CodexCollabAction: Sendable, Hashable, Codable, Comparable {
    case spawnAgent
    case sendInput
    case resumeAgent
    case wait
    case closeAgent
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "spawnAgent": self = .spawnAgent
        case "sendInput": self = .sendInput
        case "resumeAgent": self = .resumeAgent
        case "wait": self = .wait
        case "closeAgent": self = .closeAgent
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .spawnAgent: "spawnAgent"
        case .sendInput: "sendInput"
        case .resumeAgent: "resumeAgent"
        case .wait: "wait"
        case .closeAgent: "closeAgent"
        case .unknown(let value): value
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public init(from decoder: Decoder) throws { self.init(rawValue: try String(from: decoder)) }
    public func encode(to encoder: Encoder) throws { try rawValue.encode(to: encoder) }
}

public enum CodexCollabActionStatus: Sendable, Hashable, Codable, Comparable {
    case inProgress
    case completed
    case failed
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "inProgress": self = .inProgress
        case "completed": self = .completed
        case "failed": self = .failed
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .inProgress: "inProgress"
        case .completed: "completed"
        case .failed: "failed"
        case .unknown(let value): value
        }
    }

    public var isTerminal: Bool { self == .completed || self == .failed }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public init(from decoder: Decoder) throws { self.init(rawValue: try String(from: decoder)) }
    public func encode(to encoder: Encoder) throws { try rawValue.encode(to: encoder) }
}

public struct CodexCollabAgentState: Sendable, Equatable, Codable {
    public var lifecycle: CodexCollabAgentLifecycle
    public var message: String?

    public init(lifecycle: CodexCollabAgentLifecycle, message: String? = nil) {
        self.lifecycle = lifecycle
        self.message = message
    }
}

/// One collaboration action, keyed by its composite canonical item identity.
/// `item/started` and `item/completed` therefore update one record rather than
/// producing two lifecycle rows.
public struct CodexThreadGraphAction: Sendable, Equatable, Identifiable {
    public var id: ItemKey { sourceItem }
    public let sourceItem: ItemKey
    public var action: CodexCollabAction
    public var status: CodexCollabActionStatus
    public var sender: CodexThreadGraphKey
    public var receivers: [CodexThreadGraphKey]
    public var prompt: String?
    public var model: String?
    public var reasoningEffort: String?
    public var agentStates: [CodexThreadGraphKey: CodexCollabAgentState]
    public var startedAt: ProtocolMilliseconds?
    public var completedAt: ProtocolMilliseconds?

    public init(
        sourceItem: ItemKey,
        action: CodexCollabAction,
        status: CodexCollabActionStatus,
        sender: CodexThreadGraphKey,
        receivers: [CodexThreadGraphKey],
        prompt: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        agentStates: [CodexThreadGraphKey: CodexCollabAgentState] = [:],
        startedAt: ProtocolMilliseconds? = nil,
        completedAt: ProtocolMilliseconds? = nil
    ) {
        self.sourceItem = sourceItem
        self.action = action
        self.status = status
        self.sender = sender
        self.receivers = receivers
        self.prompt = prompt
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.agentStates = agentStates
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

public struct CodexThreadGraphEdge: Sendable, Hashable, Identifiable {
    public enum Source: Sendable, Hashable {
        case collaboration(ItemKey)
        case threadMetadata
        case forkMetadata
    }

    public var id: String { "\(parent.description)>\(child.description)>\(source)" }
    public let parent: CodexThreadGraphKey
    public let child: CodexThreadGraphKey
    public let source: Source

    public init(parent: CodexThreadGraphKey, child: CodexThreadGraphKey, source: Source) {
        self.parent = parent
        self.child = child
        self.source = source
    }
}

public struct CodexThreadGraphNode: Sendable, Equatable, Identifiable {
    public var id: CodexThreadGraphKey { key }
    public let key: CodexThreadGraphKey
    public var parent: CodexThreadGraphKey?
    public var children: [CodexThreadGraphKey]
    public var depth: Int?
    public var kind: CodexThreadGraphKind
    public var prompt: String?
    public var model: String?
    public var reasoningEffort: String?
    public var lifecycle: CodexCollabAgentLifecycle?
    public var resultMessage: String?
    public var errorMessage: String?
    public var sourceTurnID: TurnID?
    public var sourceItemID: ItemID?
    public var agentNickname: String?
    public var agentRole: String?
    public var agentPath: String?
    public var cwd: CodexJSONValue?
    public var ephemeral: Bool?
    public var archived: Bool?
    public var createdAt: ProtocolSeconds?
    public var updatedAt: ProtocolSeconds?
    public var isLoaded: Bool

    public init(
        key: CodexThreadGraphKey,
        parent: CodexThreadGraphKey? = nil,
        children: [CodexThreadGraphKey] = [],
        depth: Int? = nil,
        kind: CodexThreadGraphKind = .unknown,
        prompt: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        lifecycle: CodexCollabAgentLifecycle? = nil,
        resultMessage: String? = nil,
        errorMessage: String? = nil,
        sourceTurnID: TurnID? = nil,
        sourceItemID: ItemID? = nil,
        agentNickname: String? = nil,
        agentRole: String? = nil,
        agentPath: String? = nil,
        cwd: CodexJSONValue? = nil,
        ephemeral: Bool? = nil,
        archived: Bool? = nil,
        createdAt: ProtocolSeconds? = nil,
        updatedAt: ProtocolSeconds? = nil,
        isLoaded: Bool = false
    ) {
        self.key = key
        self.parent = parent
        self.children = children
        self.depth = depth
        self.kind = kind
        self.prompt = prompt
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.lifecycle = lifecycle
        self.resultMessage = resultMessage
        self.errorMessage = errorMessage
        self.sourceTurnID = sourceTurnID
        self.sourceItemID = sourceItemID
        self.agentNickname = agentNickname
        self.agentRole = agentRole
        self.agentPath = agentPath
        self.cwd = cwd
        self.ephemeral = ephemeral
        self.archived = archived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isLoaded = isLoaded
    }
}

public struct CodexThreadGraphSnapshot: Sendable, Equatable {
    public let revision: StateRevision
    public let nodes: [CodexThreadGraphKey: CodexThreadGraphNode]
    public let edges: [CodexThreadGraphEdge]
    public let actions: [CodexThreadGraphAction]
    public let roots: [CodexThreadGraphKey]
    public let cycleEdges: [CodexThreadGraphEdge]

    public init(
        revision: StateRevision,
        nodes: [CodexThreadGraphKey: CodexThreadGraphNode],
        edges: [CodexThreadGraphEdge],
        actions: [CodexThreadGraphAction],
        roots: [CodexThreadGraphKey],
        cycleEdges: [CodexThreadGraphEdge] = []
    ) {
        self.revision = revision
        self.nodes = nodes
        self.edges = edges
        self.actions = actions
        self.roots = roots
        self.cycleEdges = cycleEdges
    }

    public func node(hostID: String, threadID: ThreadID) -> CodexThreadGraphNode? {
        nodes[.init(hostID: hostID, threadID: threadID)]
    }

    /// Breadth-first recursive discovery. Multiple parents and malformed cycles
    /// are safe; every descendant is returned at most once.
    public func descendants(of root: CodexThreadGraphKey) -> [CodexThreadGraphKey] {
        var seen: Set<CodexThreadGraphKey> = [root]
        var queue = nodes[root]?.children ?? []
        var result: [CodexThreadGraphKey] = []
        var queueIndex = 0
        while queueIndex < queue.count {
            let next = queue[queueIndex]
            queueIndex += 1
            guard seen.insert(next).inserted else { continue }
            result.append(next)
            queue.append(contentsOf: nodes[next]?.children ?? [])
        }
        return result
    }
}

/// Pure canonical graph projection. It consumes immutable canonical snapshots;
/// it does not subscribe to wire events or own a second protocol reducer.
public enum CodexThreadGraphProjector {
    public static func project(
        _ snapshot: CanonicalStateSnapshot,
        hostID: String
    ) -> CodexThreadGraphSnapshot {
        var nodes: [CodexThreadGraphKey: CodexThreadGraphNode] = [:]
        var edges: [CodexThreadGraphEdge] = []
        var actions: [CodexThreadGraphAction] = []
        var edgeSet: Set<CodexThreadGraphEdge> = []
        let sortedThreadIDs = snapshot.threads.keys.sorted()
        var orderedThreadIDs: [ThreadID] = []
        orderedThreadIDs.reserveCapacity(snapshot.threadOrder.count + sortedThreadIDs.count)
        var seenThreadIDs: Set<ThreadID> = []
        for threadID in snapshot.threadOrder + sortedThreadIDs
        where seenThreadIDs.insert(threadID).inserted {
            orderedThreadIDs.append(threadID)
        }

        func key(_ id: ThreadID) -> CodexThreadGraphKey {
            .init(hostID: hostID, threadID: id)
        }
        func ensure(_ id: ThreadID) {
            let graphKey = key(id)
            if nodes[graphKey] == nil { nodes[graphKey] = .init(key: graphKey) }
        }
        func appendEdge(_ edge: CodexThreadGraphEdge) {
            if edgeSet.insert(edge).inserted { edges.append(edge) }
        }

        for threadID in snapshot.threadOrder + sortedThreadIDs {
            guard let thread = snapshot.threads[threadID] else { continue }
            ensure(threadID)
            let graphKey = key(threadID)
            var node = nodes[graphKey]!
            node.agentNickname = thread.metadata.agentNickname
            node.agentRole = thread.metadata.agentRole
            node.agentPath = thread.metadata.path
            node.cwd = thread.metadata.cwd
            node.ephemeral = thread.metadata.ephemeral
            node.archived = thread.isArchived
            node.createdAt = thread.metadata.createdAt
            node.updatedAt = thread.metadata.updatedAt
            node.isLoaded = thread.isLoaded
            node.kind = inferredKind(thread)
            nodes[graphKey] = node

            if let parentID = thread.metadata.parentThreadID {
                ensure(parentID)
                appendEdge(.init(parent: key(parentID), child: graphKey, source: .threadMetadata))
            }
            if let parentID = thread.metadata.forkedFromID {
                ensure(parentID)
                appendEdge(.init(parent: key(parentID), child: graphKey, source: .forkMetadata))
            }
        }

        let orderedItems = canonicalItemOrder(snapshot, threadIDs: orderedThreadIDs)
        for item in orderedItems where item.kind == .collabAgentToolCall {
            let payload = item.payload
            let senderID = ThreadID(
                CodexJSONCoercion.string(in: payload, keys: ["senderThreadId"])
                    ?? item.key.threadID.rawValue
            )
            let receiverIDs =
                CodexJSONCoercion
                .stringArray(in: payload, key: "receiverThreadIds")
                .map { ThreadID($0) }
            ensure(senderID)
            receiverIDs.forEach(ensure)

            let action = CodexCollabAction(
                rawValue:
                    CodexJSONCoercion.string(in: payload, keys: ["tool"]) ?? "unknown"
            )
            let state = CodexCollabActionStatus(
                rawValue:
                    CodexJSONCoercion.string(in: payload, keys: ["status"])
                    ?? (item.authority == .completed ? "completed" : "inProgress")
            )
            var agentStates: [CodexThreadGraphKey: CodexCollabAgentState] = [:]
            for (rawID, rawState) in CodexJSONCoercion.dictionary(in: payload, key: "agentsStates")
                ?? [:]
            {
                guard let object = CodexJSONCoercion.dictionary(from: rawState),
                    let rawLifecycle = CodexJSONCoercion.string(in: object, keys: ["status"])
                else { continue }
                let agentKey = key(ThreadID(rawID))
                ensure(agentKey.threadID)
                agentStates[agentKey] = .init(
                    lifecycle: .init(rawValue: rawLifecycle),
                    message: CodexJSONCoercion.string(in: object, keys: ["message"])
                )
            }

            let graphAction = CodexThreadGraphAction(
                sourceItem: item.key,
                action: action,
                status: state,
                sender: key(senderID),
                receivers: receiverIDs.map(key),
                prompt: CodexJSONCoercion.string(in: payload, keys: ["prompt"]),
                model: CodexJSONCoercion.string(in: payload, keys: ["model"]),
                reasoningEffort: CodexJSONCoercion.string(in: payload, keys: ["reasoningEffort"]),
                agentStates: agentStates,
                startedAt: item.startedAt,
                completedAt: item.completedAt
            )
            actions.append(graphAction)

            for receiverID in receiverIDs {
                let receiverKey = key(receiverID)
                appendEdge(
                    .init(
                        parent: key(senderID), child: receiverKey, source: .collaboration(item.key))
                )
                var node = nodes[receiverKey]!
                node.kind = .collabChild
                node.prompt = graphAction.prompt ?? node.prompt
                node.model = graphAction.model ?? node.model
                node.reasoningEffort = graphAction.reasoningEffort ?? node.reasoningEffort
                node.sourceTurnID = item.key.turnID
                node.sourceItemID = item.key.itemID
                if let agentState = agentStates[receiverKey] {
                    node.lifecycle = agentState.lifecycle
                    if agentState.lifecycle == .errored || agentState.lifecycle == .notFound {
                        node.errorMessage = agentState.message
                    } else if agentState.lifecycle.isTerminal {
                        node.resultMessage = agentState.message
                    }
                } else if action == .closeAgent, item.authority == .completed {
                    node.lifecycle = .shutdown
                }
                nodes[receiverKey] = node
            }
        }

        // Activity items can announce a child before either metadata or the
        // spawn action is hydrated. Preserve that partial edge immediately.
        for item in orderedItems where item.kind == .subAgentActivity {
            guard let rawChild = CodexJSONCoercion.string(in: item.payload, keys: ["agentThreadId"])
            else { continue }
            let childID = ThreadID(rawChild)
            ensure(item.key.threadID)
            ensure(childID)
            let parentKey = key(item.key.threadID)
            let childKey = key(childID)
            appendEdge(.init(parent: parentKey, child: childKey, source: .collaboration(item.key)))
            var node = nodes[childKey]!
            node.kind = .collabChild
            node.sourceTurnID = node.sourceTurnID ?? item.key.turnID
            node.sourceItemID = node.sourceItemID ?? item.key.itemID
            node.agentPath =
                CodexJSONCoercion.string(in: item.payload, keys: ["agentPath"])
                ?? node.agentPath
            let activity = CodexJSONCoercion.string(in: item.payload, keys: ["kind"])
            if activity == "started" || activity == "interacted", node.lifecycle == nil {
                node.lifecycle = .running
            }
            if activity == "interrupted" { node.lifecycle = .interrupted }
            nodes[childKey] = node
        }

        let order = Dictionary(
            uniqueKeysWithValues:
                orderedThreadIDs.enumerated().map { ($0.element, $0.offset) }
        )
        edges.sort {
            let lhs = (
                order[$0.parent.threadID] ?? .max, order[$0.child.threadID] ?? .max, $0.child
            )
            let rhs = (
                order[$1.parent.threadID] ?? .max, order[$1.child.threadID] ?? .max, $1.child
            )
            return lhs < rhs
        }

        var childrenByParent: [CodexThreadGraphKey: [CodexThreadGraphKey]] = [:]
        var primaryParent: [CodexThreadGraphKey: CodexThreadGraphKey] = [:]
        var cycleEdges: [CodexThreadGraphEdge] = []
        for edge in edges {
            if edge.parent == edge.child
                || createsCycle(parent: edge.parent, child: edge.child, parents: primaryParent)
            {
                cycleEdges.append(edge)
                continue
            }
            if primaryParent[edge.child] == nil { primaryParent[edge.child] = edge.parent }
            if childrenByParent[edge.parent, default: []].contains(edge.child) == false {
                childrenByParent[edge.parent, default: []].append(edge.child)
            }
        }

        for graphKey in nodes.keys {
            nodes[graphKey]?.parent = primaryParent[graphKey]
            nodes[graphKey]?.children = childrenByParent[graphKey] ?? []
        }
        let roots = nodes.keys.filter { primaryParent[$0] == nil }.sorted {
            let lhs = order[$0.threadID] ?? .max
            let rhs = order[$1.threadID] ?? .max
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
        var queue = roots.map { ($0, 0) }
        var visited: Set<CodexThreadGraphKey> = []
        var queueIndex = 0
        while queueIndex < queue.count {
            let (next, depth) = queue[queueIndex]
            queueIndex += 1
            guard visited.insert(next).inserted else { continue }
            nodes[next]?.depth = depth
            queue.append(contentsOf: (nodes[next]?.children ?? []).map { ($0, depth + 1) })
        }

        return .init(
            revision: snapshot.revision,
            nodes: nodes,
            edges: edges,
            actions: actions,
            roots: roots,
            cycleEdges: cycleEdges
        )
    }

    private static func inferredKind(_ thread: CanonicalThread) -> CodexThreadGraphKind {
        if thread.metadata.ephemeral == true, thread.metadata.forkedFromID != nil {
            return .sideChat
        }
        if thread.metadata.parentThreadID != nil { return .collabChild }
        if thread.metadata.forkedFromID != nil { return .fork }
        let source = CodexJSONCoercion.string(
            from: thread.metadata.threadSource ?? thread.metadata.source,
            dictionaryKeys: ["kind", "type", "source"]
        )?.lowercased()
        if source?.contains("cloud") == true { return .cloud }
        if source?.contains("worktree") == true { return .worktree }
        if source?.contains("subagent") == true || source?.contains("sub_agent") == true {
            return .collabChild
        }
        return .topLevel
    }

    private static func canonicalItemOrder(
        _ snapshot: CanonicalStateSnapshot,
        threadIDs: [ThreadID]
    ) -> [CanonicalItem] {
        var seen: Set<ItemKey> = []
        var result: [CanonicalItem] = []
        for threadID in threadIDs {
            for turn in snapshot.turns(in: threadID) {
                for item in snapshot.items(in: turn.key) where seen.insert(item.key).inserted {
                    result.append(item)
                }
            }
        }
        result.append(
            contentsOf: snapshot.items.keys.sorted().compactMap { key in
                guard seen.insert(key).inserted else { return nil }
                return snapshot.items[key]
            })
        return result
    }

    private static func createsCycle(
        parent: CodexThreadGraphKey,
        child: CodexThreadGraphKey,
        parents: [CodexThreadGraphKey: CodexThreadGraphKey]
    ) -> Bool {
        var cursor: CodexThreadGraphKey? = parent
        var seen: Set<CodexThreadGraphKey> = []
        while let current = cursor, seen.insert(current).inserted {
            if current == child { return true }
            cursor = parents[current]
        }
        return false
    }
}
