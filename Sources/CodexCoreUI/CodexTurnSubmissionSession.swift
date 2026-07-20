import Foundation
import CodexCore

public enum CodexDraftSubmissionRoute: Equatable, Sendable {
    case none
    case followUp(CodexComposerSubmission)
    case goal(CodexComposerSubmission)
    case turn(CodexComposerSubmission)
}

public enum CodexFollowUpSubmissionRoute: Equatable, Sendable {
    case queued(submission: CodexComposerSubmission, activity: CodexActivity)
    case steer(submission: CodexComposerSubmission, activity: CodexActivity)
}

public struct CodexQueuedFollowUpSubmission: Equatable, Sendable {
    public var submission: CodexComposerSubmission
    public var prompt: String
    public var input: [CodexInput]
    public var activity: CodexActivity

    public init(submission: CodexComposerSubmission, activity: CodexActivity) {
        self.submission = submission
        self.prompt = submission.prompt
        self.input = submission.turnInput
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
        guard !prompt.isEmpty || !composerSession.referencedFiles.isEmpty else { return .none }

        if canSendFollowUp {
            return composerSession.consumeDraftForFollowUp().map(CodexDraftSubmissionRoute.followUp) ?? .none
        }

        if isGoalPursuitEnabled {
            return composerSession.consumeDraftForGoal().map(CodexDraftSubmissionRoute.goal) ?? .none
        }

        return composerSession.consumeDraftForTurn().map(CodexDraftSubmissionRoute.turn) ?? .none
    }

    public static func prepareFollowUp(
        submission: CodexComposerSubmission,
        composerSession: inout CodexComposerStateSession,
        mainChatSession: inout CodexMainChatSession,
        followUpBehavior: CodexFollowUpBehavior,
        canSteer: Bool
    ) -> CodexFollowUpSubmissionRoute {
        if followUpBehavior == .steer, canSteer {
            return .steer(
                submission: submission,
                activity: mainChatSession.appendSteeredFollowUp(submission.prompt)
            )
        }

        composerSession.enqueueFollowUp(submission)
        return .queued(
            submission: submission,
            activity: mainChatSession.appendQueuedFollowUp(submission.prompt)
        )
    }

    public static func prepareFollowUp(
        prompt: String,
        composerSession: inout CodexComposerStateSession,
        mainChatSession: inout CodexMainChatSession,
        followUpBehavior: CodexFollowUpBehavior,
        canSteer: Bool
    ) -> CodexFollowUpSubmissionRoute {
        prepareFollowUp(
            submission: CodexComposerSubmission(prompt: prompt),
            composerSession: &composerSession,
            mainChatSession: &mainChatSession,
            followUpBehavior: followUpBehavior,
            canSteer: canSteer
        )
    }

    public static func failSteeredFollowUp(
        submission: CodexComposerSubmission,
        message: String,
        composerSession: inout CodexComposerStateSession
    ) -> CodexActivity {
        composerSession.enqueueFollowUp(submission)
        return CodexActivity(kind: .turn, title: "Steer failed — queued instead", detail: message)
    }

    public static func dequeueQueuedFollowUp(
        composerSession: inout CodexComposerStateSession,
        mainChatSession: inout CodexMainChatSession,
        isSending: Bool
    ) -> CodexQueuedFollowUpSubmission? {
        guard let submission = composerSession.dequeueQueuedFollowUpSubmission(isSending: isSending) else { return nil }
        return CodexQueuedFollowUpSubmission(
            submission: submission,
            activity: mainChatSession.beginQueuedFollowUp(submission.prompt)
        )
    }

    public static func failQueuedFollowUp(
        _ submission: CodexQueuedFollowUpSubmission,
        message: String,
        composerSession: inout CodexComposerStateSession,
        mainChatSession: inout CodexMainChatSession
    ) -> CodexActivity {
        composerSession.requeueFollowUp(submission.submission)
        return mainChatSession.failQueuedFollowUp(message: message)
    }
}
