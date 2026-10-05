import AppKit
import SwiftUI
import CodexCore

public struct CodexMCPAppHostContext: Sendable {
    public let provider: any CodexIntegrationControlPlaneProvider
    public let onOpenFullscreen: @MainActor @Sendable (CodexMCPAppDescriptor) -> Void
    public let onSendMessage: (@MainActor @Sendable (CodexMCPAppDescriptor, String) -> Void)?
    public let onUpdateModelContext: (@MainActor @Sendable (CodexMCPAppDescriptor, CodexJSONValue) -> Void)?
    public let appResources: [CodexMCPAppCatalogResource]

    public init(provider: any CodexIntegrationControlPlaneProvider,
                onOpenFullscreen: @escaping @MainActor @Sendable (CodexMCPAppDescriptor) -> Void,
                onSendMessage: (@MainActor @Sendable (CodexMCPAppDescriptor, String) -> Void)? = nil,
                onUpdateModelContext: (@MainActor @Sendable (CodexMCPAppDescriptor, CodexJSONValue) -> Void)? = nil,
                appResources: [CodexMCPAppCatalogResource] = []) {
        self.provider = provider; self.onOpenFullscreen = onOpenFullscreen; self.onSendMessage = onSendMessage
        self.onUpdateModelContext = onUpdateModelContext
        self.appResources = appResources
    }
}

private struct CodexMCPAppHostContextKey: EnvironmentKey {
    static let defaultValue: CodexMCPAppHostContext? = nil
}

extension EnvironmentValues {
    var codexMCPAppHostContext: CodexMCPAppHostContext? {
        get { self[CodexMCPAppHostContextKey.self] }
        set { self[CodexMCPAppHostContextKey.self] = newValue }
    }
}

extension View {
    /// Enables persisted MCP app widgets in the transcript and delegates expanded presentation to the host.
    public func codexMCPAppHost(provider: any CodexIntegrationControlPlaneProvider,
                               onOpenFullscreen: @escaping @MainActor @Sendable (CodexMCPAppDescriptor) -> Void,
                               onSendMessage: (@MainActor @Sendable (CodexMCPAppDescriptor, String) -> Void)? = nil,
                               onUpdateModelContext: (@MainActor @Sendable (CodexMCPAppDescriptor, CodexJSONValue) -> Void)? = nil,
                               appResources: [CodexMCPAppCatalogResource] = []) -> some View {
        environment(\.codexMCPAppHostContext, .init(provider: provider, onOpenFullscreen: onOpenFullscreen,
                                                  onSendMessage: onSendMessage, onUpdateModelContext: onUpdateModelContext, appResources: appResources))
    }
}

/// Renders an MCP Apps 2026-01-26 resource with an isolated, request-scoped bridge.
/// Hosts present fullscreen descriptors in a sheet using `displayMode: .fullscreen`.
public struct CodexMCPAppView: View {
    @Environment(\.codexAgentTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var bridge: CodexMCPAppBridge
    private let onClose: (@MainActor () -> Void)?

    public init(descriptor: CodexMCPAppDescriptor, provider: any CodexIntegrationControlPlaneProvider,
                displayMode: CodexMCPAppDescriptor.DisplayMode = .inline,
                onOpenFullscreen: (@MainActor (CodexMCPAppDescriptor) -> Void)? = nil,
                onSendMessage: (@MainActor (CodexMCPAppDescriptor, String) -> Void)? = nil,
                onUpdateModelContext: (@MainActor (CodexMCPAppDescriptor, CodexJSONValue) -> Void)? = nil,
                onClose: (@MainActor () -> Void)? = nil) {
        _bridge = State(initialValue: CodexMCPAppBridge(descriptor: descriptor, provider: provider,
                                                      displayMode: displayMode, onFullscreen: onOpenFullscreen,
                                                      onMessage: onSendMessage, onUpdateContext: onUpdateModelContext,
                                                      openLink: { NSWorkspace.shared.open($0) }))
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "app.connected.to.app.below.fill").foregroundStyle(theme.colors.textSecondary)
                Text(bridge.descriptor.appName).font(theme.fonts.body).fontWeight(.semibold)
                Spacer()
                if bridge.canOpenFullscreen {
                    Button("Open fullscreen", systemImage: "arrow.up.left.and.arrow.down.right") { bridge.openFullscreen() }.labelStyle(.iconOnly)
                }
                if let onClose { Button("Close", systemImage: "xmark", action: onClose).labelStyle(.iconOnly) }
            }
            if let resource = bridge.resource {
                CodexMCPAppWebView(resource: resource, bridge: bridge, theme: colorScheme == .dark ? "dark" : "light", styleVariables: appStyleVariables)
                    .frame(height: bridge.displayMode == .inline ? bridge.preferredHeight : 640)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let error = bridge.error {
                Text(error).foregroundStyle(theme.colors.danger).textSelection(.enabled)
            } else {
                HStack { ProgressView().controlSize(.small); Text("Loading app…").foregroundStyle(theme.colors.textSecondary) }
                    .frame(height: 120)
            }
        }
        .padding(12).background(theme.colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.colors.border, lineWidth: 1))
        .task(id: bridge.descriptor.id) { await bridge.load() }
        .onDisappear { bridge.stop() }
        .confirmationDialog(bridge.confirmation?.title ?? "Allow app operation?", isPresented: Binding(
            get: { bridge.confirmation != nil }, set: { if !$0 { bridge.resolveConfirmation(false) } }
        )) {
            Button("Allow once") { bridge.resolveConfirmation(true) }
            Button("Cancel", role: .cancel) { bridge.resolveConfirmation(false) }
        } message: { Text(bridge.confirmation?.detail ?? "") }
    }

    private var appStyleVariables: [String: String] {
        func css(_ color: Color) -> String {
            guard let value = NSColor(color).usingColorSpace(.sRGB) else { return "transparent" }
            return "rgba(\(Int((value.redComponent * 255).rounded())),\(Int((value.greenComponent * 255).rounded())),\(Int((value.blueComponent * 255).rounded())),\(value.alphaComponent))"
        }
        return ["--color-background-primary": css(theme.colors.surface), "--color-background-secondary": css(theme.colors.surfaceSunken),
                "--color-text-primary": css(theme.colors.textPrimary), "--color-text-secondary": css(theme.colors.textSecondary),
                "--color-border-primary": css(theme.colors.border), "--color-text-danger": css(theme.colors.danger)]
    }
}

struct CodexMCPAppTranscriptCard: View {
    let descriptor: CodexMCPAppDescriptor
    let context: CodexMCPAppHostContext
    var body: some View {
        if descriptor.preferredDisplayMode == .fullscreen {
            Button { context.onOpenFullscreen(descriptor) } label: {
                Label("Open \(descriptor.appName)", systemImage: "arrow.up.left.and.arrow.down.right")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.buttonStyle(.bordered)
        } else {
            CodexMCPAppView(descriptor: descriptor, provider: context.provider,
                            onOpenFullscreen: context.onOpenFullscreen, onSendMessage: context.onSendMessage,
                            onUpdateModelContext: context.onUpdateModelContext)
        }
    }
}
