import AppKit
import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

@MainActor
struct CodexTranscriptRenderProjectionTests {
    @Test func streamingAnswerKeepsOnlyLiveWorkChipVisible() async throws {
        let projector = CodexTranscriptRenderProjector()
        let turn = CodexTurnV2(
            id: "turn",
            narrative: [.workGroup(.init(
                id: "work",
                rows: [
                    .command(.init(
                        id: "done",
                        command: "pwd",
                        label: "Ran pwd",
                        action: .run,
                        status: .completed,
                        exitCode: 0
                    )),
                    .command(.init(
                        id: "live",
                        command: "swift test",
                        label: "Running tests",
                        action: .run,
                        status: .inProgress
                    ))
                ]
            ))],
            finalAnswer: .init(id: "answer", text: "Partial answer", isStreaming: true),
            status: .working(since: 1)
        )
        let snapshot = try await projector.project(
            presentation: .init(threadID: "thread", transcript: .init(turns: [turn])),
            availableWidth: 860,
            theme: CodexTranscriptAppKitTheme(.officialDark)
        )
        let rowIDs = snapshot.orderedItemIDs.filter { $0.rawValue.contains(":row:") }
        #expect(rowIDs.count == 1)
        #expect(rowIDs.first?.rawValue.hasSuffix(":row:live") == true)
        #expect(snapshot.itemsByID[rowIDs[0]]?.workRow?.kind == .command)
        #expect(snapshot.itemsByID[rowIDs[0]]?.workRow?.isActionable == false)
        #expect(snapshot.itemsByID.values.contains { $0.textRole == .finalAnswer })
    }

    @Test func markdownLinksNestedListsAndCompletedCodeCarryExplicitStyling() async throws {
        let projector = CodexTranscriptRenderProjector()
        let markdown = """
        Read [the docs](https://example.com/docs).

        1. first
        2. second
           1. nested one
           2. nested two
        3. third

        ```swift
        let answer = "forty two"
        ```
        """
        let presentation = CodexThreadUIPresentation(
            threadID: "thread",
            transcript: .init(turns: [.init(
                id: "turn",
                finalAnswer: .init(id: "final", text: markdown, isStreaming: false),
                status: .done(durationMs: 1)
            )])
        )
        let theme = CodexTranscriptAppKitTheme(.officialDark)
        let snapshot = try await projector.project(
            presentation: presentation,
            availableWidth: 860,
            theme: theme
        )
        let prose = try #require(snapshot.itemsByID.values.first { $0.textRole == .finalAnswer })
        let attributed = try #require(prose.preparedText?.attributedString)
        let docsRange = (attributed.string as NSString).range(of: "the docs")
        #expect(attributed.attribute(.link, at: docsRange.location, effectiveRange: nil) != nil)
        #expect(attributed.attribute(.foregroundColor, at: docsRange.location, effectiveRange: nil) as? NSColor == theme.accent)
        #expect((attributed.attribute(.underlineStyle, at: docsRange.location, effectiveRange: nil) as? Int) == NSUnderlineStyle.single.rawValue)

        let nestedRange = (attributed.string as NSString).range(of: "nested one")
        let nestedStyle = try #require(attributed.attribute(
            .paragraphStyle,
            at: nestedRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        #expect(nestedStyle.firstLineHeadIndent == 24)
        #expect(nestedStyle.headIndent == 48)
        #expect(attributed.string.contains("1.\tnested one\n2.\tnested two"))

        let code = try #require(snapshot.itemsByID.values.first { $0.code != nil })
        let highlighted = try #require(code.preparedText?.attributedString)
        let keywordRange = (highlighted.string as NSString).range(of: "let")
        let stringRange = (highlighted.string as NSString).range(of: "\"forty two\"")
        #expect(highlighted.attribute(.foregroundColor, at: keywordRange.location, effectiveRange: nil) as? NSColor == theme.codeKeyword)
        #expect(highlighted.attribute(.foregroundColor, at: stringRange.location, effectiveRange: nil) as? NSColor == theme.codeString)
    }

    @Test func incompleteStreamingCodeStaysPlainUntilStable() async throws {
        let projector = CodexTranscriptRenderProjector()
        let presentation = CodexThreadUIPresentation(
            threadID: "thread",
            transcript: .init(turns: [.init(
                id: "turn",
                finalAnswer: .init(id: "final", text: "```swift\nlet answer = 42", isStreaming: true),
                status: .working(since: 1)
            )])
        )
        let theme = CodexTranscriptAppKitTheme(.officialDark)
        let snapshot = try await projector.project(
            presentation: presentation,
            availableWidth: 860,
            theme: theme
        )
        let code = try #require(snapshot.itemsByID.values.first { $0.code != nil })
        let attributed = try #require(code.preparedText?.attributedString)
        let keywordRange = (attributed.string as NSString).range(of: "let")
        #expect(attributed.attribute(.foregroundColor, at: keywordRange.location, effectiveRange: nil) as? NSColor == theme.codeText)
        #expect(code.allowsTextSelection)
    }

    @Test func shortUserMessageIsPlainTextAndUsesIntrinsicBubbleWidth() async throws {
        let projector = CodexTranscriptRenderProjector()
        let presentation = CodexThreadUIPresentation(
            threadID: "thread",
            transcript: .init(turns: [.init(
                id: "turn",
                userMessage: .init(id: "user", text: "*stars* # heading `ticks`"),
                status: .done(durationMs: 1)
            )])
        )
        let theme = CodexTranscriptAppKitTheme(.officialDark)
        let snapshot = try await projector.project(
            presentation: presentation,
            availableWidth: 860,
            theme: theme
        )
        let user = try #require(snapshot.itemsByID.values.first { $0.textRole == .user })

        #expect(user.preparedText?.attributedString.string == "*stars* # heading `ticks`")
        #expect(try #require(user.intrinsicContentWidth) < user.maxContentWidth)
        #expect(user.maxContentWidth <= theme.transcriptOuterMaxWidth * 0.77)
    }

    @Test func allV2KindsProjectToFineGrainedStableItems() async throws {
        let projector = CodexTranscriptRenderProjector()
        let turn = allKindsTurn()
        let presentation = CodexThreadUIPresentation(
            threadID: "thread",
            transcript: .init(turns: [turn]),
            expandedWorkTurnIDs: [turn.id],
            expandedRowIDs: ["command"],
            presentedAtByTurnID: [turn.id: Date(timeIntervalSince1970: 100)]
        )
        let snapshot = try await projector.project(
            presentation: presentation,
            availableWidth: 860,
            theme: CodexTranscriptAppKitTheme(.officialDark)
        )

        #expect(snapshot.sectionIDs == ["thread:turn:turn"])
        #expect(snapshot.orderedItemIDs.count > 16)
        #expect(!snapshot.orderedItemIDs.contains(CodexTranscriptRenderItemID(rawValue: turn.id)))
        let rawIDs = snapshot.orderedItemIDs.map(\.rawValue)
        #expect(rawIDs.contains { $0.contains(":user:user") })
        #expect(rawIDs.contains { $0.hasSuffix(":work-header") })
        #expect(rawIDs.contains { $0.contains(":commentary:commentary:selection-surface:") })
        #expect(rawIDs.contains { $0.contains(":group:group:header") })
        #expect(rawIDs.contains { $0.contains(":row:command") })
        #expect(rawIDs.contains { $0.contains(":row:command:detail") })
        #expect(rawIDs.contains { $0.contains(":row:file") })
        #expect(rawIDs.contains { $0.contains(":row:mcp") })
        #expect(rawIDs.contains { $0.contains(":row:web") })
        #expect(rawIDs.contains { $0.contains(":row:collab") })
        #expect(rawIDs.contains { $0.contains(":row:other") })
        #expect(rawIDs.contains { $0.contains(":product:product") })
        #expect(rawIDs.contains { $0.contains(":notice:notice") })
        #expect(rawIDs.contains { $0.contains(":final:final:selection-surface:") })

        let commandDetail = try #require(snapshot.itemsByID.first { $0.key.rawValue.contains(":row:command:detail") }?.value)
        #expect(commandDetail.textRole == .expandedOutput)
        #expect(commandDetail.preparedText?.attributedString.string.contains("Output truncated for display") == true)
        #expect(commandDetail.copyText?.count == 20_100)
        let collab = try #require(snapshot.itemsByID.first { $0.key.rawValue.contains(":row:collab") }?.value)
        #expect(collab.action == .openSubagent(threadID: "child-thread"))
        #expect(collab.copyTurnText.contains("Assistant\n# Final"))
        #expect(snapshot.itemsByID.values.contains { item in
            guard let text = item.preparedText?.attributedString, text.length > 0 else { return false }
            var hasTableBlock = false
            text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, stop in
                if let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty {
                    hasTableBlock = true
                    stop.pointee = true
                }
            }
            return hasTableBlock
        })
    }

    @Test func streamingDeltaChangesOnlyStableTailRevision() async throws {
        let projector = CodexTranscriptRenderProjector()
        let date = Date(timeIntervalSince1970: 100)
        func presentation(answer: String) -> CodexThreadUIPresentation {
            .init(
                threadID: "thread",
                transcript: .init(turns: [.init(
                    id: "turn",
                    userMessage: .init(id: "user", text: "Question"),
                    finalAnswer: .init(id: "final", text: answer, isStreaming: true),
                    status: .working(since: 100)
                )]),
                presentedAtByTurnID: ["turn": date]
            )
        }
        let theme = CodexTranscriptAppKitTheme(.officialDark)
        let first = try await projector.project(presentation: presentation(answer: "Hello"), availableWidth: 860, theme: theme)
        let second = try await projector.project(presentation: presentation(answer: "Hello world"), availableWidth: 860, theme: theme)
        let firstFinal = try #require(first.orderedItemIDs.first {
            $0.rawValue.contains(":final:final:selection-surface:")
        })
        let secondFinal = try #require(second.orderedItemIDs.first {
            $0.rawValue.contains(":final:final:selection-surface:")
        })

        #expect(firstFinal == secondFinal)
        #expect(second.changedItemIDs == [secondFinal])
        #expect(second.itemsByID[secondFinal]?.revision == (first.itemsByID[firstFinal]?.revision ?? 0) + 1)
        #expect(second.diagnostics.heightCacheHitCount >= 3)
    }

    @Test func unchangedProjectionHitsHeightCacheAndHasNoChangedItems() async throws {
        let projector = CodexTranscriptRenderProjector()
        let presentation = CodexThreadUIPresentation(
            threadID: "thread",
            transcript: .init(turns: [allKindsTurn()]),
            expandedWorkTurnIDs: ["turn"],
            presentedAtByTurnID: ["turn": Date(timeIntervalSince1970: 100)]
        )
        let theme = CodexTranscriptAppKitTheme(.officialDark)
        let first = try await projector.project(presentation: presentation, availableWidth: 860, theme: theme)
        let second = try await projector.project(presentation: presentation, availableWidth: 860, theme: theme)

        #expect(second.changedItemIDs.isEmpty)
        #expect(second.diagnostics.heightCacheHitCount == first.orderedItemIDs.count)
        #expect(second.diagnostics.heightCacheMissCount == 0)
        #expect(second.diagnostics.preparedTextCacheHitCount > 0)
        #expect(second.diagnostics.preparedTextCacheMissCount == 0)
    }

    private func allKindsTurn() -> CodexTurnV2 {
        let output = String(repeating: "x", count: 20_100)
        return CodexTurnV2(
            id: "turn",
            userMessage: .init(id: "user", text: "Question"),
            narrative: [
                .prose(.init(
                    id: "commentary",
                    text: "**Commentary**\n\n```swift\nlet x = 1\n```\n\n| Name | Value |\n| --- | ---: |\n| item | 1 |",
                    isStreaming: false
                )),
                .workGroup(.init(
                    id: "group",
                    header: "Ran a command, edited a file, called GitHub and searched",
                    rows: [
                        .command(.init(id: "command", command: "swift test", label: "Ran swift test", action: .run, status: .completed, exitCode: 0, durationMs: 50, output: output)),
                        .fileChange(.init(id: "file", files: ["File.swift"], status: .completed, durationMs: 10, diff: "+line")),
                        .mcpToolCall(.init(id: "mcp", appName: "GitHub", server: "github", tool: "get", status: .failed, durationMs: 20, errorFirstLine: "404", arguments: .dictionary(["id": .string("1")]), result: .dictionary(["error": .string("404")]))),
                        .webSearch(.init(id: "web", query: "AppKit diffable", status: .completed)),
                        .collabAgent(.init(id: "collab", action: .created, agentNames: ["Reviewer"], agentThreadIDs: ["child-thread"], instructions: "Review", status: .completed)),
                        .other(.init(id: "other", label: "Generated an image", status: .completed))
                    ],
                    isLive: false
                )),
                .productToolCall(.init(id: "product", tool: "lookup", namespace: "host", arguments: nil, status: .completed, contentItems: [], success: true)),
                .notice(.init(id: "notice", message: "Compacted context"))
            ],
            finalAnswer: .init(id: "final", text: "# Final\n\nAnswer with `code`.", isStreaming: false),
            status: .done(durationMs: 2_000)
        )
    }
}
