import Foundation
import GhosttyTerminal
import XCTest
@testable import CodexCoreUI

final class CodexWorkspaceToolsTests: XCTestCase {
    func testLauncherOptionsEnableTerminalAndBrowserAndDisableFutureTools() {
        let options = CodexWorkspaceToolCatalog.launcherOptions

        XCTAssertEqual(options.first?.id, CodexWorkspaceToolCatalog.terminalID)
        XCTAssertEqual(options.first?.title, "Terminal")
        XCTAssertEqual(options.first?.isEnabled, true)

        let browser = options.first { $0.id == CodexWorkspaceToolCatalog.browserID }
        XCTAssertEqual(browser?.title, "Browser")
        XCTAssertEqual(browser?.isEnabled, true)
        XCTAssertEqual(browser?.detail, "Browse docs and local previews")

        let disabledOptions = options.filter { ![CodexWorkspaceToolCatalog.terminalID, CodexWorkspaceToolCatalog.browserID].contains($0.id) }
        XCTAssertTrue(disabledOptions.allSatisfy { !$0.isEnabled })
        XCTAssertTrue(disabledOptions.allSatisfy { $0.detail.contains("Not available") })
    }

    @MainActor
    func testPanelStateOpensNumberedToolsAndSelectsLatest() {
        let panel = CodexWorkspacePanelState()

        let firstTerminal = panel.openTerminal(workspacePath: "/tmp")
        let firstBrowser = panel.openBrowser()

        XCTAssertEqual(panel.terminalSessions.count, 1)
        XCTAssertEqual(panel.browserSessions.count, 1)
        XCTAssertEqual(panel.terminalSessions.first?.title, "Terminal")
        XCTAssertEqual(panel.browserSessions.first?.title, "Browser")
        // The most-recently opened tool becomes selected.
        XCTAssertEqual(panel.selectedTabID, firstBrowser)

        let secondTerminal = panel.openTerminal(workspacePath: "/tmp")
        XCTAssertEqual(panel.terminalSessions.last?.title, "Terminal 2")
        XCTAssertEqual(panel.selectedTabID, secondTerminal)
        XCTAssertNotEqual(firstTerminal, secondTerminal)
        XCTAssertTrue(panel.hasOpenTools)
    }

    @MainActor
    func testPanelStateCloseFallsBackToRemainingTabThenProvidedTabs() {
        let panel = CodexWorkspacePanelState()
        let terminal = panel.openTerminal(workspacePath: "/tmp")
        let browser = panel.openBrowser()

        // Closing the selected browser falls back to the surviving terminal.
        panel.closeBrowser(id: browser, fallbackTabIDs: ["review-tab"])
        XCTAssertTrue(panel.browserSessions.isEmpty)
        XCTAssertEqual(panel.selectedTabID, terminal)

        // Closing the last tool falls back to a provided panel tab id.
        panel.closeTerminal(id: terminal, fallbackTabIDs: ["review-tab"])
        XCTAssertTrue(panel.terminalSessions.isEmpty)
        XCTAssertEqual(panel.selectedTabID, "review-tab")
        XCTAssertFalse(panel.hasOpenTools)
    }

    @MainActor
    func testPanelStatePurgeClearsSessionsAndClosesPanel() {
        let panel = CodexWorkspacePanelState()
        panel.openTerminal(workspacePath: "/tmp")
        panel.openBrowser()
        panel.isAgentPanelOpen = true

        panel.purge()

        XCTAssertTrue(panel.terminalSessions.isEmpty)
        XCTAssertTrue(panel.browserSessions.isEmpty)
        XCTAssertNil(panel.selectedTabID)
        XCTAssertFalse(panel.isAgentPanelOpen)
    }

    @MainActor
    func testTerminalSessionUsesGhosttyExecBackendAndWorkspaceDirectory() {
        let workspace = FileManager.default.temporaryDirectory.path
        let session = CodexTerminalSession(workingDirectory: workspace, fontSize: 12)

        XCTAssertEqual(session.title, "Terminal")
        XCTAssertEqual(session.initialWorkingDirectory, workspace)
        XCTAssertEqual(session.state.configuration.workingDirectory, workspace)
        XCTAssertEqual(session.state.configuration.fontSize, 12)
        if case .exec = session.state.configuration.backend {
            XCTAssertTrue(true)
        } else {
            XCTFail("Terminal sessions should use Ghostty exec backend")
        }
    }

    func testTerminalPathFormatterCompactsHomeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        XCTAssertEqual(CodexTerminalPathFormatter.display(home), "~")
        XCTAssertEqual(CodexTerminalPathFormatter.display(home + "/Projects/CodexCore"), "~/Projects/CodexCore")
        XCTAssertEqual(CodexTerminalPathFormatter.display("/tmp/CodexCore"), "/tmp/CodexCore")
    }

    func testBrowserNavigationResolverKeepsFullURLs() {
        XCTAssertEqual(
            CodexBrowserNavigationResolver.url(for: "https://example.com/docs?q=swift").absoluteString,
            "https://example.com/docs?q=swift"
        )
        XCTAssertEqual(
            CodexBrowserNavigationResolver.url(for: "http://localhost:3000").absoluteString,
            "http://localhost:3000"
        )
    }

    func testBrowserNavigationResolverInfersBareDomains() {
        XCTAssertEqual(
            CodexBrowserNavigationResolver.url(for: "example.com").absoluteString,
            "https://example.com"
        )
        XCTAssertEqual(
            CodexBrowserNavigationResolver.url(for: "example.com/docs").absoluteString,
            "https://example.com/docs"
        )
    }

    func testBrowserNavigationResolverUsesHTTPForBareLocalhost() {
        XCTAssertEqual(
            CodexBrowserNavigationResolver.url(for: "localhost:5173").absoluteString,
            "http://localhost:5173"
        )
        XCTAssertEqual(
            CodexBrowserNavigationResolver.url(for: "127.0.0.1:8080").absoluteString,
            "http://127.0.0.1:8080"
        )
    }

    func testBrowserNavigationResolverSearchesOtherText() {
        XCTAssertEqual(
            CodexBrowserNavigationResolver.url(for: "swift webkit docs").absoluteString,
            "https://duckduckgo.com/?q=swift%20webkit%20docs"
        )
    }

    @MainActor
    func testBrowserSessionInitialState() {
        let session = CodexBrowserSession()

        XCTAssertEqual(session.title, "Browser")
        XCTAssertEqual(session.addressText, "")
        XCTAssertNil(session.currentURL)
        XCTAssertFalse(session.isLoading)
        XCTAssertFalse(session.canGoBack)
        XCTAssertFalse(session.canGoForward)
    }

    @MainActor
    func testBrowserSessionNavigateNormalizesAddressText() {
        let session = CodexBrowserSession()
        session.addressText = "example.com"

        session.navigateToAddressText()

        XCTAssertEqual(session.addressText, "https://example.com")
        XCTAssertEqual(session.currentURL?.absoluteString, "https://example.com")
    }
}
