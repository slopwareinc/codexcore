import AppKit
import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

@MainActor
struct CodexTranscriptRenderProjectionTests {
    @Test func fableTranscriptGeometryUsesReferenceSpacing() async throws {
        #expect(CodexTranscriptColumnMetrics.horizontalMargin == 24)
        #expect(CodexTranscriptColumnMetrics.turnGap == 16)
        #expect(CodexTranscriptColumnMetrics.itemGap == 4)
        #expect(CodexTranscriptColumnMetrics.userBubbleHorizontalPadding == 12)
        #expect(CodexTranscriptColumnMetrics.userBubbleVerticalPadding == 8)
        #expect(CodexTranscriptColumnMetrics.workHeaderHeight == 22)
        #expect(CodexTranscriptColumnMetrics.footerHeight == 22)
        #expect(CodexTranscriptColumnMetrics.actionCardHeight == 32)
        #expect(CodexTranscriptColumnMetrics.actionCardRadius == 10)
        #expect(CodexTranscriptColumnMetrics.interactiveBottomSpacing == 8)
        #expect(CodexTranscriptColumnMetrics.topContentInset == 0)

        let theme = CodexTranscriptAppKitTheme(.officialDark)
        #expect(theme.bubbleRadius == 16)
        #expect(theme.transcriptOuterMaxWidth == 768)
        #expect(CodexTranscriptColumnMetrics(viewportWidth: 1_200).outerWidth(theme) == 768)
        #expect(CodexTranscriptColumnMetrics(viewportWidth: 300).outerWidth(theme) == 252)
        let snapshot = try await CodexTranscriptRenderProjector().project(
            presentation: .init(threadID: "thread", transcript: .init(turns: [.init(
                id: "turn",
                userMessage: .init(id: "user", text: "hello", isOptimistic: false),
                status: .done(durationMs: nil)
            )])),
            availableWidth: 860,
            theme: theme
        )
        let user = try #require(snapshot.itemsByID.values.first { $0.textRole == .user })
        let textHeight = try #require(user.preparedText).attributedString.boundingRect(
            with: NSSize(
                width: user.maxContentWidth - CodexTranscriptColumnMetrics.userBubbleHorizontalPadding * 2,
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        #expect(user.measuredHeight == ceil(textHeight) + 16)
    }

    @Test func missingCompletedDurationNeverRendersAsZeroSeconds() {
        #expect(CodexWorkBlockViewV2.completedLabel(nil) == "Worked")
        #expect(CodexWorkBlockViewV2.completedLabel(8_000) == "Worked for 8s")
    }

    @Test func attachmentUserBubbleKeepsFilesSeparateAndEditsWithRawContext() async throws {
        let file = CodexReferencedFile(path: "/tmp/reference.swift", kind: .file)
        let rawText = CodexFileReferencePromptCodec.encode(files: [file], request: "Review this")
        let message = CodexUserMessageV2(
            id: "user",
            text: "Review this",
            rawText: rawText,
            referencedFiles: [file]
        )
        let snapshot = try await CodexTranscriptRenderProjector().project(
            presentation: .init(threadID: "thread", transcript: .init(turns: [.init(
                id: "turn",
                userMessage: message,
                status: .done(durationMs: nil)
            )])),
            availableWidth: 860,
            theme: .init(.officialDark)
        )
        let user = try #require(snapshot.itemsByID.values.first { $0.textRole == .user })
        let attachments = try #require(snapshot.itemsByID.values.first { !$0.agentChips.isEmpty })
        #expect(user.preparedText?.attributedString.string == "Review this")
        #expect(attachments.agentChips.map(\.label) == ["reference.swift"])
        #expect(attachments.agentChips.map(\.attachmentKind) == [.file])
        #expect(attachments.isTrailingAligned)
        #expect(user.copyText == "Review this")
        #expect(user.editUserText == rawText)
    }

    @Test func fileOnlyUserBubbleCopiesVisibleAttachmentInsteadOfHiddenPromptEnvelope() async throws {
        let file = CodexReferencedFile(path: "/tmp/reference.png", kind: .image)
        let rawText = CodexFileReferencePromptCodec.encode(files: [file], request: "")
        let snapshot = try await CodexTranscriptRenderProjector().project(
            presentation: .init(threadID: "thread", transcript: .init(turns: [.init(
                id: "turn",
                userMessage: .init(
                    id: "user",
                    text: "",
                    rawText: rawText,
                    referencedFiles: [file]
                ),
                status: .done(durationMs: nil)
            )])),
            availableWidth: 860,
            theme: .init(.officialDark)
        )

        let user = try #require(snapshot.itemsByID.values.first { $0.textRole == .user })
        let attachments = try #require(snapshot.itemsByID.values.first { !$0.agentChips.isEmpty })
        #expect(user.copyText == "📎 reference.png")
        #expect(user.editUserText == rawText)
        #expect(attachments.agentChips.map(\.attachmentKind) == [.image])
        #expect(attachments.measuredHeight == 64 + CodexTranscriptColumnMetrics.interactiveBottomSpacing)
    }

    @Test func steeredMessagesInterleaveWithWorkInCanonicalConversationOrder() async throws {
        let firstSteer = CodexUserMessageV2(id: "steer-one", text: "First direction")
        let secondSteer = CodexUserMessageV2(id: "steer-two", text: "Second direction")
        let beforeSteer = CodexNarrativeEntry.prose(.init(
            id: "before-steer", text: "Before first steer", isStreaming: true
        ))
        let betweenSteers = CodexNarrativeEntry.prose(.init(
            id: "between-steers", text: "After first steer", isStreaming: true
        ))
        let afterSteers = CodexNarrativeEntry.prose(.init(
            id: "after-steers", text: "After second steer", isStreaming: true
        ))
        let turn = CodexTurnV2(
            id: "turn",
            userMessage: .init(id: "original", text: "Original prompt"),
            steeredMessages: [firstSteer, secondSteer],
            conversationSegments: [
                .init(id: "initial", narrative: [beforeSteer]),
                .init(id: "first", steeredMessage: firstSteer, narrative: [betweenSteers]),
                .init(id: "second", steeredMessage: secondSteer, narrative: [afterSteers])
            ],
            narrative: [beforeSteer, betweenSteers, afterSteers],
            status: .working(since: nil)
        )
        let snapshot = try await CodexTranscriptRenderProjector().project(
            presentation: .init(threadID: "thread", transcript: .init(turns: [turn])),
            availableWidth: 860,
            theme: .init(.officialDark)
        )
        let orderedItems = snapshot.orderedItemIDs.compactMap { snapshot.itemsByID[$0] }
        let userItems = orderedItems.filter { $0.textRole == .user }

        #expect(userItems.map { $0.preparedText?.attributedString.string } == [
            "Original prompt", "First direction", "Second direction"
        ])
        #expect(Set(userItems.map(\.id)).count == 3)
        let workIndex = try #require(orderedItems.firstIndex { $0.workHeader != nil })
        let beforeIndex = try #require(orderedItems.firstIndex {
            $0.preparedText?.attributedString.string == "Before first steer"
        })
        let firstSteerIndex = try #require(orderedItems.firstIndex { $0.id.rawValue.contains(":user:steer-one") })
        let betweenIndex = try #require(orderedItems.firstIndex {
            $0.preparedText?.attributedString.string == "After first steer"
        })
        let secondSteerIndex = try #require(orderedItems.firstIndex { $0.id.rawValue.contains(":user:steer-two") })
        let afterIndex = try #require(orderedItems.firstIndex {
            $0.preparedText?.attributedString.string == "After second steer"
        })
        #expect(workIndex < beforeIndex)
        #expect(beforeIndex < firstSteerIndex)
        #expect(firstSteerIndex < betweenIndex)
        #expect(betweenIndex < secondSteerIndex)
        #expect(secondSteerIndex < afterIndex)
        let copyTurnText = try #require(userItems.first).copyTurnText
        let copyBefore = try #require(copyTurnText.range(of: "Before first steer"))
        let copyFirstSteer = try #require(copyTurnText.range(of: "You\nFirst direction"))
        let copyBetween = try #require(copyTurnText.range(of: "After first steer"))
        let copySecondSteer = try #require(copyTurnText.range(of: "You\nSecond direction"))
        let copyAfter = try #require(copyTurnText.range(of: "After second steer"))
        #expect(copyBefore.lowerBound < copyFirstSteer.lowerBound)
        #expect(copyFirstSteer.lowerBound < copyBetween.lowerBound)
        #expect(copyBetween.lowerBound < copySecondSteer.lowerBound)
        #expect(copySecondSteer.lowerBound < copyAfter.lowerBound)
    }

    @Test func expandedWorkProseUsesTheFinalAnswerForeground() async throws {
        let theme = CodexTranscriptAppKitTheme(.officialDark)
        let turn = CodexTurnV2(
            id: "turn",
            narrative: [.prose(.init(id: "work", text: "Inspecting the implementation", isStreaming: false))],
            status: .done(durationMs: 1)
        )
        let snapshot = try await CodexTranscriptRenderProjector().project(
            presentation: .init(
                threadID: "thread", transcript: .init(turns: [turn]),
                expandedWorkTurnIDs: [turn.id]
            ),
            availableWidth: 860,
            theme: theme
        )
        let prose = try #require(snapshot.itemsByID.values.first { $0.textRole == .commentary })
        let color = prose.preparedText?.attributedString.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor
        #expect(color == theme.textPrimary)
    }

    @Test func inlineDirectivesInterleaveWithAssistantProse() async throws {
        let projector = CodexTranscriptRenderProjector()
        let text = """
        Before the handoff.
        ::created-thread{threadId="019f670d-ce61-7cb2-a1eb-3b9bc5256026"}
        After the handoff.
        """
        let snapshot = try await projector.project(
            presentation: .init(threadID: "thread", transcript: .init(turns: [.init(
                id: "turn",
                finalAnswer: .init(id: "final", text: text, isStreaming: false),
                status: .done(durationMs: 1)
            )])),
            availableWidth: 860,
            theme: CodexTranscriptAppKitTheme(.officialDark)
        )
        let content = snapshot.orderedItemIDs.compactMap { snapshot.itemsByID[$0] }.filter { $0.footer == nil }
        #expect(content.count == 3)
        #expect(content[0].preparedText?.attributedString.string.contains("Before the handoff") == true)
        guard case .createdThread(let threadID, _) = content[1].directive?.kind else {
            Issue.record("Expected a created-thread render item")
            return
        }
        #expect(threadID == "019f670d-ce61-7cb2-a1eb-3b9bc5256026")
        #expect(content[1].action == .openSubagent(threadID: threadID!))
        #expect(content[2].preparedText?.attributedString.string.contains("After the handoff") == true)
    }

    @Test func expandedFileChangeProjectsOneTabbedColoredPatchPanel() async throws {
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
                expandedWorkTurnIDs: ["turn"], expandedRowIDs: ["files"],
                selectedDiffFileIndexByRowID: ["files": 1]
            ),
            availableWidth: 860,
            theme: CodexTranscriptAppKitTheme(.officialDark)
        )
        let row = try #require(snapshot.itemsByID.values.first { $0.workRow?.kind == .fileChange })
        #expect(row.workRow?.label == "Edited 2 files · +2 −1")
        let panel = try #require(snapshot.itemsByID.values.first { $0.diffPanel != nil })
        #expect(panel.diffPanel?.files.count == 2)
        #expect(panel.diffPanel?.selectedFileIndex == 1)
        #expect(panel.diffPanel?.selectedFile?.path == "B.swift")
        #expect(panel.copyText?.contains("B.swift") == true)
        #expect(panel.isScrollableOutput)
        #expect(panel.measuredHeight == CodexTranscriptColumnMetrics.diffPanelHeight + 8)
        #expect(panel.bottomSpacing == 8)
    }


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
        #expect(rawIDs.contains { $0.contains(":group:group:agents") })
        #expect(rawIDs.contains { $0.contains(":row:other") })
        #expect(rawIDs.contains { $0.contains(":product:product") })
        #expect(rawIDs.contains { $0.contains(":notice:notice") })
        #expect(rawIDs.contains { $0.contains(":final:final:selection-surface:") })

        let commandDetail = try #require(snapshot.itemsByID.first { $0.key.rawValue.contains(":row:command:detail") }?.value)
        #expect(commandDetail.textRole == .expandedOutput)
        #expect(commandDetail.preparedText?.attributedString.string.contains("Output truncated for display") == true)
        #expect(commandDetail.copyText?.count == 20_100)
        let collab = try #require(snapshot.itemsByID.first { $0.key.rawValue.contains(":group:group:agents") }?.value)
        #expect(collab.agentChips.first?.threadID == "child-thread")
        #expect(collab.agentChips.first?.status == .done)
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
