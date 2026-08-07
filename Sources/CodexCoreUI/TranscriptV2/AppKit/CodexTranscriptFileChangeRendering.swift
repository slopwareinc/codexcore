import AppKit
import Foundation
import SwiftUI

public struct CodexTranscriptReviewRequest: Sendable, Equatable {
    public var session: CodexGitReviewSession
    public var selectedFilePath: String?

    public init(session: CodexGitReviewSession, selectedFilePath: String? = nil) {
        self.session = session
        self.selectedFilePath = selectedFilePath
    }
}

/// Lightweight tab state for the AppKit patch panel. The panel deliberately
/// carries prepared summaries instead of recreating parser-owned diff files.
struct CodexTranscriptDiffPanelRender: Sendable, Equatable {
    var rowID: String
    var files: [CodexPreparedFileChangeSummaryV2]
    var selectedFileIndex: Int
    var omittedFileCount: Int

    var selectedFile: CodexPreparedFileChangeSummaryV2? {
        guard files.indices.contains(selectedFileIndex) else { return files.first }
        return files[selectedFileIndex]
    }
}

struct CodexTranscriptFileChangeRenderProjection {
    var panel: CodexTranscriptDiffPanelRender
    var selectedChange: CodexPreparedFileChangeV2
    var copyPayload: CodexTranscriptCopyPayload?
    var accessibilityLabel: String
    var panelFingerprint: UInt64
}

struct CodexTranscriptTurnDiffRender: Sendable, Equatable {
    var rowID: String
    var files: [CodexPreparedFileChangeSummaryV2]
    var reviewSession: CodexGitReviewSession
    var omittedFileCount: Int
    var isExpanded: Bool

    var visibleFiles: [CodexPreparedFileChangeSummaryV2] {
        isExpanded ? files : Array(files.prefix(3))
    }

    var hiddenFileCount: Int {
        max(0, files.count - visibleFiles.count) + omittedFileCount
    }

    var totalAdded: Int { files.reduce(0) { $0 + $1.added } }
    var totalRemoved: Int { files.reduce(0) { $0 + $1.removed } }

    var title: String {
        if files.count + omittedFileCount == 1, let file = files.first {
            return "Edited \((file.path as NSString).lastPathComponent)"
        }
        return "Edited \(files.count + omittedFileCount) files"
    }

    func reviewRequest(selectedFilePath: String? = nil) -> CodexTranscriptReviewRequest {
        CodexTranscriptReviewRequest(
            session: reviewSession,
            selectedFilePath: selectedFilePath
        )
    }
}

struct CodexTranscriptTurnDiffCard: View {
    /// Shared with the render projection so the measured row height and the
    /// drawn row height cannot drift apart.
    nonisolated static let horizontalInset: CGFloat = 16
    nonisolated static let iconSize: CGFloat = 32
    nonisolated static let iconGap: CGFloat = 12
    nonisolated static let headerHeight: CGFloat = 60
    nonisolated static let rowHeight: CGFloat = 32
    nonisolated static let listVerticalInset: CGFloat = 6
    /// Clearance from the work-group chip that sits directly above the card.
    nonisolated static let topSpacing: CGFloat = 10
    /// File rows hang under the header title, not under its icon.
    nonisolated static var rowLeadingInset: CGFloat { horizontalInset + iconSize + iconGap }

    @Environment(\.codexAgentTheme) private var theme
    @State private var isHeaderHovered = false
    let render: CodexTranscriptTurnDiffRender
    let onReview: ((CodexTranscriptReviewRequest) -> Void)?
    let onToggleExpanded: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Self.iconGap) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.colors.textSecondary)
                    .frame(width: Self.iconSize, height: Self.iconSize)
                    .background(theme.colors.surfaceSunken, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(render.title)
                        .font(theme.fonts.body.weight(.semibold))
                        .foregroundStyle(theme.colors.textPrimary)
                    Group {
                        if isHeaderHovered, onReview != nil {
                            Text("Review changes")
                                .foregroundStyle(theme.colors.textSecondary)
                        } else {
                            HStack(spacing: 4) {
                                Text("+\(render.totalAdded)").foregroundStyle(theme.colors.success)
                                Text("−\(render.totalRemoved)").foregroundStyle(theme.colors.danger)
                            }
                            .monospacedDigit()
                        }
                    }
                    .font(theme.fonts.caption)
                }
                Spacer(minLength: 8)
                if let onReview {
                    Button("Review") {
                        onReview(render.reviewRequest())
                    }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityHint("Opens these changes in the Review workbench")
                }
            }
            .padding(.horizontal, Self.horizontalInset)
            .frame(height: Self.headerHeight)
            .onHover { isHeaderHovered = $0 }

            Divider().overlay(theme.colors.border)

            VStack(spacing: 0) {
                ForEach(Array(render.visibleFiles.enumerated()), id: \.element.path) { _, file in
                    if let onReview {
                        Button {
                            onReview(render.reviewRequest(selectedFilePath: file.path))
                        } label: {
                            fileRow(file)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(file.path), \(file.added) additions, \(file.removed) removals")
                    } else {
                        fileRow(file)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(file.path), \(file.added) additions, \(file.removed) removals")
                    }
                }

                if render.hiddenFileCount > 0 || render.isExpanded {
                    Button(action: onToggleExpanded) {
                        HStack(spacing: 8) {
                            Text(render.isExpanded
                                 ? "Collapse files"
                                 : "Show \(render.hiddenFileCount) more file\(render.hiddenFileCount == 1 ? "" : "s")")
                            Image(systemName: "chevron.down")
                                .rotationEffect(.degrees(render.isExpanded ? 180 : 0))
                                .font(theme.fonts.micro)
                            Spacer()
                        }
                        .foregroundStyle(theme.colors.textSecondary)
                        .padding(.leading, Self.rowLeadingInset)
                        .padding(.trailing, Self.horizontalInset)
                        .frame(height: Self.rowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(render.isExpanded ? "Expanded" : "Collapsed")
                }
            }
            .padding(.vertical, Self.listVerticalInset)
        }
        .font(theme.fonts.caption)
        .background(theme.colors.surface.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
    }

    /// The directory gives up space first: the filename is what identifies the
    /// row, so it stays whole while the path ahead of it truncates.
    private func pathLabel(_ path: String) -> some View {
        let filename = (path as NSString).lastPathComponent
        let directory = String(path.dropLast(filename.count))
        return HStack(spacing: 0) {
            if !directory.isEmpty {
                Text(directory)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Text(filename)
                .foregroundStyle(theme.colors.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)
        }
    }

    private func fileRow(_ file: CodexPreparedFileChangeSummaryV2) -> some View {
        HStack(spacing: 10) {
            pathLabel(file.path)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Text("+\(file.added)").foregroundStyle(theme.colors.success)
                Text("−\(file.removed)").foregroundStyle(theme.colors.danger)
            }
            .font(theme.fonts.caption)
            .monospacedDigit()
        }
        .padding(.leading, Self.rowLeadingInset)
        .padding(.trailing, Self.horizontalInset)
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
    }
}

@_spi(VisualTesting)
public struct CodexTranscriptTurnDiffGalleryFixture: View {
    public init() {}

    public var body: some View {
        CodexTranscriptTurnDiffCard(
            render: CodexTranscriptTurnDiffRender(
                rowID: "gallery-turn-diff",
                files: [
                    summary("Sources/CodexCoreApp/CodexCoreAppModel.swift", added: 4, removed: 1),
                    summary("Sources/CodexCoreUI/CodexAgentPanelModels.swift", added: 5, removed: 0),
                    summary("Sources/CodexCoreUI/CodexChatWorkspace.swift", added: 12, removed: 3),
                    summary("Tests/CodexCoreUITests/CodexTranscriptRenderProjectionTests.swift", added: 76, removed: 2),
                    summary("docs/review-workbench-evidence/README.md", added: 18, removed: 0),
                ],
                reviewSession: CodexGitReviewSession(snapshot: CodexGitReviewSnapshot(
                    branchName: "codex/review-workbench-170"
                )),
                omittedFileCount: 0,
                isExpanded: false
            ),
            onReview: { _ in },
            onToggleExpanded: {}
        )
    }

    private func summary(_ path: String, added: Int, removed: Int) -> CodexPreparedFileChangeSummaryV2 {
        CodexPreparedFileChangeSummaryV2(
            path: path,
            previousPath: nil,
            kind: .modified,
            added: added,
            removed: removed,
            isBinary: false
        )
    }
}

extension CodexTranscriptRenderProjector {
    static func turnDiffRender(
        turn: CodexTurnV2,
        isExpanded: Bool
    ) -> CodexTranscriptTurnDiffRender? {
        guard case .done = turn.status else { return nil }
        var orderedPaths: [String] = []
        var latestByPath: [String: CodexGitReviewFileChange] = [:]
        var omitted = 0
        for entry in turn.narrative {
            guard case .workGroup(let group) = entry else { continue }
            for row in group.rows {
                guard case .fileChange(let change) = row,
                      change.status == .completed else { continue }
                omitted += change.omittedPreparedFileCount
                for prepared in change.preparedChanges {
                    let summary = prepared.summary
                    if latestByPath[summary.path] == nil { orderedPaths.append(summary.path) }
                    latestByPath[summary.path] = reviewFile(
                        prepared,
                        exactDiff: change.exactChange(at: prepared.sourceIndex)?.diff,
                        turnID: turn.id
                    )
                }
            }
        }
        let reviewFiles = orderedPaths.compactMap { latestByPath[$0] }
        guard !reviewFiles.isEmpty else { return nil }
        let reviewSession = CodexGitReviewSession(snapshot: CodexGitReviewSnapshot(
            revision: CodexGitReviewRevision(sourceID: "transcript/\(turn.id)", value: 0),
            branchName: "HEAD",
            files: reviewFiles,
            ignoredChangeCount: omitted
        ))
        return CodexTranscriptTurnDiffRender(
            rowID: "turn-diff:\(turn.id)",
            files: reviewFiles.map {
                CodexPreparedFileChangeSummaryV2(
                    path: $0.path,
                    previousPath: $0.previousPath,
                    kind: fileKind($0.status),
                    added: $0.addedLines,
                    removed: $0.removedLines,
                    isBinary: $0.isBinary
                )
            },
            reviewSession: reviewSession,
            omittedFileCount: omitted,
            isExpanded: isExpanded
        )
    }

    private static func reviewFile(
        _ prepared: CodexPreparedFileChangeV2,
        exactDiff: String?,
        turnID: String
    ) -> CodexGitReviewFileChange {
        let displayText = unifiedPatchText(prepared)
        let patchText: CodexGitReviewPatchText
        if let exactDiff {
            patchText = .bounded(fullText: unifiedPatch(exactDiff, prepared: prepared))
        } else if let exactPatch = prepared.exactPatch {
            patchText = CodexGitReviewPatchText(
                deferredFullText: CodexGitReviewDeferredPatch(
                    identity: "transcript:\(turnID):\(prepared.fingerprint)",
                    hasText: true,
                    materialize: { exactPatch.materialized() }
                ),
                displayText: displayText,
                isTruncated: prepared.isTruncated
            )
        } else {
            patchText = .bounded(fullText: displayText)
        }
        return CodexGitReviewFileChange(
            id: prepared.path,
            path: prepared.path,
            previousPath: prepared.previousPath,
            status: reviewStatus(prepared.kind),
            stagingState: .unstaged,
            addedLines: prepared.added,
            removedLines: prepared.removed,
            patchText: patchText,
            isBinary: prepared.isBinary
        )
    }

    /// Added and deleted files arrive as bare file content, not as a patch.
    /// Review renders unified diffs, so wrap that content in the headers and
    /// markers it expects instead of letting it read as unchanged context.
    private static func unifiedPatch(
        _ text: String,
        prepared: CodexPreparedFileChangeV2
    ) -> String {
        let isAddition = prepared.kind == .added
        guard isAddition || prepared.kind == .deleted,
              !looksLikeUnifiedDiff(text) else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let path = prepared.path
        let marker = isAddition ? "+" : "-"
        let range = isAddition
            ? "@@ -0,0 +1,\(lines.count) @@"
            : "@@ -1,\(lines.count) +0,0 @@"
        var patch = [
            "diff --git a/\(path) b/\(path)",
            isAddition ? "new file mode 100644" : "deleted file mode 100644",
            isAddition ? "--- /dev/null" : "--- a/\(path)",
            isAddition ? "+++ b/\(path)" : "+++ /dev/null",
            range,
        ]
        patch.append(contentsOf: lines.map { marker + $0 })
        return patch.joined(separator: "\n")
    }

    private static func looksLikeUnifiedDiff(_ text: String) -> Bool {
        text.hasPrefix("diff --git ")
            || text.hasPrefix("@@ ")
            || text.contains("\n@@ ")
    }

    /// The bounded display lines carry their own kinds; re-emit them as a
    /// unified patch so the Review gutter can tell the two sides apart.
    private static func unifiedPatchText(_ prepared: CodexPreparedFileChangeV2) -> String {
        var lines = prepared.displayLines
        let summary = "\(prepared.path) · +\(prepared.added) −\(prepared.removed)"
        if lines.first?.kind == .context, lines.first?.text == summary {
            lines.removeFirst()
        }
        var insideHunk = false
        return lines.map { line -> String in
            switch line.kind {
            case .add:
                return "+" + line.text
            case .remove:
                return "-" + line.text
            case .context:
                if line.text.hasPrefix("@@") {
                    insideHunk = true
                    return line.text
                }
                return insideHunk ? " " + line.text : line.text
            }
        }
        .joined(separator: "\n")
    }

    private static func reviewStatus(_ kind: CodexFileChangeKindV2) -> CodexGitReviewFileStatus {
        switch kind {
        case .added: .added
        case .deleted: .deleted
        case .renamed: .renamed
        case .modified, .unknown: .modified
        }
    }

    private static func fileKind(_ status: CodexGitReviewFileStatus) -> CodexFileChangeKindV2 {
        switch status {
        case .added, .untracked: .added
        case .deleted: .deleted
        case .renamed: .renamed
        case .modified: .modified
        }
    }

    static func fileChangeRenderProjection(
        rowID: String,
        fileChange: CodexFileChangeRowV2,
        requestedIndex: Int
    ) -> CodexTranscriptFileChangeRenderProjection? {
        let preparedChanges = fileChange.preparedChanges
        guard !preparedChanges.isEmpty else { return nil }

        let selectedIndex = min(max(0, requestedIndex), preparedChanges.count - 1)
        let selectedChange = preparedChanges[selectedIndex]
        let summaries = preparedChanges.map(\.summary)
        let copyPayload: CodexTranscriptCopyPayload? = {
            if let exactChange = fileChange.exactChange(at: selectedChange.sourceIndex) {
                return .text(exactChange.diff)
            }
            if let exactPatch = selectedChange.exactPatch {
                return .exactPatch(exactPatch)
            }
            return fileChange.diff.map(CodexTranscriptCopyPayload.text)
        }()

        return CodexTranscriptFileChangeRenderProjection(
            panel: .init(
                rowID: rowID,
                files: summaries,
                selectedFileIndex: selectedIndex,
                omittedFileCount: fileChange.omittedPreparedFileCount
            ),
            selectedChange: selectedChange,
            copyPayload: copyPayload,
            accessibilityLabel: "Patch for \(selectedChange.path), \(selectedChange.added) additions and \(selectedChange.removed) removals",
            panelFingerprint: fileChange.preparedSourceFingerprint
        )
    }

    static func fileChangeLabel(_ value: CodexFileChangeRowV2) -> String {
        guard value.hasPreparedDetail else {
            let paths = value.changes.isEmpty
                ? Array(value.files.prefix(3))
                : value.changes.prefix(3).map(\.displayPath)
            let visible = paths.joined(separator: " · ")
            let remainder = max(0, value.fileCount - 3)
            return remainder == 0
                ? "Edited \(visible)"
                : "Edited \(visible) · +\(remainder) more"
        }

        let count = max(value.fileCount, value.preparedChanges.count)
        let omitted = value.omittedPreparedFileCount
        let suffix = omitted > 0 ? " · \(omitted) details omitted" : ""
        return "Edited \(count) \(count == 1 ? "file" : "files") · +\(value.preparedAddedLineCount) −\(value.preparedRemovedLineCount)\(suffix)"
    }

    static func prepareDiffFile(
        _ preparedChange: CodexPreparedFileChangeV2,
        theme: CodexTranscriptAppKitTheme
    ) -> CodexPreparedTranscriptText {
        let result = NSMutableAttributedString()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = theme.lineSpacing
        paragraphStyle.paragraphSpacing = 10

        for (index, preparedLine) in preparedChange.displayLines.enumerated() {
            let line = preparedLine.text
            let color: NSColor
            if index == 0 {
                color = theme.textPrimary
            } else {
                color = switch preparedLine.kind {
                case .add: theme.success
                case .remove: theme.danger
                case .context where line.hasPrefix("@@") || line.hasPrefix("… "):
                    theme.textTertiary
                case .context:
                    theme.codeText
                }
            }
            let font = index == 0
                ? NSFontManager.shared.convert(theme.codeFont, toHaveTrait: .boldFontMask)
                : theme.codeFont
            result.append(NSAttributedString(
                string: line + (index == preparedChange.displayLines.count - 1 ? "" : "\n"),
                attributes: [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: paragraphStyle,
                ]
            ))
        }
        return CodexPreparedTranscriptText(result)
    }
}
