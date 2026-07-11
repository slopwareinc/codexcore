import XCTest
@testable import CodexCore
@testable import CodexCoreUI

final class CodexInteractivePromptProgressTests: XCTestCase {
    private let questions = [
        CodexUserInputQuestion(id: "experience", question: "What is your experience?"),
        CodexUserInputQuestion(id: "goal", question: "What should you make first?")
    ]

    func testPresentsOneQuestionAndPreservesAnswersAcrossNavigation() {
        var progress = CodexInteractivePromptProgress()

        XCTAssertEqual(progress.currentQuestion(in: questions)?.id, "experience")
        XCTAssertFalse(progress.hasAnswer(for: "experience"))

        progress.answers["experience"] = "New to both"
        progress.moveForward(count: questions.count)

        XCTAssertEqual(progress.currentQuestion(in: questions)?.id, "goal")
        XCTAssertEqual(progress.answers["experience"], "New to both")
        XCTAssertTrue(progress.isLastQuestion(count: questions.count))

        progress.moveBack()
        XCTAssertEqual(progress.currentQuestion(in: questions)?.id, "experience")
        XCTAssertEqual(progress.answers["experience"], "New to both")
    }

    func testNavigationClampsAtQuestionnaireBounds() {
        var progress = CodexInteractivePromptProgress()

        progress.moveBack()
        XCTAssertEqual(progress.questionIndex, 0)

        progress.moveForward(count: 1)
        XCTAssertEqual(progress.questionIndex, 0)
        XCTAssertTrue(progress.isLastQuestion(count: 0))
        XCTAssertNil(progress.currentQuestion(in: []))
    }
}
