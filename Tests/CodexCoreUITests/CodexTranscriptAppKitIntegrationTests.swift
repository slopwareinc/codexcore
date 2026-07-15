import AppKit
@testable import CodexCoreUI
import Foundation
import SwiftUI
import Testing

@MainActor
struct CodexTranscriptAppKitIntegrationTests {
    @Test func diffableCollectionUsesFineGrainedItemsAndNeverBroadReloads() async throws {
        let coordinator = CodexTranscriptListHost.Coordinator()
        let container = CodexTranscriptCollectionContainerView(frame: NSRect(x: 0, y: 0, width: 860, height: 700))
        let window = NSWindow(contentRect: container.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = container
        coordinator.attach(to: container)
        let clipboard = RecordingClipboard()
        let date = Date(timeIntervalSince1970: 100)
        var presentation = longPresentation(answerSuffix: "", date: date)
        coordinator.update(
            presentation: presentation,
            sessionStore: nil,
            bottomContentInset: 190,
            contentHorizontalOffset: 0,
            swiftUITheme: .officialDark,
            clipboardService: clipboard,
            productToolRenderer: nil,
            onOpenSubagent: { _ in },
            onEditUserMessage: { _ in },
            onForkChat: nil
        )
        await coordinator.waitForProjectionForTesting()
        try await Task.sleep(for: .milliseconds(20))

        #expect(coordinator.renderedItemIDsForTesting.count == 1_085)
        #expect(coordinator.diagnostics.snapshotApplyCount == 1)
        #expect(coordinator.diagnostics.broadReloadCount == 0)
        #expect(coordinator.diagnostics.insertedItemCount == coordinator.renderedItemIDsForTesting.count)
        #expect(container.scrollView.contentInsets.bottom == 190)
        #expect(abs(container.scrollView.contentView.bounds.origin.y - 250) < 1)
        #expect(!container.jumpButton.isHidden)

        presentation = longPresentation(answerSuffix: " streamed", date: date)
        coordinator.update(
            presentation: presentation,
            sessionStore: nil,
            bottomContentInset: 190,
            contentHorizontalOffset: 0,
            swiftUITheme: .officialDark,
            clipboardService: clipboard,
            productToolRenderer: nil,
            onOpenSubagent: { _ in },
            onEditUserMessage: { _ in },
            onForkChat: nil
        )
        await coordinator.waitForProjectionForTesting()
        try await Task.sleep(for: .milliseconds(20))

        #expect(coordinator.diagnostics.snapshotApplyCount == 2)
        #expect(coordinator.diagnostics.reconfiguredItemCount == 1)
        #expect(coordinator.diagnostics.broadReloadCount == 0)
        #expect(abs(container.scrollView.contentView.bounds.origin.y - 250) < 1)
        container.jumpButton.performClick(nil)
        #expect(container.jumpButton.isHidden)
        #expect(container.scrollView.contentView.bounds.origin.y > 250)
        coordinator.detach()
    }

    @Test func nativeTextSelectionSurvivesAppendAndCopyActionsWork() async throws {
        let projector = CodexTranscriptRenderProjector()
        let presentation = CodexThreadUIPresentation(
            threadID: "thread",
            transcript: .init(turns: [.init(
                id: "turn",
                userMessage: .init(id: "user", text: "Question"),
                finalAnswer: .init(id: "final", text: "Hello world", isStreaming: true),
                status: .done(durationMs: 10)
            )]),
            presentedAtByTurnID: ["turn": Date(timeIntervalSince1970: 100)]
        )
        let theme = CodexTranscriptAppKitTheme(.officialDark)
        let snapshot = try await projector.project(presentation: presentation, availableWidth: 860, theme: theme)
        let finalID = try #require(snapshot.orderedItemIDs.first { $0.rawValue.contains(":final:final:block:") })
        var item = try #require(snapshot.itemsByID[finalID])
        let clipboard = RecordingClipboard()
        let cell = CodexTranscriptCollectionItem()
        _ = cell.view
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 300), styleMask: [], backing: .buffered, defer: false)
        cell.view.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 860, height: 300)
        window.contentView = cell.view
        cell.configure(
            item: item,
            appKitTheme: theme,
            swiftUITheme: .officialDark,
            contentHorizontalOffset: 0,
            productToolRenderer: nil,
            performAction: { _ in },
            copy: clipboard.copy,
            editUserMessage: { _ in },
            forkChat: nil,
            selectionChanged: { _, _ in }
        )
        cell.selectableTextViewForTesting.setSelectedRange(NSRange(location: 0, length: 5))
        #expect(cell.selectableTextViewForTesting.selectedRange() == NSRange(location: 0, length: 5))

        item.revision += 1
        item.preparedText = CodexPreparedTranscriptText(NSAttributedString(
            string: "Hello world streamed",
            attributes: [.font: theme.bodyFont, .foregroundColor: theme.textPrimary]
        ))
        item.copyText = "Hello world streamed"
        cell.configure(
            item: item,
            appKitTheme: theme,
            swiftUITheme: .officialDark,
            contentHorizontalOffset: 0,
            productToolRenderer: nil,
            performAction: { _ in },
            copy: clipboard.copy,
            editUserMessage: { _ in },
            forkChat: nil,
            selectionChanged: { _, _ in }
        )

        #expect(!cell.selectableTextViewForTesting.isEditable)
        #expect(cell.selectableTextViewForTesting.isSelectable)
        #expect(cell.selectableTextViewForTesting.selectedRange() == NSRange(location: 0, length: 5))
        cell.copyItemForTesting()
        #expect(clipboard.lastValue == "Hello world streamed")
        cell.copyTurnForTesting()
        #expect(clipboard.lastValue == item.copyTurnText)

        NSPasteboard.general.clearContents()
        #expect(window.makeFirstResponder(cell.selectableTextViewForTesting))
        cell.selectableTextViewForTesting.copy(nil)
        #expect(NSPasteboard.general.string(forType: .string) == "Hello")
    }

    @Test func selectionSuppressesPinnedFollowAndTickerHasOneTarget() async throws {
        let coordinator = CodexTranscriptListHost.Coordinator()
        let container = CodexTranscriptCollectionContainerView(frame: NSRect(x: 0, y: 0, width: 860, height: 500))
        let window = NSWindow(contentRect: container.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = container
        coordinator.attach(to: container)
        let clipboard = RecordingClipboard()
        let store = CodexThreadUISessionStore()
        let date = Date(timeIntervalSince1970: 100)
        var presentation = workingPresentation(date: date)
        coordinator.update(
            presentation: presentation,
            sessionStore: store,
            bottomContentInset: 170,
            contentHorizontalOffset: 0,
            swiftUITheme: .officialDark,
            clipboardService: clipboard,
            productToolRenderer: nil,
            onOpenSubagent: { _ in },
            onEditUserMessage: { _ in },
            onForkChat: nil
        )
        await coordinator.waitForProjectionForTesting()
        try await Task.sleep(for: .milliseconds(20))
        #expect(coordinator.diagnostics.tickerTargetCount == 1)

        let selectableID = try #require(coordinator.renderedItemIDsForTesting.first { $0.rawValue.contains(":commentary:") })
        coordinator.setSelectingForTesting(true, id: selectableID)
        container.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 40))
        let preservedOffset = container.scrollView.contentView.bounds.origin.y
        presentation.transcript.turns[0].narrative[0] = .prose(.init(
            id: "commentary",
            text: "Working commentary plus tokens",
            isStreaming: true
        ))
        coordinator.update(
            presentation: presentation,
            sessionStore: store,
            bottomContentInset: 170,
            contentHorizontalOffset: 0,
            swiftUITheme: .officialDark,
            clipboardService: clipboard,
            productToolRenderer: nil,
            onOpenSubagent: { _ in },
            onEditUserMessage: { _ in },
            onForkChat: nil
        )
        await coordinator.waitForProjectionForTesting()
        try await Task.sleep(for: .milliseconds(20))
        #expect(abs(container.scrollView.contentView.bounds.origin.y - preservedOffset) < 1)

        presentation.transcript.turns[0].status = .done(durationMs: 1_000)
        presentation.expandedWorkTurnIDs.insert("turn")
        coordinator.update(
            presentation: presentation,
            sessionStore: store,
            bottomContentInset: 170,
            contentHorizontalOffset: 0,
            swiftUITheme: .officialDark,
            clipboardService: clipboard,
            productToolRenderer: nil,
            onOpenSubagent: { _ in },
            onEditUserMessage: { _ in },
            onForkChat: nil
        )
        await coordinator.waitForProjectionForTesting()
        try await Task.sleep(for: .milliseconds(20))
        #expect(coordinator.diagnostics.tickerTargetCount == 0)
        coordinator.detach()
    }

    @Test func subagentEditForkAndDynamicToolHooksRemainReachable() async throws {
        let turn = CodexTurnV2(
            id: "turn",
            userMessage: .init(id: "user", text: "Revise this"),
            narrative: [
                .workGroup(.init(id: "group", header: "Used an agent", rows: [
                    .collabAgent(.init(
                        id: "agent",
                        action: .created,
                        agentNames: ["Reviewer"],
                        agentThreadIDs: ["child-thread"],
                        instructions: nil,
                        status: .completed
                    ))
                ])),
                .productToolCall(.init(
                    id: "product",
                    tool: "render",
                    namespace: "host",
                    status: .completed,
                    contentItems: [],
                    success: true
                ))
            ],
            finalAnswer: .init(id: "final", text: "Done", isStreaming: false),
            status: .done(durationMs: 100)
        )
        let projector = CodexTranscriptRenderProjector()
        let theme = CodexTranscriptAppKitTheme(.officialDark)
        let snapshot = try await projector.project(
            presentation: .init(
                threadID: "thread",
                transcript: .init(turns: [turn]),
                expandedWorkTurnIDs: [turn.id],
                presentedAtByTurnID: [turn.id: Date(timeIntervalSince1970: 100)]
            ),
            availableWidth: 860,
            theme: theme
        )
        let user = try #require(snapshot.itemsByID.first { $0.key.rawValue.contains(":user:user") }?.value)
        let agent = try #require(snapshot.itemsByID.first { $0.key.rawValue.contains(":row:agent") }?.value)
        let product = try #require(snapshot.itemsByID.first { $0.key.rawValue.contains(":product:product") }?.value)
        let final = try #require(snapshot.itemsByID.first { $0.key.rawValue.contains(":final:final:block:") }?.value)
        let cell = CodexTranscriptCollectionItem()
        _ = cell.view
        var openedThreadID: String?
        var editedText: String?
        var forkCount = 0
        func configure(_ item: CodexTranscriptRenderItem, renderer: CodexProductToolRendererV2? = nil) {
            cell.configure(
                item: item,
                appKitTheme: theme,
                swiftUITheme: .officialDark,
                contentHorizontalOffset: 0,
                productToolRenderer: renderer,
                performAction: { action in
                    if case .openSubagent(let threadID) = action { openedThreadID = threadID }
                },
                copy: { _ in },
                editUserMessage: { editedText = $0 },
                forkChat: { forkCount += 1 },
                selectionChanged: { _, _ in }
            )
        }

        configure(agent)
        cell.invokePrimaryActionForTesting()
        #expect(openedThreadID == "child-thread")

        configure(user)
        cell.editUserForTesting()
        #expect(editedText == "Revise this")
        #expect(cell.selectableTextViewForTesting.accessibilityLabel()?.contains("You") == true)

        configure(final)
        cell.forkChatForTesting()
        #expect(forkCount == 1)

        configure(product, renderer: CodexProductToolRendererV2 { _ in AnyView(Text("Host-rendered tool")) })
        #expect(cell.hasHostedViewForTesting)
    }

    @Test func warmThreadSwapRestoresExactRawOffset() async throws {
        let coordinator = CodexTranscriptListHost.Coordinator()
        let container = CodexTranscriptCollectionContainerView(frame: NSRect(x: 0, y: 0, width: 860, height: 700))
        let window = NSWindow(contentRect: container.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = container
        coordinator.attach(to: container)
        let clipboard = RecordingClipboard()
        let date = Date(timeIntervalSince1970: 100)
        var threadA = longPresentation(answerSuffix: "", date: date)
        threadA.threadID = "A"
        threadA.rawScrollOffset = 417.25
        var threadB = longPresentation(answerSuffix: "", date: date)
        threadB.threadID = "B"
        threadB.rawScrollOffset = 73.5

        for presentation in [threadA, threadB, threadA] {
            coordinator.update(
                presentation: presentation,
                sessionStore: nil,
                bottomContentInset: 190,
                contentHorizontalOffset: 0,
                swiftUITheme: .officialDark,
                clipboardService: clipboard,
                productToolRenderer: nil,
                onOpenSubagent: { _ in },
                onEditUserMessage: { _ in },
                onForkChat: nil
            )
            await coordinator.waitForProjectionForTesting()
            try await Task.sleep(for: .milliseconds(20))
            #expect(abs(container.scrollView.contentView.bounds.origin.y - presentation.rawScrollOffset) < 1)
        }
        coordinator.detach()
    }

    private func longPresentation(answerSuffix: String, date: Date) -> CodexThreadUIPresentation {
        let turns = (0..<217).map { index in
            CodexTurnV2(
                id: "turn-\(index)",
                userMessage: .init(id: "user-\(index)", text: "Question \(index)"),
                narrative: [.prose(.init(
                    id: "commentary-\(index)",
                    text: "Checked implementation \(index)",
                    isStreaming: false
                ))],
                finalAnswer: .init(
                    id: "final-\(index)",
                    text: String(repeating: "Answer \(index) ", count: 8) + (index == 216 ? answerSuffix : ""),
                    isStreaming: index == 216
                ),
                status: .done(durationMs: 100)
            )
        }
        return CodexThreadUIPresentation(
            threadID: "thread",
            transcript: .init(turns: turns),
            rawScrollOffset: 250,
            isPinnedToBottom: false,
            presentedAtByTurnID: Dictionary(uniqueKeysWithValues: turns.map { ($0.id, date) })
        )
    }

    private func workingPresentation(date: Date) -> CodexThreadUIPresentation {
        let turn = CodexTurnV2(
            id: "turn",
            userMessage: .init(id: "user", text: "Question"),
            narrative: [
                .prose(.init(id: "commentary", text: "Working commentary", isStreaming: true)),
                .workGroup(.init(id: "group", header: "Ran a command", rows: [
                    .command(.init(id: "command", command: "swift test", label: "Ran swift test", action: .run, status: .inProgress))
                ]))
            ],
            liveTail: "Running swift test",
            status: .working(since: 100)
        )
        return CodexThreadUIPresentation(
            threadID: "thread",
            transcript: .init(turns: [turn]),
            isPinnedToBottom: true,
            presentedAtByTurnID: [turn.id: date]
        )
    }
}

private final class RecordingClipboard: CodexClipboardService, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    var lastValue: String? {
        lock.withLock { value }
    }

    func copy(_ text: String) {
        lock.withLock { value = text }
    }
}
