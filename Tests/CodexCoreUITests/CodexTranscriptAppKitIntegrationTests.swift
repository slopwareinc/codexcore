import AppKit
@testable import CodexCore
@testable import CodexCoreUI
import Foundation
import SwiftUI
import Testing

@MainActor
struct CodexTranscriptAppKitIntegrationTests {
    @Test func pendingApprovalRendersInlineAndRoutesBothDecisions() async throws {
        let requestKey = CodexServerRequestKey(
            connectionEpoch: 2,
            requestID: .string("approval-1")
        )
        let prompt = CodexApprovalPrompt(
            id: requestKey, method: "item/commandExecution/requestApproval", kind: .command,
            title: "Approve command?", detail: "Run tests", primaryValue: "swift test", threadId: "thread"
        )
        let snapshot = try await CodexTranscriptRenderProjector().project(
            presentation: .init(
                threadID: "thread",
                transcript: .init(turns: [.init(
                    id: "turn",
                    narrative: [.workGroup(.init(id: "work", rows: [.command(.init(
                        id: "command", command: "swift test", label: "Running tests",
                        action: .run, status: .inProgress
                    ))]))],
                    status: .working(since: 1)
                )]),
                pendingApprovals: [prompt]
            ),
            availableWidth: 860,
            theme: CodexTranscriptAppKitTheme(.officialDark)
        )
        let approval = try #require(snapshot.itemsByID.values.first { $0.approval != nil })
        #expect(approval.approval?.summary == "swift test")
        var actions: [CodexTranscriptRenderAction] = []
        let cell = CodexTranscriptCollectionItem()
        _ = cell.view
        cell.view.frame = NSRect(x: 0, y: 0, width: 860, height: approval.measuredHeight)
        cell.configure(
            item: approval, appKitTheme: .init(.officialDark), swiftUITheme: .officialDark,
            contentHorizontalOffset: 0, productToolRenderer: nil,
            performAction: { actions.append($0) }, copy: { _ in }, editUserMessage: { _ in },
            forkChat: nil, selectionChanged: { _, _ in }
        )
        #expect(cell.approvalButtonsVisibleForTesting)
        cell.allowApprovalForTesting()
        cell.denyApprovalForTesting()
        #expect(actions == [
            .resolveApproval(requestID: requestKey, approve: true),
            .resolveApproval(requestID: requestKey, approve: false)
        ])
        let workRow = try #require(snapshot.itemsByID.values.first { $0.workRow != nil })
        cell.configure(
            item: workRow, appKitTheme: .init(.officialDark), swiftUITheme: .officialDark,
            contentHorizontalOffset: 0, productToolRenderer: nil,
            performAction: { _ in }, copy: { _ in }, editUserMessage: { _ in },
            forkChat: nil, selectionChanged: { _, _ in }
        )
        #expect(!cell.approvalButtonsVisibleForTesting)
    }

    @Test func collapsedWorkRowsUsePlainTextWithSemanticStatus() async throws {
        let projector = CodexTranscriptRenderProjector()
        let theme = CodexTranscriptAppKitTheme(.officialDark)
        let presentation = CodexThreadUIPresentation(
            threadID: "thread",
            transcript: .init(turns: [.init(
                id: "turn",
                narrative: [.workGroup(.init(id: "group", rows: [
                    .command(.init(
                        id: "command",
                        command: "swift test",
                        label: "Running tests",
                        action: .run,
                        status: .inProgress
                    ))
                ]))],
                status: .working(since: 1)
            )])
        )
        let snapshot = try await projector.project(
            presentation: presentation,
            availableWidth: 860,
            theme: theme
        )
        let row = try #require(snapshot.itemsByID.values.first { $0.workRow != nil })
        let cell = CodexTranscriptCollectionItem()
        _ = cell.view
        cell.view.frame = NSRect(x: 0, y: 0, width: 860, height: row.measuredHeight)
        cell.configure(
            item: row,
            appKitTheme: theme,
            swiftUITheme: .officialDark,
            contentHorizontalOffset: 0,
            productToolRenderer: nil,
            performAction: { _ in },
            copy: { _ in },
            editUserMessage: { _ in },
            forkChat: nil,
            selectionChanged: { _, _ in }
        )

        #expect(cell.chipLabelForTesting.contains("Running swift test"))
        #expect(cell.chipIconDescriptionForTesting == "In progress")
        #expect(cell.workRowStatusForTesting == "running")
        #expect(row.indentation == 0)
        #expect(!cell.workRowBackgroundIsVisibleForTesting)
        #expect(!cell.chipIsActionableForTesting)
        #expect(row.bottomSpacing == 8)
    }

    @Test func singleLineAssistantRepliesFitTheirNativeTextLayout() async throws {
        let replies = [
            "Hello world! 👋",
            "Wherever you’d like—building, debugging, exploring, or simply testing the system. 🚀",
            "Exactly. A little chaos, a little computation. 😄",
            "Hello world—again! 🌍",
        ]
        let projector = CodexTranscriptRenderProjector()
        let theme = CodexTranscriptAppKitTheme(.officialDark)

        for (index, reply) in replies.enumerated() {
            let snapshot = try await projector.project(
                presentation: .init(
                    threadID: "thread-\(index)",
                    transcript: .init(turns: [.init(
                        id: "turn",
                        finalAnswer: .init(id: "answer", text: reply, isStreaming: false),
                        status: .done(durationMs: 1)
                    )])
                ),
                availableWidth: 1_640,
                theme: theme
            )
            let answer = try #require(snapshot.itemsByID.values.first { $0.textRole == .finalAnswer })
            let cell = CodexTranscriptCollectionItem()
            _ = cell.view
            cell.view.frame = NSRect(x: 0, y: 0, width: 1_640, height: answer.measuredHeight)
            cell.configure(
                item: answer, appKitTheme: theme, swiftUITheme: .officialDark,
                contentHorizontalOffset: 0, productToolRenderer: nil,
                performAction: { _ in }, copy: { _ in }, editUserMessage: { _ in },
                forkChat: nil, selectionChanged: { _, _ in }
            )
            cell.view.layoutSubtreeIfNeeded()

            #expect(cell.textViewportHeightForTesting >= cell.textUsedHeightForTesting + 1)
        }
    }

    @Test func expandedCommandOutputUsesABoundedInternalScroller() async throws {
        let output = (0..<300).map { "Sources/File\($0).swift" }.joined(separator: "\n")
        let turn = CodexTurnV2(
            id: "turn",
            narrative: [.workGroup(.init(id: "group", rows: [.command(.init(
                id: "command", command: "rg --files", label: "Listed files",
                action: .list, status: .completed, durationMs: 10, output: output
            ))]))],
            status: .done(durationMs: 10)
        )
        let theme = CodexTranscriptAppKitTheme(.officialDark)
        let snapshot = try await CodexTranscriptRenderProjector().project(
            presentation: .init(
                threadID: "thread",
                transcript: .init(turns: [turn]),
                expandedWorkTurnIDs: [turn.id],
                expandedRowIDs: ["command"]
            ),
            availableWidth: 860,
            theme: theme
        )
        let detail = try #require(snapshot.itemsByID.values.first { $0.textRole == .expandedOutput })
        #expect(detail.measuredHeight <= 280)

        let cell = CodexTranscriptCollectionItem()
        _ = cell.view
        cell.view.frame = NSRect(x: 0, y: 0, width: 860, height: detail.measuredHeight)
        cell.configure(
            item: detail, appKitTheme: theme, swiftUITheme: .officialDark,
            contentHorizontalOffset: 0, productToolRenderer: nil,
            performAction: { _ in }, copy: { _ in }, editUserMessage: { _ in },
            forkChat: nil, selectionChanged: { _, _ in }
        )
        cell.view.layoutSubtreeIfNeeded()
        #expect(cell.hasVerticalScrollerForTesting)
        #expect(cell.textDocumentHeightForTesting > cell.textViewportHeightForTesting)
        #expect(cell.glassPanelIsVisibleForTesting)
    }

    @Test func collaborationRowsRenderAsOneInlineChipCluster() async throws {
        let rows: [CodexWorkRowV2] = (1...5).map { index in
            .collabAgent(.init(
                id: "agent-\(index)", action: .waited,
                agentNames: ["Agent \(index)"], agentThreadIDs: ["thread-\(index)"],
                instructions: index == 2 ? "Inspect transcript rendering" : nil,
                agentMessages: index == 2 ? ["Agent 2": "Updated the AppKit cell"] : [:],
                status: index == 2 ? .inProgress : .completed,
                displayStatus: index == 2 ? .working : .done
            ))
        }
        let turn = CodexTurnV2(
            id: "turn",
            narrative: [.workGroup(.init(id: "agents", rows: rows))],
            status: .done(durationMs: 10)
        )
        let snapshot = try await CodexTranscriptRenderProjector().project(
            presentation: .init(
                threadID: "thread", transcript: .init(turns: [turn]),
                expandedWorkTurnIDs: [turn.id],
                agentDisplayNameByThreadID: ["thread-2": "Ramanujan"]
            ),
            availableWidth: 860,
            theme: CodexTranscriptAppKitTheme(.officialDark)
        )

        let cluster = try #require(snapshot.itemsByID.values.first { !$0.agentChips.isEmpty })
        #expect(cluster.agentChips.count == 5)
        #expect(cluster.indentation == 0)
        #expect(cluster.bottomSpacing == 8)
        #expect(!snapshot.itemsByID.values.contains { $0.workRow?.kind == .agent })

        let cell = CodexTranscriptCollectionItem()
        _ = cell.view
        cell.view.frame = NSRect(x: 0, y: 0, width: 860, height: cluster.measuredHeight)
        cell.configure(
            item: cluster, appKitTheme: .init(.officialDark), swiftUITheme: .officialDark,
            contentHorizontalOffset: 0, productToolRenderer: nil,
            performAction: { _ in }, copy: { _ in }, editUserMessage: { _ in },
            forkChat: nil, selectionChanged: { _, _ in }
        )
        cell.view.layoutSubtreeIfNeeded()
        #expect(cell.agentChipCountForTesting == 5)
        #expect(cell.agentChipTitlesForTesting[1] == "Ramanujan · working")
        #expect(cell.agentPillsUseGlassForTesting)
        let preview = try #require(cell.agentPreviewForTesting(at: 1))
        #expect(preview.taskSummary == "Inspect transcript rendering")
        #expect(preview.latestUpdate == "Updated the AppKit cell")
    }

    @Test func expandedDiffUsesOneGlassPanelAndRoutesTabSelection() async throws {
        let diff = """
        diff --git a/A.swift b/A.swift
        --- a/A.swift
        +++ b/A.swift
        @@ -1 +1 @@
        -old
        +new
        diff --git a/B.swift b/B.swift
        --- a/B.swift
        +++ b/B.swift
        @@ -0,0 +1 @@
        +added
        """
        let turn = CodexTurnV2(
            id: "turn",
            narrative: [.workGroup(.init(id: "work", rows: [.fileChange(.init(
                id: "files", files: ["A.swift", "B.swift"], status: .completed, diff: diff
            ))]))],
            status: .done(durationMs: 1)
        )
        let snapshot = try await CodexTranscriptRenderProjector().project(
            presentation: .init(
                threadID: "thread", transcript: .init(turns: [turn]),
                expandedWorkTurnIDs: [turn.id], expandedRowIDs: ["files"]
            ),
            availableWidth: 860,
            theme: CodexTranscriptAppKitTheme(.officialDark)
        )
        let panel = try #require(snapshot.itemsByID.values.first { $0.diffPanel != nil })
        let row = try #require(snapshot.itemsByID.values.first { $0.workRow?.kind == .fileChange })
        #expect(panel.indentation == row.indentation)
        #expect(panel.indentation == 0)
        #expect(row.bottomSpacing == 2)
        var action: CodexTranscriptRenderAction?
        let cell = CodexTranscriptCollectionItem()
        _ = cell.view
        cell.view.frame = NSRect(x: 0, y: 0, width: 860, height: panel.measuredHeight)
        cell.configure(
            item: panel, appKitTheme: .init(.officialDark), swiftUITheme: .officialDark,
            contentHorizontalOffset: 0, productToolRenderer: nil,
            performAction: { action = $0 }, copy: { _ in }, editUserMessage: { _ in },
            forkChat: nil, selectionChanged: { _, _ in }
        )
        cell.view.layoutSubtreeIfNeeded()

        #expect(cell.diffTabCountForTesting == 2)
        #expect(cell.glassPanelIsVisibleForTesting)
        cell.selectDiffTabForTesting(at: 1)
        #expect(action == .selectDiffFile(rowID: "files", index: 1))
    }

    @Test func completedWorkHeaderUsesVerticallyCenteredSymbolDisclosure() async throws {
        let turn = CodexTurnV2(
            id: "turn",
            narrative: [.prose(.init(id: "work", text: "Inspecting", isStreaming: false))],
            status: .done(durationMs: 1_000)
        )
        let snapshot = try await CodexTranscriptRenderProjector().project(
            presentation: .init(threadID: "thread", transcript: .init(turns: [turn])),
            availableWidth: 860,
            theme: .init(.officialDark)
        )
        let header = try #require(snapshot.itemsByID.values.first { $0.workHeader != nil })
        let cell = CodexTranscriptCollectionItem()
        _ = cell.view
        cell.view.frame = NSRect(x: 0, y: 0, width: 860, height: header.measuredHeight)
        cell.configure(
            item: header, appKitTheme: .init(.officialDark), swiftUITheme: .officialDark,
            contentHorizontalOffset: 0, productToolRenderer: nil,
            performAction: { _ in }, copy: { _ in }, editUserMessage: { _ in },
            forkChat: nil, selectionChanged: { _, _ in }
        )
        cell.view.layoutSubtreeIfNeeded()
        #expect(cell.workHeaderHasAlignedDisclosureForTesting)
        let gap = try #require(cell.workHeaderTitleAndDisclosureGapForTesting)
        #expect(gap >= 0)
        #expect(gap <= 8)
    }

    @Test func codeBlockUsesHeaderBandAndCopyConfirmation() async throws {
        let projector = CodexTranscriptRenderProjector()
        let theme = CodexTranscriptAppKitTheme(.officialDark)
        let presentation = CodexThreadUIPresentation(
            threadID: "thread",
            transcript: .init(turns: [.init(
                id: "turn",
                finalAnswer: .init(id: "final", text: "```swift\nlet value = 1\n```", isStreaming: false),
                status: .done(durationMs: 1)
            )])
        )
        let snapshot = try await projector.project(
            presentation: presentation,
            availableWidth: 860,
            theme: theme
        )
        let code = try #require(snapshot.itemsByID.values.first { $0.code != nil })
        let clipboard = RecordingClipboard()
        let cell = CodexTranscriptCollectionItem()
        _ = cell.view
        cell.view.frame = NSRect(x: 0, y: 0, width: 860, height: code.measuredHeight)
        cell.configure(
            item: code,
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
        cell.view.layoutSubtreeIfNeeded()

        #expect(cell.codeHeaderIsVisibleForTesting)
        #expect(cell.codeLanguageForTesting == "swift")
        let codeBounds = try #require(code.preparedText?.attributedString).boundingRect(
            with: NSSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        #expect(code.measuredHeight >= ceil(codeBounds.height) + 52)
        cell.copyItemForTesting()
        #expect(clipboard.lastValue == "let value = 1")
        #expect(cell.copyButtonAccessibilityDescriptionForTesting == "Copied")
    }

    @Test func userBubbleIsRightAlignedWithinCenteredTranscriptColumn() async throws {
        let projector = CodexTranscriptRenderProjector()
        let theme = CodexTranscriptAppKitTheme(.officialDark)
        let presentation = CodexThreadUIPresentation(
            threadID: "thread",
            transcript: .init(turns: [.init(
                id: "turn",
                userMessage: .init(id: "user", text: "Hi"),
                status: .done(durationMs: 1)
            )])
        )
        let snapshot = try await projector.project(
            presentation: presentation,
            availableWidth: 860,
            theme: theme
        )
        let user = try #require(snapshot.itemsByID.values.first { $0.textRole == .user })
        let cell = CodexTranscriptCollectionItem()
        _ = cell.view
        cell.view.frame = NSRect(x: 0, y: 0, width: 860, height: user.measuredHeight)
        cell.configure(
            item: user,
            appKitTheme: theme,
            swiftUITheme: .officialDark,
            contentHorizontalOffset: 0,
            productToolRenderer: nil,
            performAction: { _ in },
            copy: { _ in },
            editUserMessage: { _ in },
            forkChat: nil,
            selectionChanged: { _, _ in }
        )
        cell.view.layoutSubtreeIfNeeded()

        let metrics = CodexTranscriptColumnMetrics(viewportWidth: cell.view.bounds.width)
        let expectedTrailingEdge = cell.view.bounds.midX + metrics.outerWidth(theme) / 2
        #expect(abs(cell.contentFrameForTesting.maxX - expectedTrailingEdge) < 0.5)
        #expect(cell.contentFrameForTesting.width < user.maxContentWidth)
    }

    @Test func wideningViewportReflowsBubbleAndInvalidatesItsCollectionGeometry() async throws {
        let coordinator = CodexTranscriptListHost.Coordinator()
        let container = CodexTranscriptCollectionContainerView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 360)
        )
        let window = NSWindow(contentRect: container.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = container
        coordinator.attach(to: container)
        let presentation = CodexThreadUIPresentation(
            threadID: "thread",
            transcript: .init(turns: [.init(
                id: "turn",
                userMessage: .init(
                    id: "user",
                    text: "This prompt is deliberately long enough to wrap several times in a narrow transcript before the window becomes wide."
                ),
                status: .done(durationMs: 1)
            )])
        )
        coordinator.update(
            presentation: presentation,
            presentationStore: nil,
            bottomContentInset: 0,
            contentHorizontalOffset: 0,
            swiftUITheme: .officialDark,
            clipboardService: CodexNoopClipboardService(),
            productToolRenderer: nil,
            onOpenSubagent: { _ in },
            onEditUserMessage: { _ in },
            onForkChat: nil
        )
        await coordinator.waitForProjectionForTesting()
        container.layoutSubtreeIfNeeded()
        container.collectionView.layoutSubtreeIfNeeded()

        let userID = try #require(coordinator.renderedItemIDsForTesting.first {
            coordinator.renderedItemForTesting($0)?.textRole == .user
        })
        let narrowItem = try #require(coordinator.renderedItemForTesting(userID))

        window.setContentSize(NSSize(width: 900, height: 360))
        container.layoutSubtreeIfNeeded()
        await coordinator.waitForProjectionForTesting()
        container.collectionView.layoutSubtreeIfNeeded()

        let wideItem = try #require(coordinator.renderedItemForTesting(userID))
        let wideCell = try #require(coordinator.collectionItemForTesting(userID))
        #expect(wideItem.measuredHeight < narrowItem.measuredHeight)
        #expect(abs(wideCell.view.frame.height - wideItem.measuredHeight) < 1)
        #expect(abs(wideCell.contentFrameForTesting.width - (wideItem.intrinsicContentWidth ?? 0)) < 1)
        #expect(coordinator.diagnostics.targetedReconfigurePassCount >= 1)
        coordinator.detach()
    }

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
            presentationStore: nil,
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
            presentationStore: nil,
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

        #expect(coordinator.diagnostics.snapshotApplyCount == 1)
        #expect(coordinator.diagnostics.targetedReconfigurePassCount == 1)
        #expect(coordinator.diagnostics.reconfiguredItemCount == 1)
        #expect(coordinator.diagnostics.broadReloadCount == 0)
        #expect(abs(container.scrollView.contentView.bounds.origin.y - 250) < 1)
        let applyLabel = String(format: "%.3f", coordinator.diagnostics.lastSnapshotApplyDurationMilliseconds)
        let maximumApplyLabel = String(format: "%.3f", coordinator.diagnostics.maximumSnapshotApplyDurationMilliseconds)
        print(
            "APPKIT_TRANSCRIPT_DIFF items=1085 snapshots=\(coordinator.diagnostics.snapshotApplyCount) "
                + "targeted=\(coordinator.diagnostics.targetedReconfigurePassCount) "
                + "reconfigured=\(coordinator.diagnostics.reconfiguredItemCount) broad_reload=\(coordinator.diagnostics.broadReloadCount) "
                + "last_apply_ms=\(applyLabel) max_apply_ms=\(maximumApplyLabel)"
        )
        container.jumpButton.performClick(nil)
        #expect(container.jumpButton.isHidden)
        #expect(container.scrollView.contentView.bounds.origin.y > 250)
        coordinator.detach()
    }

    @Test func completedNativeTextSelectionSurvivesReconfigureAndCopyActionsWork() async throws {
        let projector = CodexTranscriptRenderProjector()
        let presentation = CodexThreadUIPresentation(
            threadID: "thread",
            transcript: .init(turns: [.init(
                id: "turn",
                userMessage: .init(id: "user", text: "Question"),
                finalAnswer: .init(id: "final", text: "Hello world", isStreaming: false),
                status: .done(durationMs: 10)
            )]),
            presentedAtByTurnID: ["turn": Date(timeIntervalSince1970: 100)]
        )
        let theme = CodexTranscriptAppKitTheme(.officialDark)
        let snapshot = try await projector.project(presentation: presentation, availableWidth: 860, theme: theme)
        let finalID = try #require(snapshot.orderedItemIDs.first { $0.rawValue.contains(":final:final:selection-surface:") })
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

    @Test func streamingAndCompletedTurnsRemainSelectableWithoutCompletionReconfigure() async throws {
        let projector = CodexTranscriptRenderProjector()
        let completed = CodexTurnV2(
            id: "completed",
            userMessage: .init(id: "older-user", text: "Older question"),
            finalAnswer: .init(id: "older-final", text: "Older answer", isStreaming: false),
            status: .done(durationMs: 10)
        )
        var streaming = CodexTurnV2(
            id: "streaming",
            userMessage: .init(id: "live-user", text: "Current question"),
            narrative: [.prose(.init(id: "live-commentary", text: "Working", isStreaming: true))],
            finalAnswer: .init(id: "live-final", text: "Partial answer", isStreaming: true),
            status: .working(since: 100)
        )
        var presentation = CodexThreadUIPresentation(
            threadID: "thread",
            transcript: .init(turns: [completed, streaming]),
            presentedAtByTurnID: ["completed": .distantPast, "streaming": .distantPast]
        )
        let theme = CodexTranscriptAppKitTheme(.officialDark)
        let liveSnapshot = try await projector.project(presentation: presentation, availableWidth: 860, theme: theme)

        let olderTextItems = liveSnapshot.itemsByID.values.filter {
            $0.turnID == "completed" && ($0.preparedText != nil || $0.code != nil) && $0.footer == nil
        }
        let liveTextItems = liveSnapshot.itemsByID.values.filter {
            $0.turnID == "streaming" && ($0.preparedText != nil || $0.code != nil) && $0.footer == nil
        }
        #expect(!olderTextItems.isEmpty)
        #expect(olderTextItems.allSatisfy { $0.allowsTextSelection })
        #expect(!liveTextItems.isEmpty)
        #expect(liveTextItems.allSatisfy { $0.allowsTextSelection })
        let liveFooter = try #require(liveSnapshot.itemsByID.values.first {
            $0.turnID == "streaming" && $0.footer?.kind == .finalAnswer
        })
        #expect(liveFooter.footer?.isTurnStreaming == true)

        streaming.status = .done(durationMs: 500)
        streaming.narrative[0] = .prose(.init(id: "live-commentary", text: "Working", isStreaming: false))
        streaming.finalAnswer?.isStreaming = false
        streaming.finalAnswer?.text = "Complete answer"
        presentation.transcript.turns[1] = streaming
        let completedSnapshot = try await projector.project(
            presentation: presentation,
            availableWidth: 860,
            theme: theme
        )
        let completedLiveTextItems = completedSnapshot.itemsByID.values.filter {
            $0.turnID == "streaming" && ($0.preparedText != nil || $0.code != nil) && $0.footer == nil
        }
        #expect(completedLiveTextItems.allSatisfy { $0.allowsTextSelection })
        let stableUserID = try #require(liveTextItems.first { $0.textRole == .user }?.id)
        #expect(!completedSnapshot.changedItemIDs.contains(stableUserID))
        let completedFooter = try #require(completedSnapshot.itemsByID.values.first {
            $0.turnID == "streaming" && $0.footer?.kind == .finalAnswer
        })
        #expect(completedFooter.footer?.isTurnStreaming == false)
        #expect(completedFooter.copyText == "Complete answer")
        #expect(completedSnapshot.changedItemIDs.contains(completedFooter.id))
    }

    @Test func timestampFooterRestoresHoverTurnActions() async throws {
        let projector = CodexTranscriptRenderProjector()
        let presentation = CodexThreadUIPresentation(
            threadID: "thread",
            transcript: .init(turns: [.init(
                id: "turn",
                userMessage: .init(id: "user", text: "Question"),
                finalAnswer: .init(id: "final", text: "Answer", isStreaming: false),
                status: .done(durationMs: 10)
            )]),
            presentedAtByTurnID: ["turn": Date(timeIntervalSince1970: 100)]
        )
        let theme = CodexTranscriptAppKitTheme(.officialDark)
        let snapshot = try await projector.project(presentation: presentation, availableWidth: 860, theme: theme)
        let footerID = try #require(snapshot.orderedItemIDs.first { $0.rawValue.hasSuffix(":final-timestamp") })
        let footer = try #require(snapshot.itemsByID[footerID])
        let clipboard = RecordingClipboard()
        let cell = CodexTranscriptCollectionItem()
        _ = cell.view
        cell.configure(
            item: footer,
            appKitTheme: theme,
            swiftUITheme: .officialDark,
            contentHorizontalOffset: 0,
            productToolRenderer: nil,
            performAction: { _ in },
            copy: clipboard.copy,
            editUserMessage: { _ in },
            forkChat: {},
            selectionChanged: { _, _ in }
        )

        #expect(!cell.footerCopyTurnIsVisibleForTesting)
        cell.setHoveredForTesting(true)
        #expect(cell.footerCopyTurnIsVisibleForTesting)
        #expect(cell.footerCopyItemTitleForTesting.isEmpty)
        #expect(cell.footerCopyItemToolTipForTesting == "Copy answer")
        cell.copyTurnForTesting()
        #expect(clipboard.lastValue == footer.copyTurnText)
        #expect(cell.footerCopyTurnAccessibilityDescriptionForTesting == "Copied")
    }

    @Test func completedFinalAnswerUsesOneNativeSurfaceForContiguousSelection() async throws {
        let markdown = """
        Intro paragraph with context.

        Three highest-risk findings:

        ## First finding

        Body with a [file reference](https://example.com/file.swift#L42).

        Final paragraph with the conclusion.
        """
        let projector = CodexTranscriptRenderProjector()
        let presentation = CodexThreadUIPresentation(
            threadID: "thread",
            transcript: .init(turns: [.init(
                id: "turn",
                finalAnswer: .init(id: "final", text: markdown, isStreaming: false),
                status: .done(durationMs: 10)
            )])
        )
        let theme = CodexTranscriptAppKitTheme(.officialDark)
        let snapshot = try await projector.project(presentation: presentation, availableWidth: 860, theme: theme)
        let answerItems = snapshot.itemsByID.values.filter {
            $0.turnID == "turn" && ($0.textRole == .finalAnswer || $0.code != nil)
        }

        #expect(answerItems.count == 1)
        let answerItem = try #require(answerItems.first)
        let renderedText = try #require(answerItem.preparedText?.attributedString.string)
        #expect(renderedText.contains("Intro paragraph with context."))
        #expect(renderedText.contains("First finding"))
        #expect(renderedText.contains("file reference"))
        #expect(renderedText.contains("Final paragraph with the conclusion."))

        let cell = CodexTranscriptCollectionItem()
        _ = cell.view
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 500),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = cell.view
        cell.configure(
            item: answerItem,
            appKitTheme: theme,
            swiftUITheme: .officialDark,
            contentHorizontalOffset: 0,
            productToolRenderer: nil,
            performAction: { _ in },
            copy: { _ in },
            editUserMessage: { _ in },
            forkChat: nil,
            selectionChanged: { _, _ in }
        )
        cell.selectableTextViewForTesting.setSelectedRange(NSRange(location: 0, length: renderedText.utf16.count))
        #expect(cell.selectableTextViewForTesting.selectedRange().length == renderedText.utf16.count)
        NSPasteboard.general.clearContents()
        #expect(window.makeFirstResponder(cell.selectableTextViewForTesting))
        cell.selectableTextViewForTesting.copy(nil)
        #expect(NSPasteboard.general.string(forType: .string) == renderedText)
    }

    @Test func selectionSuppressesPinnedFollowAndTickerHasOneTarget() async throws {
        let coordinator = CodexTranscriptListHost.Coordinator()
        let container = CodexTranscriptCollectionContainerView(frame: NSRect(x: 0, y: 0, width: 860, height: 500))
        let window = NSWindow(contentRect: container.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = container
        coordinator.attach(to: container)
        let clipboard = RecordingClipboard()
        let store = CodexPresentationStore()
        let date = Date(timeIntervalSince1970: 100)
        var presentation = workingPresentation(date: date)
        coordinator.update(
            presentation: presentation,
            presentationStore: store,
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

        let selectableID = try #require(coordinator.renderedItemIDsForTesting.first {
            $0.rawValue.contains(":commentary:completed-commentary:")
        })
        let selectedCell = try #require(coordinator.collectionItemForTesting(selectableID))
        selectedCell.selectableTextViewForTesting.setSelectedRange(NSRange(location: 0, length: 7))
        coordinator.setSelectingForTesting(true, id: selectableID)
        container.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 40))
        let preservedOffset = container.scrollView.contentView.bounds.origin.y
        presentation.transcript.turns[1].narrative[0] = .prose(.init(
            id: "commentary",
            text: "Working commentary plus tokens",
            isStreaming: true
        ))
        coordinator.update(
            presentation: presentation,
            presentationStore: store,
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
        #expect(coordinator.collectionItemForTesting(selectableID) === selectedCell)
        #expect(selectedCell.selectableTextViewForTesting.selectedRange() == NSRange(location: 0, length: 7))

        presentation.transcript.turns[1].status = .done(durationMs: 1_000)
        presentation.expandedWorkTurnIDs.insert("turn")
        coordinator.update(
            presentation: presentation,
            presentationStore: store,
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
        let agent = try #require(snapshot.itemsByID.values.first { !$0.agentChips.isEmpty })
        let product = try #require(snapshot.itemsByID.first { $0.key.rawValue.contains(":product:product") }?.value)
        let final = try #require(snapshot.itemsByID.first {
            $0.key.rawValue.contains(":final:final:selection-surface:")
        }?.value)
        let cell = CodexTranscriptCollectionItem()
        _ = cell.view
        cell.view.frame = NSRect(x: 0, y: 0, width: 860, height: 44)
        var openedThreadID: String?
        var editedText: String?
        var forkCount = 0
        var preferredProductHeight: CGFloat?
        func configure(
            _ item: CodexTranscriptRenderItem,
            renderer: CodexProductToolRendererV2? = nil,
            preferredHeightChanged: @escaping (CodexTranscriptRenderItemID, Int, CGFloat) -> Void = { _, _, _ in }
        ) {
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
                selectionChanged: { _, _ in },
                preferredHeightChanged: preferredHeightChanged
            )
        }

        configure(agent)
        cell.openAgentChipForTesting(at: 0)
        #expect(openedThreadID == "child-thread")

        configure(user)
        cell.editUserForTesting()
        #expect(editedText == "Revise this")
        #expect(cell.selectableTextViewForTesting.accessibilityLabel()?.contains("You") == true)

        configure(final)
        cell.forkChatForTesting()
        #expect(forkCount == 1)

        configure(
            product,
            renderer: CodexProductToolRendererV2 { _ in AnyView(Text("Host-rendered tool").frame(height: 120)) },
            preferredHeightChanged: { _, _, height in preferredProductHeight = height }
        )
        cell.view.layoutSubtreeIfNeeded()
        await Task.yield()
        #expect(cell.hasHostedViewForTesting)
        #expect((preferredProductHeight ?? 0) >= 120)
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
                presentationStore: nil,
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
        let completedTurn = CodexTurnV2(
            id: "completed-turn",
            userMessage: .init(id: "completed-user", text: "Earlier question"),
            narrative: [.prose(.init(
                id: "completed-commentary",
                text: "Earlier completed commentary",
                isStreaming: false
            ))],
            finalAnswer: .init(id: "completed-final", text: "Earlier answer", isStreaming: false),
            status: .done(durationMs: 100)
        )
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
            transcript: .init(turns: [completedTurn, turn]),
            isPinnedToBottom: true,
            expandedWorkTurnIDs: [completedTurn.id],
            presentedAtByTurnID: [completedTurn.id: date, turn.id: date]
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
