import XCTest
@testable import CodexCoreUI

final class CodexCommandPaletteModelTests: XCTestCase {
    func testDeferredMobileSurfaceIsAbsentFromRoutesAndCommands() {
        XCTAssertEqual(CodexAppRoute.allCases, [.chat, .search, .plugins, .automations, .settingsAbout])
        XCTAssertFalse(CodexCommandPaletteModel.defaultCommandRows.contains { row in
            row.title.localizedCaseInsensitiveContains("mobile")
                || row.detail.localizedCaseInsensitiveContains("mobile")
        })
    }

    func testEmptyPaletteShowsObservedCategoryOrderAndSuggestedCommand() {
        let model = CodexCommandPaletteModel(
            query: "",
            commandRows: CodexCommandPaletteModel.defaultCommandRows,
            chatResults: [],
            isLoading: false,
            errorMessage: nil
        )

        XCTAssertEqual(model.status, .empty)
        XCTAssertEqual(model.sections.map(\.title), [
            "Suggested",
            "Chat",
            "Navigation",
            "Panels",
            "Skills",
            "Configure",
            "App",
            "Chats"
        ])
        XCTAssertEqual(model.sections.first?.rows.first?.title, "New chat")
        XCTAssertEqual(model.sections.first?.rows.first?.shortcutBadge, "⌘N")
    }

    func testTypedPaletteMergesCommandAndChatResultsWithBadgesAndAccessibleLabels() throws {
        let results = [
            searchResult(id: "thread-validation", title: "Run validation project tests", snippet: "Review validation steps", path: "/repo/.ai/oracle/validation-project"),
            searchResult(id: "thread-test", title: "Test chat", snippet: "validation fixture", path: "/repo/validation-project")
        ]

        let model = CodexCommandPaletteModel(
            query: "validation",
            commandRows: CodexCommandPaletteModel.defaultCommandRows,
            chatResults: results,
            isLoading: false,
            errorMessage: nil
        )

        XCTAssertEqual(model.status, .results)
        XCTAssertEqual(model.sections.map(\.title), ["Chats"])
        let rows = try XCTUnwrap(model.sections.first?.rows)
        XCTAssertEqual(rows.map(\.title), ["Run validation project tests", "Test chat"])
        XCTAssertEqual(rows.map(\.shortcutBadge), ["⌘1", "⌘2"])
        XCTAssertTrue(rows[0].detail.contains(".ai/oracle/validation-project"))
        XCTAssertTrue(rows[1].accessibilityLabel.contains("Shortcut ⌘2"))
        XCTAssertTrue(rows[1].accessibilityLabel.contains("validation-project"))
    }

    func testTypedPaletteCanReturnCommandMatchesWithoutChatResults() {
        let model = CodexCommandPaletteModel(
            query: "plugin",
            commandRows: CodexCommandPaletteModel.defaultCommandRows,
            chatResults: [],
            isLoading: false,
            errorMessage: nil
        )

        XCTAssertEqual(model.status, .results)
        XCTAssertEqual(model.sections.map(\.title), ["Commands"])
        XCTAssertEqual(model.sections.first?.rows.first?.title, "Plugins")
    }

    func testPaletteLoadingErrorAndNoResultsStates() {
        let loading = CodexCommandPaletteModel(
            query: "validation",
            commandRows: [],
            chatResults: [],
            isLoading: true,
            errorMessage: nil
        )
        XCTAssertEqual(loading.status, .loading)
        XCTAssertEqual(loading.status.title, "Searching...")

        let error = CodexCommandPaletteModel(
            query: "validation",
            commandRows: [],
            chatResults: [],
            isLoading: false,
            errorMessage: "Search failed"
        )
        XCTAssertEqual(error.status, .error("Search failed"))
        XCTAssertEqual(error.status.title, "Search failed")

        let empty = CodexCommandPaletteModel(
            query: "missing",
            commandRows: [],
            chatResults: [],
            isLoading: false,
            errorMessage: nil
        )
        XCTAssertEqual(empty.status, .noResults("missing"))
        XCTAssertEqual(empty.status.title, "No results for missing")
    }

    private func searchResult(id: String, title: String, snippet: String, path: String) -> CodexThreadSearchResult {
        CodexThreadSearchResult(
            thread: CodexThreadSummary(
                id: id,
                title: title,
                preview: "Preview",
                workspacePath: path
            ),
            snippet: snippet
        )
    }
}
