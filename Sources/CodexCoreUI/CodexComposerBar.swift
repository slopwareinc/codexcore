import SwiftUI
import CodexCore
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

public struct CodexComposerBar: View {
    @Environment(\.codexAgentTheme) private var theme

    @Binding private var draft: String
    @Binding private var referencedFiles: [CodexReferencedFile]
    @Binding private var responseAnnotations: [CodexResponseTextAnnotation]
    @Binding private var approvalSelection: CodexApprovalSelection
    @Binding private var isPlanModeEnabled: Bool
    private let isGoalPursuitEnabled: Bool
    private let approvalOptions: [CodexApprovalSelection]
    @Binding private var modelSelection: CodexModelSelection
    @Binding private var isModelMenuPresented: Bool
    @Binding private var focusRequest: Bool
    private let modelOptions: [CodexModelSelection]
    private let modelPickerStyle: CodexComposerModelPickerStyle
    @Binding private var serviceTierSelection: CodexServiceTierSelection
    @Binding private var reasoningSelection: CodexReasoningSelection
    private let slashCommands: [CodexSlashCommand]
    private let mcpServers: [CodexMCPServerStatus]
    private let isLoadingMCPServers: Bool
    private let mcpErrorMessage: String?
    private let isSending: Bool
    private let canSend: Bool
    private let canUsePlanMode: Bool
    private let followUpHint: String?
    private let mentionResults: [FuzzyFileSearchResult]
    private let onMentionQueryChanged: ((String?) -> Void)?
    private let onMentionSelected: ((FuzzyFileSearchResult) -> Void)?
    private let onSend: () -> Void
    private let onInterrupt: () -> Void
    private let dictationState: CodexComposerDictationState
    private let dictationActions: CodexComposerDictationActions?
    private let onStartVoiceChat: (() -> Void)?
    private let voiceChatLabel: String
    private let onSlashCommandSelected: ((CodexSlashCommand) -> Void)?
    private let onOpenMCPDetails: (() -> Void)?
    private let onRefreshMCPServers: (() -> Void)?
    private let onAddMenuRoute: ((CodexComposerAddMenuRoute) -> Void)?
    private let onComposerChipClear: ((CodexComposerChipKind) -> Void)?
    private let onFilesDropped: (@MainActor @Sendable ([URL]) -> Void)?
    private let placeholder: String
    private let isCompact: Bool
    private let voiceFocusRequest: Int
    @FocusState private var focused: Bool
    @State private var slashPaletteSelection = CodexComposerPaletteSelection()
    @State private var activeCommandSelector: CodexComposerCommandSelector?
    @State private var commandSelectorSelection = CodexComposerPaletteSelection()
    @State private var isSlashPaletteDismissed = false
    @State private var isMCPStatusPalettePresented = false
    @State private var isFileDropTargeted = false

    public init(
        draft: Binding<String>,
        referencedFiles: Binding<[CodexReferencedFile]> = .constant([]),
        responseAnnotations: Binding<[CodexResponseTextAnnotation]> = .constant([]),
        placeholder: String = "Ask Codex anything about this workspace...",
        isCompact: Bool = false,
        approvalSelection: Binding<CodexApprovalSelection> = .constant(.askForApproval),
        isPlanModeEnabled: Binding<Bool> = .constant(false),
        isGoalPursuitEnabled: Bool = false,
        approvalOptions: [CodexApprovalSelection] = CodexApprovalSelection.defaultOptions,
        modelSelection: Binding<CodexModelSelection> = .constant(.appServerDefault),
        modelOptions: [CodexModelSelection] = CodexModelSelection.defaultOptions,
        isModelMenuPresented: Binding<Bool> = .constant(false),
        focusRequest: Binding<Bool> = .constant(false),
        modelPickerStyle: CodexComposerModelPickerStyle = .menu,
        serviceTierSelection: Binding<CodexServiceTierSelection> = .constant(.standard),
        reasoningSelection: Binding<CodexReasoningSelection> = .constant(.medium),
        slashCommands: [CodexSlashCommand] = CodexSlashCommand.observedCommands,
        mcpServers: [CodexMCPServerStatus] = [],
        isLoadingMCPServers: Bool = false,
        mcpErrorMessage: String? = nil,
        isSending: Bool,
        canSend: Bool,
        canUsePlanMode: Bool = true,
        followUpHint: String? = nil,
        mentionResults: [FuzzyFileSearchResult] = [],
        onMentionQueryChanged: ((String?) -> Void)? = nil,
        onMentionSelected: ((FuzzyFileSearchResult) -> Void)? = nil,
        onSend: @escaping () -> Void,
        onInterrupt: @escaping () -> Void,
        dictationState: CodexComposerDictationState = .init(),
        dictationActions: CodexComposerDictationActions? = nil,
        onStartVoiceChat: (() -> Void)? = nil,
        voiceChatLabel: String = "Start new voice chat",
        onSlashCommandSelected: ((CodexSlashCommand) -> Void)? = nil,
        onOpenMCPDetails: (() -> Void)? = nil,
        onRefreshMCPServers: (() -> Void)? = nil,
        onAddMenuRoute: ((CodexComposerAddMenuRoute) -> Void)? = nil,
        onComposerChipClear: ((CodexComposerChipKind) -> Void)? = nil,
        onFilesDropped: (@MainActor @Sendable ([URL]) -> Void)? = nil,
        voiceFocusRequest: Int = 0
    ) {
        self._draft = draft
        self._referencedFiles = referencedFiles
        self._responseAnnotations = responseAnnotations
        self.placeholder = placeholder
        self.isCompact = isCompact
        self.voiceFocusRequest = voiceFocusRequest
        self._approvalSelection = approvalSelection
        self._isPlanModeEnabled = isPlanModeEnabled
        self.isGoalPursuitEnabled = isGoalPursuitEnabled
        self.approvalOptions = approvalOptions
        self._modelSelection = modelSelection
        self._isModelMenuPresented = isModelMenuPresented
        self._focusRequest = focusRequest
        self.modelOptions = modelOptions
        self.modelPickerStyle = modelPickerStyle
        self._serviceTierSelection = serviceTierSelection
        self._reasoningSelection = reasoningSelection
        self.slashCommands = slashCommands
        self.mcpServers = mcpServers
        self.isLoadingMCPServers = isLoadingMCPServers
        self.mcpErrorMessage = mcpErrorMessage
        self.isSending = isSending
        self.canSend = canSend
        self.canUsePlanMode = canUsePlanMode
        self.followUpHint = followUpHint
        self.mentionResults = mentionResults
        self.onMentionQueryChanged = onMentionQueryChanged
        self.onMentionSelected = onMentionSelected
        self.onSend = onSend
        self.onInterrupt = onInterrupt
        self.dictationState = dictationState
        self.dictationActions = dictationActions
        self.onStartVoiceChat = onStartVoiceChat
        self.voiceChatLabel = voiceChatLabel
        self.onSlashCommandSelected = onSlashCommandSelected
        self.onOpenMCPDetails = onOpenMCPDetails
        self.onRefreshMCPServers = onRefreshMCPServers
        self.onAddMenuRoute = onAddMenuRoute
        self.onComposerChipClear = onComposerChipClear
        self.onFilesDropped = onFilesDropped
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isMCPStatusPalettePresented {
                CodexComposerMCPStatusPalette(
                    model: mcpStatusPaletteModel,
                    onOpenDetails: onOpenMCPDetails,
                    onRefresh: onRefreshMCPServers,
                    onClose: {
                        isMCPStatusPalettePresented = false
                    }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if let activeCommandSelector, !activeSelectorRows.isEmpty {
                CodexComposerInlineSelectorPalette(
                    title: activeCommandSelector.title,
                    rows: activeSelectorRows,
                    selectedID: commandSelectorSelection.selectedID,
                    onSelect: selectActiveSelectorRow
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if let slashQuery, isSlashPaletteVisible {
                CodexSlashCommandPalette(
                    commands: filteredSlashCommands,
                    query: slashQuery,
                    selectedCommandID: slashPaletteSelection.selectedID,
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

            VStack(alignment: .leading, spacing: isCompact ? 4 : 8) {
                if let errorMessage = dictationState.errorMessage {
                    ComposerDictationErrorBanner(
                        message: errorMessage,
                        onDismiss: dictationActions?.dismissError
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                if !referencedFiles.isEmpty {
                    CodexComposerFileReferenceStrip(
                        files: referencedFiles,
                        onRemove: removeReferencedFile
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if !responseAnnotations.isEmpty {
                    CodexResponseAnnotationAttachmentView(annotations: $responseAnnotations)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(theme.fonts.chat)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1...(isCompact ? 3 : 6))
                    .focused($focused)
                    .onSubmit(handleSubmit)
                    .padding(.leading, 6)
                    .padding(.vertical, isCompact ? 3 : 6)

                if dictationState.isRecording, let dictationActions {
                    ComposerDictationFooter(
                        state: dictationState,
                        actions: dictationActions,
                        isCompact: isCompact
                    )
                } else {
                    HStack(spacing: isCompact ? 5 : 8) {
                        ComposerAddMenu(canUsePlanMode: canUsePlanMode, onRoute: handleAddMenuRoute)
                        ForEach(composerChips) { chip in
                            ComposerModeChip(chip: chip) {
                                clearComposerChip(chip.kind)
                            }
                        }
                        ComposerApprovalMenu(selection: $approvalSelection, options: approvalOptions)

                        Spacer(minLength: 0)

                        if let followUpHint {
                            Text(followUpHint)
                                .font(theme.fonts.caption)
                                .foregroundStyle(theme.colors.textTertiary)
                                .lineLimit(1)
                                .transition(.opacity)
                        }

                        ComposerModelMenu(
                            model: $modelSelection,
                            modelOptions: modelOptions,
                            serviceTier: $serviceTierSelection,
                            reasoning: $reasoningSelection,
                            isPresented: $isModelMenuPresented
                        )
                        ComposerMicrophoneButton(
                            phase: dictationState.phase,
                            actions: dictationActions
                        )

                        if isSending {
                            // The composer stays live during a run: send steers or
                            // queues the draft, stop interrupts the turn.
                            SendButton(enabled: canSend, action: onSend)
                            ComposerStopButton(action: onInterrupt)
                        } else if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                  referencedFiles.isEmpty,
                                  responseAnnotations.isEmpty,
                                  let onStartVoiceChat {
                            ComposerVoiceButton(label: voiceChatLabel, action: onStartVoiceChat)
                        } else {
                            SendButton(enabled: canSend, action: onSend)
                        }
                    }
                }
            }
            .padding(isCompact ? 6 : 10)
            .codexGlass(RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous), role: .panel)
            .codexFileDropTarget(
                isTargeted: $isFileDropTargeted,
                isEnabled: onFilesDropped != nil,
                onDrop: handleFileDrop
            )
        }
        .onAppear {
            reconcilePaletteSelections()
            consumeFocusRequest()
            if voiceFocusRequest > 0 { focused = true }
        }
        .onChange(of: focusRequest) { _, _ in consumeFocusRequest() }
        .onChange(of: voiceFocusRequest) { _, _ in
            focused = true
        }
        .onChange(of: draft) { _, _ in
            isSlashPaletteDismissed = false
            reconcilePaletteSelections()
        }
        .onChange(of: filteredSlashCommandIDs) { _, _ in
            reconcilePaletteSelections()
        }
        .onChange(of: activeCommandSelector) { _, _ in
            reconcilePaletteSelections()
        }
        .onChange(of: activeSelectorRowIDs) { _, _ in
            reconcilePaletteSelections()
        }
        .onChange(of: mentionQuery) { _, query in
            onMentionQueryChanged?(query)
        }
        .onExitCommand {
            guard dictationState.isRecording else { return }
            dictationActions?.abort()
        }
        .background {
            #if canImport(AppKit)
            CodexComposerPaletteKeyMonitor(
                isEnabled: isAnyPaletteVisible,
                onKeyDown: handlePaletteKey
            )
            #else
            EmptyView()
            #endif
        }
    }

    private func handleFileDrop(_ urls: [URL]) {
        onFilesDropped?(urls)
    }

    private func removeReferencedFile(_ file: CodexReferencedFile) {
        referencedFiles.removeAll { $0.id == file.id }
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

    private var filteredSlashCommandIDs: [String] {
        filteredSlashCommands.map(\.id)
    }

    private var isSlashPaletteVisible: Bool {
        slashQuery != nil && activeCommandSelector == nil && !isSlashPaletteDismissed && !filteredSlashCommands.isEmpty
    }

    private var modelMenuState: CodexComposerModelMenuState {
        CodexComposerModelMenuModel.state(
            modelOptions: modelOptions,
            selectedModel: modelSelection,
            selectedReasoning: reasoningSelection
        )
    }

    private var activeSelectorRows: [CodexComposerSelectorRow] {
        guard let activeCommandSelector else { return [] }
        return selectorRows(for: activeCommandSelector)
    }

    private var activeSelectorRowIDs: [String] {
        activeSelectorRows.map(\.id)
    }

    private var activeSelectableRowIDs: [String] {
        activeSelectorRows.filter(\.isEnabled).map(\.id)
    }

    private var isAnyPaletteVisible: Bool {
        isMCPStatusPalettePresented || isSlashPaletteVisible || (activeCommandSelector != nil && !activeSelectorRows.isEmpty)
    }

    private var mcpStatusPaletteModel: CodexMCPStatusPanelModel {
        CodexMCPStatusPanelModel(
            servers: mcpServers,
            isLoading: isLoadingMCPServers,
            errorMessage: mcpErrorMessage
        )
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

    private func handleSubmit() {
        if selectHighlightedPaletteRow() {
            return
        }
        onSend()
    }

    private func handlePaletteKey(_ key: CodexComposerPaletteKey) -> Bool {
        guard isAnyPaletteVisible else { return false }

        switch key {
        case .moveDown:
            if activeCommandSelector != nil {
                commandSelectorSelection.moveDown(availableIDs: activeSelectableRowIDs)
                return true
            }
            if isSlashPaletteVisible {
                slashPaletteSelection.moveDown(availableIDs: filteredSlashCommandIDs)
                return true
            }
        case .moveUp:
            if activeCommandSelector != nil {
                commandSelectorSelection.moveUp(availableIDs: activeSelectableRowIDs)
                return true
            }
            if isSlashPaletteVisible {
                slashPaletteSelection.moveUp(availableIDs: filteredSlashCommandIDs)
                return true
            }
        case .select:
            if isMCPStatusPalettePresented {
                openMCPDetailsFromPalette()
                return true
            }
            return selectHighlightedPaletteRow()
        case .dismiss:
            return dismissActivePalette()
        }

        return false
    }

    @discardableResult
    private func selectHighlightedPaletteRow() -> Bool {
        if activeCommandSelector != nil {
            let selectedID = commandSelectorSelection.selectedID ?? activeSelectorRows.first?.id
            guard let selectedID, let row = activeSelectorRows.first(where: { $0.id == selectedID }) else { return false }
            selectActiveSelectorRow(row)
            return true
        }

        if isSlashPaletteVisible {
            let selectedID = slashPaletteSelection.selectedID ?? filteredSlashCommands.first?.id
            guard let selectedID, let command = filteredSlashCommands.first(where: { $0.id == selectedID }) else { return false }
            selectSlashCommand(command)
            return true
        }

        return false
    }

    @discardableResult
    private func dismissActivePalette() -> Bool {
        if isMCPStatusPalettePresented {
            isMCPStatusPalettePresented = false
            return true
        }

        if activeCommandSelector != nil {
            activeCommandSelector = nil
            commandSelectorSelection.clear()
            return true
        }

        if isSlashPaletteVisible {
            isSlashPaletteDismissed = true
            slashPaletteSelection.clear()
            return true
        }

        return false
    }

    private func consumeFocusRequest() {
        guard focusRequest else { return }
        focused = true
        focusRequest = false
    }

    private func reconcilePaletteSelections() {
        if isSlashPaletteVisible {
            slashPaletteSelection.reconcile(availableIDs: filteredSlashCommandIDs)
        } else {
            slashPaletteSelection.clear()
        }

        if activeCommandSelector != nil {
            commandSelectorSelection.reconcile(availableIDs: activeSelectableRowIDs)
        } else {
            commandSelectorSelection.clear()
        }
    }

    private func selectSlashCommand(_ command: CodexSlashCommand) {
        guard command.isEnabled,
              let invocation = CodexSlashCommand.invocation(from: draft),
              !command.requiresEmptyComposer || !invocation.hasOtherContent else {
            return
        }
        slashPaletteSelection.clear()
        isSlashPaletteDismissed = false
        draft = invocation.replacementDraft

        switch command.id {
        case "model":
            openCommandSelector(.model)
        case "reasoning":
            openCommandSelector(.reasoning)
        case "mcp":
            openMCPStatusPalette(command)
        default:
            activeCommandSelector = nil
            isMCPStatusPalettePresented = false
            onSlashCommandSelected?(command)
        }
    }

    private func openCommandSelector(_ selector: CodexComposerCommandSelector) {
        isMCPStatusPalettePresented = false
        activeCommandSelector = selector
        commandSelectorSelection.reconcile(availableIDs: selectorRows(for: selector).filter(\.isEnabled).map(\.id))
    }

    private func openMCPStatusPalette(_ command: CodexSlashCommand) {
        activeCommandSelector = nil
        isMCPStatusPalettePresented = true
        onSlashCommandSelected?(command)
    }

    private func openMCPDetailsFromPalette() {
        guard let onOpenMCPDetails else { return }
        isMCPStatusPalettePresented = false
        onOpenMCPDetails()
    }

    private func selectActiveSelectorRow(_ row: CodexComposerSelectorRow) {
        guard row.isEnabled else { return }

        if let model = row.model {
            selectModel(model)
        } else if let reasoning = row.reasoning {
            reasoningSelection = reasoning
        } else if let serviceTier = row.serviceTier {
            serviceTierSelection = serviceTier
        }

        activeCommandSelector = nil
        commandSelectorSelection.clear()
    }

    private func selectModel(_ selection: CodexModelSelection) {
        modelSelection = selection
        reasoningSelection = CodexComposerModelMenuModel.reconciledReasoning(reasoningSelection, for: selection)
        let reconciledTier = serviceTierSelection.reconciled(for: selection)
        if reconciledTier != serviceTierSelection {
            serviceTierSelection = reconciledTier
        }
    }

    private func selectorRows(for selector: CodexComposerCommandSelector) -> [CodexComposerSelectorRow] {
        let state = modelMenuState
        switch selector {
        case .model:
            let modelRows = state.gptFamilyItems.map { item in
                CodexComposerSelectorRow(
                    id: "model:\(item.id)",
                    section: state.gptFamilyTitle,
                    title: item.title,
                    detail: item.detail ?? (item.isSelected ? "Current model" : "Model"),
                    systemImage: item.isSelected ? "checkmark" : "sparkles",
                    isSelected: item.isSelected,
                    isEnabled: true,
                    model: item.selection
                )
            }
            let speedSelections = [CodexServiceTierSelection.standard]
                + modelSelection.serviceTiers.map(CodexServiceTierSelection.tier)
            let speedRows = speedSelections.map { selection in
                CodexComposerSelectorRow(
                    id: "speed:\(selection.id)",
                    section: state.speedTitle,
                    title: selection.displayName,
                    detail: selection.detail,
                    systemImage: selection == serviceTierSelection
                        ? "checkmark"
                        : "bolt.fill",
                    isSelected: selection == serviceTierSelection,
                    isEnabled: true,
                    serviceTier: selection
                )
            }
            return modelRows + speedRows
        case .reasoning:
            return state.reasoningItems.map { item in
                CodexComposerSelectorRow(
                    id: "reasoning:\(item.selection.id)",
                    section: state.reasoningTitle,
                    title: item.title,
                    detail: item.isSelected ? "Current reasoning" : "Reasoning effort",
                    systemImage: item.isSelected ? "checkmark" : "brain",
                    isSelected: item.isSelected,
                    isEnabled: true,
                    reasoning: item.selection
                )
            }
        }
    }

    private func selectMention(_ result: FuzzyFileSearchResult) {
        activeCommandSelector = nil
        isMCPStatusPalettePresented = false
        draft = CodexMentionQuery.applyingSelection(result.fileName, to: draft)
        onMentionSelected?(result)
    }
}

private enum CodexComposerCommandSelector: Equatable {
    case model
    case reasoning

    var title: String {
        switch self {
        case .model: return "Model"
        case .reasoning: return "Reasoning"
        }
    }
}

private struct CodexComposerSelectorRow: Identifiable, Equatable {
    let id: String
    let section: String
    let title: String
    let detail: String
    let systemImage: String
    let isSelected: Bool
    let isEnabled: Bool
    let model: CodexModelSelection?
    let reasoning: CodexReasoningSelection?
    let serviceTier: CodexServiceTierSelection?

    init(
        id: String,
        section: String,
        title: String,
        detail: String,
        systemImage: String,
        isSelected: Bool,
        isEnabled: Bool,
        model: CodexModelSelection? = nil,
        reasoning: CodexReasoningSelection? = nil,
        serviceTier: CodexServiceTierSelection? = nil
    ) {
        self.id = id
        self.section = section
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.model = model
        self.reasoning = reasoning
        self.serviceTier = serviceTier
    }
}

private enum CodexComposerPaletteKey: Equatable {
    case moveDown
    case moveUp
    case select
    case dismiss
}

#if canImport(AppKit)
private struct CodexComposerPaletteKeyMonitor: NSViewRepresentable {
    var isEnabled: Bool
    var onKeyDown: (CodexComposerPaletteKey) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, onKeyDown: onKeyDown)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onKeyDown = onKeyDown
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onKeyDown = onKeyDown
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        var isEnabled: Bool
        var onKeyDown: (CodexComposerPaletteKey) -> Bool
        private var monitor: Any?

        init(isEnabled: Bool, onKeyDown: @escaping (CodexComposerPaletteKey) -> Bool) {
            self.isEnabled = isEnabled
            self.onKeyDown = onKeyDown
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard
                    let self,
                    isEnabled,
                    let key = Self.paletteKey(for: event)
                else {
                    return event
                }

                return onKeyDown(key) ? nil : event
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        deinit {
            uninstall()
        }

        private static func paletteKey(for event: NSEvent) -> CodexComposerPaletteKey? {
            let ignoredNavigationModifiers: NSEvent.ModifierFlags = [.function, .numericPad]
            let modifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting(ignoredNavigationModifiers)

            switch event.keyCode {
            case 125:
                guard modifiers.isEmpty else { return nil }
                return .moveDown
            case 126:
                guard modifiers.isEmpty else { return nil }
                return .moveUp
            case 36, 76:
                guard modifiers.isEmpty else { return nil }
                return .select
            case 53:
                guard modifiers.isEmpty else { return nil }
                return .dismiss
            default:
                return nil
            }
        }
    }
}
#endif

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
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
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
    @Environment(\.codexAgentTheme) private var theme

    @Binding var selection: CodexApprovalSelection
    let options: [CodexApprovalSelection]
    @State private var isFullAccessConfirmationPresented = false

    var body: some View {
        Menu {
            Text("How should Codex actions be approved?")
            Divider()
            ForEach(options) { option in
                Button {
                    switch CodexPermissionSelectionDecision.resolve(
                        current: selection,
                        requested: option
                    ) {
                    case .apply(let selection):
                        self.selection = selection
                    case .confirmFullAccess:
                        isFullAccessConfirmationPresented = true
                    }
                } label: {
                    if selection == option {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
            }
        } label: {
            ComposerChipLabel(systemImage: "exclamationmark.shield", title: selection.displayName, tint: .orange)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(options.isEmpty)
        .help(options.isEmpty ? "No permission profile changes available" : "Approval mode")
        .codexFullAccessConfirmation(
            isPresented: $isFullAccessConfirmationPresented,
            onConfirm: { selection = .fullAccess }
        )
    }

}

public struct ComposerModelMenu: View {
    @Binding public var model: CodexModelSelection
    public let modelOptions: [CodexModelSelection]
    @Binding public var serviceTier: CodexServiceTierSelection
    @Binding public var reasoning: CodexReasoningSelection
    @Binding public var isPresented: Bool

    public init(
        model: Binding<CodexModelSelection>,
        modelOptions: [CodexModelSelection] = CodexModelSelection.defaultOptions,
        serviceTier: Binding<CodexServiceTierSelection> = .constant(.standard),
        reasoning: Binding<CodexReasoningSelection>,
        isPresented: Binding<Bool> = .constant(false)
    ) {
        self._model = model
        self.modelOptions = modelOptions
        self._serviceTier = serviceTier
        self._reasoning = reasoning
        self._isPresented = isPresented
    }

    public var body: some View {
        ComposerModelGridPicker(
            model: $model,
            modelOptions: modelOptions,
            serviceTier: $serviceTier,
            reasoning: $reasoning,
            isPresented: $isPresented
        )
        .onChange(of: model) { _, newModel in
            reconcileReasoning(for: newModel)
            let reconciledTier = serviceTier.reconciled(for: newModel)
            if reconciledTier != serviceTier {
                serviceTier = reconciledTier
            }
        }
    }

    private func selectModel(_ selection: CodexModelSelection) {
        model = selection
        reasoning = CodexComposerModelMenuModel.reconciledReasoning(reasoning, for: selection)
        let reconciledTier = serviceTier.reconciled(for: selection)
        if reconciledTier != serviceTier {
            serviceTier = reconciledTier
        }
    }

    private func reconcileReasoning(for model: CodexModelSelection) {
        reasoning = CodexComposerModelMenuModel.reconciledReasoning(reasoning, for: model)
    }
}

public struct ComposerChipLabel: View {
    @Environment(\.codexAgentTheme) private var theme

    public let systemImage: String
    public let title: String?
    public let tint: Color?

    public init(systemImage: String, title: String?, tint: Color? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: title == nil ? 0 : 6) {
            Image(systemName: systemImage)
                .font(theme.fonts.caption)
            if let title {
                Text(title)
                    .font(theme.fonts.caption.weight(.medium))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(tint ?? theme.colors.textSecondary)
        .frame(minWidth: title == nil ? 28 : 0, minHeight: 28)
        .padding(.horizontal, title == nil ? 0 : 4)
        .contentShape(Rectangle())
    }
}

private struct ComposerStopButton: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var tapCount = 0

    let action: () -> Void

    var body: some View {
        Button {
            tapCount &+= 1
            action()
        } label: {
            Image(systemName: "stop.fill")
                .font(theme.fonts.label)
                .foregroundStyle(theme.colors.danger)
                .frame(width: theme.spacing.iconLarge + 4, height: theme.spacing.iconLarge + 4)
                .background(theme.colors.surfaceSunken.opacity(theme.effects.textDimOpacity), in: Circle())
                .overlay(Circle().stroke(theme.colors.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel(CodexComposerAccessibility.stopButtonLabel)
        .help(CodexComposerAccessibility.stopButtonHelp)
        .sensoryFeedback(.impact(weight: .medium), trigger: tapCount)
    }
}

private struct ComposerVoiceButton: View {
    @Environment(\.codexAgentTheme) private var theme
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "waveform")
                .font(theme.fonts.label.weight(.semibold))
                .foregroundStyle(theme.colors.canvas)
                .frame(
                    width: theme.spacing.iconLarge + 4,
                    height: theme.spacing.iconLarge + 4
                )
                .background(theme.colors.textPrimary, in: Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
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
        .codexGlass(RoundedRectangle(cornerRadius: theme.radii.composer, style: .continuous), role: .panel)
    }
}

private struct CodexSlashCommandPalette: View {
    @Environment(\.codexAgentTheme) private var theme

    let commands: [CodexSlashCommand]
    let query: String
    let selectedCommandID: String?
    let onSelect: (CodexSlashCommand) -> Void

    var body: some View {
        ScrollViewReader { proxy in
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
                                    command.id == selectedCommandID ? theme.colors.surfaceElevated.opacity(theme.effects.glassOpacity) : .clear,
                                    in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                                )
                            }
                            .id(command.id)
                            .buttonStyle(.plain)
                            .help(command.detail)
                        }
                    }
                }
                .padding(theme.spacing.rowGap)
            }
            .onChange(of: selectedCommandID) { _, id in
                guard let id else { return }
                withAnimation(.snappy(duration: theme.animations.snappyDuration)) {
                    proxy.scrollTo(id, anchor: .center)
                                }
                            }
        }
        .frame(maxWidth: 736, alignment: .leading)
        .frame(maxHeight: 320, alignment: .top)
        .codexGlass(RoundedRectangle(cornerRadius: theme.radii.composer, style: .continuous), role: .panel)
    }

    private var sectionNames: [String] {
        var names: [String] = []
        for command in commands where !names.contains(command.section) {
            names.append(command.section)
        }
        return names
    }
}

private struct CodexComposerMCPStatusPalette: View {
    @Environment(\.codexAgentTheme) private var theme

    let model: CodexMCPStatusPanelModel
    let onOpenDetails: (() -> Void)?
    let onRefresh: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "server.rack")
                    .font(theme.fonts.label)
                    .foregroundStyle(theme.colors.textTertiary)
                    .frame(width: 18)

                Text(model.title)
                    .font(theme.fonts.caption.weight(.semibold))
                    .foregroundStyle(theme.colors.textPrimary)

                Text(model.detail)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let onRefresh {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.colors.textSecondary)
                    .help("Refresh MCP servers")
                }

                if let onOpenDetails {
                    Button {
                        onClose()
                        onOpenDetails()
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.colors.textSecondary)
                    .help("Open MCP details")
                }

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.colors.textTertiary)
                .help("Close")
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)

            if !model.rows.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.rows) { row in
                            serverRow(row)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 188, alignment: .top)
            }
        }
        .frame(maxWidth: 736, alignment: .leading)
        .codexGlass(RoundedRectangle(cornerRadius: theme.radii.composer, style: .continuous), role: .panel)
    }

    private func serverRow(_ row: CodexMCPStatusPanelServerRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.enabledLabel == "Enabled" ? "checkmark.circle" : "minus.circle")
                .font(theme.fonts.label)
                .foregroundStyle(row.enabledLabel == "Enabled" ? theme.colors.success : theme.colors.textTertiary)
                .frame(width: 18)

            Text(row.displayName)
                .font(theme.fonts.caption.weight(.semibold))
                .foregroundStyle(theme.colors.textPrimary)
                .lineLimit(1)

            Text(row.authLabel)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textTertiary)
                .lineLimit(1)

            Text(row.startupLabel)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textTertiary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(row.inventorySummary)
                .font(theme.fonts.micro)
                .foregroundStyle(theme.colors.textTertiary)
                .lineLimit(1)
        }
        .frame(height: 29)
        .padding(.horizontal, 10)
        .background(theme.colors.surfaceElevated.opacity(theme.effects.textFaintOpacity), in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
        .help(row.name)
    }
}

private struct CodexComposerInlineSelectorPalette: View {
    @Environment(\.codexAgentTheme) private var theme

    let title: String
    let rows: [CodexComposerSelectorRow]
    let selectedID: String?
    let onSelect: (CodexComposerSelectorRow) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.top, 4)

                    ForEach(sectionNames, id: \.self) { section in
                        if section != sectionNames.first {
                            Text(section)
                                .font(theme.fonts.caption)
                                .foregroundStyle(theme.colors.textTertiary)
                                .padding(.horizontal, 10)
                                .padding(.top, 4)
                        }

                        ForEach(rows.filter { $0.section == section }) { row in
                            Button {
                                onSelect(row)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: row.systemImage)
                                        .font(theme.fonts.label)
                                        .foregroundStyle(row.isEnabled ? theme.colors.textTertiary : theme.colors.textTertiary.opacity(0.55))
                                        .frame(width: 18)
                                    Text(row.title)
                                        .font(theme.fonts.caption.weight(.semibold))
                                        .foregroundStyle(row.isEnabled ? theme.colors.textPrimary : theme.colors.textTertiary)
                                    Text(row.detail)
                                        .font(theme.fonts.caption)
                                        .foregroundStyle(theme.colors.textTertiary)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    if row.isSelected {
                                        Image(systemName: "checkmark")
                                            .font(theme.fonts.caption.weight(.semibold))
                                            .foregroundStyle(theme.colors.accent)
                                    }
                                }
                                .frame(height: 29)
                                .padding(.horizontal, 10)
                                .background(
                                    row.id == selectedID ? theme.colors.surfaceElevated.opacity(theme.effects.glassOpacity) : .clear,
                                    in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                                )
                                .opacity(row.isEnabled ? 1 : 0.55)
                            }
                            .id(row.id)
                            .buttonStyle(.plain)
                            .disabled(!row.isEnabled)
                            .help(row.detail)
                        }
                    }
                }
                .padding(theme.spacing.rowGap)
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.snappy(duration: theme.animations.snappyDuration)) {
                    proxy.scrollTo(id, anchor: .center)
                                }
                            }
        }
        .frame(maxWidth: 736, alignment: .leading)
        .frame(maxHeight: 320, alignment: .top)
        .codexGlass(RoundedRectangle(cornerRadius: theme.radii.composer, style: .continuous), role: .panel)
    }

    private var sectionNames: [String] {
        var names: [String] = []
        for row in rows where !names.contains(row.section) {
            names.append(row.section)
        }
        return names
    }
}

struct CodexQueuedFollowUpStack: View {
    @Environment(\.codexAgentTheme) private var theme

    let submissions: [CodexComposerSubmission]
    let canSteer: Bool
    let onSteer: (String) -> Void
    let onRemove: (String) -> Void
    let onEdit: (String) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(submissions, id: \.clientID) { submission in
                queuedRow(submission)
            }
        }
        .animation(.snappy(duration: theme.animations.snappyDuration), value: submissions.map(\.clientID))
    }

    private func queuedRow(_ submission: CodexComposerSubmission) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.turn.down.right")
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textTertiary)

            VStack(alignment: .leading, spacing: 3) {
                Text(queuedTitle(for: submission))
                    .font(theme.fonts.chat)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !submission.responseAnnotations.isEmpty {
                    Label(
                        annotationSummary(for: submission.responseAnnotations.count),
                        systemImage: "text.bubble"
                    )
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                } else if !submission.referencedFiles.isEmpty {
                    Label(
                        "\(submission.referencedFiles.count) attachment\(submission.referencedFiles.count == 1 ? "" : "s")",
                        systemImage: "paperclip"
                    )
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                }
            }

            Button {
                onSteer(submission.clientID)
            } label: {
                Label("Steer", systemImage: "arrow.turn.down.right")
                    .font(theme.fonts.chat.weight(.medium))
                    .foregroundStyle(canSteer ? theme.colors.textSecondary : theme.colors.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(!canSteer)
            .help(canSteer ? "Send this message to the active turn" : "No active turn to steer")

            Button {
                onRemove(submission.clientID)
            } label: {
                Image(systemName: "trash")
                    .font(theme.fonts.chat)
                    .foregroundStyle(theme.colors.textTertiary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove queued follow-up")
            .help("Remove from queue")

            Menu {
                Button("Edit message", systemImage: "pencil") {
                    onEdit(submission.clientID)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(theme.fonts.chat)
                    .foregroundStyle(theme.colors.textTertiary)
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Queued follow-up actions")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .codexGlass(RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous), role: .panel)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func queuedTitle(for submission: CodexComposerSubmission) -> String {
        if !submission.prompt.isEmpty { return submission.prompt }
        if !submission.responseAnnotations.isEmpty {
            return annotationSummary(for: submission.responseAnnotations.count)
        }
        return "Attached follow-up"
    }

    private func annotationSummary(for count: Int) -> String {
        count == 1 ? "1 annotation" : "\(count) annotations"
    }
}

private struct SendButton: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var tapCount = 0

    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button {
            tapCount &+= 1
            action()
        } label: {
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
        .accessibilityLabel(CodexComposerAccessibility.sendButtonLabel(isEnabled: enabled))
        .help(CodexComposerAccessibility.sendButtonHelp(isEnabled: enabled))
        .animation(.snappy(duration: theme.animations.snappyDuration), value: enabled)
        .sensoryFeedback(.impact(weight: .light), trigger: tapCount)
    }
}
