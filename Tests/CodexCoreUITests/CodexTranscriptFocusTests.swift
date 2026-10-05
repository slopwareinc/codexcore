import AppKit
import SwiftUI
import Testing
@testable import CodexCoreUI

@MainActor struct CodexTranscriptFocusTests {
    @Test func exactAssistantItemFocusUsesSourceIdentityRatherThanRenderIDPrefix() async throws {
        let coordinator = CodexTranscriptListHost.Coordinator()
        let container = CodexTranscriptCollectionContainerView(frame: NSRect(x: 0, y: 0, width: 860, height: 500))
        let window = hostingWindow(container)
        coordinator.attach(to: container)
        defer { coordinator.detach(); window.close() }
        var turns = fixture()
        turns[12].finalAnswer = .init(id: "answer:12", text: "Exact target", isStreaming: false)
        let request = CodexTranscriptFocusRequest(threadID: "thread", turnID: "turn-12", itemID: "answer:12")
        update(coordinator, turns: turns, request: request)
        await coordinator.waitForProjectionForTesting()
        let id = try #require(coordinator.focusedItemIDForTesting)
        let item = try #require(coordinator.renderedItemForTesting(id))
        #expect(item.sourceItemID == "answer:12")
        #expect(item.turnID == "turn-12")
        #expect(item.textRole == .finalAnswer)
        #expect(container.scrollView.contentView.bounds.origin.y > 0)
        #expect(coordinator.pendingFocusRequestForTesting == nil)
        _ = EmptyView().codexTranscriptFocus(request)
    }

    @Test func focusingCollapsedCommandRevealsAndScrollsToItsOutput() async throws {
        let coordinator = CodexTranscriptListHost.Coordinator()
        let container = CodexTranscriptCollectionContainerView(frame: NSRect(x: 0, y: 0, width: 860, height: 500))
        let window = hostingWindow(container)
        coordinator.attach(to: container)
        defer { coordinator.detach(); window.close() }
        var turns = fixture()
        let narrative: [CodexNarrativeEntry] = [.workGroup(.init(id: "group", rows: [.command(.init(
            id: "command", command: "test", label: "Ran test", action: .run, status: .completed, output: "Find this result"
        ))]))]
        turns[8].narrative = narrative
        turns[8].conversationSegments = [.init(id: "segment", narrative: narrative)]
        let request = CodexTranscriptFocusRequest(threadID: "thread", turnID: "turn-8", itemID: "command")
        update(coordinator, turns: turns, request: request)
        await coordinator.waitForProjectionForTesting()
        let id = try #require(coordinator.focusedItemIDForTesting)
        let item = try #require(coordinator.renderedItemForTesting(id))
        #expect(item.sourceItemID == "command")
        #expect(item.textRole == .expandedOutput)
        #expect(item.preparedText?.attributedString.string == "Find this result")
        #expect(id.rawValue.hasSuffix(":command:detail"))
    }

    @Test func unloadedOccurrenceStaysPendingUntilItsHistoryPageArrives() async throws {
        let coordinator = CodexTranscriptListHost.Coordinator()
        let container = CodexTranscriptCollectionContainerView(frame: NSRect(x: 0, y: 0, width: 860, height: 500))
        let window = hostingWindow(container)
        coordinator.attach(to: container)
        defer { coordinator.detach(); window.close() }
        let request = CodexTranscriptFocusRequest(threadID: "thread", turnID: "history", itemID: "historical-answer")
        update(coordinator, turns: fixture(), request: request)
        await coordinator.waitForProjectionForTesting()
        #expect(coordinator.focusedItemIDForTesting == nil)
        #expect(coordinator.pendingFocusRequestForTesting == request)
        let historical = CodexTurnV2(id: "history", userMessage: .init(id: "historical-user", text: "Earlier"),
                                     finalAnswer: .init(id: "historical-answer", text: "Loaded answer", isStreaming: false), status: .done(durationMs: nil))
        update(coordinator, turns: [historical] + fixture(), request: request)
        await coordinator.waitForProjectionForTesting()
        let id = try #require(coordinator.focusedItemIDForTesting)
        #expect(coordinator.renderedItemForTesting(id)?.sourceItemID == "historical-answer")
        #expect(coordinator.pendingFocusRequestForTesting == nil)
    }

    @Test func focusDoesNotNavigateAThreadWithCoincidentItemIDs() async throws {
        let coordinator = CodexTranscriptListHost.Coordinator()
        let container = CodexTranscriptCollectionContainerView(frame: NSRect(x: 0, y: 0, width: 860, height: 500))
        let window = hostingWindow(container)
        coordinator.attach(to: container)
        defer { coordinator.detach(); window.close() }
        let request = CodexTranscriptFocusRequest(threadID: "other-thread", turnID: "turn-12", itemID: "answer-12")
        update(coordinator, turns: fixture(), request: request)
        await coordinator.waitForProjectionForTesting()
        #expect(coordinator.focusedItemIDForTesting == nil)
        update(coordinator, turns: fixture(), request: nil)
        await coordinator.waitForProjectionForTesting()
        #expect(coordinator.pendingFocusRequestForTesting == nil)
    }

    @Test func freshRequestCanRevisitSameTurnWithoutRebuildingTranscript() async throws {
        let coordinator = CodexTranscriptListHost.Coordinator()
        let container = CodexTranscriptCollectionContainerView(frame: NSRect(x: 0, y: 0, width: 860, height: 500))
        let window = hostingWindow(container)
        coordinator.attach(to: container)
        defer { coordinator.detach(); window.close() }
        let first = CodexTranscriptFocusRequest(threadID: "thread", turnID: "turn-12")
        let turns = fixture()
        update(coordinator, turns: turns, request: first)
        await coordinator.waitForProjectionForTesting()
        let expectedID = try #require(coordinator.focusedItemIDForTesting)
        let expectedOffset = container.scrollView.contentView.bounds.origin.y
        #expect(expectedOffset > 0)
        container.scrollView.contentView.setBoundsOrigin(.zero)
        let second = CodexTranscriptFocusRequest(threadID: "thread", turnID: "turn-12")
        #expect(first.id != second.id)
        update(coordinator, turns: turns, request: second)
        await coordinator.waitForProjectionForTesting()
        #expect(coordinator.focusedItemIDForTesting == expectedID)
        #expect(abs(container.scrollView.contentView.bounds.origin.y - expectedOffset) < 1)
    }

    private func fixture() -> [CodexTurnV2] {
        (0..<25).map { index in
            .init(id: "turn-\(index)", userMessage: .init(id: "user-\(index)", text: "Question \(index)"),
                  finalAnswer: .init(id: "answer-\(index)", text: "Answer \(index)", isStreaming: false), status: .done(durationMs: nil))
        }
    }

    private func hostingWindow(_ container: NSView) -> NSWindow {
        let window = NSWindow(contentRect: container.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        return window
    }

    private func update(_ coordinator: CodexTranscriptListHost.Coordinator, turns: [CodexTurnV2], request: CodexTranscriptFocusRequest?) {
        coordinator.update(presentation: .init(threadID: "thread", transcript: .init(turns: turns)), presentationStore: nil,
                           bottomContentInset: 0, contentHorizontalOffset: 0, swiftUITheme: .officialDark,
                           colorScheme: .dark, clipboardService: CodexNoopClipboardService(), productToolRenderer: nil,
                           focusRequest: request, onOpenSubagent: { _ in }, onEditUserMessage: { _ in }, onForkChat: nil)
    }
}
