import Foundation

public enum CodexThreadGraphServiceError: Error, Sendable, Equatable, LocalizedError {
    case hostMismatch(expected: String, actual: String)
    case unknownThread(CodexThreadGraphKey)
    case noTurn(CodexThreadGraphKey)
    case waitTimedOut([CodexThreadGraphKey])
    case unsupportedCollaborationAction(CodexCollabAction)

    public var errorDescription: String? {
        switch self {
        case .hostMismatch(let expected, let actual):
            "Thread belongs to host \(actual), but this graph service owns \(expected)."
        case .unknownThread(let key): "Unknown thread \(key)."
        case .noTurn(let key): "Thread \(key) has no turn to control."
        case .waitTimedOut(let keys):
            "Timed out waiting for \(keys.map(\.description).joined(separator: ", "))."
        case .unsupportedCollaborationAction(let action):
            "\(action.rawValue) is a model-internal collaboration tool, not an app-server request."
        }
    }
}

public struct CodexThreadGraphOperationFailure: Sendable, Equatable {
    public let thread: CodexThreadGraphKey
    public let message: String

    public init(thread: CodexThreadGraphKey, message: String) {
        self.thread = thread
        self.message = message
    }
}

public struct CodexThreadGraphOperationReport: Sendable, Equatable {
    public let attempted: [CodexThreadGraphKey]
    public let succeeded: [CodexThreadGraphKey]
    public let failures: [CodexThreadGraphOperationFailure]

    public init(
        attempted: [CodexThreadGraphKey],
        succeeded: [CodexThreadGraphKey],
        failures: [CodexThreadGraphOperationFailure]
    ) {
        self.attempted = attempted
        self.succeeded = succeeded
        self.failures = failures
    }

    public var isComplete: Bool { failures.isEmpty }
}

public struct CodexThreadMessageReceipt: Sendable, Equatable {
    public let thread: CodexThreadGraphKey
    public let turnID: TurnID
    public let startedAtRevision: StateRevision

    public init(thread: CodexThreadGraphKey, turnID: TurnID, startedAtRevision: StateRevision) {
        self.thread = thread
        self.turnID = turnID
        self.startedAtRevision = startedAtRevision
    }
}

public struct CodexThreadWaitResult: Sendable, Equatable {
    public let thread: CodexThreadGraphKey
    public let turnID: TurnID?
    public let status: CanonicalTurnStatus?
    public let lifecycle: CodexCollabAgentLifecycle?
    public let result: String?
    public let error: String?
    public let revision: StateRevision

    public init(
        thread: CodexThreadGraphKey,
        turnID: TurnID?,
        status: CanonicalTurnStatus?,
        lifecycle: CodexCollabAgentLifecycle?,
        result: String?,
        error: String?,
        revision: StateRevision
    ) {
        self.thread = thread
        self.turnID = turnID
        self.status = status
        self.lifecycle = lifecycle
        self.result = result
        self.error = error
        self.revision = revision
    }

    public var isTerminal: Bool {
        status?.isTerminal == true || lifecycle?.isTerminal == true
    }
}

/// Lifecycle and action facade over one ordered `CodexSession`.
///
/// This service never reduces wire notifications. It derives graph snapshots
/// from the canonical session owner and uses ordinary app-server requests for
/// actions the protocol actually exposes. Collaboration-tool names that have no
/// host RPC fail explicitly instead of being approximated by archive or lease
/// release.
public actor CodexThreadGraphService {
    public let hostID: String
    private let codex: Codex

    public init(codex: Codex, hostID: String = "local") {
        self.codex = codex
        self.hostID = hostID
    }

    public func snapshot() async -> CodexThreadGraphSnapshot {
        CodexThreadGraphProjector.project(
            await codex.session.canonicalSnapshot(),
            hostID: hostID
        )
    }

    public func sendMessage(
        to target: CodexThreadGraphKey,
        prompt: String,
        cwd: String? = nil,
        runtimeWorkspaceRoots: [String] = []
    ) async throws -> CodexThreadMessageReceipt {
        try validateHost(target)
        let lease = try await resume(
            target,
            cwd: cwd,
            runtimeWorkspaceRoots: runtimeWorkspaceRoots
        )
        do {
            let turn = try await lease.startTurn(
                .init(
                    clientUserMessageID: UUID().uuidString,
                    cwd: cwd,
                    input: [CodexSchemaUserInput(CodexInput.text(prompt).jsonValue)],
                    runtimeWorkspaceRoots: runtimeWorkspaceRoots.map {
                        CodexSchemaAbsolutePathBuf(.string($0))
                    },
                    threadID: target.threadID.rawValue
                ))
            let receipt = CodexThreadMessageReceipt(
                thread: target,
                turnID: turn.key.turnID,
                startedAtRevision: turn.responseRevision
            )
            Task {
                _ = try? await turn.awaitTerminal()
                await lease.close()
            }
            return receipt
        } catch {
            await lease.close()
            throw error
        }
    }

    /// Re-establishes a durable thread lease. This corresponds to the public
    /// app-server `thread/resume` operation, not the internal `resumeAgent` tool.
    public func resume(
        _ target: CodexThreadGraphKey,
        cwd: String? = nil,
        runtimeWorkspaceRoots: [String] = []
    ) async throws -> CodexThreadLease {
        try validateHost(target)
        let resolvedCWD: String?
        if let cwd {
            resolvedCWD = cwd
        } else {
            let response = try await codex.perform(
                CodexRequest.threadRead(
                    .init(
                        includeTurns: false,
                        threadID: target.threadID.rawValue
                    )))
            resolvedCWD = CodexJSONCoercion.flatString(from: response.thread.cwd.rawValue)
        }
        return try await codex.resumeThread(
            .init(
                cwd: resolvedCWD,
                runtimeWorkspaceRoots: runtimeWorkspaceRoots.map {
                    CodexSchemaAbsolutePathBuf(.string($0))
                },
                threadID: target.threadID.rawValue
            ))
    }

    public func fork(
        _ source: CodexThreadGraphKey,
        cwd: String? = nil,
        runtimeWorkspaceRoots: [String] = [],
        ephemeral: Bool = false,
        developerInstructions: String? = nil,
        threadSource: CodexSchemaThreadSource? = nil
    ) async throws -> CodexThreadLease {
        let sourceLease = try await resume(
            source,
            cwd: cwd,
            runtimeWorkspaceRoots: runtimeWorkspaceRoots
        )
        do {
            let child = try await sourceLease.fork(
                .init(
                    cwd: cwd,
                    developerInstructions: developerInstructions,
                    ephemeral: ephemeral,
                    runtimeWorkspaceRoots: runtimeWorkspaceRoots.map {
                        CodexSchemaAbsolutePathBuf(.string($0))
                    },
                    threadID: source.threadID.rawValue,
                    threadSource: threadSource
                ))
            await sourceLease.close()
            return child
        } catch {
            await sourceLease.close()
            throw error
        }
    }

    public func wait(
        for targets: [CodexThreadGraphKey],
        timeout: Duration? = nil
    ) async throws -> [CodexThreadWaitResult] {
        try targets.forEach(validateHost)
        let uniqueTargets = targets.reduce(into: [CodexThreadGraphKey]()) { result, target in
            if !result.contains(target) { result.append(target) }
        }
        guard let timeout else { return try await waitUntilTerminal(uniqueTargets) }
        return try await withThrowingTaskGroup(of: [CodexThreadWaitResult].self) { group in
            group.addTask { try await self.waitUntilTerminal(uniqueTargets) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CodexThreadGraphServiceError.waitTimedOut(uniqueTargets)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    public func interruptRecursively(
        _ root: CodexThreadGraphKey
    ) async -> CodexThreadGraphOperationReport {
        do { try validateHost(root) } catch {
            return .init(
                attempted: [root], succeeded: [],
                failures: [
                    .init(thread: root, message: error.localizedDescription)
                ])
        }
        let graph = await snapshot()
        let attempted = (graph.descendants(of: root) + [root]).reversed()
        var succeeded: [CodexThreadGraphKey] = []
        var failures: [CodexThreadGraphOperationFailure] = []
        for target in attempted {
            let state = await codex.session.canonicalSnapshot(
                scope: .thread(target.threadID, fields: [.turnStructure, .turnStatus])
            )
            guard let latest = state.turns(in: target.threadID).last,
                latest.status == .inProgress
            else {
                succeeded.append(target)
                continue
            }
            do {
                _ = try await codex.session.perform(
                    CodexRequest.turnInterrupt(
                        .init(
                            threadID: target.threadID.rawValue,
                            turnID: latest.key.turnID.rawValue
                        )))
                succeeded.append(target)
            } catch {
                failures.append(.init(thread: target, message: error.localizedDescription))
            }
        }
        return .init(attempted: Array(attempted), succeeded: succeeded, failures: failures)
    }

    public func setArchivedRecursively(
        _ root: CodexThreadGraphKey,
        archived: Bool
    ) async -> CodexThreadGraphOperationReport {
        do { try validateHost(root) } catch {
            return .init(
                attempted: [root], succeeded: [],
                failures: [
                    .init(thread: root, message: error.localizedDescription)
                ])
        }
        let graph = await snapshot()
        let descendants = graph.descendants(of: root)
        // Archive leaf-first; unarchive root-first so parents become visible
        // before descendants. Both paths remain idempotent.
        let attempted = archived ? Array((descendants + [root]).reversed()) : [root] + descendants
        var succeeded: [CodexThreadGraphKey] = []
        var failures: [CodexThreadGraphOperationFailure] = []
        for target in attempted {
            if graph.nodes[target]?.archived == archived {
                succeeded.append(target)
                continue
            }
            do {
                if archived {
                    _ = try await codex.perform(
                        CodexRequest.threadArchive(
                            .init(
                                threadID: target.threadID.rawValue
                            )))
                } else {
                    _ = try await codex.perform(
                        CodexRequest.threadUnarchive(
                            .init(
                                threadID: target.threadID.rawValue
                            )))
                }
                succeeded.append(target)
            } catch {
                failures.append(.init(thread: target, message: error.localizedDescription))
            }
        }
        return .init(attempted: attempted, succeeded: succeeded, failures: failures)
    }

    /// Internal collaboration actions are observable in the graph but cannot be
    /// invoked through the pinned app-server protocol. Callers receive a typed limitation.
    public func requireCallable(_ action: CodexCollabAction) throws {
        switch action {
        case .sendInput, .resumeAgent, .wait:
            // These have public thread-level equivalents on this service, but
            // are not the same model-internal collab call.
            throw CodexThreadGraphServiceError.unsupportedCollaborationAction(action)
        case .spawnAgent, .closeAgent, .unknown:
            throw CodexThreadGraphServiceError.unsupportedCollaborationAction(action)
        }
    }

    private func waitUntilTerminal(
        _ targets: [CodexThreadGraphKey]
    ) async throws -> [CodexThreadWaitResult] {
        // A child's exact collaboration lifecycle is carried by an item in its
        // parent thread. Observe the canonical session graph so multiplexed
        // parent events can complete a child that has no materialized turn.
        let scope = StateObservationScope(
            entities: .all,
            fields: [
                .threadMetadata,
                .threadStatus,
                .turnStructure,
                .turnStatus,
                .itemStructure,
                .itemContent,
                .itemLifecycle,
            ]
        )
        let observation = await codex.session.observe(scope: scope)
        defer { Task { await codex.session.cancelObservation(observation.id) } }
        var canonical = observation.seed
        var iterator = observation.signals.makeAsyncIterator()
        while true {
            try Task.checkCancellation()
            let graph = CodexThreadGraphProjector.project(canonical, hostID: hostID)
            let results = targets.map { waitResult(for: $0, canonical: canonical, graph: graph) }
            if results.allSatisfy(\.isTerminal) { return results }
            guard await iterator.next() != nil else { throw CancellationError() }
            canonical = await codex.session.canonicalSnapshot(scope: scope)
        }
    }

    private func waitResult(
        for target: CodexThreadGraphKey,
        canonical: CanonicalStateSnapshot,
        graph: CodexThreadGraphSnapshot
    ) -> CodexThreadWaitResult {
        let latest = canonical.turns(in: target.threadID).last
        let node = graph.nodes[target]
        let assistantText = latest.flatMap { turn in
            canonical.items(in: turn.key).reversed().first(where: { $0.kind == .agentMessage })
        }.flatMap { item in
            CodexJSONCoercion.string(in: item.payload, keys: ["text"])
                ?? item.liveOverlay.agentMessage.joined().nilIfBlank
        }
        return .init(
            thread: target,
            turnID: latest?.key.turnID,
            status: latest?.status,
            lifecycle: node?.lifecycle,
            result: node?.resultMessage ?? assistantText,
            error: node?.errorMessage ?? latest?.error?.message,
            revision: canonical.revision
        )
    }

    private func validateHost(_ target: CodexThreadGraphKey) throws {
        guard target.hostID == hostID else {
            throw CodexThreadGraphServiceError.hostMismatch(
                expected: hostID,
                actual: target.hostID
            )
        }
    }
}

extension CodexSession {
    public func threadGraphSnapshot(hostID: String = "local") -> CodexThreadGraphSnapshot {
        CodexThreadGraphProjector.project(canonicalSnapshot(), hostID: hostID)
    }
}
