import AppKit
import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

@MainActor
struct CodexTranscriptFileChangeRenderingTests {
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
                expandedWorkTurnIDs: ["turn"], expandedRowIDs: ["work", "files"],
                selectedDiffFileIndexByRowID: ["files": 1]
            ),
            availableWidth: 860,
            theme: CodexTranscriptAppKitTheme(.officialDark, colorScheme: .dark)
        )
        let row = try #require(snapshot.itemsByID.values.first { $0.workRow?.kind == .fileChange })
        #expect(row.workRow?.label == "Edited 2 files · +2 −1")
        let panel = try #require(snapshot.itemsByID.values.first { $0.diffPanel != nil })
        #expect(panel.diffPanel?.files.count == 2)
        #expect(panel.diffPanel?.selectedFileIndex == 1)
        #expect(panel.diffPanel?.selectedFile?.path == "B.swift")
        guard let copyPayload = panel.copyPayload,
              case .exactPatch = copyPayload
        else {
            Issue.record("Expected a lazy legacy exact-patch copy payload")
            return
        }
        #expect(panel.isScrollableOutput)
        #expect(
            panel.measuredHeight
                == CodexTranscriptColumnMetrics.diffPanelHeight
                    + CodexTranscriptColumnMetrics.interactiveBottomSpacing
        )
        #expect(panel.bottomSpacing == CodexTranscriptColumnMetrics.interactiveBottomSpacing)

        var copiedPatch: String?
        let cell = CodexTranscriptCollectionItem()
        _ = cell.view
        cell.view.frame = NSRect(x: 0, y: 0, width: 860, height: panel.measuredHeight)
        cell.configure(
            item: panel,
            appKitTheme: .init(.officialDark, colorScheme: .dark),
            swiftUITheme: .officialDark,
            contentHorizontalOffset: 0,
            productToolRenderer: nil,
            performAction: { _ in },
            copy: { copiedPatch = $0 },
            editUserMessage: { _ in },
            forkChat: nil,
            selectionChanged: { _, _ in }
        )
        #expect(cell.copyButtonIsVisibleForTesting)
        #expect(copiedPatch == nil)
        cell.copyItemForTesting()
        #expect(copiedPatch?.contains("B.swift") == true)
        #expect(copiedPatch?.contains("A.swift") == false)
        #expect(copiedPatch?.contains("-old") == false)
    }

    @Test func canonicalFileEntriesRenderPreparedPatchWithoutAggregateDiff() async throws {
        let row = CodexFileChangeRowV2(
            id: "files",
            changes: [
                .init(
                    id: "files:file:Sources/Canonical.swift:0",
                    path: "Sources/Canonical.swift",
                    kind: .modified,
                    diff: "@@ -1 +1 @@\n-let old = true\n+let new = true"
                ),
            ],
            status: .completed
        )
        let turn = CodexTurnV2(
            id: "turn",
            narrative: [.workGroup(.init(id: "work", rows: [.fileChange(row)]))],
            status: .done(durationMs: 1)
        )

        let snapshot = try await CodexTranscriptRenderProjector().project(
            presentation: .init(
                threadID: "thread",
                transcript: .init(turns: [turn]),
                expandedWorkTurnIDs: ["turn"],
                expandedRowIDs: ["work", "files"]
            ),
            availableWidth: 860,
            theme: CodexTranscriptAppKitTheme(.officialDark, colorScheme: .dark)
        )

        #expect(row.diff == nil)
        let renderedRow = try #require(
            snapshot.itemsByID.values.first { $0.workRow?.kind == .fileChange }
        )
        #expect(renderedRow.workRow?.label == "Edited 1 file · +1 −1")
        let panel = try #require(snapshot.itemsByID.values.first { $0.diffPanel != nil })
        #expect(panel.diffPanel?.selectedFile?.path == "Sources/Canonical.swift")
        guard let copyPayload = panel.copyPayload,
              case .text(let canonicalCopy) = copyPayload
        else {
            Issue.record("Expected canonical exact change to stay a String payload")
            return
        }
        #expect(canonicalCopy.contains("let new = true"))
    }

    @Test func canonicalCopySelectionUsesPreparedSourceIndex() throws {
        let row = CodexFileChangeRowV2(
            id: "files",
            changes: [
                .init(
                    id: "duplicate-id",
                    path: "Sources/First.swift",
                    kind: .modified,
                    diff: "@@ -1 +1 @@\n-first\n+FIRST"
                ),
                .init(
                    id: "duplicate-id",
                    path: "Sources/Second.swift",
                    kind: .modified,
                    diff: "@@ -1 +1 @@\n-second\n+SECOND"
                ),
            ],
            status: .completed
        )

        let projection = try #require(CodexTranscriptRenderProjector.fileChangeRenderProjection(
            rowID: row.id,
            fileChange: row,
            requestedIndex: 1
        ))

        #expect(projection.panel.files.map(\.path) == [
            "Sources/First.swift",
            "Sources/Second.swift",
        ])
        #expect(projection.panel.selectedFileIndex == 1)
        #expect(projection.selectedChange.sourceIndex == 1)
        guard case .text(let copy)? = projection.copyPayload else {
            Issue.record("Expected indexed canonical copy text")
            return
        }
        #expect(copy.contains("+SECOND"))
        #expect(!copy.contains("+FIRST"))
    }

    @Test func preparedEntryCapIsVisibleInRowAndPanelSummaries() throws {
        let limit = CodexPreparedFileChangeSetV2.maximumPreparedEntryCount
        let changes = (0...limit).map { index in
            CodexFileChangeV2(
                id: "file:\(index)",
                path: "Generated/File\(index).swift",
                kind: .added,
                diff: ""
            )
        }
        let row = CodexFileChangeRowV2(
            id: "files",
            changes: changes,
            status: .completed
        )
        let projection = try #require(
            CodexTranscriptRenderProjector.fileChangeRenderProjection(
                rowID: row.id,
                fileChange: row,
                requestedIndex: 0
            )
        )

        #expect(row.omittedPreparedFileCount == 1)
        #expect(projection.panel.omittedFileCount == 1)
        #expect(
            CodexTranscriptRenderProjector.fileChangeLabel(row)
                .contains("1 details omitted")
        )
    }

    @Test func siblingTabChangeRevisesPanelWithoutRepreparingSelectedText() async throws {
        func presentation(siblingPath: String) -> CodexThreadUIPresentation {
            let row = CodexFileChangeRowV2(
                id: "files",
                changes: [
                    .init(
                        id: "selected",
                        path: "Sources/Selected.swift",
                        kind: .modified,
                        diff: "@@ -1 +1 @@\n-old\n+new"
                    ),
                    .init(
                        id: "sibling",
                        path: siblingPath,
                        kind: .added,
                        diff: "sibling"
                    ),
                ],
                status: .completed
            )
            return .init(
                threadID: "thread",
                transcript: .init(turns: [.init(
                    id: "turn",
                    narrative: [.workGroup(.init(
                        id: "work",
                        rows: [.fileChange(row)]
                    ))],
                    status: .done(durationMs: 1)
                )]),
                expandedWorkTurnIDs: ["turn"],
                expandedRowIDs: ["work", "files"]
            )
        }
        let projector = CodexTranscriptRenderProjector()
        let theme = CodexTranscriptAppKitTheme(.officialDark, colorScheme: .dark)
        let first = try await projector.project(
            presentation: presentation(siblingPath: "Sources/Before.swift"),
            availableWidth: 860,
            theme: theme
        )
        let second = try await projector.project(
            presentation: presentation(siblingPath: "Sources/After.swift"),
            availableWidth: 860,
            theme: theme
        )
        let firstPanel = try #require(
            first.itemsByID.values.first { $0.diffPanel != nil }
        )
        let secondPanel = try #require(second.itemsByID[firstPanel.id])
        let firstText = try #require(firstPanel.preparedText)
        let secondText = try #require(secondPanel.preparedText)

        #expect(second.changedItemIDs.contains(firstPanel.id))
        #expect(secondPanel.diffPanel?.files.map(\.path) == [
            "Sources/Selected.swift",
            "Sources/After.swift",
        ])
        #expect(firstText === secondText)
        #expect(second.diagnostics.preparedTextCacheHitCount == 1)
    }

    @Test func preparedDiffMaterializesDisplayLinesDirectly() throws {
        let theme = CodexTranscriptAppKitTheme(.officialDark, colorScheme: .dark)
        let prepared = CodexPreparedFileChangeV2(
            sourceIndex: 0,
            summary: .init(
                path: "Sources/Display.swift",
                previousPath: nil,
                kind: .modified,
                added: 1,
                removed: 1,
                isBinary: false
            ),
            displayLines: [
                .init(kind: .context, text: "Sources/Display.swift"),
                .init(kind: .context, text: "@@ -1 +1 @@"),
                .init(kind: .remove, text: "-old"),
                .init(kind: .add, text: "+new"),
            ],
            exactPatch: nil,
            isMalformed: false,
            truncation: nil,
            fingerprint: 1,
            retainedUTF8ByteCount: 49,
            retainedLineCount: 4
        )

        let attributed = CodexTranscriptRenderProjector.prepareDiffFile(
            prepared,
            theme: theme
        ).attributedString

        #expect(attributed.string == "Sources/Display.swift\n@@ -1 +1 @@\n-old\n+new")
        let string = attributed.string as NSString
        let removalColor = attributed.attribute(
            .foregroundColor,
            at: string.range(of: "-old").location,
            effectiveRange: nil
        ) as? NSColor
        let additionColor = attributed.attribute(
            .foregroundColor,
            at: string.range(of: "+new").location,
            effectiveRange: nil
        ) as? NSColor
        #expect(removalColor == theme.danger)
        #expect(additionColor == theme.success)
    }

    @Test func preparedTextCacheRetainsOnlyTheMostRecentDiffPanel() async throws {
        let projector = CodexTranscriptRenderProjector()
        let theme = CodexTranscriptAppKitTheme(.officialDark, colorScheme: .dark)
        func presentation(_ index: Int) -> CodexThreadUIPresentation {
            let patch = "@@ -1 +1 @@\n-old \(index)\n+new \(index)"
            let row = CodexFileChangeRowV2(
                id: "files-\(index)",
                changes: [.init(
                    id: "change-\(index)",
                    path: "Sources/File\(index).swift",
                    kind: .modified,
                    diff: patch
                )],
                status: .completed
            )
            return .init(
                threadID: "thread-\(index)",
                transcript: .init(turns: [.init(
                    id: "turn-\(index)",
                    narrative: [.workGroup(.init(
                        id: "work-\(index)",
                        rows: [.fileChange(row)]
                    ))],
                    status: .done(durationMs: 1)
                )]),
                expandedWorkTurnIDs: ["turn-\(index)"],
                expandedRowIDs: ["work-\(index)", "files-\(index)"]
            )
        }

        let first = try await projector.project(
            presentation: presentation(0),
            availableWidth: 860,
            theme: theme
        )
        let repeated = try await projector.project(
            presentation: presentation(0),
            availableWidth: 860,
            theme: theme
        )
        let replacement = try await projector.project(
            presentation: presentation(1),
            availableWidth: 860,
            theme: theme
        )
        let evicted = try await projector.project(
            presentation: presentation(0),
            availableWidth: 860,
            theme: theme
        )

        #expect(first.diagnostics.preparedTextCacheMissCount == 1)
        #expect(repeated.diagnostics.preparedTextCacheHitCount == 1)
        #expect(repeated.diagnostics.preparedTextCacheMissCount == 0)
        #expect(replacement.diagnostics.preparedTextCacheMissCount == 1)
        #expect(evicted.diagnostics.preparedTextCacheHitCount == 0)
        #expect(evicted.diagnostics.preparedTextCacheMissCount == 1)
    }

    @Test func collapsedLargeCanonicalPatchStaysBoundedAndExpandedCopyIsExact() async throws {
        let body = (0..<20_000).map { "+let value\($0) = true" }.joined(separator: "\n")
        let exactDiff = "@@ -0,0 +1,20000 @@\n\(body)"
        let row = CodexFileChangeRowV2(
            id: "files",
            changes: [.init(
                id: "change",
                path: "Sources/Large.swift",
                kind: .modified,
                diff: exactDiff
            )],
            status: .completed
        )
        let turn = CodexTurnV2(
            id: "turn",
            narrative: [.workGroup(.init(id: "work", rows: [.fileChange(row)]))],
            status: .done(durationMs: 1)
        )
        let projector = CodexTranscriptRenderProjector()
        let collapsed = try await projector.project(
            presentation: .init(
                threadID: "thread",
                transcript: .init(turns: [turn]),
                expandedWorkTurnIDs: ["turn"],
                expandedRowIDs: ["work"]
            ),
            availableWidth: 860,
            theme: CodexTranscriptAppKitTheme(.officialDark, colorScheme: .dark)
        )

        #expect(collapsed.itemsByID.values.allSatisfy { $0.diffPanel == nil })
        #expect(
            collapsed.itemsByID.values.first {
                $0.workRow?.kind == .fileChange
            }?.copyPayload == nil
        )
        #expect(
            row.retainedPreparedUTF8ByteCount
                <= CodexPreparedFileChangeSetV2.maximumRetainedUTF8Bytes
        )
        let displayUTF8ByteCount = row.preparedChanges.first?.displayLines.reduce(into: 0) {
            $0 += $1.text.utf8.count + 1
        } ?? .max
        #expect(displayUTF8ByteCount < exactDiff.utf8.count)

        let expanded = try await projector.project(
            presentation: .init(
                threadID: "thread",
                transcript: .init(turns: [turn]),
                expandedWorkTurnIDs: ["turn"],
                expandedRowIDs: ["work", "files"]
            ),
            availableWidth: 860,
            theme: CodexTranscriptAppKitTheme(.officialDark, colorScheme: .dark)
        )
        let panel = try #require(expanded.itemsByID.values.first { $0.diffPanel != nil })

        guard let copyPayload = panel.copyPayload,
              case .text(let canonicalCopy) = copyPayload
        else {
            Issue.record("Expected canonical exact change to stay a String payload")
            return
        }
        #expect(canonicalCopy == exactDiff)
        #expect(panel.preparedText?.attributedString.length ?? .max < exactDiff.utf8.count)
    }
}
