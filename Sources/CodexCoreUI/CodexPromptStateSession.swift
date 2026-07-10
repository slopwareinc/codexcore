import Foundation
import CodexCore

public enum CodexInteractivePromptEvent: Sendable, Equatable {
    case added(CodexInteractivePrompt)
    case resolved(String)
}

public struct CodexPromptStateActivity: Equatable, Sendable {
    public var title: String
    public var detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

public enum CodexInteractivePromptResponseTarget: Equatable, Sendable {
    case userInput
    case bridge
}

public enum CodexPromptResponseEffect: Equatable, Sendable {
    case approvalResolved(id: String)
    case interactivePromptResolved(id: String)
    case none
}

public struct CodexPromptStateSession: Equatable, Sendable {
    public private(set) var approvalPrompts: [CodexApprovalPrompt]
    public private(set) var interactivePrompts: [CodexInteractivePrompt]

    private var lastApprovalIDs: Set<String>
    private var lastUserInputIDs: Set<String>

    public init(
        approvalPrompts: [CodexApprovalPrompt] = [],
        interactivePrompts: [CodexInteractivePrompt] = []
    ) {
        self.approvalPrompts = approvalPrompts
        self.interactivePrompts = interactivePrompts
        self.lastApprovalIDs = Set(approvalPrompts.map(\.id))
        self.lastUserInputIDs = []
    }

    @discardableResult
    public mutating func sync(
        approvalRequests: [CodexApprovalRequest],
        userInputs: [CodexUserInputRequest]
    ) -> [CodexPromptStateActivity] {
        var activities: [CodexPromptStateActivity] = []
        let prompts = approvalRequests.map { CodexApprovalPrompt(request: $0) }
        let ids = Set(prompts.map(\.id))

        if ids != lastApprovalIDs || prompts != approvalPrompts {
            let newPrompts = prompts.filter { !lastApprovalIDs.contains($0.id) }
            approvalPrompts = prompts
            activities += newPrompts.map {
                CodexPromptStateActivity(
                    title: "Approval requested",
                    detail: $0.primaryValue ?? $0.kind.displayName
                )
            }
            lastApprovalIDs = ids
        }

        let userInputPrompts = userInputs.map { CodexInteractivePrompt(request: $0) }
        let userInputIDs = Set(userInputPrompts.map(\.id))
        if userInputIDs != lastUserInputIDs
            || userInputPrompts != interactivePrompts.filter({ lastUserInputIDs.contains($0.id) }) {
            let bridgePrompts = interactivePrompts.filter { !lastUserInputIDs.contains($0.id) }
            interactivePrompts = userInputPrompts + bridgePrompts
            activities += userInputPrompts
                .filter { !lastUserInputIDs.contains($0.id) }
                .map { CodexPromptStateActivity(title: "Input requested", detail: $0.detail) }
            lastUserInputIDs = userInputIDs
        }

        return activities
    }

    @available(*, deprecated, message: "Use sync(approvalRequests:userInputs:) for concurrent requests.")
    @discardableResult
    public mutating func sync(
        approvalRequests: [CodexApprovalRequest],
        userInput: CodexUserInputRequest?
    ) -> [CodexPromptStateActivity] {
        sync(approvalRequests: approvalRequests, userInputs: userInput.map { [$0] } ?? [])
    }

    @discardableResult
    public mutating func apply(_ event: CodexInteractivePromptEvent) -> CodexPromptStateActivity? {
        switch event {
        case .added(let prompt):
            upsertInteractivePrompt(prompt)
            return CodexPromptStateActivity(title: "Input requested", detail: prompt.detail)
        case .resolved(let id):
            interactivePrompts.removeAll(where: { $0.id == id })
            return CodexPromptStateActivity(title: "Input resolved", detail: id)
        }
    }

    @discardableResult
    public mutating func resolveApproval(id: String) -> CodexPromptStateActivity {
        approvalPrompts.removeAll(where: { $0.id == id })
        lastApprovalIDs.remove(id)
        return CodexPromptStateActivity(title: "Approval resolved", detail: id)
    }

    public mutating func removeInteractivePrompt(id: String) {
        interactivePrompts.removeAll(where: { $0.id == id })
        lastUserInputIDs.remove(id)
    }

    @discardableResult
    public mutating func apply(_ effect: CodexPromptResponseEffect) -> CodexPromptStateActivity? {
        switch effect {
        case .approvalResolved(let id):
            return resolveApproval(id: id)
        case .interactivePromptResolved(let id):
            removeInteractivePrompt(id: id)
            return nil
        case .none:
            return nil
        }
    }

    public func interactivePromptKind(id: String) -> CodexInteractivePromptKind? {
        interactivePrompts.first(where: { $0.id == id })?.kind
    }

    public func responseTarget(forInteractivePromptID id: String) -> CodexInteractivePromptResponseTarget? {
        guard let kind = interactivePromptKind(id: id) else { return nil }
        switch kind {
        case .userInput:
            return .userInput
        case .mcpElicitation:
            return .bridge
        }
    }

    public func resolveApprovalPrompt(
        id: String,
        approved: Bool,
        using codex: Codex?
    ) async -> CodexPromptResponseEffect {
        await resolveApprovalPrompt(
            id: id,
            decision: approved ? .accept : .decline,
            using: codex
        )
    }

    public func resolveApprovalPrompt(
        id: String,
        decision: CodexCommandApprovalDecision,
        using codex: Codex?
    ) async -> CodexPromptResponseEffect {
        guard let prompt = approvalPrompts.first(where: { $0.id == id }) else { return .none }
        let resolved: Bool
        if prompt.kind == .command {
            resolved = await codex?.respondToCommandApproval(id: id, decision: decision) ?? false
        } else if let scalar = decision.scalarDecision {
            resolved = await codex?.respondToApproval(id: id, decision: scalar) ?? false
        } else {
            resolved = false
        }
        return resolved ? .approvalResolved(id: id) : .none
    }

    public func submitInteractivePrompt(
        id: String,
        answers: [String: String],
        using codex: Codex?,
        bridge: CodexInteractivePromptBridge
    ) async -> CodexPromptResponseEffect {
        switch responseTarget(forInteractivePromptID: id) {
        case .userInput:
            let resolved = await codex?.respondToUserInput(id: id, answers: answers.mapValues { [$0] }) ?? false
            return resolved ? .interactivePromptResolved(id: id) : .none
        case .bridge:
            await bridge.resolveUserInput(id: id, answers: answers)
            return .none
        case nil:
            return .none
        }
    }

    public func declineInteractivePrompt(
        id: String,
        using codex: Codex?,
        bridge: CodexInteractivePromptBridge
    ) async -> CodexPromptResponseEffect {
        switch responseTarget(forInteractivePromptID: id) {
        case .userInput:
            let resolved = await codex?.respondToUserInput(id: id, answers: [:]) ?? false
            return resolved ? .interactivePromptResolved(id: id) : .none
        case .bridge:
            await bridge.decline(id: id)
            return .none
        case nil:
            return .none
        }
    }

    public func acceptInteractivePrompt(
        id: String,
        bridge: CodexInteractivePromptBridge
    ) async {
        await bridge.acceptElicitation(id: id)
    }

    public mutating func reset() {
        approvalPrompts.removeAll()
        interactivePrompts.removeAll()
        lastApprovalIDs.removeAll()
        lastUserInputIDs.removeAll()
    }

    private mutating func upsertInteractivePrompt(_ prompt: CodexInteractivePrompt) {
        if let index = interactivePrompts.firstIndex(where: { $0.id == prompt.id }) {
            interactivePrompts[index] = prompt
        } else {
            interactivePrompts.append(prompt)
        }
    }
}

private extension CodexCommandApprovalDecision {
    var scalarDecision: CodexApprovalDecision? {
        switch self {
        case .accept: return .accept
        case .acceptForSession: return .acceptForSession
        case .decline: return .decline
        case .cancel: return .cancel
        case .acceptWithExecpolicyAmendment, .applyNetworkPolicyAmendment: return nil
        }
    }
}

public actor CodexInteractivePromptBridge {
    private struct PendingPrompt {
        var prompt: CodexInteractivePrompt
        var continuation: CheckedContinuation<CodexJSONValue, Never>
    }

    private var pendingPrompts: [String: PendingPrompt] = [:]
    private var eventContinuation: AsyncStream<CodexInteractivePromptEvent>.Continuation?
    private var eventContinuationID = 0

    public init() {}

    public func events() -> AsyncStream<CodexInteractivePromptEvent> {
        AsyncStream { continuation in
            Task { await self.attach(continuation) }
        }
    }

    public func handle(_ request: JSONRPCServerRequest) async -> CodexJSONValue? {
        guard let prompt = CodexInteractivePrompt(serverRequest: request) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            pendingPrompts[prompt.id] = PendingPrompt(prompt: prompt, continuation: continuation)
            eventContinuation?.yield(.added(prompt))
        }
    }

    public func resolveUserInput(id: String, answers: [String: String]) {
        guard let pending = pendingPrompts.removeValue(forKey: id) else { return }
        let response = pending.prompt.kind == .mcpElicitation
            ? pending.prompt.elicitationResponse(answers: answers)
            : pending.prompt.userInputResponse(answers: answers)
        pending.continuation.resume(returning: response)
        eventContinuation?.yield(.resolved(id))
    }

    public func acceptElicitation(id: String) {
        guard let pending = pendingPrompts.removeValue(forKey: id) else { return }
        pending.continuation.resume(returning: pending.prompt.acceptElicitationResponse())
        eventContinuation?.yield(.resolved(id))
    }

    public func decline(id: String) {
        guard let pending = pendingPrompts.removeValue(forKey: id) else { return }
        pending.continuation.resume(returning: pending.prompt.declineResponse())
        eventContinuation?.yield(.resolved(id))
    }

    public func cancelAll() {
        let prompts = pendingPrompts
        pendingPrompts.removeAll()
        for pending in prompts.values {
            pending.continuation.resume(returning: pending.prompt.declineResponse())
            eventContinuation?.yield(.resolved(pending.prompt.id))
        }
    }

    private func attach(_ continuation: AsyncStream<CodexInteractivePromptEvent>.Continuation) async {
        eventContinuation?.finish()
        eventContinuationID += 1
        let continuationID = eventContinuationID
        eventContinuation = continuation
        continuation.onTermination = { @Sendable _ in
            Task { await self.clearEventContinuation(id: continuationID) }
        }
        for pending in pendingPrompts.values {
            continuation.yield(.added(pending.prompt))
        }
    }

    private func clearEventContinuation(id: Int) {
        guard id == eventContinuationID else { return }
        eventContinuation = nil
    }
}
