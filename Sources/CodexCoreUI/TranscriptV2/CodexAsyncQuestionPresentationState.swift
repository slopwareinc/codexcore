import CodexCore
import Observation

/// UI-owned drafts outlive collection cells, while remaining separate from
/// canonical questions and protocol request lifetimes.
@MainActor
@Observable
final class CodexAsyncQuestionPresentationState {
    enum SubmissionStatus: Equatable {
        case idle, submitting, accepted, staged
        case retainedForRetry(String), rejected(String)

        var canSubmit: Bool {
            switch self {
            case .idle, .rejected: true
            case .submitting, .accepted, .staged, .retainedForRetry: false
            }
        }
    }
    var drafts: [String: CodexAsyncQuestionAnswerDraft] = [:]
    var questionIndex = 0
    var isCollapsed = false
    private(set) var submissionStatus: SubmissionStatus = .idle

    /// Called synchronously before awaiting the host, so repeated clicks cannot
    /// create fresh submissions while the first action is in flight.
    func beginSubmission() -> Bool {
        guard submissionStatus.canSubmit else { return false }
        submissionStatus = .submitting
        return true
    }

    func completeSubmission(_ receipt: CodexTranscriptUserMessageReceipt) {
        switch receipt {
        case .accepted: submissionStatus = .accepted
        case .retainedForRetry(let message): submissionStatus = .retainedForRetry(message)
        case .rejected(let message): submissionStatus = .rejected(message)
        }
    }

    func completeStaging() { submissionStatus = .staged }

    func reset() {
        drafts.removeAll()
        questionIndex = 0
        isCollapsed = false
        submissionStatus = .idle
    }
}

@MainActor
final class CodexAsyncQuestionPresentationStore {
    private struct Key: Hashable {
        var threadID: ThreadID
        var questionID: String
    }
    private var states: [Key: CodexAsyncQuestionPresentationState] = [:]
    private var recency: [Key] = []
    private let capacity: Int

    init(capacity: Int = 128) { self.capacity = max(1, capacity) }

    func state(threadID: ThreadID, questionID: String) -> CodexAsyncQuestionPresentationState {
        let key = Key(threadID: threadID, questionID: questionID)
        recency.removeAll { $0 == key }
        recency.append(key)
        if let existing = states[key] { return existing }
        let state = CodexAsyncQuestionPresentationState()
        states[key] = state
        while recency.count > capacity {
            states.removeValue(forKey: recency.removeFirst())
        }
        return state
    }

    func clear() {
        states.removeAll()
        recency.removeAll()
    }
}
