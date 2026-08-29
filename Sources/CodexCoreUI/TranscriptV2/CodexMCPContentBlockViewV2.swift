import SwiftUI

/// Optional rich MCP content renderer. The default view is deliberately
/// bounded and non-executable; a host can provide a widget adapter for trusted
/// resources without changing canonical state.
public struct CodexMCPContentBlockViewV2: View {
    @Environment(\.codexAgentTheme) private var theme
    public let block: CodexMCPContentBlockV2
    private let widgetRenderer: ((CodexMCPWidgetV2) -> AnyView?)?

    public init(
        block: CodexMCPContentBlockV2,
        widgetRenderer: ((CodexMCPWidgetV2) -> AnyView?)? = nil
    ) {
        self.block = block
        self.widgetRenderer = widgetRenderer
    }

    public var body: some View {
        switch block {
        case .text(let value):
            Text(value)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)
                .textSelection(.enabled)
        case .image(_, _, let alt):
            Label(alt ?? "Image result", systemImage: "photo")
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)
        case .audio:
            Label("Audio result", systemImage: "waveform")
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)
        case .resource(let uri, _, let text):
            VStack(alignment: .leading, spacing: 3) {
                Label("Resource", systemImage: "doc.text")
                Text(text ?? uri)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                    .textSelection(.enabled)
            }
        case .resourceLink(let uri, let name, _):
            Label(name ?? uri, systemImage: "link")
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)
        case .structured(let fields):
            Label(
                fields.keys.sorted().prefix(12).joined(separator: ", ").isEmpty
                    ? "Structured result"
                    : "Structured result",
                systemImage: "curlybraces"
            )
            .font(theme.fonts.caption)
            .foregroundStyle(theme.colors.textSecondary)
        case .widget(let id, let uri, let payload):
            if let widgetRenderer,
               let rendered = widgetRenderer(.init(id: id ?? uri ?? "widget", uri: uri, payload: payload)) {
                rendered
            } else {
                Label("Interactive widget", systemImage: "rectangle.on.rectangle")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                    .accessibilityLabel("Interactive MCP widget")
            }
        }
    }
}

