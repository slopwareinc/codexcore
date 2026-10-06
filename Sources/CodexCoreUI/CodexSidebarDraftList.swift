import Foundation
import SwiftUI

struct CodexSidebarDraftItem: Identifiable, Equatable, Sendable {
    let id: CodexComposerDraftID
    let title: String
    let projectTitle: String
    let isProjectless: Bool
    let isSelected: Bool
}

/// Draft identity and scoping stay independent of native thread summaries and workspace paths.
struct CodexSidebarDraftProjection {
    let items: [CodexSidebarDraftItem]

    init(
        drafts: [CodexComposerDraftSnapshot],
        projects: [CodexProjectSummary],
        projectScopeID: String? = nil,
        activeDraftID: CodexComposerDraftID? = nil
    ) {
        let projectByID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<CodexComposerDraftID> = []
        items = drafts.filter { draft in
            draft.threadID == nil && Self.hasUserContent(draft) && seen.insert(draft.draftID).inserted
                && (projectScopeID == nil || (!draft.isProjectless && draft.projectID == projectScopeID))
        }.sorted { $0.draftID.rawValue < $1.draftID.rawValue }.map { draft in
            let projectTitle: String
            if draft.isProjectless {
                projectTitle = "Projectless"
            } else if let id = draft.projectID, let project = projectByID[id] {
                projectTitle = project.displayName
            } else {
                projectTitle = draft.workspacePath.map { URL(fileURLWithPath: $0).lastPathComponent }
                    .flatMap { $0.isEmpty ? nil : $0 } ?? "Project"
            }
            return .init(id: draft.draftID, title: Self.title(for: draft), projectTitle: projectTitle,
                isProjectless: draft.isProjectless, isSelected: draft.draftID == activeDraftID)
        }
    }

    private static func hasUserContent(_ draft: CodexComposerDraftSnapshot) -> Bool {
        !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.referencedFiles.isEmpty || !draft.responseAnnotations.isEmpty
            || !draft.attachedSkills.isEmpty || !draft.selectedMentions.isEmpty
    }

    static func title(for draft: CodexComposerDraftSnapshot) -> String {
        let prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstLine = prompt.split(whereSeparator: \.isNewline).first, !firstLine.isEmpty {
            return String(firstLine).trimmingCharacters(in: .whitespaces)
        }
        let attachments = draft.referencedFiles.count + draft.responseAnnotations.count
        if attachments > 0 { return "\(attachments) attachment\(attachments == 1 ? "" : "s")" }
        if let skill = draft.attachedSkills.first { return "Skill: \(skill.title)" }
        if let mention = draft.selectedMentions.first { return "Mention: \(mention.fileName)" }
        return "Unsent draft"
    }
}

/// A compact host-driven section. Drafts never acquire invented thread status or timestamps.
struct CodexSidebarDraftList: View {
    @Environment(\.codexAgentTheme) private var theme
    let items: [CodexSidebarDraftItem]
    var showsHeading = false
    var onSelect: ((CodexComposerDraftID) -> Void)?
    var onDiscard: ((CodexComposerDraftID) -> Void)?

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                if showsHeading {
                    Text("Drafts")
                        .font(theme.fonts.sidebar.sectionHeader.font)
                        .foregroundStyle(theme.colors.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 24, alignment: .leading)
                }
                ForEach(items) { item in
                    CodexSidebarDraftRow(item: item, onSelect: onSelect, onDiscard: onDiscard)
                }
                Rectangle().fill(theme.colors.border.opacity(0.6)).frame(height: 1)
                    .padding(.horizontal, 10).padding(.vertical, 6).accessibilityHidden(true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Unsent drafts")
        }
    }
}

// Two-line draft card adapted from T3 Code Sidebar.tsx's SidebarDraftRow at
// 7bf6de174171ffcf0215bf55556f0e3ee7e6d78f. Copyright (c) 2026 T3 Tools Inc.
// MIT; see THIRD_PARTY_NOTICES.md.
private struct CodexSidebarDraftRow: View {
    @Environment(\.codexAgentTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    let item: CodexSidebarDraftItem
    let onSelect: ((CodexComposerDraftID) -> Void)?
    let onDiscard: ((CodexComposerDraftID) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil")
                    .font(metadataFont).foregroundStyle(secondary).accessibilityHidden(true)
                if !item.isProjectless { CodexT3ProjectMonogram(projectName: item.projectTitle) }
                Text(item.projectTitle).font(metadataFont.weight(.medium))
                    .foregroundStyle(secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Text("Draft").font(metadataFont).foregroundStyle(secondary.opacity(0.8))
            }
            .frame(height: 20)
            Text(item.title).font(theme.fonts.sidebar.chatTitle.font.weight(.medium))
                .foregroundStyle(primary.opacity(0.9)).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading).frame(height: 20)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(height: theme.interfaceStyle == .t3Code ? 78 : 60)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect?(item.id) }
        .focusable(onSelect != nil).focused($isFocused).focusEffectDisabled()
        .onKeyPress(.return, action: activate)
        .onKeyPress(.space, action: activate)
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 6).strokeBorder(theme.colors.accent, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .contextMenu { discardAction }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.projectTitle), unsent draft")
        .accessibilityValue("Draft")
        .accessibilityIdentifier("sidebar-draft-\(item.id.rawValue)")
        .accessibilityHint("Open this unsent draft")
        .accessibilityAddTraits(onSelect == nil ? [] : .isButton)
        .accessibilityAddTraits(item.isSelected ? .isSelected : [])
        .accessibilityAction(.default) { onSelect?(item.id) }
        .accessibilityActions { discardAction }
        .help(item.title)
        .padding(.vertical, 2)
    }

    private func activate() -> KeyPress.Result {
        guard let onSelect else { return .ignored }
        onSelect(item.id)
        return .handled
    }

    @ViewBuilder private var discardAction: some View {
        if let onDiscard {
            Button("Discard draft", systemImage: "trash", role: .destructive) { onDiscard(item.id) }
        }
    }

    private var metadataFont: Font {
        var token = theme.fonts.sidebar.chatTitle
        token.size = max(8, token.size - 2)
        token.weight = .regular
        return token.font
    }
    private var primary: Color {
        theme.interfaceStyle == .t3Code ? CodexT3SidebarColors.foreground(for: colorScheme) : theme.colors.textPrimary
    }
    private var secondary: Color {
        theme.interfaceStyle == .t3Code ? CodexT3SidebarColors.secondary(for: colorScheme) : theme.colors.textSecondary
    }
    private var fill: Color {
        if theme.interfaceStyle == .t3Code {
            if item.isSelected { return CodexT3SidebarColors.active(for: colorScheme) }
            if isHovered || isFocused { return CodexT3SidebarColors.hover(for: colorScheme) }
        } else {
            if item.isSelected { return theme.colors.selection.opacity(theme.effects.selectionOpacity) }
            if isHovered || isFocused { return theme.colors.hover.opacity(theme.effects.hoverOpacity) }
        }
        return .clear
    }
}
