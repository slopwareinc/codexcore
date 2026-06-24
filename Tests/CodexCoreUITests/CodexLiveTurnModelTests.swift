import XCTest
@testable import CodexCoreUI

final class CodexLiveTurnModelTests: XCTestCase {
    func testLiveTurnPhaseStateMatchesCapturedWorkingAndWorkedLabels() {
        let start = Date(timeIntervalSince1970: 100)

        let active = CodexLiveTurnModel.phaseState(
            isActive: true,
            startedAt: start,
            now: start.addingTimeInterval(37)
        )

        XCTAssertEqual(active.statusTitle, "Working")
        XCTAssertEqual(active.thinkingTitle, "Thinking")
        XCTAssertEqual(active.elapsedLabel, "Working for 37s")
        XCTAssertEqual(active.stopTitle, "Stop")
        XCTAssertEqual(active.stopShortcut, "Esc")

        let finished = CodexLiveTurnModel.phaseState(
            isActive: false,
            startedAt: start,
            endedAt: start.addingTimeInterval(68),
            now: start.addingTimeInterval(90)
        )

        XCTAssertEqual(finished.statusTitle, "Worked")
        XCTAssertEqual(finished.elapsedLabel, "Worked for 1m 8s")
        XCTAssertNil(finished.stopTitle)
        XCTAssertNil(finished.stopShortcut)
    }

    func testFirstOracleLiveTurnOperationRowsAndFinalResponseActions() {
        let messages = firstImplementationTurnMessages()

        XCTAssertEqual(CodexLiveTurnModel.operationRows(for: messages).map(\.title), [
            "Listed files, ran 2 commands",
            "Read 4 files",
            "Created a file, edited 3 files",
            "Ran npm test for 1s",
            "Ran git status --short",
            "Ran git diff -- README.md package.json test/run.sh src/habits.js"
        ])
        XCTAssertEqual(
            CodexLiveTurnModel.finalAssistantSummary(in: messages),
            "Implemented the habit tracker CLI and verified it with npm test."
        )
        XCTAssertEqual(CodexLiveTurnModel.responseActionTitles, [
            "Copy",
            "Good response",
            "Bad response",
            "Fork from this point"
        ])
    }

    func testFirstOracleLiveTurnAggregateChangeCardSummary() throws {
        let changes = firstImplementationTurnMessages().compactMap(\.fileChange)
        let summary = try XCTUnwrap(CodexLiveTurnModel.changeCardSummary(for: changes))

        XCTAssertEqual(summary.primaryPath, "README.md")
        XCTAssertEqual(summary.primaryType, "Document · MD")
        XCTAssertEqual(summary.title, "Edited 4 files")
        XCTAssertEqual(summary.addedLabel, "+151")
        XCTAssertEqual(summary.removedLabel, "-10")
        XCTAssertEqual(summary.actionTitles, ["Undo", "Review"])
        XCTAssertEqual(summary.visibleFileRows.map(\.displayTitle), [
            "README.md +5 -3",
            "package.json +1 -1",
            "src/habits.js +124 -0"
        ])
        XCTAssertEqual(summary.hiddenRowsTitle, "Show 1 more file")
    }

    func testSecondOracleLiveTurnRowsAndChangeCardSummary() throws {
        let messages = secondImplementationTurnMessages()
        let summary = try XCTUnwrap(CodexLiveTurnModel.changeCardSummary(for: messages.compactMap(\.fileChange), visibleRowLimit: 3))

        XCTAssertEqual(CodexLiveTurnModel.operationRows(for: messages).map(\.title), [
            "Read 3 files",
            "Edited 3 files",
            "Ran npm test for 1s",
            "Ran git status --short"
        ])
        XCTAssertEqual(summary.title, "Edited 3 files")
        XCTAssertEqual(summary.addedLabel, "+34")
        XCTAssertEqual(summary.removedLabel, "-0")
        XCTAssertEqual(summary.visibleFileRows.map(\.displayTitle), [
            "README.md +1 -0",
            "src/habits.js +27 -0",
            "test/run.sh +6 -0"
        ])
        XCTAssertNil(summary.hiddenRowsTitle)
        XCTAssertEqual(CodexLiveTurnModel.finalAssistantSummary(in: messages), "Added the stats command to the habit tracker.")
    }

    private func firstImplementationTurnMessages() -> [CodexChatMessage] {
        [
            command("pwd"),
            command("ls"),
            command("git status --short"),
            read("package.json"),
            read("hello.js"),
            read("README.md"),
            read("run.sh"),
            change(path: "README.md", kind: "update", added: 5, removed: 3),
            change(path: "package.json", kind: "update", added: 1, removed: 1),
            change(path: "src/habits.js", kind: "add", added: 124, removed: 0),
            change(path: "test/run.sh", kind: "update", added: 21, removed: 6),
            command("npm test", duration: "1s"),
            command("git status --short"),
            command("git diff -- README.md package.json test/run.sh src/habits.js"),
            assistant("Implemented the habit tracker CLI and verified it with npm test.")
        ]
    }

    private func secondImplementationTurnMessages() -> [CodexChatMessage] {
        [
            read("README.md"),
            read("src/habits.js"),
            read("test/run.sh"),
            change(path: "README.md", kind: "update", added: 1, removed: 0),
            change(path: "src/habits.js", kind: "update", added: 27, removed: 0),
            change(path: "test/run.sh", kind: "update", added: 6, removed: 0),
            command("npm test", duration: "1s"),
            command("git status --short"),
            assistant("Added the stats command to the habit tracker.")
        ]
    }

    private func command(_ command: String, duration: String? = nil) -> CodexChatMessage {
        CodexChatMessage(
            role: .terminal,
            text: command,
            commandRun: CodexChatMessage.CommandRun(
                itemID: command,
                command: command,
                output: duration.map { "duration=\($0)" } ?? "",
                status: "completed",
                exitCode: 0,
                isStreaming: false
            )
        )
    }

    private func read(_ path: String) -> CodexChatMessage {
        CodexChatMessage(
            role: .tool,
            text: "Read \(path)",
            toolCall: CodexChatMessage.ToolCall(
                itemID: path,
                server: "filesystem",
                tool: "read_file",
                progress: ["Read \(path)"],
                result: path,
                isStreaming: false
            )
        )
    }

    private func change(path: String, kind: String, added: Int, removed: Int) -> CodexChatMessage {
        CodexChatMessage(
            role: .fileChange,
            text: path,
            fileChange: CodexChatMessage.fileChange(
                itemID: path,
                path: path,
                diff: diff(path: path, added: added, removed: removed),
                kind: kind,
                status: "completed",
                isStreaming: false
            )
        )
    }

    private func assistant(_ text: String) -> CodexChatMessage {
        CodexChatMessage(role: .assistant, text: text, detail: "final_answer")
    }

    private func diff(path: String, added: Int, removed: Int) -> String {
        var lines = [
            "diff --git a/\(path) b/\(path)",
            "--- a/\(path)",
            "+++ b/\(path)",
            "@@ -1 +1 @@"
        ]
        lines.append(contentsOf: Array(repeating: "-old", count: removed))
        lines.append(contentsOf: Array(repeating: "+new", count: added))
        return lines.joined(separator: "\n")
    }
}
