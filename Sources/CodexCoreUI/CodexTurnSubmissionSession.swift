import Foundation
import CodexCore

public enum CodexDraftSubmissionRoute: Equatable, Sendable {
    case none
    case followUp(String)
    case goal(CodexComposerSubmission)
    case turn(CodexComposerSubmission)
}

public enum CodexFollowUpSubmissionRoute: Equatable, Sendable {
    case queued(prompt: String, activity: CodexActivity)
    case steer(prompt: String, activity: CodexActivity)
}

public struct CodexQueuedFollowUpSubmission: Equatable, Sendable {
    public var prompt: String
    public var input: [CodexInput]
    public var activity: CodexActivity

    public init(prompt: String, input: [CodexInput], activity: CodexActivity) {
        self.prompt = prompt
        self.input = input
        self.activity = activity
    }
}

public enum CodexTurnSubmissionSession {
    public static func consumeDraft(
        composerSession: inout CodexComposerStateSession,
        canSendFollowUp: Bool,
        isGoalPursuitEnabled: Bool
    ) -> CodexDraftSubmissionRoute {
        let prompt = composerSession.trimmedDraft
        guard !prompt.isEmpty else { return .none }

        if canSendFollowUp {
            return composerSession.consumeDraftForFollowUp().map(CodexDraftSubmissionRoute.followUp) ?? .none
        }

        if isGoalPursuitEnabled {
            return composerSession.consumeDraftForGoal().map(CodexDraftSubmissionRoute.goal) ?? .none
        }

        return composerSession.consumeDraftForTurn().map(CodexDraftSubmissionRoute.turn) ?? .none
    }

    public static func prepareFollowUp(
        prompt: String,
        composerSession: inout CodexComposerStateSession,
        mainChatSession: inout CodexMainChatSession,
        followUpBehavior: CodexFollowUpBehavior,
        canSteer: Bool
    ) -> CodexFollowUpSubmissionRoute {
        if followUpBehavior == .steer, canSteer {
            return .steer(
                prompt: prompt,
                activity: mainChatSession.appendSteeredFollowUp(prompt)
            )
        }

        composerSession.enqueueFollowUp(prompt)
        return .queued(
            prompt: prompt,
            activity: mainChatSession.appendQueuedFollowUp(prompt)
        )
    }

    public static func failSteeredFollowUp(
        prompt: String,
        message: String,
        composerSession: inout CodexComposerStateSession
    ) -> CodexActivity {
        composerSession.enqueueFollowUp(prompt)
        return CodexActivity(kind: .turn, title: "Steer failed — queued instead", detail: message)
    }

    public static func dequeueQueuedFollowUp(
        composerSession: inout CodexComposerStateSession,
        mainChatSession: inout CodexMainChatSession,
        isSending: Bool
    ) -> CodexQueuedFollowUpSubmission? {
        guard let prompt = composerSession.dequeueQueuedFollowUp(isSending: isSending) else { return nil }
        return CodexQueuedFollowUpSubmission(
            prompt: prompt,
            input: CodexComposerSubmission(prompt: prompt).turnInput,
            activity: mainChatSession.beginQueuedFollowUp(prompt)
        )
    }

    public static func failQueuedFollowUp(
        _ submission: CodexQueuedFollowUpSubmission,
        message: String,
        composerSession: inout CodexComposerStateSession,
        mainChatSession: inout CodexMainChatSession
    ) -> CodexActivity {
        composerSession.requeueFollowUp(submission.prompt)
        return mainChatSession.failQueuedFollowUp(message: message)
    }
}

public struct CodexTurnLaunchConfiguration: Equatable, Sendable {
    public var approvalMode: ApprovalMode
    public var cwd: String
    public var effort: ReasoningEffort?
    public var modelIdentifier: String?
    public var sandbox: Sandbox
    public var parameters: [String: CodexJSONValue]

    public init(
        approvalMode: ApprovalMode,
        cwd: String,
        effort: ReasoningEffort?,
        modelIdentifier: String?,
        sandbox: Sandbox,
        parameters: [String: CodexJSONValue] = [:]
    ) {
        self.approvalMode = approvalMode
        self.cwd = cwd
        self.effort = effort
        self.modelIdentifier = modelIdentifier
        self.sandbox = sandbox
        self.parameters = parameters
    }
}

public extension CodexThread {
    func turn(
        _ input: [CodexInput],
        configuration: CodexTurnLaunchConfiguration
    ) async throws -> CodexTurnHandle {
        try await turn(
            input,
            approvalMode: configuration.approvalMode,
            cwd: configuration.cwd,
            effort: configuration.effort,
            model: configuration.modelIdentifier,
            sandbox: configuration.sandbox,
            params: configuration.parameters
        )
    }
}
