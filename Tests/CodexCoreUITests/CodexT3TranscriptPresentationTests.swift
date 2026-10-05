import AppKit
import CodexCore
@testable import CodexCoreUI
import Foundation
import SwiftUI
import Testing

@MainActor
struct CodexT3TranscriptPresentationTests {
    @Test func summaryPrioritizesTwoActionCategoriesAndCountsTheRemainder() {
        let rows: [CodexWorkRowV2] = [
            command("run-1", .run), command("read", .read),
            .fileChange(.init(id: "edit-1", files: ["A.swift", "B.swift"], status: .completed)),
            command("run-2", .run), command("search", .search),
            .fileChange(.init(id: "edit-2", files: ["A.swift"], status: .completed)),
        ]
        #expect(CodexT3WorkGroupSummary.synthesize(rows: rows)
            == "Ran 2 commands, changed 2 files, and performed 2 other actions")
        #expect(CodexT3WorkGroupSummary.synthesize(rows: [command("search", .search)]) == "Searched code 1 time")
        #expect(CodexT3WorkGroupSummary.synthesize(rows: [command("read", .read), command("list", .list)]) == "Read 2 files")
    }

    @Test func summaryRetainsUniqueIntegrationNamesInArrivalOrder() {
        let rows: [CodexWorkRowV2] = [
            .mcpToolCall(.init(id: "docs-1", appName: "Docs", server: "docs", tool: "search", status: .completed)),
            command("run", .run),
            .mcpToolCall(.init(id: "github", appName: "GitHub", server: "github", tool: "read", status: .completed)),
            .mcpToolCall(.init(id: "docs-2", appName: "Docs", server: "docs", tool: "read", status: .completed)),
        ]
        #expect(CodexT3WorkGroupSummary.synthesize(rows: rows) == "Used Docs and GitHub integrations and ran 1 command")
        #expect(CodexT3WorkGroupSummary.synthesize(rows: []) == "")
    }

    @Test func completedCommentaryAndCompactGroupsRemainVisibleWithoutTurnExpansion() async throws {
        let turn = CodexTurnV2(
            id: "turn", narrative: [
                .prose(.init(id: "commentary", text: "Checking the source.", isStreaming: false)),
                .workGroup(.init(id: "group", rows: [command("read", .read), command("test", .run)], isLive: false)),
            ], finalAnswer: .init(id: "answer", text: "Done.", isStreaming: false), status: .done(durationMs: 4_000)
        )
        let projector = CodexTranscriptRenderProjector()
        let presentation = CodexThreadUIPresentation(threadID: "thread", transcript: .init(turns: [turn]))
        let t3 = try await projector.project(presentation: presentation, availableWidth: 1_200, theme: t3Theme)
        #expect(t3.itemsByID.values.contains { $0.sourceItemID == "commentary" })
        #expect(!t3.itemsByID.values.contains { $0.workHeader != nil })
        let summary = try #require(t3.itemsByID.values.first { $0.workRow?.style == .activitySummary })
        #expect(summary.workRow?.label == "Read 1 file and ran 1 command")
        #expect(summary.measuredHeight == 28)
        #expect(!t3.itemsByID.values.contains { $0.sourceItemID == "read" })

        let native = try await projector.project(presentation: presentation, availableWidth: 1_200, theme: .init(.officialDark, colorScheme: .dark))
        #expect(native.itemsByID.values.contains { $0.workHeader != nil })
        #expect(!native.itemsByID.values.contains { $0.sourceItemID == "commentary" })
    }

    @Test func oneCompletedToolUsesItsDirectDetailActionAndPreservesExactOutput() async throws {
        let row = command("read", .read, output: "Full source output")
        let turn = CodexTurnV2(id: "turn", narrative: [.workGroup(.init(id: "group", rows: [row], isLive: false))], status: .done(durationMs: nil))
        let projector = CodexTranscriptRenderProjector()
        var presentation = CodexThreadUIPresentation(threadID: "thread", transcript: .init(turns: [turn]))
        let collapsed = try await projector.project(presentation: presentation, availableWidth: 860, theme: t3Theme)
        #expect(!collapsed.itemsByID.values.contains { $0.workRow?.style == .activitySummary })
        let visible = try #require(collapsed.itemsByID.values.first { $0.sourceItemID == "read" })
        #expect(visible.action == .toggleRow(rowID: "read"))
        presentation.expandedRowIDs = ["read"]
        let expanded = try await projector.project(presentation: presentation, availableWidth: 860, theme: t3Theme)
        let detail = try #require(expanded.itemsByID.values.first { $0.textRole == .expandedOutput })
        #expect(detail.indentation == 28)
        #expect(detail.copyText == "Full source output")
    }

    @Test func firstFinalAnswerDeltaKeepsPriorCommentaryWorkPlansAndQuestionsVisible() async throws {
        let turn = CodexTurnV2(id: "turn", narrative: [
            .prose(.init(id: "commentary", text: "I checked the source.", isStreaming: false)),
            .workGroup(.init(id: "group", rows: [command("read", .read)], isLive: false)),
            .proposedPlan(.init(id: "plan", markdown: "# Update\n\nKeep state stable.")),
            .questions(.init(id: "question", prompt: "Select the mode", questions: [.init(id: "mode", title: "Mode", options: ["Compact", "Expanded"])])),
        ], finalAnswer: .init(id: "answer", text: "The result", isStreaming: true), status: .working(since: 1))
        let snapshot = try await CodexTranscriptRenderProjector().project(
            presentation: .init(threadID: "thread", transcript: .init(turns: [turn])), availableWidth: 860, theme: t3Theme
        )
        #expect(snapshot.itemsByID.values.contains { $0.sourceItemID == "commentary" })
        #expect(snapshot.itemsByID.values.contains { $0.sourceItemID == "read" })
        #expect(snapshot.itemsByID.values.contains { $0.proposedPlan?.plan.id == "plan" })
        #expect(snapshot.itemsByID.values.contains { $0.questions?.id == "question" })
        #expect(snapshot.itemsByID.values.contains { $0.textRole == .finalAnswer })
    }

    @Test func t3BubbleUsesEightyPercentLaneAndTwelvePointPadding() async throws {
        let turn = CodexTurnV2(id: "turn", userMessage: .init(id: "user", text: String(repeating: "A readable request. ", count: 30)), status: .done(durationMs: nil))
        let snapshot = try await CodexTranscriptRenderProjector().project(
            presentation: .init(threadID: "thread", transcript: .init(turns: [turn])), availableWidth: 1_200, theme: t3Theme
        )
        let user = try #require(snapshot.itemsByID.values.first { $0.textRole == .user })
        #expect(abs(user.maxContentWidth - 736 * 0.8) < 0.001)
        let textHeight = try #require(user.preparedText).attributedString.boundingRect(
            with: NSSize(width: user.maxContentWidth - 24, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        #expect(user.measuredHeight == ceil(textHeight) + 24)
    }

    @Test func proposedPlanUsesSemanticTitleBoundedPreviewAndExactExport() async throws {
        let markdown = "# Refactor the runtime\n\n## Summary\n\n" + (1...30).map { "\($0). Preserve canonical state" }.joined(separator: "\n") + "\n\n"
        #expect(CodexProposedPlanPresentation.title(markdown) == "Refactor the runtime")
        #expect(CodexProposedPlanPresentation.canCollapse(markdown))
        #expect(CodexProposedPlanPresentation.preview(markdown).contains("10. Preserve canonical state"))
        #expect(!CodexProposedPlanPresentation.preview(markdown).contains("11. Preserve canonical state"))
        #expect(!CodexProposedPlanPresentation.displayMarkdown(markdown).contains("## Summary"))
        #expect(CodexProposedPlanPresentation.exportFilename(markdown) == "refactor-the-runtime.md")
        #expect(CodexProposedPlanPresentation.exportMarkdown(markdown).hasSuffix("state\n"))
        #expect(CodexProposedPlanPresentation.exportMarkdown(markdown).hasPrefix("# Refactor the runtime"))
        let plan = CodexProposedPlanV2(id: "plan", markdown: markdown)
        let turn = CodexTurnV2(id: "turn", narrative: [.proposedPlan(plan)], status: .done(durationMs: nil))
        let projector = CodexTranscriptRenderProjector()
        var presentation = CodexThreadUIPresentation(threadID: "thread", transcript: .init(turns: [turn]))
        let preview = try await projector.project(presentation: presentation, availableWidth: 860, theme: t3Theme)
        let previewItem = try #require(preview.itemsByID.values.first { $0.proposedPlan != nil })
        #expect(previewItem.sourceItemID == "plan")
        #expect(previewItem.copyText == markdown)
        #expect(previewItem.action == .toggleRow(rowID: "proposed-plan:turn:plan"))
        presentation.expandedRowIDs = ["proposed-plan:turn:plan"]
        let full = try await projector.project(presentation: presentation, availableWidth: 860, theme: t3Theme)
        let fullItem = try #require(full.itemsByID.values.first { $0.proposedPlan != nil })
        #expect(fullItem.proposedPlan?.displayedMarkdown.contains("30. Preserve canonical state") == true)
        #expect(fullItem.measuredHeight > previewItem.measuredHeight)
        presentation.transcript.turns.append(.init(id: "later-turn", narrative: [.proposedPlan(plan)], status: .done(durationMs: nil)))
        let repeatedID = try await projector.project(presentation: presentation, availableWidth: 860, theme: t3Theme)
        let firstPlan = try #require(repeatedID.itemsByID[fullItem.id])
        let laterPlan = try #require(repeatedID.itemsByID.values.first { $0.proposedPlan != nil && $0.id != fullItem.id })
        #expect(firstPlan.proposedPlan?.isExpanded == true)
        #expect(laterPlan.proposedPlan?.isExpanded == false)
        #expect(laterPlan.action == .toggleRow(rowID: "proposed-plan:later-turn:plan"))
        #expect(laterPlan.proposedPlan?.displayedMarkdown.contains("30. Preserve canonical state") == false)
    }

    @Test func markdownMessageHeadingsKeepTheReadingFontSize() async throws {
        let turn = CodexTurnV2(id: "turn", finalAnswer: .init(id: "answer", text: "# Outcome", isStreaming: false), status: .done(durationMs: nil))
        let snapshot = try await CodexTranscriptRenderProjector().project(
            presentation: .init(threadID: "thread", transcript: .init(turns: [turn])), availableWidth: 860, theme: t3Theme
        )
        let heading = try #require(snapshot.itemsByID.values.first { $0.textRole == .finalAnswer }?.preparedText)
        let font = heading.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == t3Theme.bodyFont.pointSize)
    }

    @Test func changedFileTreeCompactsChainsAndRetainsExactReviewPaths() {
        let files = [summary("Sources/UI/View10.swift", 2, 1), summary("Sources/UI/View2.swift", 3, 4), summary("README.md", 1, 0)]
        let collapsed = CodexChangedFilesTreeV2.rows(files: files, rowID: "diff", allExpanded: false, toggledDirectoryIDs: [])
        #expect(collapsed.map(\.name) == ["Sources/UI", "README.md"])
        #expect(collapsed.first?.added == 5)
        #expect(collapsed.first?.removed == 5)
        let expanded = CodexChangedFilesTreeV2.rows(files: files, rowID: "diff", allExpanded: false, toggledDirectoryIDs: ["diff:directory:Sources/UI"])
        #expect(expanded.map(\.name) == ["Sources/UI", "View2.swift", "View10.swift", "README.md"])
        #expect(expanded[1].path == "Sources/UI/View2.swift")
        #expect(expanded[1].depth == 1)
        #expect(CodexChangedFilesTreeV2.compactCount(1_250) == "1.3k")
        #expect(CodexChangedFilesTreeV2.compactCount(12_000) == "12k")
    }

    @Test func changedFilesFollowTheAssistantAnswerAndDirectoryDisclosureUsesCanonicalState() async throws {
        let patch = "--- a/Sources/UI/View.swift\n+++ b/Sources/UI/View.swift\n@@ -1 +1 @@\n-old\n+new\n"
        let turn = CodexTurnV2(id: "turn", narrative: [.workGroup(.init(id: "group", rows: [
            .fileChange(.init(id: "edit", files: ["Sources/UI/View.swift"], status: .completed, diff: patch))
        ], isLive: false))], finalAnswer: .init(id: "answer", text: "Updated the view.", isStreaming: false), status: .done(durationMs: nil))
        let projector = CodexTranscriptRenderProjector()
        var presentation = CodexThreadUIPresentation(threadID: "thread", transcript: .init(turns: [turn]))
        let collapsed = try await projector.project(presentation: presentation, availableWidth: 860, theme: t3Theme)
        let answerIndex = try #require(collapsed.orderedItemIDs.firstIndex { collapsed.itemsByID[$0]?.textRole == .finalAnswer })
        let diffIndex = try #require(collapsed.orderedItemIDs.firstIndex { collapsed.itemsByID[$0]?.turnDiff != nil })
        #expect(answerIndex < diffIndex)
        #expect(collapsed.itemsByID[collapsed.orderedItemIDs[diffIndex]]?.turnDiff?.treeRows.map(\.name) == ["Sources/UI"])
        presentation.expandedRowIDs = ["turn-diff:turn:directory:Sources/UI"]
        let expanded = try await projector.project(presentation: presentation, availableWidth: 860, theme: t3Theme)
        #expect(expanded.itemsByID.values.first { $0.turnDiff != nil }?.turnDiff?.treeRows.map(\.name) == ["Sources/UI", "View.swift"])
    }

    @Test func metadataDrivenMCPDetailsShowSourceAndPageWithoutReplacingProviderData() async throws {
        let arguments: CodexJSONValue = .dictionary(["query": .string("codex")])
        let result: CodexJSONValue = .dictionary(["raw": .string("Provider result")])
        let row = CodexMCPToolCallRowV2(
            id: "browser", appName: "", server: "browser", tool: "open_page", status: .completed,
            arguments: arguments, result: result,
            presentation: .init(sourceName: "Chrome", title: "Open page", symbolName: "globe", pageURL: "https://example.com/docs")
        )
        let detail = try #require(row.transcriptDetail)
        #expect(detail.contains("Source\nChrome"))
        #expect(detail.contains("Page\nhttps://example.com/docs"))
        #expect(detail.contains("Arguments\n\(arguments.description)"))
        #expect(detail.contains("Result\n\(result.description)"))
        let turn = CodexTurnV2(id: "turn", narrative: [.workGroup(.init(id: "group", rows: [.mcpToolCall(row)], isLive: false))], status: .done(durationMs: nil))
        let snapshot = try await CodexTranscriptRenderProjector().project(
            presentation: .init(threadID: "thread", transcript: .init(turns: [turn]), expandedRowIDs: [row.id]), availableWidth: 860, theme: t3Theme
        )
        let work = try #require(snapshot.itemsByID.values.first { $0.workRow != nil })
        #expect(work.workRow?.label == "Open page")
        #expect(work.workRow?.systemImage == "globe")
        let output = try #require(snapshot.itemsByID.values.first { $0.textRole == .expandedOutput })
        #expect(output.copyText == detail)
        #expect(row.result == result)
    }

    @Test func hostedPlanAndQuestionHeightRetainsTheTranscriptGapAndFitsAllActions() async throws {
        let turn = CodexTurnV2(id: "turn", narrative: [
            .proposedPlan(.init(id: "plan", markdown: "# Preserve the runtime\n\n" + (1...24).map { "\($0). Keep canonical state authoritative." }.joined(separator: "\n"))),
            .questions(.init(id: "questions", prompt: "Choose the implementation", questions: [.init(id: "mode", title: "Mode", options: ["Compact", "Expanded", "Automatic", "Custom"])])),
        ], status: .done(durationMs: nil))
        let snapshot = try await CodexTranscriptRenderProjector().project(
            presentation: .init(threadID: "thread", transcript: .init(turns: [turn])), availableWidth: 860, theme: t3Theme
        )
        let cell = CodexTranscriptCollectionItem()
        _ = cell.view
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = cell.view
        defer { window.close() }
        for var item in snapshot.itemsByID.values.filter({ $0.proposedPlan != nil || $0.questions != nil }) {
            let questionState = CodexAsyncQuestionPresentationState()
            item.measuredHeight = 80 // Simulate the first estimate before native hosting measures the card.
            cell.view.frame = NSRect(x: 0, y: 0, width: 860, height: item.measuredHeight)
            var reportedHeight: CGFloat?
            func configure() {
                cell.configure(
                    item: item, appKitTheme: t3Theme,
                    swiftUITheme: CodexAppearanceSettings.t3Code.agentTheme(uiFontSize: 14, reduceMotion: true),
                    contentHorizontalOffset: 0, productToolRenderer: nil,
                    performAction: { _ in }, copy: { _ in }, editUserMessage: { _ in },
                    questionPresentationState: questionState,
                    forkChat: nil, selectionChanged: { _, _ in },
                    preferredHeightChanged: { id, revision, height in
                        #expect(id == item.id)
                        #expect(revision == item.revision)
                        reportedHeight = height
                    }
                )
            }
            configure()
            cell.view.layoutSubtreeIfNeeded()
            await Task.yield()
            let host = try #require(cell.view.subviews.first { $0 is NSHostingView<AnyView> })
            let measuredCardHeight = ceil(host.fittingSize.height)
            let totalHeight = try #require(reportedHeight)
            #expect(item.bottomSpacing > 0)
            #expect(totalHeight >= measuredCardHeight + item.bottomSpacing)
            item.measuredHeight = totalHeight
            cell.view.frame.size.height = totalHeight
            configure()
            cell.view.layoutSubtreeIfNeeded()
            #expect(host.frame.height >= measuredCardHeight)
            #expect(abs((cell.view.bounds.height - host.frame.height) - item.bottomSpacing) < 1)
            if item.questions != nil {
                reportedHeight = nil
                questionState.isCollapsed = true
                try await Task.sleep(for: .milliseconds(30))
                cell.view.layoutSubtreeIfNeeded()
                await Task.yield()
                let collapsedHeight = try #require(reportedHeight)
                #expect(collapsedHeight < totalHeight)
                #expect(collapsedHeight >= ceil(host.fittingSize.height) + item.bottomSpacing)
            }
        }
    }

    @Test func historyReadingCallbackIgnoresProgrammaticScrollAndOnlyReportsGestureTransitions() async throws {
        let coordinator = CodexTranscriptListHost.Coordinator()
        let container = CodexTranscriptCollectionContainerView(frame: NSRect(x: 0, y: 0, width: 860, height: 500))
        let window = NSWindow(contentRect: container.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        coordinator.attach(to: container)
        defer { coordinator.detach(); window.close() }
        let turn = CodexTurnV2(id: "turn", finalAnswer: .init(id: "answer", text: (1...80).map { "Line \($0) in the transcript." }.joined(separator: "\n\n"), isStreaming: false), status: .done(durationMs: nil))
        var reported: [Bool] = []
        coordinator.update(
            presentation: .init(threadID: "thread", transcript: .init(turns: [turn])),
            presentationStore: nil, bottomContentInset: 170, contentHorizontalOffset: 0,
            swiftUITheme: CodexAppearanceSettings.t3Code.agentTheme(uiFontSize: 14, reduceMotion: true),
            colorScheme: .dark, clipboardService: CodexNoopClipboardService(), productToolRenderer: nil,
            onOpenSubagent: { _ in }, onEditUserMessage: { _ in },
            onReadingHistoryChanged: { reported.append($0) }, onForkChat: nil
        )
        await coordinator.waitForProjectionForTesting()
        try await Task.sleep(for: .milliseconds(20))
        container.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 0))
        container.scrollView.reflectScrolledClipView(container.scrollView.contentView)
        #expect(reported.isEmpty)
        container.scrollView.onUserScroll?()
        container.scrollView.onUserScroll?()
        #expect(reported == [true])
        container.onJumpToLatest?()
        #expect(reported == [true, false])
    }

    private var t3Theme: CodexTranscriptAppKitTheme { .init(CodexAppearanceSettings.t3Code.agentTheme(uiFontSize: 14, reduceMotion: true), colorScheme: .dark) }

    private func command(_ id: String, _ action: CodexWorkCategoryV2, output: String? = nil) -> CodexWorkRowV2 {
        .command(.init(id: id, command: "source command", label: "Read source", action: action, status: .completed, output: output))
    }

    private func summary(_ path: String, _ added: Int, _ removed: Int) -> CodexPreparedFileChangeSummaryV2 {
        .init(path: path, previousPath: nil, kind: .modified, added: added, removed: removed, isBinary: false)
    }
}
