import AppKit
import SwiftUI

/// The legacy review surface is retained for projectless chats. Those chats
/// have no repository boundary to mutate, so the panel explains the boundary
/// and offers the one useful local action instead of presenting disabled Git
/// controls.
public struct CodexGitReviewPanel: View {
    @Environment(\.codexAgentTheme) private var theme

    private let session: CodexGitReviewSession

    public init(session: CodexGitReviewSession) {
        self.session = session
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 28))
                .foregroundStyle(theme.colors.textTertiary)

            Text("Review requires a Git-backed workspace")
                .font(theme.fonts.body.weight(.semibold))
                .foregroundStyle(theme.colors.textPrimary)

            Text("This projectless chat has no repository to compare, commit, or push. Open a folder in Finder, then start a project chat to review its changes.")
                .font(theme.fonts.chat)
                .foregroundStyle(theme.colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                openFolder()
            } label: {
                Label("Open a folder", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .help("Choose a folder to open in Finder")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("codex.review.projectless-empty-state")
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        NSWorkspace.shared.open(url)
    }
}
