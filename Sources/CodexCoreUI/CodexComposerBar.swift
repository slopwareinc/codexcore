import SwiftUI
import CodexCore

public struct CodexComposerBar: View {
    @Environment(\.codexAgentTheme) private var theme

    @Binding private var draft: String
    @Binding private var approvalSelection: CodexApprovalSelection
    @Binding private var isPlanModeEnabled: Bool
    private let isGoalPursuitEnabled: Bool
    private let approvalOptions: [CodexApprovalSelection]
    @Binding private var modelSelection: CodexModelSelection
    private let modelOptions: [CodexModelSelection]
    @Binding private var reasoningSelection: CodexReasoningSelection
    private let slashCommands: [CodexSlashCommand]
    private let isSending: Bool
    private let canSend: Bool
    private let canUsePlanMode: Bool
    private let followUpHint: String?
    private let mentionResults: [FuzzyFileSearchResult]
    private let onMentionQueryChanged: ((String?) -> Void)?
    private let onMentionSelected: ((FuzzyFileSearchResult) -> Void)?
    private let onSend: () -> Void
    private let onInterrupt: () -> Void
    private let onSlashCommandSelected: ((CodexSlashCommand) -> Void)?
    private let onAddMenuRoute: ((CodexComposerAddMenuRoute) -> Void)?
    private let onComposerChipClear: ((CodexComposerChipKind) -> Void)?
    @FocusState private var focused: Bool

    public init(
        draft: Binding<String>,
        approvalSelection: Binding<CodexApprovalSelection> = .constant(.fullAccess),
        isPlanModeEnabled: Binding<Bool> = .constant(false),
        isGoalPursuitEnabled: Bool = false,
        approvalOptions: [CodexApprovalSelection] = CodexApprovalSelection.defaultOptions,
        modelSelection: Binding<CodexModelSelection> = .constant(.appServerDefault),
        modelOptions: [CodexModelSelection] = CodexModelSelection.defaultOptions,
        reasoningSelection: Binding<CodexReasoningSelection> = .constant(.medium),
        slashCommands: [CodexSlashCommand] = CodexSlashCommand.observedCommands,
        isSending: Bool,
        canSend: Bool,
        canUsePlanMode: Bool = true,
        followUpHint: String? = nil,
        mentionResults: [FuzzyFileSearchResult] = [],
        onMentionQueryChanged: ((String?) -> Void)? = nil,
        onMentionSelected: ((FuzzyFileSearchResult) -> Void)? = nil,
        onSend: @escaping () -> Void,
        onInterrupt: @escaping () -> Void,
        onSlashCommandSelected: ((CodexSlashCommand) -> Void)? = nil,
        onAddMenuRoute: ((CodexComposerAddMenuRoute) -> Void)? = nil,
        onComposerChipClear: ((CodexComposerChipKind) -> Void)? = nil
    ) {
        self._draft = draft
        self._approvalSelection = approvalSelection
        self._isPlanModeEnabled = isPlanModeEnabled
        self.isGoalPursuitEnabled = isGoalPursuitEnabled
        self.approvalOptions = approvalOptions
        self._modelSelection = modelSelection
        self.modelOptions = modelOptions
        self._reasoningSelection = reasoningSelection
        self.slashCommands = slashCommands
        self.isSending = isSending
        self.canSend = canSend
        self.canUsePlanMode = canUsePlanMode
        self.followUpHint = followUpHint
        self.mentionResults = mentionResults
        self.onMentionQueryChanged = onMentionQueryChanged
        self.onMentionSelected = onMentionSelected
        self.onSend = onSend
        self.onInterrupt = onInterrupt
        self.onSlashCommandSelected = onSlashCommandSelected
        self.onAddMenuRoute = onAddMenuRoute
        self.onComposerChipClear = onComposerChipClear
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let slashQuery, !filteredSlashCommands.isEmpty {
                CodexSlashCommandPalette(
                    commands: filteredSlashCommands,
                    query: slashQuery,
                    onSelect: selectSlashCommand
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if mentionQuery != nil, !mentionResults.isEmpty {
                CodexMentionPalette(results: mentionResults, onSelect: selectMention)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            VStack(spacing: 8) {
                TextField("Ask Codex anything about this workspace...", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(theme.fonts.chat)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit(onSend)
                    .padding(.leading, 6)
                    .padding(.vertical, 6)

                HStack(spacing: 8) {
                    ComposerAddMenu(canUsePlanMode: canUsePlanMode, onRoute: handleAddMenuRoute)
                    ForEach(composerChips) { chip in
                        ComposerModeChip(chip: chip) {
                            clearComposerChip(chip.kind)
                        }
                    }
                    ComposerApprovalMenu(selection: $approvalSelection, options: approvalOptions)
                    ComposerModelMenu(model: $modelSelection, modelOptions: modelOptions, reasoning: $reasoningSelection)

                    Spacer(minLength: 0)

                    if let followUpHint {
                        Text(followUpHint)
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.textTertiary)
                            .lineLimit(1)
                            .transition(.opacity)
                    }

                    if isSending {
                        // The composer stays live during a run: send steers or
                        // queues the draft, stop interrupts the turn.
                        SendButton(enabled: canSend, action: onSend)
                        ComposerStopButton(action: onInterrupt)
                    } else {
                        SendButton(enabled: canSend, action: onSend)
                    }
                }
            }
            .padding(10)
            .codexGlass(RoundedRectangle(cornerRadius: theme.radii.composer, style: .continuous))
        }
        .onAppear { focused = true }
        .onChange(of: mentionQuery) { _, query in
            onMentionQueryChanged?(query)
        }
    }

    private var slashQuery: String? {
        CodexSlashCommand.query(from: draft)
    }

    private var mentionQuery: String? {
        CodexMentionQuery.query(from: draft)
    }

    private var filteredSlashCommands: [CodexSlashCommand] {
        CodexSlashCommand.filteredCommands(from: slashCommands, matching: draft)
    }

    private var composerChips: [CodexComposerChipModel] {
        CodexComposerAddMenuModel.chips(
            isGoalPursuitEnabled: isGoalPursuitEnabled,
            isPlanModeEnabled: isPlanModeEnabled
        )
    }

    private func handleAddMenuRoute(_ route: CodexComposerAddMenuRoute) {
        if let onAddMenuRoute {
            onAddMenuRoute(route)
            return
        }
        if route.hostActions.contains(.enablePlanMode) {
            isPlanModeEnabled = true
        }
    }

    private func clearComposerChip(_ kind: CodexComposerChipKind) {
        switch kind {
        case .goal:
            onComposerChipClear?(.goal)
        case .plan:
            isPlanModeEnabled = false
            onComposerChipClear?(.plan)
        }
    }

    private func selectSlashCommand(_ command: CodexSlashCommand) {
        draft = command.draftText ?? ""
        onSlashCommandSelected?(command)
    }

    private func selectMention(_ result: FuzzyFileSearchResult) {
        draft = CodexMentionQuery.applyingSelection(result.fileName, to: draft)
        onMentionSelected?(result)
    }
}

private struct ComposerAddMenu: View {
    let canUsePlanMode: Bool
    let onRoute: (CodexComposerAddMenuRoute) -> Void

    var body: some View {
        Menu {
            ForEach(CodexComposerAddMenuModel.observedItems(canUsePlanMode: canUsePlanMode)) { item in
                Button {
                    onRoute(CodexComposerAddMenuModel.route(itemID: item.id, canUsePlanMode: canUsePlanMode))
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                }
                .disabled(!item.isEnabled)
            }
        } label: {
            ComposerChipLabel(systemImage: "plus", title: nil)
        }
        .fixedSize()
        .help("Add files and more")
    }
}

private struct ComposerModeChip: View {
    let chip: CodexComposerChipModel
    let onClear: () -> Void

    var body: some View {
        Button(action: onClear) {
            ComposerChipLabel(systemImage: chip.kind.systemImage, title: chip.title)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chip.clearAccessibilityLabel)
        .help(chip.clearAccessibilityLabel)
    }
}

private extension CodexComposerChipKind {
    var systemImage: String {
        switch self {
        case .goal:
            return "target"
        case .plan:
            return "list.bullet.clipboard"
        }
    }
}

private struct ComposerApprovalMenu: View {
    @Binding var selection: CodexApprovalSelection
    let options: [CodexApprovalSelection]

    var body: some View {
        Menu {
            Text("How should Codex actions be approved?")
            Divider()
            ForEach(availableOptions) { option in
                Button {
                    selection = option
                } label: {
                    if selection == option {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
            }
        } label: {
            ComposerChipLabel(systemImage: "checkmark.seal.fill", title: selection.displayName)
        }
        .fixedSize()
        .help("Approval mode")
    }

    private var availableOptions: [CodexApprovalSelection] {
        options.isEmpty ? CodexApprovalSelection.defaultOptions : options
    }
}

private struct ComposerModelMenu: View {
    @Binding var model: CodexModelSelection
    let modelOptions: [CodexModelSelection]
    @Binding var reasoning: CodexReasoningSelection

    var body: some View {
        Menu {
            Section("Reasoning") {
                ForEach(availableReasoningOptions) { option in
                    Button {
                        reasoning = option
                    } label: {
                        if reasoning == option {
                            Label(option.displayName, systemImage: "checkmark")
                        } else {
                            Text(option.displayName)
                        }
                    }
                }
            }
            Divider()
            ForEach(availableModelOptions) { option in
                Button {
                    model = option
                    reconcileReasoning(for: option)
                } label: {
                    if model == option {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
            }
        } label: {
            ComposerChipLabel(systemImage: "sparkles", title: "\(model.displayName) \(reasoning.displayName)")
        }
        .fixedSize()
        .help("Model and reasoning")
        .onChange(of: model) { _, newModel in
            reconcileReasoning(for: newModel)
        }
    }

    private var availableModelOptions: [CodexModelSelection] {
        modelOptions.isEmpty ? CodexModelSelection.defaultOptions : modelOptions
    }

    private var availableReasoningOptions: [CodexReasoningSelection] {
        model.supportedReasoning.isEmpty ? CodexReasoningSelection.defaultOptions : model.supportedReasoning
    }

    private func reconcileReasoning(for model: CodexModelSelection) {
        let supported = model.supportedReasoning.isEmpty ? CodexReasoningSelection.defaultOptions : model.supportedReasoning
        if supported.contains(reasoning) { return }
        if let defaultReasoning = model.defaultReasoning, supported.contains(defaultReasoning) {
            reasoning = defaultReasoning
        } else {
            reasoning = supported.first ?? .medium
        }
    }
}

private struct ComposerChipLabel: View {
    @Environment(\.codexAgentTheme) private var theme

    let systemImage: String
    let title: String?

    var body: some View {
        HStack(spacing: title == nil ? 0 : 6) {
            Image(systemName: systemImage)
                .font(theme.fonts.caption)
            if let title {
                Text(title)
                    .font(theme.fonts.caption.weight(.medium))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(theme.colors.textSecondary)
        .frame(minWidth: title == nil ? 28 : 0, minHeight: 28)
        .padding(.horizontal, title == nil ? 0 : 10)
        .background(theme.colors.surfaceSunken.opacity(theme.effects.glassOpacity), in: Capsule())
        .overlay(Capsule().stroke(theme.colors.border, lineWidth: 1))
        .contentShape(Capsule())
    }
}

private struct ComposerIconButton: View {
    @Environment(\.codexAgentTheme) private var theme

    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(theme.fonts.label)
                .foregroundStyle(theme.colors.textSecondary)
                .frame(width: theme.spacing.iconLarge, height: theme.spacing.iconLarge)
                .background(theme.colors.surfaceSunken.opacity(theme.effects.textFaintOpacity), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct ComposerStopButton: View {
    @Environment(\.codexAgentTheme) private var theme

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "stop.fill")
                .font(theme.fonts.label)
                .foregroundStyle(theme.colors.danger)
                .frame(width: theme.spacing.iconLarge + 4, height: theme.spacing.iconLarge + 4)
                .background(theme.colors.surfaceSunken.opacity(theme.effects.textDimOpacity), in: Circle())
                .overlay(Circle().stroke(theme.colors.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Stop")
    }
}

/// Parses the trailing `@...` token from a draft, e.g. "fix @clien" -> "clien".
public enum CodexMentionQuery {
    public static func query(from draft: String) -> String? {
        guard let atIndex = draft.lastIndex(of: "@") else { return nil }
        // The token must start the draft or follow whitespace.
        if atIndex > draft.startIndex {
            let previous = draft[draft.index(before: atIndex)]
            guard previous.isWhitespace || previous.isNewline else { return nil }
        }
        let token = draft[draft.index(after: atIndex)...]
        guard !token.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return String(token)
    }

    /// Replaces the trailing `@token` in the draft with `@fileName `.
    public static func applyingSelection(_ fileName: String, to draft: String) -> String {
        guard let atIndex = draft.lastIndex(of: "@") else { return draft }
        return String(draft[..<atIndex]) + "@\(fileName) "
    }
}

private struct CodexMentionPalette: View {
    @Environment(\.codexAgentTheme) private var theme

    let results: [FuzzyFileSearchResult]
    let onSelect: (FuzzyFileSearchResult) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Files")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)

                ForEach(results.prefix(8)) { result in
                    Button {
                        onSelect(result)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: result.matchType == .directory ? "folder" : "doc.text")
                                .font(theme.fonts.label)
                                .foregroundStyle(theme.colors.textTertiary)
                                .frame(width: 18)
                            Text(result.fileName)
                                .font(theme.fonts.caption.weight(.semibold))
                                .foregroundStyle(theme.colors.textPrimary)
                            Text(result.path)
                                .font(theme.fonts.caption)
                                .foregroundStyle(theme.colors.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .frame(height: 29)
                        .padding(.horizontal, 10)
                        .background(
                            result.id == results.first?.id ? theme.colors.surfaceElevated.opacity(theme.effects.glassOpacity) : .clear,
                            in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(result.absolutePath)
                }
            }
            .padding(theme.spacing.rowGap)
        }
        .frame(maxWidth: 736, alignment: .leading)
        .frame(maxHeight: 280, alignment: .top)
        .codexGlass(RoundedRectangle(cornerRadius: theme.radii.composer, style: .continuous))
    }
}

private struct CodexSlashCommandPalette: View {
    @Environment(\.codexAgentTheme) private var theme

    let commands: [CodexSlashCommand]
    let query: String
    let onSelect: (CodexSlashCommand) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(sectionNames, id: \.self) { section in
                    if section != sectionNames.first {
                        Text(section)
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.textTertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 4)
                    }

                    ForEach(commands.filter { $0.section == section }) { command in
                        Button {
                            onSelect(command)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: command.systemImage)
                                    .font(theme.fonts.label)
                                    .foregroundStyle(theme.colors.textTertiary)
                                    .frame(width: 18)
                                Text(command.title)
                                    .font(theme.fonts.caption.weight(.semibold))
                                    .foregroundStyle(theme.colors.textPrimary)
                                Text(command.detail)
                                    .font(theme.fonts.caption)
                                    .foregroundStyle(theme.colors.textTertiary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if let scopeBadge = command.scopeBadge {
                                    Text(scopeBadge)
                                        .font(theme.fonts.caption)
                                        .foregroundStyle(theme.colors.textTertiary)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(theme.colors.surfaceSunken.opacity(theme.effects.glassOpacity), in: Capsule())
                                }
                            }
                            .frame(height: 29)
                            .padding(.horizontal, 10)
                            .background(
                                command.id == highlightedCommandID ? theme.colors.surfaceElevated.opacity(theme.effects.glassOpacity) : .clear,
                                in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .help(command.detail)
                    }
                }
            }
            .padding(theme.spacing.rowGap)
        }
        .frame(maxWidth: 736, alignment: .leading)
        .frame(maxHeight: 320, alignment: .top)
        .codexGlass(RoundedRectangle(cornerRadius: theme.radii.composer, style: .continuous))
    }

    private var highlightedCommandID: String? {
        if query.isEmpty { return commands.first?.id }
        return commands.first?.id
    }

    private var sectionNames: [String] {
        var names: [String] = []
        for command in commands where !names.contains(command.section) {
            names.append(command.section)
        }
        return names
    }
}

private struct SendButton: View {
    @Environment(\.codexAgentTheme) private var theme

    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(theme.fonts.chat)
                .foregroundStyle(enabled ? theme.colors.onAccent : theme.colors.textTertiary)
                .frame(width: theme.spacing.iconLarge + 4, height: theme.spacing.iconLarge + 4)
        }
        .buttonStyle(.plain)
        .background {
            if enabled {
                Circle().fill(theme.colors.accent)
            } else {
                Circle().fill(theme.colors.surfaceSunken)
            }
        }
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(!enabled)
        .animation(.snappy(duration: theme.animations.snappyDuration), value: enabled)
    }
}
