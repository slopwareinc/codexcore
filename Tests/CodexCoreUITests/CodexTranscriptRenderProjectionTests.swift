import AppKit
import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

@MainActor
struct CodexTranscriptRenderProjectionTests {
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
        #expect(rawIDs.contains { $0.contains(":commentary:commentary:block:") })
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
        #expect(rawIDs.contains { $0.contains(":final:final:block:") })

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
        let firstFinal = try #require(first.orderedItemIDs.first { $0.rawValue.contains(":final:final:block:") })
        let secondFinal = try #require(second.orderedItemIDs.first { $0.rawValue.contains(":final:final:block:") })

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
