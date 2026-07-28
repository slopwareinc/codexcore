import AppKit
import Foundation

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

extension CodexTranscriptRenderProjector {
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
