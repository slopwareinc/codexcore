import SwiftUI

/// Compact, consistent +N/-M diff counter used across file-change cards and
/// git review rows. Applies a true minus glyph (U+2212), the theme's
/// success/danger colors, and monospaced digits so widths stop jittering as
/// counts grow from single to triple digits.
///
/// Wrap in your own capsule/background per call site; this view only owns the
/// two text runs and their typography.
public struct CodexDiffCounter: View {
    @Environment(\.codexAgentTheme) private var theme

    public let added: Int
    public let removed: Int

    public init(added: Int, removed: Int) {
        self.added = added
        self.removed = removed
    }

    public var body: some View {
        HStack(spacing: 4) {
            Text("+\(added)")
                .foregroundStyle(theme.colors.success)
            Text("\u{2212}\(removed)")
                .foregroundStyle(theme.colors.danger)
        }
        .font(theme.fonts.micro)
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(added) added, \(removed) removed")
    }
}