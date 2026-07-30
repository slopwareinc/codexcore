import AppKit
@testable import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

@MainActor
struct CodexTranscriptTurnMinimapTests {
    @Test func previewProjectionUsesCanonicalRequestAndAssistantResult() async throws {
        let presentation = CodexThreadUIPresentation(
            threadID: "thread",
            transcript: .init(turns: [.init(
                id: "turn",
                userMessage: .init(
                    id: "user",
                    text: "Inspect   the transcript\nnavigation"
                ),
                finalAnswer: .init(
                    id: "answer",
                    text: "Implemented the turn rail and jump behavior.",
                    isStreaming: false
                ),
                status: .done(durationMs: 10)
            )])
        )
        let snapshot = try await CodexTranscriptRenderProjector().project(
            presentation: presentation,
            availableWidth: 860,
            theme: CodexTranscriptAppKitTheme(.officialDark, colorScheme: .dark)
        )

        let entry = try #require(
            CodexTranscriptTurnMinimapProjection.entries(
                presentation: presentation,
                snapshot: snapshot
            ).first
        )
        #expect(entry.turnID == "turn")
        #expect(entry.title == "Inspect the transcript navigation")
        #expect(entry.detail == "Implemented the turn rail and jump behavior.")
        #expect(snapshot.itemsByID[entry.targetItemID]?.turnID == "turn")
    }

    @Test func longTranscriptShowsAccessibleMarkersPreviewAndJumpNavigation() async throws {
        let coordinator = CodexTranscriptListHost.Coordinator()
        let container = CodexTranscriptCollectionContainerView(
            frame: NSRect(x: 0, y: 0, width: 860, height: 360)
        )
        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        coordinator.attach(to: container)
        let turns = (0..<12).map { index in
            CodexTurnV2(
                id: "turn-\(index)",
                userMessage: .init(id: "user-\(index)", text: "Question \(index)"),
                finalAnswer: .init(
                    id: "answer-\(index)",
                    text: String(repeating: "Answer \(index) with enough detail. ", count: 8),
                    isStreaming: false
                ),
                status: .done(durationMs: 10)
            )
        }
        coordinator.update(
            presentation: .init(
                threadID: "thread",
                transcript: .init(turns: turns),
                rawScrollOffset: 0,
                isPinnedToBottom: false
            ),
            presentationStore: nil,
            bottomContentInset: 80,
            contentHorizontalOffset: 0,
            swiftUITheme: .officialDark,
            colorScheme: .dark,
            clipboardService: CodexNoopClipboardService(),
            productToolRenderer: nil,
            onOpenSubagent: { _ in },
            onEditUserMessage: { _ in },
            onForkChat: nil
        )
        await coordinator.waitForProjectionForTesting()
        try await Task.sleep(for: .milliseconds(20))
        container.layoutSubtreeIfNeeded()
        container.turnMinimap.layoutSubtreeIfNeeded()

        #expect(!container.turnMinimap.isHidden)
        #expect(container.turnMinimap.entriesForTesting.count == turns.count)
        #expect(abs(container.turnMinimap.frame.height - CGFloat(turns.count) * 11) < 1)
        let marker = try #require(
            container.turnMinimap.markerForTesting(turnID: "turn-8")
        )
        let previousMarker = try #require(
            container.turnMinimap.markerForTesting(turnID: "turn-7")
        )
        #expect(abs(marker.frame.minY - previousMarker.frame.minY - 11) < 1)
        #expect(marker.accessibilityLabel() == "Jump to turn: Question 8")

        let initiallyVisibleTurnIDs = container.turnMinimap.visibleTurnIDsForTesting
        #expect(!initiallyVisibleTurnIDs.isEmpty)
        for turnID in initiallyVisibleTurnIDs {
            #expect(container.turnMinimap.markerIsVisibleForTesting(turnID: turnID) == true)
            #expect(container.turnMinimap.markerLineWidthForTesting(turnID: turnID) == 10)
        }

        container.turnMinimap.setHoveredTurnIDForTesting("turn-6")
        let hoveredInfluence = try #require(
            container.turnMinimap.hoverMountInfluenceForTesting(turnID: "turn-6")
        )
        let adjacentInfluence = try #require(
            container.turnMinimap.hoverMountInfluenceForTesting(turnID: "turn-5")
        )
        let secondNeighborInfluence = try #require(
            container.turnMinimap.hoverMountInfluenceForTesting(turnID: "turn-4")
        )
        #expect(hoveredInfluence == 1)
        #expect(adjacentInfluence < hoveredInfluence)
        #expect(secondNeighborInfluence < adjacentInfluence)
        #expect(
            container.turnMinimap.hoverMountInfluenceForTesting(turnID: "turn-7")
                == adjacentInfluence
        )
        let hoveredWidth = try #require(
            container.turnMinimap.markerLineWidthForTesting(turnID: "turn-6")
        )
        let adjacentWidth = try #require(
            container.turnMinimap.markerLineWidthForTesting(turnID: "turn-5")
        )
        #expect(hoveredWidth > adjacentWidth)

        let originalOffset = container.scrollView.contentView.bounds.origin.y
        let markerCenterInWindow = marker.convert(
            NSPoint(x: marker.bounds.midX, y: marker.bounds.midY),
            to: nil
        )
        let markerCenterInContainer = container.convert(markerCenterInWindow, from: nil)
        let hitView = try #require(container.hitTest(markerCenterInContainer))
        #expect(hitView === marker)
        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: markerCenterInWindow,
            modifierFlags: [],
            timestamp: 1,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        hitView.mouseDown(with: click)
        let clickedOffset = container.scrollView.contentView.bounds.origin.y
        #expect(clickedOffset > originalOffset + 100)
        await Task.yield()
        #expect(abs(container.scrollView.contentView.bounds.origin.y - clickedOffset) < 1)
        #expect(container.turnMinimap.visibleTurnIDsForTesting.contains("turn-8"))
        #expect(container.turnMinimap.visibleTurnIDsForTesting != initiallyVisibleTurnIDs)

        let entry = try #require(
            container.turnMinimap.entriesForTesting.first { $0.turnID == "turn-8" }
        )
        container.showTurnPreview(entry, beside: marker)
        #expect(!container.turnPreview.isHidden)
        #expect((86...154).contains(container.turnPreview.frame.height))
        #expect(container.turnPreview.accessibilityLabel() == "Question 8")
        if #available(macOS 26.0, *) {
            #expect(container.turnPreview.usesNativeLiquidGlassForTesting)
        }
        coordinator.detach()
    }

    @Test func visibilityProjectionIncludesEveryTurnIntersectingTheViewport() {
        let entries = (0..<4).map { index in
            CodexTranscriptTurnMinimapEntry(
                turnID: "turn-\(index)",
                targetItemID: .init(rawValue: "item-\(index)"),
                title: "Turn \(index)",
                detail: ""
            )
        }
        let visible = CodexTranscriptTurnVisibilityProjection.visibleTurnIDs(
            entries: entries,
            targetYByTurnID: [
                "turn-0": 0,
                "turn-1": 100,
                "turn-2": 200,
                "turn-3": 300,
            ],
            contentHeight: 400,
            viewport: NSRect(x: 0, y: 75, width: 800, height: 175)
        )

        #expect(visible == ["turn-0", "turn-1", "turn-2"])
    }

    @Test func shortTranscriptKeepsTurnNavigatorHidden() async {
        let coordinator = CodexTranscriptListHost.Coordinator()
        let container = CodexTranscriptCollectionContainerView(
            frame: NSRect(x: 0, y: 0, width: 860, height: 700)
        )
        coordinator.attach(to: container)
        coordinator.update(
            presentation: .init(
                threadID: "thread",
                transcript: .init(turns: [.init(
                    id: "turn",
                    userMessage: .init(id: "user", text: "Short question"),
                    finalAnswer: .init(id: "answer", text: "Short answer", isStreaming: false),
                    status: .done(durationMs: 1)
                )])
            ),
            presentationStore: nil,
            bottomContentInset: 170,
            contentHorizontalOffset: 0,
            swiftUITheme: .officialDark,
            colorScheme: .dark,
            clipboardService: CodexNoopClipboardService(),
            productToolRenderer: nil,
            onOpenSubagent: { _ in },
            onEditUserMessage: { _ in },
            onForkChat: nil
        )
        await coordinator.waitForProjectionForTesting()

        #expect(container.turnMinimap.isHidden)
        coordinator.detach()
    }
}
