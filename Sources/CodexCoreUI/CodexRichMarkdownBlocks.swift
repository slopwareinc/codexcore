import SwiftUI

/// Safe math surface. A host may replace this view with a KaTeX/MathJax
/// adapter; the default keeps the source selectable and never executes input.
public struct CodexMathBlockView: View {
    @Environment(\.codexAgentTheme) private var theme
    public let latex: String
    public let display: Bool

    public init(latex: String, display: Bool = true) {
        self.latex = latex
        self.display = display
    }

    public var body: some View {
        Text(latex)
            .font(theme.fonts.code)
            .foregroundStyle(theme.colors.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: display ? .center : .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(theme.colors.surfaceSunken, in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Mathematical expression: \(latex)")
    }
}

/// Mermaid is intentionally rendered as a bounded source card by default.
/// Product hosts can inject a trusted diagram renderer at this seam without
/// allowing untrusted transcript text to execute JavaScript or HTML.
public struct CodexMermaidBlockView: View {
    @Environment(\.codexAgentTheme) private var theme
    public let diagram: String
    public let isComplete: Bool

    public init(diagram: String, isComplete: Bool = true) {
        self.diagram = diagram
        self.isComplete = isComplete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(isComplete ? "Mermaid diagram" : "Mermaid diagram (streaming)", systemImage: "point.3.connected.trianglepath.dotted")
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)
            Text(boundedDiagram)
                .font(theme.fonts.code)
                .foregroundStyle(theme.colors.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(theme.colors.surfaceSunken, in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mermaid diagram: \(boundedDiagram)")
    }

    private var boundedDiagram: String {
        guard diagram.utf8.count > 40_000 else { return diagram }
        return String(diagram.prefix(40_000)) + "\n… diagram truncated"
    }
}

