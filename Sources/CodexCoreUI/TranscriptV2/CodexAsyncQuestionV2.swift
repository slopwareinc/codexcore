import CodexCore
import Foundation

/// An asynchronous assistant question answered through an ordinary user message.
/// It does not represent a pending app-server RPC or block the originating turn.
public struct CodexAsyncQuestionV2: Identifiable, Sendable, Equatable {
    public struct Question: Identifiable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var options: [String]

        public init(id: String, title: String, options: [String] = []) {
            self.id = id
            self.title = title
            self.options = options
        }
    }

    public var id: String
    public var prompt: String
    public var questions: [Question]
    public var isStreaming: Bool

    public init(id: String, prompt: String = "", questions: [Question], isStreaming: Bool = false) {
        self.id = id
        self.prompt = prompt
        self.questions = questions
        self.isStreaming = isStreaming
    }

    /// Matches T3 Code's message-mode reply: question, answer, then a blank line
    /// before the next pair. Every question requires an explicit nonempty answer.
    public func answerMessage(answers: [String: String]) -> String? {
        guard !isStreaming, !questions.isEmpty else { return nil }
        var replies: [String] = []
        for question in questions {
            guard let answer = answers[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !answer.isEmpty else { return nil }
            replies.append("\(question.title)\n\(answer)")
        }
        return replies.joined(separator: "\n\n")
    }

    init?(itemID: String, payload: [String: CodexJSONValue], isStreaming: Bool) {
        guard payload["delivery"] == .string("async"),
              case .array(let values) = payload["questions"], !values.isEmpty else { return nil }
        var questions: [Question] = []
        for (index, value) in values.enumerated() {
            guard let question = try? value.decode(CodexSchemaAsyncUserInputQuestion.self),
                  !question.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            questions.append(.init(id: "\(itemID):\(index)", title: question.title, options: question.options ?? []))
        }
        self.init(
            id: itemID,
            prompt: CodexJSONCoercion.string(from: payload["text"]) ?? "",
            questions: questions,
            isStreaming: isStreaming
        )
    }
}

/// Keeps a typed custom answer when the user temporarily selects a suggestion.
/// Reopening Other restores that draft instead of silently discarding it.
struct CodexAsyncQuestionAnswerDraft: Equatable {
    var selectedOption: String?
    var customAnswer = ""
    var usesCustomAnswer = false

    var answer: String? {
        if usesCustomAnswer { return customAnswer.nilIfBlank }
        return selectedOption?.nilIfBlank
    }

    mutating func selectOption(_ option: String) {
        selectedOption = option
        usesCustomAnswer = false
    }

    mutating func editCustomAnswer(_ answer: String) {
        customAnswer = answer
        usesCustomAnswer = true
    }
}
