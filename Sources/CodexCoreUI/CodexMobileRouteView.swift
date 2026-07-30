import SwiftUI

public struct CodexMobileRouteView: View {
    @Environment(\.codexAgentTheme) private var theme

    public let state: CodexMobileRouteState
    public let onRefreshStatus: () -> Void
    public let onGetStarted: () -> Void
    public let onCancelPermissionGate: () -> Void
    public let onAllow: () -> Void

    public init(
        state: CodexMobileRouteState,
        onRefreshStatus: @escaping () -> Void,
        onGetStarted: @escaping () -> Void,
        onCancelPermissionGate: @escaping () -> Void,
        onAllow: @escaping () -> Void
    ) {
        self.state = state
        self.onRefreshStatus = onRefreshStatus
        self.onGetStarted = onGetStarted
        self.onCancelPermissionGate = onCancelPermissionGate
        self.onAllow = onAllow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(state.title)
                    .font(theme.fonts.routeTitle)
                    .foregroundStyle(theme.colors.textPrimary)
                Text(state.subtitle)
                    .font(theme.fonts.body)
                    .foregroundStyle(theme.colors.textSecondary)
            }

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    CodexMobileBenefitRow(systemImage: "arrow.triangle.2.circlepath", title: state.benefits[0])
                    CodexMobileBenefitRow(systemImage: "bell", title: state.benefits[1])
                    CodexMobileBenefitRow(systemImage: "sparkles", title: state.benefits[2])

                    Text(state.warning)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.warning)
                        .fixedSize(horizontal: false, vertical: true)

                    mobileStatusCard

                    HStack(spacing: 10) {
                        Button(action: onGetStarted) {
                            Text(state.getStartedTitle)
                        }
                        .buttonStyle(.borderedProminent)
                        Button(action: onRefreshStatus) {
                            Text("Refresh status")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)

                CodexPhoneMockView()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.colors.surface)
        .onAppear(perform: onRefreshStatus)
        .sheet(isPresented: Binding(
            get: { state.isPermissionGatePresented },
            set: { presented in
                if !presented {
                    onCancelPermissionGate()
                }
            }
        )) {
            CodexMobilePermissionGate(state: state, onCancel: onCancelPermissionGate, onAllow: onAllow)
                .codexAgentTheme(theme)
        }
    }

    private var mobileStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Remote control")
                    .font(theme.fonts.caption.weight(.semibold))
                    .foregroundStyle(theme.colors.textTertiary)
                Text(state.status.statusLine)
                    .font(theme.fonts.caption)
                    .foregroundStyle(state.status.kind == .error ? theme.colors.warning : theme.colors.textSecondary)
            }
            Text(state.pairing.statusLabel)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)
            ForEach(state.clients) { client in
                Text("\(client.displayName) · \(client.platformLabel)")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
        }
        .padding(12)
        .background(theme.colors.surfaceElevated.opacity(0.58), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
    }
}

private struct CodexMobileBenefitRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let systemImage: String
    let title: String

    init(systemImage: String, title: String) {
        self.systemImage = systemImage
        self.title = title
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(theme.fonts.label)
                .foregroundStyle(theme.colors.accent)
                .frame(width: 18)
            Text(title)
                .font(theme.fonts.caption.weight(.medium))
                .foregroundStyle(theme.colors.textPrimary)
        }
    }
}

private struct CodexPhoneMockView: View {
    @Environment(\.codexAgentTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(theme.colors.success)
                    .frame(width: 8, height: 8)
                Text("Codex")
                    .font(theme.fonts.label)
                Spacer()
            }
            .foregroundStyle(theme.colors.textPrimary)

            VStack(alignment: .leading, spacing: 7) {
                Text("Projects")
                    .font(theme.fonts.caption.weight(.semibold))
                    .foregroundStyle(theme.colors.textTertiary)
                Text("CodexCore")
                    .font(theme.fonts.caption.weight(.medium))
                    .foregroundStyle(theme.colors.textPrimary)
                Text("Chats")
                    .font(theme.fonts.caption.weight(.semibold))
                    .foregroundStyle(theme.colors.textTertiary)
                Text("Continue release plan")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
        }
        .padding(18)
        .frame(width: 190, height: 300, alignment: .topLeading)
        .background(theme.colors.surfaceElevated.opacity(0.82), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
    }
}

private struct CodexMobilePermissionGate: View {
    @Environment(\.codexAgentTheme) private var theme

    let state: CodexMobileRouteState
    let onCancel: () -> Void
    let onAllow: () -> Void

    init(state: CodexMobileRouteState, onCancel: @escaping () -> Void, onAllow: @escaping () -> Void) {
        self.state = state
        self.onCancel = onCancel
        self.onAllow = onAllow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(state.permissionTitle)
                .font(theme.fonts.sheetTitle)
                .foregroundStyle(theme.colors.textPrimary)
            Text(state.permissionQuestion)
                .font(theme.fonts.panelTitle)
                .foregroundStyle(theme.colors.textPrimary)
            Text(state.permissionDetail)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Allow", action: onAllow)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(theme.colors.surface)
    }
}
