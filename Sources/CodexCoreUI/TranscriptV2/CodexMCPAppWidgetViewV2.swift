import SwiftUI

/// Sandboxed MCP App host boundary.  The default host never executes payload
/// data; trusted products inject a view at `content` and still get explicit
/// loading/error/reload states from the presentation lifecycle.
public struct CodexMCPAppWidgetViewV2: View {
    @Environment(\.codexAgentTheme) private var theme
    public let widget: CodexMCPWidgetV2
    private let content: ((CodexMCPWidgetV2) -> AnyView?)?
    @State private var lifecycle: CodexMCPAppHostLifecycle

    public init(
        widget: CodexMCPWidgetV2,
        content: ((CodexMCPWidgetV2) -> AnyView?)? = nil
    ) {
        self.widget = widget
        self.content = content
        self._lifecycle = State(initialValue: CodexMCPAppHostLifecycle(widget: widget))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch lifecycle.state {
            case .disabled:
                Button("Load MCP app", systemImage: "rectangle.on.rectangle") {
                    lifecycle.reveal()
                }
                .buttonStyle(.plain)
            case .loading:
                Label("Loading MCP app", systemImage: "hourglass")
                    .foregroundStyle(theme.colors.textSecondary)
            case .ready:
                if let content, let view = content(widget) {
                    view
                } else {
                    Label("Interactive MCP widget", systemImage: "rectangle.on.rectangle")
                        .foregroundStyle(theme.colors.textSecondary)
                }
            case .failed:
                Label("MCP app unavailable", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(theme.colors.warning)
                Button("Reload") {
                    lifecycle.reset()
                    lifecycle.reveal()
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.colors.accent)
            }
        }
        .font(theme.fonts.caption)
        .padding(10)
        .background(theme.colors.surfaceElevated.opacity(0.35), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .onAppear {
            // A visible host may begin loading, while an offscreen row never
            // mounts an iframe/web view or performs layout work.
            if lifecycle.isVisible == false { lifecycle.reveal() }
        }
    }

    private var accessibilityLabel: String {
        switch lifecycle.state {
        case .disabled: "MCP app, not loaded"
        case .loading: "Loading MCP app"
        case .ready: "MCP app ready"
        case .failed: "MCP app unavailable"
        }
    }
}
