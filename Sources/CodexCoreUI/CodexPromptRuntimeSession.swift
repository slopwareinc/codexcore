import Foundation
import Observation
import CodexCore

/// Narrow seam used by the prompt projection. `CodexSession` is the production
/// adapter; tests use an in-memory actor with the same exact-key semantics.
public protocol CodexPromptSessionAdapter: Actor {
    func serverRequestInboxSnapshot(
        entities: StateEntityScope
    ) -> CodexServerRequestInboxSnapshot

    func observeServerRequests(
        entities: StateEntityScope
    ) -> StateObservation<CodexServerRequestInboxSnapshot>

    func catchUp(
        observationID: StateObservationID,
        after revision: StateRevision
    ) -> StateCatchUp

    func cancelObservation(_ observationID: StateObservationID)

    func resolveServerRequest(
        _ key: CodexServerRequestKey,
        result: CodexJSONValue
    ) throws

    func failServerRequest(
        _ key: CodexServerRequestKey,
        error: CodexServerRequestResponseError
    ) throws
}

extension CodexSession: CodexPromptSessionAdapter {}

public enum CodexPromptRuntimeError: Error, Sendable, Equatable, LocalizedError {
    case notConnected
    case unknownPrompt(CodexServerRequestKey)
    case unsupportedApprovalDecision(
        CodexApprovalPromptKind,
        CodexCommandApprovalDecision
    )
    case wrongInteractivePromptKind(
        expected: CodexInteractivePromptKind,
        actual: CodexInteractivePromptKind
    )
    case invalidElicitationSubmission(CodexServerRequestKey)
    case missingRequestedPermissions(CodexServerRequestKey)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            "The prompt runtime is not connected to a Codex session."
        case .unknownPrompt(let key):
            "No pending prompt exists for \(key.presentationID)."
        case .unsupportedApprovalDecision(let kind, let decision):
            "Approval kind \(kind.rawValue) cannot use decision \(String(describing: decision))."
        case .wrongInteractivePromptKind(let expected, let actual):
            "Expected a \(expected.rawValue) prompt, received \(actual.rawValue)."
        case .invalidElicitationSubmission(let key):
            "The MCP form response for \(key.presentationID) is incomplete or unsupported."
        case .missingRequestedPermissions(let key):
            "The permissions request \(key.presentationID) has no sanitized permission profile."
        }
    }
}

@MainActor
@Observable
public final class CodexPromptRuntimeSession {
    private var promptSession = CodexPromptStateSession()

    @ObservationIgnored
    private var adapter: (any CodexPromptSessionAdapter)?
    @ObservationIgnored
    private var observationTask: Task<Void, Never>?
    @ObservationIgnored
    private var observationID: StateObservationID?
    @ObservationIgnored
    private var connectionGeneration: UInt64 = 0
    @ObservationIgnored
    private var automaticallyHandledKeys: Set<CodexServerRequestKey> = []
    @ObservationIgnored
    private var onActivity: (@MainActor (CodexPromptStateActivity) -> Void)?
    @ObservationIgnored
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public var approvalPrompts: [CodexApprovalPrompt] {
        promptSession.approvalPrompts
    }

    public var interactivePrompts: [CodexInteractivePrompt] {
        promptSession.interactivePrompts
    }

    public func connect(
        to session: CodexSession,
        onActivity: @escaping @MainActor (CodexPromptStateActivity) -> Void = { _ in }
    ) {
        connect(adapter: session, onActivity: onActivity)
    }

    public func connect(
        adapter: any CodexPromptSessionAdapter,
        onActivity: @escaping @MainActor (CodexPromptStateActivity) -> Void = { _ in }
    ) {
        disconnect()
        self.adapter = adapter
        self.onActivity = onActivity
        connectionGeneration &+= 1
        let generation = connectionGeneration
        observationTask = Task { @MainActor [weak self, adapter] in
            let observation = await adapter.observeServerRequests(entities: .all)
            guard let self, generation == connectionGeneration, !Task.isCancelled else {
                await adapter.cancelObservation(observation.id)
                return
            }
            observationID = observation.id
            await apply(observation.seed, from: adapter, generation: generation)

            for await _ in observation.signals {
                guard generation == connectionGeneration, !Task.isCancelled else { break }
                let baseRevision = promptSession.revision ?? observation.revision
                _ = await adapter.catchUp(
                    observationID: observation.id,
                    after: baseRevision
                )
                guard generation == connectionGeneration, !Task.isCancelled else { break }
                let snapshot = await adapter.serverRequestInboxSnapshot(entities: .all)
                await apply(snapshot, from: adapter, generation: generation)
            }

            await adapter.cancelObservation(observation.id)
            if generation == connectionGeneration, observationID == observation.id {
                observationID = nil
            }
        }
    }

    public func disconnect() {
        connectionGeneration &+= 1
        observationTask?.cancel()
        observationTask = nil
        if let adapter, let observationID {
            Task { await adapter.cancelObservation(observationID) }
        }
        observationID = nil
        adapter = nil
        onActivity = nil
        automaticallyHandledKeys.removeAll(keepingCapacity: false)
        promptSession.reset()
    }

    /// Clears disposable presentation state and immediately reseeds it from the
    /// connected session. This never responds to or cancels a pending request.
    public func reset() {
        promptSession.reset()
        automaticallyHandledKeys.removeAll(keepingCapacity: false)
        guard let adapter else { return }
        let generation = connectionGeneration
        Task { @MainActor [weak self, adapter] in
            let snapshot = await adapter.serverRequestInboxSnapshot(entities: .all)
            guard let self, generation == connectionGeneration else { return }
            await apply(snapshot, from: adapter, generation: generation)
        }
    }

    public func resolveApprovalPrompt(
        id key: CodexServerRequestKey,
        approved: Bool
    ) async throws -> CodexPromptStateActivity? {
        try await resolveApprovalPrompt(
            id: key,
            decision: approved ? .accept : .decline
        )
    }

    public func resolveApprovalPrompt(
        id key: CodexServerRequestKey,
        decision: CodexCommandApprovalDecision
    ) async throws -> CodexPromptStateActivity? {
        guard let prompt = promptSession.approvalPrompt(for: key) else {
            throw CodexPromptRuntimeError.unknownPrompt(key)
        }
        let result = try approvalResult(for: prompt, decision: decision)
        let adapter = try connectedAdapter()
        try await adapter.resolveServerRequest(key, result: result)
        return promptSession.resolutionActivity(for: key)
    }

    public func submitInteractivePrompt(
        id key: CodexServerRequestKey,
        answers: [String: String]
    ) async throws -> CodexPromptStateActivity? {
        guard let prompt = promptSession.interactivePrompt(for: key) else {
            throw CodexPromptRuntimeError.unknownPrompt(key)
        }
        let result: CodexJSONValue
        switch prompt.kind {
        case .userInput:
            result = prompt.userInputResult(answers: answers)
        case .mcpElicitation:
            guard prompt.isElicitationSubmissionValid(answers: answers) else {
                throw CodexPromptRuntimeError.invalidElicitationSubmission(key)
            }
            result = prompt.elicitationResult(answers: answers)
        }
        let adapter = try connectedAdapter()
        try await adapter.resolveServerRequest(key, result: result)
        return promptSession.resolutionActivity(for: key)
    }

    public func acceptInteractivePrompt(
        id key: CodexServerRequestKey
    ) async throws -> CodexPromptStateActivity? {
        guard let prompt = promptSession.interactivePrompt(for: key) else {
            throw CodexPromptRuntimeError.unknownPrompt(key)
        }
        guard prompt.kind == .mcpElicitation else {
            throw CodexPromptRuntimeError.wrongInteractivePromptKind(
                expected: .mcpElicitation,
                actual: prompt.kind
            )
        }
        guard prompt.canAcceptElicitation else {
            throw CodexPromptRuntimeError.invalidElicitationSubmission(key)
        }
        let adapter = try connectedAdapter()
        try await adapter.resolveServerRequest(
            key,
            result: prompt.acceptElicitationResult()
        )
        return promptSession.resolutionActivity(for: key)
    }

    public func declineInteractivePrompt(
        id key: CodexServerRequestKey
    ) async throws -> CodexPromptStateActivity? {
        guard let prompt = promptSession.interactivePrompt(for: key) else {
            throw CodexPromptRuntimeError.unknownPrompt(key)
        }
        let adapter = try connectedAdapter()
        try await adapter.resolveServerRequest(key, result: prompt.declineResult())
        return promptSession.resolutionActivity(for: key)
    }

    public func failPrompt(
        id key: CodexServerRequestKey,
        error: CodexServerRequestResponseError
    ) async throws {
        guard promptSession.contains(key) else {
            throw CodexPromptRuntimeError.unknownPrompt(key)
        }
        let adapter = try connectedAdapter()
        try await adapter.failServerRequest(key, error: error)
    }

    private func connectedAdapter() throws -> any CodexPromptSessionAdapter {
        guard let adapter else { throw CodexPromptRuntimeError.notConnected }
        return adapter
    }

    private func approvalResult(
        for prompt: CodexApprovalPrompt,
        decision: CodexCommandApprovalDecision
    ) throws -> CodexJSONValue {
        switch prompt.kind {
        case .command:
            return CodexValidatedServerRequestResult.commandApproval(decision).jsonValue

        case .fileChange:
            guard let scalar = decision.scalarDecision else {
                throw CodexPromptRuntimeError.unsupportedApprovalDecision(
                    prompt.kind,
                    decision
                )
            }
            return CodexValidatedServerRequestResult.fileChangeApproval(scalar).jsonValue

        case .permissions:
            guard let scalar = decision.scalarDecision else {
                throw CodexPromptRuntimeError.unsupportedApprovalDecision(
                    prompt.kind,
                    decision
                )
            }
            let permissions: CodexJSONValue
            if scalar.isApproval {
                guard let requested = prompt.additionalPermissions else {
                    throw CodexPromptRuntimeError.missingRequestedPermissions(prompt.id)
                }
                permissions = requested
            } else {
                permissions = .dictionary([:])
            }
            return CodexValidatedServerRequestResult.permissions(
                permissions: permissions,
                scope: scalar == .acceptForSession ? .session : .turn,
                strictAutoReview: nil
            ).jsonValue

        case .execCommand:
            return CodexValidatedServerRequestResult.legacyExecCommandApproval(
                decision.legacyDecision
            ).jsonValue

        case .applyPatch:
            return CodexValidatedServerRequestResult.legacyApplyPatchApproval(
                decision.legacyDecision
            ).jsonValue
        }
    }

    private func apply(
        _ snapshot: CodexServerRequestInboxSnapshot,
        from adapter: any CodexPromptSessionAdapter,
        generation: UInt64
    ) async {
        guard generation == connectionGeneration else { return }
        let activities = promptSession.sync(snapshot, presentedAt: now())
        activities.forEach { onActivity?($0) }

        let currentKeys = Set(snapshot.requests.map(\.key))
        automaticallyHandledKeys.formIntersection(currentKeys)
        for entry in snapshot.requests {
            guard case .unsupported(let kind) = entry.body,
                  !automaticallyHandledKeys.contains(entry.key),
                  generation == connectionGeneration else { continue }
            do {
                try await automaticallyHandle(entry.key, kind: kind, using: adapter)
                automaticallyHandledKeys.insert(entry.key)
            } catch CodexSessionError.unknownServerRequest {
                automaticallyHandledKeys.insert(entry.key)
            } catch {
                onActivity?(.init(
                    title: "Request handling failed",
                    detail: "\(kind.method): \(error.localizedDescription)"
                ))
            }
        }
    }

    private func automaticallyHandle(
        _ key: CodexServerRequestKey,
        kind: CodexServerRequestKind,
        using adapter: any CodexPromptSessionAdapter
    ) async throws {
        switch kind {
        case .currentTime:
            let seconds = Int64(now().timeIntervalSince1970.rounded(.down))
            try await adapter.resolveServerRequest(
                key,
                result: CodexValidatedServerRequestResult.currentTime(
                    unixSeconds: seconds
                ).jsonValue
            )

        case .dynamicToolCall:
            try await adapter.resolveServerRequest(
                key,
                result: CodexValidatedServerRequestResult.dynamicTool(
                    success: false,
                    contentItems: []
                ).jsonValue
            )

        case .tokenRefresh, .attestation:
            try await adapter.failServerRequest(
                key,
                error: .init(
                    code: -32_004,
                    message: "Client capability is not configured",
                    data: .dictionary(["method": .string(kind.method)])
                )
            )

        case .unknown(let method):
            try await adapter.failServerRequest(
                key,
                error: .init(
                    code: -32_601,
                    message: "Method not found",
                    data: .dictionary(["method": .string(method)])
                )
            )

        case .commandApproval, .fileChangeApproval, .permissionsApproval,
             .userInput, .mcpElicitation, .legacyApplyPatchApproval,
             .legacyExecCommandApproval:
            try await adapter.failServerRequest(
                key,
                error: .init(
                    code: -32_603,
                    message: "Interactive request could not be projected",
                    data: .dictionary(["method": .string(kind.method)])
                )
            )
        }
    }
}

private extension CodexCommandApprovalDecision {
    var scalarDecision: CodexApprovalDecision? {
        switch self {
        case .accept: .accept
        case .acceptForSession: .acceptForSession
        case .decline: .decline
        case .cancel: .cancel
        case .acceptWithExecpolicyAmendment, .applyNetworkPolicyAmendment: nil
        }
    }

    var legacyDecision: CodexLegacyReviewDecision {
        switch self {
        case .accept: .approved
        case .acceptForSession: .approvedForSession
        case .acceptWithExecpolicyAmendment(let amendment):
            .approvedExecpolicyAmendment(amendment)
        case .applyNetworkPolicyAmendment(let amendment):
            .networkPolicyAmendment(amendment)
        case .decline: .denied
        case .cancel: .abort
        }
    }
}
