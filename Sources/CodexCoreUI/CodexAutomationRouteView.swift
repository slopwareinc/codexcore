import SwiftUI
import CodexCore

public struct CodexAutomationRouteView: View {
    @Environment(\.codexAgentTheme) private var theme

    public let onAction: (CodexAutomationRouteAction) -> Void
    @State private var session = CodexAutomationRouteSession()

    public init(onAction: @escaping (CodexAutomationRouteAction) -> Void) {
        self.onAction = onAction
    }

    private var state: CodexAutomationRouteState {
        session.state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.colors.border)
            VStack(alignment: .leading, spacing: 24) {
                segmentedControls
                if state.showsEmptyState {
                    emptyTemplates
                } else {
                    automationRows
                }
            }
            .padding(24)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.colors.surface)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: CodexAppRoute.automations.systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.colors.textSecondary)
                .frame(width: 24, height: 28)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(state.headerTitle)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(theme.colors.textPrimary)
                    Button {
                        onAction(.learnMore)
                    } label: {
                        Text(state.learnMoreTitle)
                            .font(theme.fonts.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.colors.accent)
                    .accessibilityLabel(state.learnMoreTitle)
                }
                Text(state.description)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
            Spacer(minLength: 0)
            Button {} label: {
                Label(state.newAutomationOptionsTitle, systemImage: "ellipsis.circle")
            }
            .buttonStyle(.bordered)
            .disabled(true)
            .help(state.newAutomationOptionsTitle)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var segmentedControls: some View {
        HStack(spacing: 8) {
            ForEach(CodexAutomationRouteMode.allCases) { mode in
                Button {
                    selectMode(mode)
                } label: {
                    Text(mode.title)
                        .font(theme.fonts.caption.weight(.semibold))
                        .foregroundStyle(state.mode == mode ? theme.colors.textPrimary : theme.colors.textSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(
                            state.mode == mode ? theme.colors.surfaceElevated.opacity(0.9) : theme.colors.surfaceSunken.opacity(0.42),
                            in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                                .stroke(theme.colors.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.title)
            }
        }
    }

    private var emptyTemplates: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.emptyTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.colors.textPrimary)

            HStack(spacing: 10) {
            ForEach(state.templates) { template in
                    CodexAutomationTemplateButton(template: template) {
                        perform(.template(template))
                    }
                }
            }
        }
    }

    private var automationRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(state.automations) { automation in
                HStack {
                    Text(automation.title)
                        .font(theme.fonts.chat.weight(.semibold))
                    Spacer()
                    Text(automation.statusLabel)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                }
                .padding(12)
                .background(theme.colors.surfaceElevated.opacity(0.66), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
            }
        }
    }

    private func selectMode(_ mode: CodexAutomationRouteMode) {
        switch mode {
        case .viewTemplates:
            session.viewTemplates()
        case .createViaChat:
            perform(.createViaChat)
        }
    }

    private func perform(_ action: CodexAutomationRouteAction) {
        _ = session.perform(action)
        onAction(action)
    }
}

private struct CodexAutomationTemplateButton: View {
    @Environment(\.codexAgentTheme) private var theme

    let template: CodexAutomationTemplate
    let action: () -> Void

    init(template: CodexAutomationTemplate, action: @escaping () -> Void) {
        self.template = template
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: template.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.colors.textSecondary)
                Text(template.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(template.isDraftBacked ? theme.colors.textPrimary : theme.colors.textTertiary)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(width: 156, height: 82, alignment: .leading)
            .background(theme.colors.surfaceElevated.opacity(0.72), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                    .stroke(theme.colors.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!template.isDraftBacked)
        .help(template.title)
    }
}
