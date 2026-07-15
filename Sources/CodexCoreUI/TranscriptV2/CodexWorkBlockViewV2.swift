import CodexCore
import Foundation
import SwiftUI

/// One chronological work block for a turn.
public struct CodexWorkBlockViewV2: View {
    @Environment(\.codexAgentTheme) private var theme

    private let narrative: [CodexNarrativeEntry]
    private let liveTail: String?
    private let status: CodexTurnStatusV2
    private let finalAnswer: CodexAssistantTextV2?
    private let productToolRenderer: CodexProductToolRendererV2?
    private let onOpenSubagent: (String) -> Void
    @State private var isExpanded: Bool
    @State private var clientStartedAt = Date()

    public init(
        narrative: [CodexNarrativeEntry],
        liveTail: String?,
        status: CodexTurnStatusV2,
        finalAnswer: CodexAssistantTextV2? = nil,
        productToolRenderer: CodexProductToolRendererV2? = nil,
        onOpenSubagent: @escaping (String) -> Void = { _ in },
        initiallyExpanded: Bool = false
    ) {
        self.narrative = narrative
        self.liveTail = liveTail
        self.status = status
        self.finalAnswer = finalAnswer
        self.productToolRenderer = productToolRenderer
        self.onOpenSubagent = onOpenSubagent
        self._isExpanded = State(initialValue: initiallyExpanded)
    }

    public init(
        turn: CodexTurnV2,
        productToolRenderer: CodexProductToolRendererV2? = nil,
        initiallyExpanded: Bool = false
    ) {
        self.init(
            narrative: turn.narrative,
            liveTail: turn.liveTail,
            status: turn.status,
            finalAnswer: turn.finalAnswer,
            productToolRenderer: productToolRenderer,
            initiallyExpanded: initiallyExpanded
        )
    }

    public var body: some View {
        if shouldRender {
            VStack(alignment: .leading, spacing: 12) {
                switch status {
                case .working(let since):
                    if Self.showsWorkingDuration(narrative: narrative, liveTail: liveTail) {
                        Text(verbatim: Self.workingLabel(
                            at: Date(),
                            since: since,
                            clientStartedAt: clientStartedAt
                        ))
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.textTertiary)
                    } else {
                        CodexLiveTailV2(text: "Thinking")
                    }
                    if !narrative.isEmpty { narrativeBody }
                    if let liveTail, !liveTail.isEmpty { CodexLiveTailV2(text: liveTail) }

                case .done(let durationMs):
                    Button {
                        withAnimation(.snappy(duration: theme.animations.snappyDuration)) { isExpanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(verbatim: "Worked for " + Self.duration(durationMs))
                            Image(systemName: "chevron.right")
                                .font(theme.fonts.micro)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        }
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if isExpanded { narrativeBody }

                case .failed(let message):
                    Text(message.isEmpty ? "Work failed" : message)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                }
            }
            .frame(maxWidth: theme.spacing.cardMaxWidth, alignment: .leading)
        }
    }

    private var hasContent: Bool { !narrative.isEmpty || liveTail != nil }

    private var shouldRender: Bool {
        switch status {
        case .working:
            // The app-server can announce the final-answer item before its
            // first delta. Keep the active work state visible until text exists.
            finalAnswer?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        case .done, .failed: hasContent
        }
    }

    /// The protocol exposes turn/item activity, not a presentation label. A single
    /// final answer is just thinking until the model has produced intermediate work.
    nonisolated static func showsWorkingDuration(narrative: [CodexNarrativeEntry], liveTail: String?) -> Bool {
        if liveTail?.isEmpty == false, liveTail != "Thinking" { return true }
        if narrative.contains(where: { entry in
            switch entry {
            case .workGroup, .productToolCall: true
            case .prose, .notice: false
            }
        }) { return true }
        return narrative.count(where: {
            if case .prose = $0 { return true }
            return false
        }) > 1
    }

    private var narrativeBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(narrative) { entry in
                switch entry {
                case .prose(let prose):
                    CodexAssistantContentView(
                        text: prose.text,
                        isStreaming: prose.isStreaming,
                        cacheNamespace: "transcript-v2-prose-\(prose.id)"
                    )
                    .foregroundStyle(theme.colors.textSecondary)
                case .workGroup(let group):
                    CodexWorkGroupViewV2(group: group, onOpenSubagent: onOpenSubagent)
                case .notice(let notice):
                    Text(notice.message)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                case .productToolCall(let call):
                    if let rendered = productToolRenderer?.render(call) { rendered }
                    else { CodexProductToolFallbackV2(call: call) }
                }
            }
        }
    }

    nonisolated static func elapsedSeconds(at date: Date, since: Int64?, clientStartedAt: Date) -> Int {
        let start = since.map { TimeInterval($0) } ?? clientStartedAt.timeIntervalSince1970
        return max(0, Int(date.timeIntervalSince1970 - start))
    }

    nonisolated static func workingLabel(at date: Date, since: Int64?, clientStartedAt: Date) -> String {
        "Working for " + String(elapsedSeconds(at: date, since: since, clientStartedAt: clientStartedAt)) + "s"
    }

    nonisolated static func duration(_ milliseconds: Int?) -> String {
        let seconds = max(0, (milliseconds ?? 0) / 1_000)
        let minutes = seconds / 60
        let remainder = seconds % 60
        return minutes > 0
            ? String(minutes) + "m " + String(remainder) + "s"
            : String(remainder) + "s"
    }
}

private struct CodexLiveTailV2: View {
    @Environment(\.codexAgentTheme) private var theme
    let text: String

    var body: some View {
        Text(text)
            .font(theme.fonts.caption)
            .foregroundStyle(theme.colors.textTertiary)
        .accessibilityLabel(text)
    }
}

private struct CodexProductToolFallbackV2: View {
    @Environment(\.codexAgentTheme) private var theme
    let call: CodexProductToolCallV2

    var body: some View {
        HStack(spacing: 6) {
            Text(codexStatusGlyphV2(call.status))
            Text([call.namespace, call.tool].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                .lineLimit(1)
        }
        .font(theme.fonts.caption)
        .foregroundStyle(theme.colors.textSecondary)
        .padding(theme.spacing.chipPadding)
        .background(theme.colors.surfaceSunken)
        .clipShape(Capsule())
        .overlay { Capsule().stroke(theme.colors.border, lineWidth: 1) }
    }
}

func codexStatusGlyphV2(_ status: CodexWorkItemStatusV2) -> String {
    switch status { case .inProgress: "◌"; case .completed: "✓"; case .failed: "!" }
}

#if DEBUG
#Preview("Live turn mid-work") {
    CodexWorkBlockViewV2(
        narrative: [
            .prose(.init(id: "live-prose", text: "I'll take a quick repo pulse.", isStreaming: false)),
            .workGroup(CodexTranscriptV2PreviewData.commandGroup)
        ],
        liveTail: "Searching files in AGENTS.md folder",
        status: .working(since: Int64(Date().timeIntervalSince1970) - 36)
    )
    .padding()
}

#Preview("Completed collapsed turn") {
    CodexWorkBlockViewV2(
        narrative: [.workGroup(CodexTranscriptV2PreviewData.commandGroup)],
        liveTail: nil,
        status: .done(durationMs: 68_000)
    )
    .padding()
}

#Preview("Expanded narrative") {
    CodexWorkBlockViewV2(
        narrative: [
            .prose(.init(id: "expanded-prose", text: "So far: clean main, synced with origin/main.", isStreaming: false)),
            .workGroup(CodexTranscriptV2PreviewData.commandGroup),
            .workGroup(CodexTranscriptV2PreviewData.fileGroup),
            .productToolCall(.init(
                id: "product-tool", tool: "lookup", namespace: "github",
                arguments: nil, status: .completed, contentItems: [], success: true
            ))
        ],
        liveTail: nil,
        status: .done(durationMs: 68_000),
        initiallyExpanded: true
    )
    .padding()
}

#Preview("Failed turn") {
    CodexWorkBlockViewV2(
        narrative: [.notice(.init(id: "failure-notice", message: "The operation could not be completed."))],
        liveTail: nil,
        status: .failed(message: "Connection lost")
    )
    .padding()
}

private enum CodexTranscriptV2PreviewData {
    static let commandGroup = CodexWorkGroupV2(
        id: "commands", header: "Listed files, ran a command",
        rows: [
            .command(.init(
                id: "status", command: "git status --short --branch", label: "Ran git status",
                action: .run, status: .completed, exitCode: 0, durationMs: 420, output: "## codex/transcript-v2"
            )),
            .command(.init(
                id: "list", command: "ls Sources/CodexCoreUI", label: "Listed files",
                action: .list, status: .completed, exitCode: 0, durationMs: 180
            ))
        ], isLive: false
    )

    static let fileGroup = CodexWorkGroupV2(
        id: "files", header: "Read 2 files and searched",
        rows: [
            .fileChange(.init(
                id: "change", files: ["CodexTurnViewV2.swift", "CodexWorkBlockViewV2.swift"],
                status: .completed, durationMs: 310, diff: "+ presentation grammar"
            )),
            .webSearch(.init(id: "search", query: "SwiftUI disclosure", status: .completed))
        ], isLive: false
    )
}
#endif
