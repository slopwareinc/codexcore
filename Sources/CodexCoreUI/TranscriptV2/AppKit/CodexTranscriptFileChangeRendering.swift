import AppKit
import Foundation
import SwiftUI

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
}

struct CodexTranscriptTurnDiffCard: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var isHeaderHovered = false
    let render: CodexTranscriptTurnDiffRender
    let onReview: (() -> Void)?
    let onToggleExpanded: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(theme.colors.textSecondary)
                    .frame(width: 40, height: 40)
                    .background(theme.colors.surfaceSunken, in: RoundedRectangle(cornerRadius: 10))
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
                    Button("Review", action: onReview)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .accessibilityHint("Opens these changes in the Review workbench")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 84)
            .onHover { isHeaderHovered = $0 }

            Divider().overlay(theme.colors.border)

            ForEach(Array(render.visibleFiles.enumerated()), id: \.element.path) { _, file in
                if let onReview {
                    Button(action: onReview) {
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
                Divider().overlay(theme.colors.border)
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
                    .padding(.horizontal, 16)
                    .frame(height: 42)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(render.isExpanded ? "Expanded" : "Collapsed")
            }
        }
        .font(theme.fonts.chat)
        .background(theme.colors.surface.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
    }

    private func pathLabel(_ path: String) -> some View {
        let filename = (path as NSString).lastPathComponent
        let directory = String(path.dropLast(filename.count))
        return HStack(spacing: 0) {
            Text(directory).foregroundStyle(theme.colors.textSecondary)
            Text(filename).foregroundStyle(theme.colors.textPrimary)
        }
    }

    private func fileRow(_ file: CodexPreparedFileChangeSummaryV2) -> some View {
        HStack(spacing: 10) {
            pathLabel(file.path)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Text("+\(file.added)").foregroundStyle(theme.colors.success)
                Text("−\(file.removed)").foregroundStyle(theme.colors.danger)
            }
            .font(theme.fonts.caption)
            .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
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
                omittedFileCount: 0,
                isExpanded: false
            ),
            onReview: {},
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
        var latestByPath: [String: CodexPreparedFileChangeSummaryV2] = [:]
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
                    latestByPath[summary.path] = summary
                }
            }
        }
        let files = orderedPaths.compactMap { latestByPath[$0] }
        guard !files.isEmpty else { return nil }
        return CodexTranscriptTurnDiffRender(
            rowID: "turn-diff:\(turn.id)",
            files: files,
            omittedFileCount: omitted,
            isExpanded: isExpanded
        )
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
