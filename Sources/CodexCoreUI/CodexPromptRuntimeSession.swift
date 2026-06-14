import Foundation
import CodexCore

@MainActor
public final class CodexPromptRuntimeSession {
    private var promptSession: CodexPromptStateSession
    private let eventSession: CodexPromptEventSession
    private let bridge: CodexInteractivePromptBridge

    public init(
        promptSession: CodexPromptStateSession = CodexPromptStateSession(),
        eventSession: CodexPromptEventSession = CodexPromptEventSession(),
        bridge: CodexInteractivePromptBridge = CodexInteractivePromptBridge()
    ) {
        self.promptSession = promptSession
        self.eventSession = eventSession
        self.bridge = bridge
    }

    public var approvalPrompts: [CodexApprovalPrompt] {
        promptSession.approvalPrompts
    }

    public var interactivePrompts: [CodexInteractivePrompt] {
        promptSession.interactivePrompts
    }

    public func handleMCPServerElicitationRequest(_ request: JSONRPCServerRequest) async -> CodexJSONValue? {
        guard request.method == CodexAppServerServerRequestMethod.mcpServerElicitationRequest.rawValue else {
            return nil
        }
        return await bridge.handle(request)
    }

    public func startApprovalStoreMirror(
        from codex: Codex,
        onActivity: @escaping @MainActor (CodexPromptStateActivity) -> Void
    ) {
        eventSession.startApprovalStoreMirror(from: codex) { [weak self] approvals, userInput in
            guard let self else { return }
            for activity in promptSession.sync(approvalRequests: approvals, userInput: userInput) {
                onActivity(activity)
            }
        }
    }

    public func startInteractivePromptEventListener(
        onActivity: @escaping @MainActor (CodexPromptStateActivity) -> Void
    ) {
        eventSession.startInteractivePromptEventListener(from: bridge) { [weak self] event in
            guard let self else { return }
            if let activity = promptSession.apply(event) {
                onActivity(activity)
            }
        }
    }

    public func resolveApprovalPrompt(
        id: String,
        approved: Bool,
        using codex: Codex?
    ) async -> CodexPromptStateActivity? {
        let effect = await promptSession.resolveApprovalPrompt(id: id, approved: approved, using: codex)
        return promptSession.apply(effect)
    }

    public func submitInteractivePrompt(
        id: String,
        answers: [String: String],
        using codex: Codex?
    ) async -> CodexPromptStateActivity? {
        let effect = await promptSession.submitInteractivePrompt(
            id: id,
            answers: answers,
            using: codex,
            bridge: bridge
        )
        return promptSession.apply(effect)
    }

    public func acceptInteractivePrompt(id: String) async {
        await promptSession.acceptInteractivePrompt(id: id, bridge: bridge)
    }

    public func declineInteractivePrompt(
        id: String,
        using codex: Codex?
    ) async -> CodexPromptStateActivity? {
        let effect = await promptSession.declineInteractivePrompt(
            id: id,
            using: codex,
            bridge: bridge
        )
        return promptSession.apply(effect)
    }

    public func reset() {
        eventSession.reset()
        promptSession.reset()
    }

    public func cancelAllPrompts() async {
        await bridge.cancelAll()
    }
}
