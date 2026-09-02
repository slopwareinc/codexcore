import Foundation

private func boundedResourceString(_ value: String?, limit: Int = 4_096) -> String? {
    guard let value = value?.nilIfBlank,
          value.utf8.count <= limit,
          !value.contains("\n"),
          !value.contains("\r") else { return nil }
    return value
}

/// The stable origin of a resource exposed by a thread.
///
/// Resource identity is deliberately based on protocol coordinates rather than
/// a view index or arrival time. A resource can therefore be projected again
/// after history/live reconciliation without changing its identity.
public struct CodexThreadResourceOrigin: Codable, Hashable, Sendable, Equatable {
    public let threadID: ThreadID
    public let turnID: TurnID?
    public let itemID: ItemID?

    public init(
        threadID: ThreadID,
        turnID: TurnID? = nil,
        itemID: ItemID? = nil
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
    }

    public init(_ key: ItemKey) {
        self.init(threadID: key.threadID, turnID: key.turnID, itemID: key.itemID)
    }

    public init(_ key: TurnKey) {
        self.init(threadID: key.threadID, turnID: key.turnID)
    }

    /// A lossless, URL-safe-ish identity used by tab requests and diagnostics.
    public var stableID: String {
        [
            threadID.rawValue,
            turnID?.rawValue ?? "thread",
            itemID?.rawValue ?? "turn",
        ].joined(separator: "/")
    }
}

/// Resource families shared by Summary, New Tab, and workspace-tab requests.
public enum CodexThreadResourceKind: Codable, CaseIterable, Hashable, Sendable {
    case plan
    case subagent
    case editedFile
    case outputFile
    case generatedImage
    case visualization
    case artifact
    case source
    case webActivity
    case mcpResource
    case mcpApp
    case backgroundTerminal
    case pullRequest
    case review
    case sideChat
    case unknown(String)

    public static let allCases: [Self] = [
        .plan, .subagent, .editedFile, .outputFile, .generatedImage,
        .visualization, .artifact, .source, .webActivity, .mcpResource,
        .mcpApp, .backgroundTerminal, .pullRequest, .review, .sideChat,
    ]

    public init(rawValue: String) {
        switch rawValue {
        case "plan": self = .plan
        case "subagent": self = .subagent
        case "editedFile": self = .editedFile
        case "outputFile": self = .outputFile
        case "generatedImage": self = .generatedImage
        case "visualization": self = .visualization
        case "artifact": self = .artifact
        case "source": self = .source
        case "webActivity": self = .webActivity
        case "mcpResource": self = .mcpResource
        case "mcpApp": self = .mcpApp
        case "backgroundTerminal": self = .backgroundTerminal
        case "pullRequest": self = .pullRequest
        case "review": self = .review
        case "sideChat": self = .sideChat
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .plan: "plan"
        case .subagent: "subagent"
        case .editedFile: "editedFile"
        case .outputFile: "outputFile"
        case .generatedImage: "generatedImage"
        case .visualization: "visualization"
        case .artifact: "artifact"
        case .source: "source"
        case .webActivity: "webActivity"
        case .mcpResource: "mcpResource"
        case .mcpApp: "mcpApp"
        case .backgroundTerminal: "backgroundTerminal"
        case .pullRequest: "pullRequest"
        case .review: "review"
        case .sideChat: "sideChat"
        case .unknown(let value): value
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try String(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try rawValue.encode(to: encoder)
    }
}

/// Protocol-derived lifecycle, kept separate from presentation affordances.
public enum CodexThreadResourceStatus: Codable, Hashable, Sendable, Equatable {
    case available
    case inProgress
    case completed
    case failed
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "available", "ready": self = .available
        case "inProgress", "running", "active": self = .inProgress
        case "completed", "done", "success": self = .completed
        case "failed", "error": self = .failed
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .available: "available"
        case .inProgress: "inProgress"
        case .completed: "completed"
        case .failed: "failed"
        case .unknown(let value): value
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try String(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try rawValue.encode(to: encoder)
    }
}

/// Bounded typed metadata carried by a resource. Large payloads and binary
/// contents never enter the inventory; adapters resolve them lazily by id.
public struct CodexThreadResourceMetadata: Codable, Hashable, Sendable, Equatable {
    public var path: String?
    public var url: String?
    public var query: String?
    public var server: String?
    public var tool: String?
    public var appName: String?
    public var childThreadID: ThreadID?
    public var processID: String?
    public var command: String?
    public var cwd: String?
    public var mimeType: String?
    public var branch: String?
    public var sourceID: String?
    public var statusDetail: String?
    public var isDraft: Bool?
    public var line: Int?
    public var sizeBytes: Int?

    public init(
        path: String? = nil,
        url: String? = nil,
        query: String? = nil,
        server: String? = nil,
        tool: String? = nil,
        appName: String? = nil,
        childThreadID: ThreadID? = nil,
        processID: String? = nil,
        command: String? = nil,
        cwd: String? = nil,
        mimeType: String? = nil,
        branch: String? = nil,
        sourceID: String? = nil,
        statusDetail: String? = nil,
        isDraft: Bool? = nil,
        line: Int? = nil,
        sizeBytes: Int? = nil
    ) {
        self.path = boundedResourceString(path)
        self.url = boundedResourceString(url)
        self.query = boundedResourceString(query)
        self.server = boundedResourceString(server)
        self.tool = boundedResourceString(tool)
        self.appName = boundedResourceString(appName)
        self.childThreadID = childThreadID
        self.processID = boundedResourceString(processID)
        self.command = boundedResourceString(command)
        self.cwd = boundedResourceString(cwd)
        self.mimeType = boundedResourceString(mimeType)
        self.branch = boundedResourceString(branch)
        self.sourceID = boundedResourceString(sourceID)
        self.statusDetail = boundedResourceString(statusDetail)
        self.isDraft = isDraft
        self.line = line
        self.sizeBytes = sizeBytes
    }
}

/// A supplemental fact supplied by a host adapter. It is still fact-only:
/// selection, expansion, placement, and tab lifetime do not belong here.
public struct CodexThreadResourceFact: Codable, Hashable, Sendable, Equatable {
    public let id: String
    public let kind: CodexThreadResourceKind
    public let title: String
    public let detail: String?
    public let status: CodexThreadResourceStatus
    public let origin: CodexThreadResourceOrigin
    public let metadata: CodexThreadResourceMetadata

    public init(
        id: String,
        kind: CodexThreadResourceKind,
        title: String,
        detail: String? = nil,
        status: CodexThreadResourceStatus = .available,
        origin: CodexThreadResourceOrigin,
        metadata: CodexThreadResourceMetadata = .init()
    ) {
        self.id = boundedResourceString(id) ?? ""
        self.kind = kind
        self.title = boundedResourceString(title) ?? kind.rawValue
        self.detail = boundedResourceString(detail)
        self.status = status
        self.origin = origin
        self.metadata = metadata
    }
}

/// One row in the deterministic resource inventory.
public struct CodexThreadResource: Identifiable, Codable, Hashable, Sendable, Equatable {
    public let id: String
    public let kind: CodexThreadResourceKind
    public let title: String
    public let detail: String?
    public let status: CodexThreadResourceStatus
    public let origin: CodexThreadResourceOrigin
    public let metadata: CodexThreadResourceMetadata

    public init(
        id: String,
        kind: CodexThreadResourceKind,
        title: String,
        detail: String? = nil,
        status: CodexThreadResourceStatus = .available,
        origin: CodexThreadResourceOrigin,
        metadata: CodexThreadResourceMetadata = .init()
    ) {
        self.id = boundedResourceString(id) ?? ""
        self.kind = kind
        self.title = boundedResourceString(title) ?? kind.rawValue
        self.detail = boundedResourceString(detail)
        self.status = status
        self.origin = origin
        self.metadata = metadata
    }

    init(_ fact: CodexThreadResourceFact) {
        self.init(
            id: fact.id,
            kind: fact.kind,
            title: fact.title,
            detail: fact.detail,
            status: fact.status,
            origin: fact.origin,
            metadata: fact.metadata
        )
    }
}

/// The revision key used to decide whether a disposable inventory is stale.
public struct CodexThreadResourceProjectionKey: Hashable, Sendable, Equatable, Codable {
    public let canonicalRevision: StateRevision
    public let supplementalRevision: UInt64

    public init(
        canonicalRevision: StateRevision,
        supplementalRevision: UInt64 = 0
    ) {
        self.canonicalRevision = canonicalRevision
        self.supplementalRevision = supplementalRevision
    }
}

public struct CodexThreadResourceProjectionInput: Sendable, Equatable {
    public let snapshot: CanonicalStateSnapshot
    public let threadID: ThreadID
    public let supplementalFacts: [CodexThreadResourceFact]
    public let supplementalRevision: UInt64

    public init(
        snapshot: CanonicalStateSnapshot,
        threadID: ThreadID,
        supplementalFacts: [CodexThreadResourceFact] = [],
        supplementalRevision: UInt64 = 0
    ) {
        self.snapshot = snapshot
        self.threadID = threadID
        self.supplementalFacts = supplementalFacts
        self.supplementalRevision = supplementalRevision
    }

    public var key: CodexThreadResourceProjectionKey {
        .init(
            canonicalRevision: snapshot.revision,
            supplementalRevision: supplementalRevision
        )
    }
}

/// Disposable, fact-only projection shared by all resource surfaces.
public struct CodexThreadResourceInventory: Sendable, Equatable, Codable {
    public let threadID: ThreadID
    public let key: CodexThreadResourceProjectionKey
    public let resources: [CodexThreadResource]
    public let malformedResourceCount: Int

    public var revision: StateRevision { key.canonicalRevision }
    public var sourceRevision: StateRevision { key.canonicalRevision }

    public init(
        threadID: ThreadID,
        key: CodexThreadResourceProjectionKey,
        resources: [CodexThreadResource] = [],
        malformedResourceCount: Int = 0
    ) {
        self.threadID = threadID
        self.key = key
        self.resources = resources
        self.malformedResourceCount = max(0, malformedResourceCount)
    }

    public func resources(of kind: CodexThreadResourceKind) -> [CodexThreadResource] {
        resources.filter { $0.kind == kind }
    }

    public func resource(id: String) -> CodexThreadResource? {
        resources.first { $0.id == id }
    }

    public var isEmpty: Bool { resources.isEmpty }
}

/// Small revision-aware cache for hosts that read a projection from a
/// frequently-rendered view model. It never stores canonical state and makes
/// render-count assertions explicit in tests.
public struct CodexThreadResourceProjectionCache: Sendable, Equatable {
    public private(set) var inventory: CodexThreadResourceInventory?
    public private(set) var projectionCount: UInt64
    public private(set) var cacheHitCount: UInt64

    public init(inventory: CodexThreadResourceInventory? = nil) {
        self.inventory = inventory
        self.projectionCount = inventory == nil ? 0 : 1
        self.cacheHitCount = 0
    }

    /// Applies a new input and returns `true` only when a projection was
    /// recomputed. Equal revision keys are render-neutral.
    @discardableResult
    public mutating func apply(
        _ input: CodexThreadResourceProjectionInput
    ) -> Bool {
        guard CodexThreadResourceProjector.isInvalidated(previous: inventory, by: input) else {
            cacheHitCount &+= 1
            return false
        }
        inventory = CodexThreadResourceProjector.project(input)
        projectionCount &+= 1
        return true
    }

    public mutating func invalidate() {
        inventory = nil
    }
}

/// Pure projection from canonical state plus explicitly supplied host facts.
/// No presentation state is read or retained here.
public struct CodexThreadResourceProjector: Sendable {
    public init() {}

    public func project(_ input: CodexThreadResourceProjectionInput) -> CodexThreadResourceInventory {
        Self.project(input)
    }

    public static func project(
        _ input: CodexThreadResourceProjectionInput
    ) -> CodexThreadResourceInventory {
        var resources: [CodexThreadResource] = []
        var indexes: [String: Int] = [:]
        var malformedCount = 0

        func append(_ fact: CodexThreadResourceFact, mergeExisting: Bool = true) {
            guard !fact.id.isEmpty else { return }
            if let index = indexes[fact.id], mergeExisting {
                let existing = resources[index]
                // Keep the first origin forever. Later lifecycle payloads may
                // refine title/status/detail but must not move the row.
                resources[index] = CodexThreadResource(
                    id: existing.id,
                    kind: existing.kind,
                    title: existing.kind == .plan && existing.title != "Plan"
                        ? existing.title
                        : fact.title.nilIfBlank ?? existing.title,
                    detail: fact.detail ?? existing.detail,
                    status: fact.status,
                    origin: existing.origin,
                    metadata: merge(existing.metadata, fact.metadata)
                )
            } else if indexes[fact.id] == nil {
                indexes[fact.id] = resources.count
                resources.append(.init(fact))
            }
        }

        guard input.snapshot.threads[input.threadID] != nil else {
            let sortedFacts = input.supplementalFacts.sorted { $0.id < $1.id }
            sortedFacts.forEach { append($0) }
            return .init(
                threadID: input.threadID,
                key: input.key,
                resources: resources,
                malformedResourceCount: 0
            )
        }

        let turns = orderedTurns(input.snapshot, threadID: input.threadID)

        for turn in turns {
            if turn.plan != nil || turn.planExplanation?.nilIfBlank != nil {
                let steps = turn.plan ?? []
                let completed = steps.count { $0.status == .completed }
                append(.init(
                    id: "plan:\(input.threadID.rawValue):\(turn.key.turnID.rawValue)",
                    kind: .plan,
                    title: turn.planExplanation?.nilIfBlank ?? "Plan",
                    detail: steps.isEmpty ? nil : "\(completed)/\(steps.count) tasks",
                    status: resourceStatus(turn.status),
                    origin: .init(turn.key),
                    metadata: .init(sourceID: turn.key.turnID.rawValue)
                ), mergeExisting: true)
            }

            if let diff = turn.diff?.nilIfBlank {
                let paths = diffPaths(diff)
                for path in paths {
                    append(.init(
                        id: "edited-file:\(input.threadID.rawValue):\(turn.key.turnID.rawValue):\(path)",
                        kind: .editedFile,
                        title: path.lastPathComponent,
                        detail: path,
                        status: resourceStatus(turn.status),
                        origin: .init(turn.key),
                        metadata: .init(path: path)
                    ), mergeExisting: true)
                }
                append(.init(
                    id: "review:\(input.threadID.rawValue):\(turn.key.turnID.rawValue)",
                    kind: .review,
                    title: "Review",
                    detail: paths.isEmpty ? "Turn changes" : "\(paths.count) changed file\(paths.count == 1 ? "" : "s")",
                    status: resourceStatus(turn.status),
                    origin: .init(turn.key),
                    metadata: .init(sourceID: turn.key.turnID.rawValue)
                ), mergeExisting: true)
            }

            for item in input.snapshot.items(in: turn.key) {
                let origin = CodexThreadResourceOrigin(item.key)
                project(item, origin: origin, append: append, malformedCount: &malformedCount)
            }
        }

        // A resumed thread can expose child metadata before the parent turn's
        // collaboration item has hydrated. Include those graph facts now and
        // let a later item payload refine the same stable child row.
        let childThreads = input.snapshot.threads.values
            .filter {
                $0.id != input.threadID
                    && ($0.metadata.parentThreadID == input.threadID
                        || $0.metadata.forkedFromID == input.threadID)
            }
            .sorted { $0.id < $1.id }
        for child in childThreads {
            let status: CodexThreadResourceStatus
            switch child.status {
            case .active: status = .inProgress
            case .systemError: status = .failed
            case .idle: status = .completed
            case .notLoaded: status = .available
            case .unknown(let type, _): status = .unknown(type ?? "unknown")
            }
            append(.init(
                id: "subagent:\(input.threadID.rawValue):\(child.id.rawValue)",
                kind: .subagent,
                title: child.metadata.agentNickname
                    ?? child.metadata.name
                    ?? child.id.rawValue,
                detail: child.metadata.agentRole,
                status: status,
                origin: .init(threadID: input.threadID),
                metadata: .init(
                    appName: child.metadata.agentRole,
                    childThreadID: child.id,
                    sourceID: child.metadata.sessionID
                )
            ), mergeExisting: true)
        }

        if let terminals = input.snapshot.backgroundTerminals[input.threadID] {
            for terminal in terminals.terminals {
                let origin = originForBackgroundTerminal(
                    terminal,
                    snapshot: input.snapshot,
                    threadID: input.threadID
                )
                append(.init(
                    id: "background-terminal:\(input.threadID.rawValue):\(terminal.processID)",
                    kind: .backgroundTerminal,
                    title: terminal.command.nilIfBlank ?? "Background process",
                    detail: terminal.cwd.stringValue,
                    status: .inProgress,
                    origin: origin,
                    metadata: .init(
                        processID: terminal.processID,
                        command: terminal.command,
                        cwd: terminal.cwd.stringValue,
                        sourceID: terminal.itemID
                    )
                ))
            }
        }

        // Host adapters (Git, MCP catalog, source folders, and future product
        // integrations) are facts, not presentation. Sorting gives callers a
        // deterministic result even when an async catalog finishes out of order.
        for fact in input.supplementalFacts.sorted(by: { $0.id < $1.id }) {
            append(fact)
        }

        return .init(
            threadID: input.threadID,
            key: input.key,
            resources: resources,
            malformedResourceCount: malformedCount
        )
    }

    public static func project(
        snapshot: CanonicalStateSnapshot,
        threadID: ThreadID,
        supplementalFacts: [CodexThreadResourceFact] = [],
        supplementalRevision: UInt64 = 0
    ) -> CodexThreadResourceInventory {
        project(.init(
            snapshot: snapshot,
            threadID: threadID,
            supplementalFacts: supplementalFacts,
            supplementalRevision: supplementalRevision
        ))
    }

    public static func isInvalidated(
        previous: CodexThreadResourceInventory?,
        by input: CodexThreadResourceProjectionInput
    ) -> Bool {
        previous?.threadID != input.threadID || previous?.key != input.key
    }
}

/// Namespace-style spelling for callers that prefer a projection over a
/// projector instance. Both entry points share the same implementation.
public enum CodexThreadResourceProjection {
    public static func project(
        snapshot: CanonicalStateSnapshot,
        threadID: ThreadID,
        supplementalFacts: [CodexThreadResourceFact] = [],
        supplementalRevision: UInt64 = 0
    ) -> CodexThreadResourceInventory {
        CodexThreadResourceProjector.project(
            snapshot: snapshot,
            threadID: threadID,
            supplementalFacts: supplementalFacts,
            supplementalRevision: supplementalRevision
        )
    }
}

private extension CodexThreadResourceProjector {
    static func orderedTurns(
        _ snapshot: CanonicalStateSnapshot,
        threadID: ThreadID
    ) -> [CanonicalTurn] {
        guard let thread = snapshot.threads[threadID] else { return [] }
        var seen: Set<TurnID> = []
        var result = thread.turnOrder.compactMap { id -> CanonicalTurn? in
            guard seen.insert(id).inserted else { return nil }
            return snapshot.turns[TurnKey(threadID: threadID, turnID: id)]
        }
        let missing = snapshot.turns.values
            .filter { $0.key.threadID == threadID && !seen.contains($0.key.turnID) }
            .sorted { $0.key.turnID < $1.key.turnID }
        result.append(contentsOf: missing)
        return result
    }

    static func project(
        _ item: CanonicalItem,
        origin: CodexThreadResourceOrigin,
        append: (CodexThreadResourceFact, Bool) -> Void,
        malformedCount: inout Int
    ) {
        let status = resourceStatus(item)
        let payload = item.payload

        switch item.kind {
        case .collabAgentToolCall:
            let receiverIDs = orderedUnion(
                stringArray(payload["receiverThreadIds"]),
                stringArray(payload["receiverThreadIDs"]),
                dictionaryKeys(payload["agentsStates"])
            )
            if receiverIDs.isEmpty {
                malformedCount += 1
                append(.init(
                    id: "subagent:\(origin.stableID)",
                    kind: .subagent,
                    title: "Subagent",
                    detail: string(payload["prompt"]),
                    status: status,
                    origin: origin,
                    metadata: .init(tool: string(payload["tool"]))
                ), true)
            } else {
                for childID in receiverIDs {
                    let state = object(payload["agentsStates"])?[childID]
                    let stateObject = object(state)
                    let childStatus = CodexThreadResourceStatus(
                        rawValue: string(stateObject?["status"]) ?? status.rawValue
                    )
                    append(.init(
                        id: "subagent:\(origin.threadID.rawValue):\(childID)",
                        kind: .subagent,
                        title: string(stateObject?["name"]) ?? shortAgentName(childID),
                        detail: string(stateObject?["message"]) ?? string(payload["prompt"]),
                        status: childStatus,
                        origin: origin,
                        metadata: .init(
                            tool: string(payload["tool"]),
                            appName: string(payload["model"]),
                            childThreadID: ThreadID(childID)
                        )
                    ), true)
                }
            }

        case .subAgentActivity:
            guard let childID = string(payload["agentThreadId"]) ?? string(payload["agentThreadID"]) else {
                malformedCount += 1
                return
            }
            append(.init(
                id: "subagent:\(origin.threadID.rawValue):\(childID)",
                kind: .subagent,
                title: displayAgentName(string(payload["agentPath"]) ?? childID),
                detail: string(payload["kind"]),
                status: status,
                origin: origin,
                metadata: .init(childThreadID: ThreadID(childID))
            ), true)

        case .fileChange:
            let changes = array(payload["changes"])
            if changes.isEmpty {
                malformedCount += 1
                append(.init(
                    id: "edited-file:\(origin.stableID)",
                    kind: .editedFile,
                    title: "File changes",
                    detail: "No file paths were supplied",
                    status: status,
                    origin: origin
                ), true)
            } else {
                var emitted = false
                for change in changes {
                    guard let path = string(object(change)?["path"])?.nilIfBlank else {
                        malformedCount += 1
                        continue
                    }
                    emitted = true
                    append(.init(
                        id: "edited-file:\(origin.stableID):\(path)",
                        kind: .editedFile,
                        title: path.lastPathComponent,
                        detail: path,
                        status: status,
                        origin: origin,
                        metadata: .init(path: path)
                    ), true)
                }
                if !emitted {
                    append(.init(
                        id: "edited-file:\(origin.stableID)",
                        kind: .editedFile,
                        title: "File changes",
                        detail: "File paths are unavailable",
                        status: status,
                        origin: origin
                    ), true)
                }
            }

        case .imageGeneration:
            let source = bounded(string(payload["savedPath"]) ?? string(payload["result"]))
            let failure = object(payload["failure"])
            append(.init(
                id: "generated-image:\(origin.stableID)",
                kind: .generatedImage,
                title: "Generated image",
                detail: source ?? string(failure?["type"]),
                status: failure == nil && source != nil ? .completed : status,
                origin: origin,
                metadata: .init(
                    path: source?.hasPrefix("/") == true ? source : nil,
                    url: source?.hasPrefix("/") == true ? nil : source,
                    statusDetail: string(payload["revisedPrompt"])
                )
            ), true)

        case .imageView:
            guard let path = bounded(string(payload["path"])) else {
                malformedCount += 1
                return
            }
            append(.init(
                id: "generated-image:\(origin.stableID)",
                kind: .generatedImage,
                title: path.lastPathComponent,
                detail: path,
                status: status,
                origin: origin,
                metadata: .init(path: path)
            ), true)

        case .webSearch:
            guard let query = string(payload["query"])?.nilIfBlank else {
                malformedCount += 1
                return
            }
            append(.init(
                id: "web:\(origin.stableID)",
                kind: .webActivity,
                title: "Web search",
                detail: query,
                status: status,
                origin: origin,
                metadata: .init(query: query)
            ), true)

        case .mcpToolCall:
            projectMCP(
                item: item,
                origin: origin,
                status: status,
                append: append,
                malformedCount: &malformedCount
            )

        case .dynamicToolCall:
            projectOutputLike(
                item: item,
                origin: origin,
                status: status,
                append: append,
                malformedCount: &malformedCount
            )

        case .enteredReviewMode, .exitedReviewMode:
            append(.init(
                id: "review:\(origin.threadID.rawValue):\(origin.turnID?.rawValue ?? origin.stableID)",
                kind: .review,
                title: item.kind == .enteredReviewMode ? "Review" : "Review completed",
                detail: string(payload["review"]),
                status: item.kind == .enteredReviewMode ? .inProgress : .completed,
                origin: origin,
                metadata: .init(sourceID: string(payload["reviewId"]) ?? string(payload["reviewID"]))
            ), true)

        case .plan:
            append(.init(
                id: "plan:\(origin.threadID.rawValue):\(origin.turnID?.rawValue ?? origin.stableID)",
                kind: .plan,
                title: string(payload["title"]) ?? "Plan",
                detail: string(payload["text"]),
                status: status,
                origin: origin
            ), true)

        case .agentMessage:
            for directive in CodexVisualizationDirectiveProjection.directives(
                in: string(payload["text"])
                    ?? string(payload["content"])
                    ?? string(payload["message"])
                    ?? ""
            ) {
                append(.init(
                    id: "visualization:\(origin.threadID.rawValue):\(directive.path)",
                    kind: .visualization,
                    title: directive.title ?? directive.path.lastPathComponent,
                    detail: directive.path,
                    status: status,
                    origin: origin,
                    metadata: .init(
                        path: directive.path,
                        mimeType: "text/html",
                        statusDetail: directive.isWide ? "wide" : nil
                    )
                ), true)
            }
            projectOutputLike(
                item: item,
                origin: origin,
                status: status,
                append: append,
                malformedCount: &malformedCount,
                includeGenericOutput: false
            )

        case .userMessage, .reasoning, .commandExecution,
             .hookPrompt, .sleep, .contextCompaction, .unknown:
            projectOutputLike(
                item: item,
                origin: origin,
                status: status,
                append: append,
                malformedCount: &malformedCount,
                includeGenericOutput: false
            )
        }
    }

    static func projectMCP(
        item: CanonicalItem,
        origin: CodexThreadResourceOrigin,
        status: CodexThreadResourceStatus,
        append: (CodexThreadResourceFact, Bool) -> Void,
        malformedCount: inout Int
    ) {
        let payload = item.payload
        let appContext = object(payload["appContext"])
        let server = string(payload["server"])
        let tool = string(payload["tool"])
        let appName = string(appContext?["appName"]) ?? server ?? "MCP tool"
        let appURI = string(payload["mcpAppResourceUri"])
            ?? string(appContext?["resourceUri"])

        var emitted = false

        if let appURI = bounded(appURI) {
            emitted = true
            append(.init(
                id: "mcp-app:\(origin.stableID):\(appURI)",
                kind: .mcpApp,
                title: appName,
                detail: tool,
                status: status,
                origin: origin,
                metadata: .init(
                    url: appURI,
                    server: server,
                    tool: tool,
                    appName: appName
                )
            ), true)
        }

        let result = object(payload["result"])
        let contents = array(result?["content"])
        for value in contents {
            guard let object = object(value) else {
                malformedCount += 1
                continue
            }
            let type = string(object["type"])?.lowercased()
            guard ["resource", "resource_link", "resourcelink", "embedded_resource", "embeddedresource"].contains(type ?? "") else {
                continue
            }
            let nestedResource = CodexThreadResourceProjector.object(object["resource"])
            guard let uri = bounded(
                string(object["uri"])
                    ?? string(object["resourceUri"])
                    ?? string(object["url"])
                    ?? string(nestedResource?["uri"])
            ) else {
                malformedCount += 1
                continue
            }
            emitted = true
            append(.init(
                id: "mcp-resource:\(origin.stableID):\(uri)",
                kind: .mcpResource,
                title: string(object["title"])
                    ?? string(object["name"])
                    ?? string(nestedResource?["title"])
                    ?? uri,
                detail: string(object["description"])
                    ?? string(object["mimeType"])
                    ?? string(nestedResource?["mimeType"]),
                status: status,
                origin: origin,
                metadata: .init(
                    url: uri,
                    server: server,
                    tool: tool,
                    mimeType: string(object["mimeType"])
                        ?? string(nestedResource?["mimeType"])
                )
            ), true)
        }

        // A tool call is itself still useful when its result is empty or
        // malformed; this preserves an actionable MCP row rather than hiding
        // a failed call.
        if !emitted {
            append(.init(
                id: "mcp-resource:\(origin.stableID)",
                kind: .mcpResource,
                title: appName,
                detail: tool,
                status: status,
                origin: origin,
                metadata: .init(server: server, tool: tool, appName: appName)
            ), true)
        }
    }

    static func projectOutputLike(
        item: CanonicalItem,
        origin: CodexThreadResourceOrigin,
        status: CodexThreadResourceStatus,
        append: (CodexThreadResourceFact, Bool) -> Void,
        malformedCount: inout Int,
        includeGenericOutput: Bool = true
    ) {
        let payload = item.payload
        let candidates = [
            "outputFiles", "output_files", "outputs", "files", "artifacts",
            "artifact", "visualizations", "visualization", "visualizationURL",
            "visualizationUrl", "visualizationURLS", "visualizationUrls",
            "pullRequest", "pullRequests", "pullRequestUrl", "pullRequestURL",
            "review", "reviewId", "reviewID", "sources", "source",
            "memoryCitation", "memoryCitations",
            "contentItems", "content",
        ]

        for key in candidates {
            guard let value = payload[key] else { continue }
            let values: [CodexJSONValue]
            switch value {
            case .array(let array): values = array
            default: values = [value]
            }
            for (index, value) in values.enumerated() {
                guard let rawFact = factFromOutput(
                    value,
                    key: key,
                    origin: origin,
                    status: status,
                    index: index
                ) else {
                    if value != .null { malformedCount += 1 }
                    continue
                }
                let fact = item.kind == .userMessage
                    ? sourceFact(rawFact)
                    : rawFact
                append(fact, true)
            }
        }

        if includeGenericOutput,
           candidates.allSatisfy({ payload[$0] == nil }),
           let tool = string(payload["tool"]),
           tool.localizedCaseInsensitiveContains("artifact") {
            let kind: CodexThreadResourceKind = .artifact
            append(.init(
                id: "\(kind.rawValue):\(origin.stableID)",
                kind: kind,
                title: tool,
                status: status,
                origin: origin,
                metadata: .init(tool: tool)
            ), true)
        }
    }

    static func sourceFact(_ fact: CodexThreadResourceFact) -> CodexThreadResourceFact {
        guard fact.kind == .outputFile else { return fact }
        return .init(
            id: fact.id.replacingOccurrences(of: "output-file:", with: "source:"),
            kind: .source,
            title: fact.title,
            detail: fact.detail,
            status: fact.status,
            origin: fact.origin,
            metadata: fact.metadata
        )
    }

    static func factFromOutput(
        _ value: CodexJSONValue,
        key: String,
        origin: CodexThreadResourceOrigin,
        status: CodexThreadResourceStatus,
        index: Int
    ) -> CodexThreadResourceFact? {
        let object = object(value)
        let raw = bounded(string(value))
        let path = bounded(
            string(object?["path"])
                ?? string(object?["file"])
                ?? string(object?["filePath"])
                ?? string(object?["file_path"])
        )
            ?? raw.flatMap { $0.hasPrefix("/") ? $0 : nil }
        let url = bounded(
            string(object?["url"])
                ?? string(object?["uri"])
                ?? string(object?["imageUrl"])
                ?? string(object?["image_url"])
                ?? string(object?["fileUrl"])
                ?? string(object?["file_url"])
        )
            ?? (path == nil ? raw : nil)
        let title = string(object?["title"]) ?? string(object?["name"])
        let lower = key.lowercased()
        let contentType = string(object?["type"])?.lowercased() ?? ""
        if lower.contains("contentitem") || lower == "content" {
            let target: CodexThreadResourceKind?
            if contentType.contains("image") {
                target = .generatedImage
            } else if contentType.contains("resource") {
                target = .mcpResource
            } else if contentType.contains("artifact") {
                target = .artifact
            } else if contentType.contains("file") || path != nil {
                target = .outputFile
            } else {
                target = nil
            }
            if let target, let value = path ?? url ?? raw {
                return .init(
                    id: "\(target.rawValue):\(origin.stableID):\(value)",
                    kind: target,
                    title: title ?? value.lastPathComponent,
                    detail: string(object?["description"]) ?? value,
                    status: status,
                    origin: origin,
                    metadata: .init(
                        path: path,
                        url: path == nil ? url : nil,
                        server: string(object?["server"]),
                        tool: string(object?["tool"]),
                        mimeType: string(object?["mimeType"])
                    )
                )
            }
        }
        if lower.contains("visual") {
            let source = path ?? url
            guard source != nil else { return nil }
            return .init(
                id: "visualization:\(origin.threadID.rawValue):\(source ?? "")",
                kind: .visualization,
                title: title ?? "Visualization",
                detail: source,
                status: status,
                origin: origin,
                metadata: .init(path: path, url: path == nil ? url : nil)
            )
        }
        if lower.contains("pullrequest") || lower.contains("pull_request") {
            guard let url else { return nil }
            let branch = string(object?["branch"]) ?? string(object?["headBranch"])
            return .init(
                id: "pull-request:\(origin.stableID):\(url)",
                kind: .pullRequest,
                title: title ?? "Pull request",
                detail: branch,
                status: status,
                origin: origin,
                metadata: .init(url: url, branch: branch, isDraft: bool(object?["isDraft"]))
            )
        }
        if lower.contains("review") {
            let reviewID = string(object?["id"]) ?? string(object?["reviewId"]) ?? raw
            guard let reviewID else { return nil }
            return .init(
                id: "review:\(origin.stableID):\(reviewID)",
                kind: .review,
                title: title ?? "Review",
                detail: string(object?["status"]) ?? raw,
                status: status,
                origin: origin,
                metadata: .init(sourceID: reviewID)
            )
        }
        if lower.contains("memory") {
            let entries = array(object?["entries"])
            let entry = entries.first.flatMap { CodexThreadResourceProjector.object($0) }
            let memoryPath = bounded(string(entry?["path"]) ?? string(object?["path"]))
            let note = string(entry?["note"]) ?? string(object?["note"])
            guard memoryPath != nil || note != nil || raw != nil else { return nil }
            return .init(
                id: "source:\(origin.stableID):memory:\(memoryPath ?? note ?? "citation")",
                kind: .source,
                title: memoryPath?.lastPathComponent ?? "Memory citation",
                detail: note ?? memoryPath ?? "Memory citation",
                status: status,
                origin: origin,
                metadata: .init(path: memoryPath, sourceID: raw)
            )
        }
        if lower.contains("source") {
            guard let source = path ?? url else { return nil }
            return .init(
                id: "source:\(origin.stableID):\(source)",
                kind: .source,
                title: title ?? source.lastPathComponent,
                detail: source,
                status: status,
                origin: origin,
                metadata: .init(path: path, url: path == nil ? url : nil)
            )
        }
        if lower.contains("artifact") {
            guard let artifact = path ?? url ?? raw else { return nil }
            return .init(
                id: "artifact:\(origin.stableID):\(artifact)",
                kind: .artifact,
                title: title ?? artifact.lastPathComponent,
                detail: artifact,
                status: status,
                origin: origin,
                metadata: .init(path: path, url: path == nil ? url : nil, mimeType: string(object?["mimeType"]))
            )
        }
        if lower.contains("output") || lower == "files" {
            guard let output = path ?? url ?? raw else { return nil }
            return .init(
                id: "output-file:\(origin.stableID):\(output)",
                kind: .outputFile,
                title: title ?? output.lastPathComponent,
                detail: output,
                status: status,
                origin: origin,
                metadata: .init(path: path, url: path == nil ? url : nil, mimeType: string(object?["mimeType"]))
            )
        }
        if lower == "source" || lower == "sources" {
            guard let source = path ?? url ?? raw else { return nil }
            return .init(
                id: "source:\(origin.stableID):\(source)",
                kind: .source,
                title: title ?? source.lastPathComponent,
                detail: source,
                status: status,
                origin: origin,
                metadata: .init(path: path, url: path == nil ? url : nil)
            )
        }
        return nil
    }

    static func originForBackgroundTerminal(
        _ terminal: CanonicalBackgroundTerminal,
        snapshot: CanonicalStateSnapshot,
        threadID: ThreadID
    ) -> CodexThreadResourceOrigin {
        for key in snapshot.items.keys.sorted() where key.threadID == threadID {
            if key.itemID.rawValue == terminal.itemID {
                return .init(key)
            }
        }
        return .init(threadID: threadID, itemID: ItemID(terminal.itemID))
    }

    static func diffPaths(_ diff: String) -> [String] {
        var seen: Set<String> = []
        var paths: [String] = []
        for line in diff.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("diff --git ") else { continue }
            let parts = line.dropFirst("diff --git ".count).split(separator: " ")
            guard parts.count >= 2 else { continue }
            let path = String(parts[1]).hasPrefix("b/")
                ? String(String(parts[1]).dropFirst(2))
                : String(parts[1])
            guard let normalized = path.nilIfBlank,
                  !normalized.contains("\n"),
                  seen.insert(normalized).inserted else { continue }
            paths.append(normalized)
        }
        return paths
    }

    static func resourceStatus(_ item: CanonicalItem) -> CodexThreadResourceStatus {
        if let status = string(item.payload["status"]) {
            return .init(rawValue: status)
        }
        switch item.authority {
        case .completed: return .completed
        case .started: return .inProgress
        case .placeholder: return .available
        }
    }

    static func resourceStatus(_ status: CanonicalTurnStatus) -> CodexThreadResourceStatus {
        switch status {
        case .inProgress: .inProgress
        case .completed: .completed
        case .failed, .interrupted: .failed
        case .unknown(let value): .unknown(value)
        }
    }

    static func merge(
        _ existing: CodexThreadResourceMetadata,
        _ incoming: CodexThreadResourceMetadata
    ) -> CodexThreadResourceMetadata {
        .init(
            path: incoming.path ?? existing.path,
            url: incoming.url ?? existing.url,
            query: incoming.query ?? existing.query,
            server: incoming.server ?? existing.server,
            tool: incoming.tool ?? existing.tool,
            appName: incoming.appName ?? existing.appName,
            childThreadID: incoming.childThreadID ?? existing.childThreadID,
            processID: incoming.processID ?? existing.processID,
            command: incoming.command ?? existing.command,
            cwd: incoming.cwd ?? existing.cwd,
            mimeType: incoming.mimeType ?? existing.mimeType,
            branch: incoming.branch ?? existing.branch,
            sourceID: incoming.sourceID ?? existing.sourceID,
            statusDetail: incoming.statusDetail ?? existing.statusDetail,
            isDraft: incoming.isDraft ?? existing.isDraft,
            line: incoming.line ?? existing.line,
            sizeBytes: incoming.sizeBytes ?? existing.sizeBytes
        )
    }

    static func orderedUnion(_ arrays: [String]...) -> [String] {
        var seen: Set<String> = []
        return arrays.flatMap { $0 }.filter { seen.insert($0).inserted }
    }

    static func string(_ value: CodexJSONValue?) -> String? {
        CodexJSONCoercion.flatString(from: value)?.nilIfBlank
    }

    static func object(_ value: CodexJSONValue?) -> [String: CodexJSONValue]? {
        guard case .dictionary(let object)? = value else { return nil }
        return object
    }

    static func array(_ value: CodexJSONValue?) -> [CodexJSONValue] {
        guard case .array(let values)? = value else { return [] }
        return values
    }

    static func stringArray(_ value: CodexJSONValue?) -> [String] {
        switch value {
        case .array(let values): values.compactMap { string($0) }
        case .string: string(value).map { [$0] } ?? []
        default: []
        }
    }

    static func dictionaryKeys(_ value: CodexJSONValue?) -> [String] {
        object(value)?.keys.sorted() ?? []
    }

    static func bool(_ value: CodexJSONValue?) -> Bool? {
        CodexJSONCoercion.bool(from: value)
    }

    static func bounded(_ value: String?, limit: Int = 4_096) -> String? {
        guard let value = value?.nilIfBlank else { return nil }
        guard value.utf8.count <= limit else { return nil }
        return value
    }

    static func shortAgentName(_ value: String) -> String {
        let suffix = value.split(separator: "-").last.map(String.init) ?? value
        return "agent-\(suffix.prefix(8))"
    }

    static func displayAgentName(_ value: String) -> String {
        let leaf = value.split(separator: "/").last.map(String.init) ?? value
        return leaf.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private extension String {
    var lastPathComponent: String {
        URL(fileURLWithPath: self).lastPathComponent.nilIfBlank ?? self
    }
}

private extension CodexJSONValue {
    var stringValue: String? {
        CodexJSONCoercion.flatString(from: self)?.nilIfBlank
    }
}
