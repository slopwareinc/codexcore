import SwiftUI
import CodexCoreUI

struct CodexAppRuntimeNoticeFeaturesView: View {
    @Environment(\.codexAgentTheme) private var theme
    @Bindable var features: CodexAppRuntimeNoticeFeatures
    let threadID: String?
    let turnID: String?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            if let first = features.notices.first {
                DisclosureGroup(isExpanded: $expanded) {
                    noticeRows
                } label: {
                    Text(features.notices.count > 1 ? "\(first.title) · \(features.notices.count) notices" : first.title)
                        .font(theme.fonts.label)
                }
            }
            if let message = features.errorMessage { Text(message).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary) }
        }
        .foregroundStyle(theme.colors.textPrimary)
        .task(id: CodexAppRuntimeNoticeSelection(threadID: threadID, turnID: turnID)) {
            await features.select(threadID: threadID, turnID: turnID)
        }
    }

    private var noticeRows: some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            ForEach(features.notices) { notice in
                HStack(alignment: .top, spacing: theme.spacing.sm) {
                    Image(systemName: notice.severity == .error ? "exclamationmark.octagon" : "info.circle")
                        .foregroundStyle(theme.colors.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(notice.title).font(theme.fonts.label)
                        Text(notice.detail).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(theme.spacing.md)
                .background(theme.colors.surface, in: RoundedRectangle(cornerRadius: theme.radii.medium))
                .overlay(RoundedRectangle(cornerRadius: theme.radii.medium).stroke(theme.colors.border))
            }
        }
    }
}
