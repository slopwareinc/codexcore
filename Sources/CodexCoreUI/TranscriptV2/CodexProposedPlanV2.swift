import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A model-authored `plan` item. Checklist progress is a separate runtime value.
public struct CodexProposedPlanV2: Identifiable, Sendable, Equatable {
    public var id: String
    public var markdown: String
    public var isStreaming: Bool

    public init(id: String, markdown: String, isStreaming: Bool = false) {
        self.id = id
        self.markdown = markdown
        self.isStreaming = isStreaming
    }
}

/// Adapted from T3 Code's `proposedPlan.ts` and `ProposedPlanCard.tsx`.
enum CodexProposedPlanPresentation {
    private static let heading = try! NSRegularExpression(pattern: #"^\s{0,3}#{1,6}\s+(.+)$"#)

    static func title(_ markdown: String) -> String {
        lines(markdown).lazy.compactMap(headingText).first ?? "Proposed plan"
    }

    static func canCollapse(_ markdown: String) -> Bool {
        markdown.count > 900 || lines(markdown).count > 20
    }

    static func displayMarkdown(_ markdown: String) -> String {
        var source = lines(markdown.trimmingCharacters(in: .newlines))
        if let first = source.first, headingText(first) != nil { source.removeFirst() }
        while source.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { source.removeFirst() }
        if let first = source.first, headingText(first)?.lowercased() == "summary" {
            source.removeFirst()
            while source.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { source.removeFirst() }
        }
        return source.joined(separator: "\n")
    }

    static func preview(_ markdown: String, maximumVisibleLines: Int = 10) -> String {
        let source = lines(displayMarkdown(markdown))
        var result: [String] = []
        var visible = 0
        var hasMore = false
        for line in source {
            let isVisible = !line.trimmingCharacters(in: .whitespaces).isEmpty
            if isVisible && visible >= max(1, maximumVisibleLines) { hasMore = true; break }
            result.append(line)
            if isVisible { visible += 1 }
        }
        while result.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { result.removeLast() }
        if result.isEmpty { return title(markdown) }
        if hasMore { result.append(contentsOf: ["", "…"]) }
        return result.joined(separator: "\n")
    }

    static func exportMarkdown(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) + "\n"
    }

    static func exportFilename(_ markdown: String) -> String {
        let segment = title(markdown).lowercased()
            .replacingOccurrences(of: #"[`'\".,!?()\[\]{}]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (segment.isEmpty ? "plan" : segment) + ".md"
    }

    private static func lines(_ markdown: String) -> [String] {
        markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    private static func headingText(_ line: String) -> String? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = heading.firstMatch(in: line, range: range),
              let titleRange = Range(match.range(at: 1), in: line) else { return nil }
        let title = String(line[titleRange]).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }
}

struct CodexTranscriptProposedPlanRender: Sendable, Equatable {
    var plan: CodexProposedPlanV2
    var isExpanded: Bool
    var displayedMarkdown: String {
        CodexProposedPlanPresentation.canCollapse(plan.markdown) && !isExpanded
            ? CodexProposedPlanPresentation.preview(plan.markdown)
            : CodexProposedPlanPresentation.displayMarkdown(plan.markdown)
    }
}

struct CodexProposedPlanCardV2: View {
    @Environment(\.codexAgentTheme) private var theme
    let render: CodexTranscriptProposedPlanRender
    let onToggleExpanded: () -> Void
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.lg) {
            HStack(spacing: theme.spacing.sm) {
                Text("Plan")
                    .font(theme.fonts.caption.weight(.medium))
                    .padding(.horizontal, theme.spacing.sm)
                    .padding(.vertical, theme.spacing.xxs)
                    .background(theme.colors.surfaceSunken, in: Capsule())
                Text(CodexProposedPlanPresentation.title(render.plan.markdown))
                    .font(theme.fonts.label)
                    .lineLimit(1)
                Spacer(minLength: theme.spacing.sm)
                Menu {
                    Button("Copy to clipboard") { onCopy(CodexProposedPlanPresentation.exportMarkdown(render.plan.markdown)) }
                    Button("Export as Markdown…") { CodexProposedPlanExport.save(render.plan.markdown) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Plan actions")
                .accessibilityLabel("Plan actions")
            }
            CodexAssistantContentView(
                text: render.displayedMarkdown,
                isStreaming: render.plan.isStreaming,
                cacheNamespace: "proposed-plan-\(render.plan.id)-\(render.isExpanded)"
            )
            if CodexProposedPlanPresentation.canCollapse(render.plan.markdown) {
                HStack {
                    Spacer()
                    Button(render.isExpanded ? "Collapse plan" : "Expand plan", action: onToggleExpanded)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityValue(render.isExpanded ? "Expanded" : "Collapsed")
                    Spacer()
                }
            }
        }
        .foregroundStyle(theme.colors.textPrimary)
        .padding(theme.spacing.lg)
        .background(theme.colors.surface, in: RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(theme.colors.border, lineWidth: 1))
    }

    private var cornerRadius: CGFloat {
        theme.interfaceStyle == .t3Code ? 24 : theme.radii.large
    }
}

struct CodexStandaloneProposedPlanCardV2: View {
    let plan: CodexProposedPlanV2
    @Environment(\.codexClipboardService) private var clipboardService
    @State private var isExpanded = false

    var body: some View {
        CodexProposedPlanCardV2(
            render: .init(plan: plan, isExpanded: isExpanded),
            onToggleExpanded: { isExpanded.toggle() },
            onCopy: { clipboardService.copy($0) }
        )
    }
}

@MainActor
private enum CodexProposedPlanExport {
    static func save(_ markdown: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = CodexProposedPlanPresentation.exportFilename(markdown)
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                try CodexProposedPlanPresentation.exportMarkdown(markdown).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}
