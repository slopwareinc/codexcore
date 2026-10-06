@testable import CodexCore
@testable import CodexCoreUI
import Testing

struct CodexAsyncQuestionTests {
    @MainActor
    @Test func submissionReceiptsPreventDuplicatesAndOnlyRejectionsAllowRetry() {
        let state = CodexAsyncQuestionPresentationState()
        #expect(state.beginSubmission())
        #expect(!state.beginSubmission())
        state.completeSubmission(.rejected(message: "Reconnect first."))
        #expect(state.submissionStatus == .rejected("Reconnect first."))
        #expect(state.beginSubmission())
        state.completeSubmission(.retainedForRetry(message: "The request failed."))
        #expect(state.submissionStatus == .retainedForRetry("The request failed."))
        #expect(!state.beginSubmission())
        state.reset()
        #expect(state.beginSubmission())
        state.completeSubmission(.accepted)
        #expect(state.submissionStatus == .accepted)
        #expect(!state.beginSubmission())
        state.reset()
        #expect(state.beginSubmission())
        state.completeStaging()
        #expect(state.submissionStatus == .staged)
        #expect(!state.beginSubmission())
    }

    @MainActor
    @Test func sameQuestionIDInDifferentTurnsKeepsDistinctDraftsAndSubmissionReceipts() {
        let store = CodexAsyncQuestionPresentationStore()
        let first = store.state(threadID: "thread", questionID: "thread:turn-1:item:question")
        first.drafts["question:0"] = .init(selectedOption: "main")
        #expect(first.beginSubmission())
        first.completeSubmission(.accepted)
        let second = store.state(threadID: "thread", questionID: "thread:turn-2:item:question")
        #expect(second !== first)
        #expect(second.drafts.isEmpty)
        #expect(second.submissionStatus == .idle)
        #expect(store.state(threadID: "thread", questionID: "thread:turn-1:item:question").submissionStatus == .accepted)
    }

    @MainActor
    @Test func presentationDraftsSurviveCellReuseAndAreScopedAndBounded() {
        let store = CodexAsyncQuestionPresentationStore(capacity: 2)
        let original = store.state(threadID: "thread", questionID: "question")
        original.drafts["question:0"] = .init(selectedOption: "main")
        original.questionIndex = 1
        original.isCollapsed = true
        let revisited = store.state(threadID: "thread", questionID: "question")
        #expect(revisited === original)
        #expect(revisited.drafts["question:0"]?.answer == "main")
        #expect(revisited.questionIndex == 1)
        #expect(revisited.isCollapsed)
        let otherThread = store.state(threadID: "other-thread", questionID: "question")
        #expect(otherThread !== original)
        #expect(otherThread.drafts.isEmpty)
        _ = store.state(threadID: "thread", questionID: "new-question")
        #expect(store.state(threadID: "thread", questionID: "question") !== original)
        store.clear()
        #expect(store.state(threadID: "other-thread", questionID: "question") !== otherThread)
    }

    @Test func asyncAgentQuestionsStayInNarrativeWithoutBecomingFinalAnswerOrRPCPrompt() throws {
        let result = projectQuestion(delivery: "async")
        let turn = try #require(result.presentation.transcript.turns.first)
        let question = try #require(turn.narrative.compactMap { entry -> CodexAsyncQuestionV2? in
            guard case .questions(let value) = entry else { return nil }
            return value
        }.first)
        #expect(question.id == "question")
        #expect(question.prompt == "Which branch?")
        #expect(question.questions == [.init(id: "question:0", title: "Which branch?", options: ["main", "dev"])])
        #expect(question.isStreaming == false)
        #expect(turn.finalAnswer == nil)
        #expect(result.presentation.pendingRequests.isEmpty)
    }

    @Test func unknownDeliveryAndMalformedQuestionPayloadPreserveAssistantText() throws {
        for result in [projectQuestion(delivery: "future"), projectQuestion(delivery: "async", title: "  ")] {
            let turn = try #require(result.presentation.transcript.turns.first)
            #expect(turn.finalAnswer?.text == "Which branch?")
            #expect(!turn.narrative.contains {
                if case .questions = $0 { return true }
                return false
            })
        }
    }

    @Test func repliesMatchT3MessageModeFormatAndRequireEveryExplicitAnswer() {
        let model = CodexAsyncQuestionV2(id: "questions", questions: [
            .init(id: "branch", title: "Which branch?", options: ["main", "dev"]),
            .init(id: "tests", title: "Which tests?"),
        ])
        #expect(model.answerMessage(answers: [:]) == nil)
        #expect(model.answerMessage(answers: ["branch": "main"]) == nil)
        #expect(model.answerMessage(answers: ["branch": "main", "tests": " \n"]) == nil)
        #expect(model.answerMessage(answers: ["branch": " main ", "tests": "unit\nintegration"]) == "Which branch?\nmain\n\nWhich tests?\nunit\nintegration")
        var streaming = model
        streaming.isStreaming = true
        #expect(streaming.answerMessage(answers: ["branch": "main", "tests": "all"]) == nil)
    }

    @Test func optionSelectionPreservesCustomDraftAndEditingRestoresIt() {
        var draft = CodexAsyncQuestionAnswerDraft()
        draft.editCustomAnswer("custom branch")
        #expect(draft.answer == "custom branch")
        draft.selectOption("main")
        #expect(draft.answer == "main")
        #expect(draft.customAnswer == "custom branch")
        draft.editCustomAnswer(draft.customAnswer)
        #expect(draft.answer == "custom branch")
        draft.editCustomAnswer(" \n")
        #expect(draft.answer == nil)
    }

    private func projectQuestion(delivery: String, title: String = "Which branch?") -> CodexCanonicalTranscriptProjectionResult {
        let threadID: ThreadID = "thread"
        let turnID: TurnID = "turn"
        let item = CanonicalItem(
            key: .init(threadID: threadID, turnID: turnID, itemID: "question"),
            kind: .agentMessage,
            payload: [
                "delivery": .string(delivery), "text": .string("Which branch?"),
                "questions": .array([.dictionary([
                    "title": .string(title), "options": .array([.string("main"), .string("dev")]),
                ])]),
            ],
            authority: .completed,
            consistency: .authoritative,
            lastChangedRevision: StateRevision(1)
        )
        let turn = CanonicalTurn(
            key: .init(threadID: threadID, turnID: turnID), status: .completed,
            itemOrder: [item.key.itemID], itemsCoverage: .full,
            lastChangedRevision: StateRevision(1)
        )
        let snapshot = CanonicalStateSnapshot(
            revision: StateRevision(1), threadOrder: [threadID],
            threads: [threadID: .init(id: threadID, status: .idle, turnOrder: [turnID])],
            turns: [turn.key: turn], items: [item.key: item]
        )
        return CodexCanonicalTranscriptProjector().rebuild(snapshot: snapshot, threadID: threadID)
    }
}
