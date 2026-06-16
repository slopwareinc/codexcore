import AppKit
import SwiftUI
import CodexCore
import CodexCoreUI

struct CodexExampleAppShell: View {
    @Bindable var model: CodexChatModel
    @State private var isSidebarVisible = true
    @State private var isRenameSheetPresented = false
    @State private var isSearchSheetPresented = false
    @State private var isMCPStatusSheetPresented = false
    @State private var isPluginsSheetPresented = false
    @State private var renameDraft = ""

    var body: some View {
        HStack(spacing: 0) {
            if isSidebarVisible {
                CodexExampleProjectSidebar(
                    serverName: model.serverName,
                    workspacePath: model.workspacePath,
                    isThreadReady: model.isThreadReady,
                    currentThreadID: model.currentThreadID,
                    projects: model.recentProjects,
                    recentChats: model.recentChats,
                    onNewChat: { Task { await model.startNewChat() } },
                    onSearch: { isSearchSheetPresented = true },
                    onPlugins: {
                        isPluginsSheetPresented = true
                        Task { await model.refreshPlugins() }
                    },
                    onSelectProject: { path in Task { await model.switchWorkspace(to: path) } },
                    onOpenFolder: { chooseWorkspaceFolder() },
                    onSelectChat: { threadID in Task { await model.resumeChat(id: threadID) } }
                )
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            CodexChatWorkspaceView(
                messages: model.messages,
                lifecycleEvents: model.lifecycleEvents,
                sideChat: model.sideChat,
                subagents: model.subagents,
                activities: model.activities,
                connectionState: model.connectionState,
                workspacePath: model.workspacePath,
                showsSidebarToggle: true,
                isSidebarVisible: isSidebarVisible,
                chatActions: CodexChatActionHandlers(
                    renameChat: {
                        renameDraft = model.currentChatTitle
                        isRenameSheetPresented = true
                    },
                    archiveChat: { Task { await model.archiveCurrentChat() } },
                    openSideChat: { model.openSideChat() },
                    copyChat: { model.copyChatTranscript() },
                    forkChat: { Task { await model.forkCurrentChat() } }
                ),
                approvalOptions: model.approvalOptions,
                modelOptions: model.modelOptions,
                slashCommands: model.slashCommands,
                approvalSelection: $model.approvalSelection,
                isPlanModeEnabled: $model.isPlanModeEnabled,
                modelSelection: $model.modelSelection,
                reasoningSelection: $model.reasoningSelection,
                draft: $model.draft,
                sideChatDraft: $model.sideChatDraft,
                isSending: model.isSending,
                isSideChatSending: model.isSideChatSending,
                canSend: model.canSend,
                canSendSideChatMessage: model.canSendSideChatMessage,
                canUsePlanMode: model.canUsePlanMode,
                followUpHint: model.followUpHint,
                mentionResults: model.mentionResults,
                onMentionQueryChanged: { model.updateMentionQuery($0) },
                onMentionSelected: { model.selectMention($0) },
                onSend: { Task { await model.sendDraft() } },
                onInterrupt: { Task { await model.interrupt() } },
                onSendSideChatMessage: { Task { await model.sendSideChatDraft() } },
                onInterruptSideChatMessage: { Task { await model.interruptSideChat() } },
                onToggleSidebar: {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                        isSidebarVisible.toggle()
                    }
                },
                onDisconnect: { Task { await model.disconnect() } },
                onSlashCommandSelected: { command in
                    model.handleSlashCommand(command) {
                        isMCPStatusSheetPresented = true
                    }
                }
            )
            .codexFileChangeUndo { change in
                Task { @MainActor in
                    model.undoFileChange(change)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if !model.approvalPrompts.isEmpty || !model.interactivePrompts.isEmpty || !model.currentPlan.isEmpty || model.currentDiff != nil {
                VStack(alignment: .trailing, spacing: 10) {
                    if !model.approvalPrompts.isEmpty {
                        ApprovalRequestsPanel(
                            prompts: model.approvalPrompts,
                            onApprove: { id in model.resolveApprovalPrompt(id: id, approved: true) },
                            onDeny: { id in model.resolveApprovalPrompt(id: id, approved: false) }
                        )
                    }

                    if !model.interactivePrompts.isEmpty {
                        InteractivePromptsPanel(
                            prompts: model.interactivePrompts,
                            onSubmit: { id, answers in model.submitInteractivePrompt(id: id, answers: answers) },
                            onAccept: { id in model.acceptInteractivePrompt(id: id) },
                            onDecline: { id in model.declineInteractivePrompt(id: id) }
                        )
                    }

                    if !model.currentPlan.isEmpty || model.currentDiff != nil {
                        TurnPlanPanel(
                            steps: model.currentPlan,
                            explanation: model.currentPlanExplanation,
                            diff: model.currentDiff
                        )
                    }
                }
                .codexAgentTheme(model.themePreset.theme)
                .padding(.top, 54)
                .padding(.trailing, 18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .sheet(isPresented: $isRenameSheetPresented) {
            RenameChatSheet(
                name: $renameDraft,
                onCancel: { isRenameSheetPresented = false },
                onSave: {
                    isRenameSheetPresented = false
                    Task { await model.renameCurrentChat(to: renameDraft) }
                }
            )
            .codexAgentTheme(model.themePreset.theme)
        }
        .sheet(isPresented: $isSearchSheetPresented) {
            SearchChatsSheet(
                model: model,
                onClose: { isSearchSheetPresented = false },
                onSelect: { result in
                    isSearchSheetPresented = false
                    Task { await model.resumeSearchResult(result) }
                }
            )
            .codexAgentTheme(model.themePreset.theme)
        }
        .sheet(isPresented: $isMCPStatusSheetPresented) {
            MCPStatusSheet(
                model: model,
                onClose: { isMCPStatusSheetPresented = false },
                onRefresh: { Task { await model.refreshMCPServers() } }
            )
            .codexAgentTheme(model.themePreset.theme)
        }
        .sheet(isPresented: $isPluginsSheetPresented) {
            PluginsSheet(
                model: model,
                onClose: { isPluginsSheetPresented = false },
                onRefresh: { Task { await model.refreshPlugins() } }
            )
            .codexAgentTheme(model.themePreset.theme)
        }
    }

    private func chooseWorkspaceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: model.workspacePath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.switchWorkspace(to: url.path) }
    }
}

private struct TurnPlanPanel: View {
    @Environment(\.codexAgentTheme) private var theme

    let steps: [TurnPlanStep]
    let explanation: String?
    let diff: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.colors.accent)
                Text("Plan")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Spacer(minLength: 0)
                if !steps.isEmpty {
                    Text("\(steps.filter { $0.status == .completed }.count)/\(steps.count)")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                }
            }

            if let explanation, !explanation.isEmpty {
                Text(explanation)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                    .lineLimit(2)
            }

            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: statusImage(step.status))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(statusColor(step.status))
                        .frame(width: 16)
                    Text(step.step)
                        .font(theme.fonts.caption)
                        .foregroundStyle(step.status == .completed ? theme.colors.textTertiary : theme.colors.textPrimary)
                        .strikethrough(step.status == .completed, color: theme.colors.textTertiary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }

            if let diff, !diff.isEmpty {
                Divider().overlay(theme.colors.border)
                HStack(spacing: 8) {
                    Image(systemName: "plusminus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.colors.textSecondary)
                        .frame(width: 16)
                    Text(diffSummary(diff))
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diff, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.colors.textTertiary)
                    .help("Copy diff")
                }
            }
        }
        .padding(12)
        .frame(width: 360)
        .background(theme.colors.surfaceElevated.opacity(0.96), in: RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 12)
    }

    private func statusImage(_ status: TurnPlanStepStatus) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "circle.dotted.circle"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private func statusColor(_ status: TurnPlanStepStatus) -> Color {
        switch status {
        case .pending: return theme.colors.textTertiary
        case .inProgress: return theme.colors.accent
        case .completed: return theme.colors.success
        }
    }

    private func diffSummary(_ diff: String) -> String {
        let files = diff.components(separatedBy: "diff --git").count - 1
        let added = diff.split(separator: "\n").filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
        let removed = diff.split(separator: "\n").filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
        if files > 0 {
            return "\(files) file(s) · +\(added) −\(removed)"
        }
        return "+\(added) −\(removed)"
    }
}

private struct ApprovalRequestsPanel: View {
    @Environment(\.codexAgentTheme) private var theme

    let prompts: [CodexApprovalPrompt]
    let onApprove: (String) -> Void
    let onDeny: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.colors.warning)
                Text("Approval needed")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Spacer(minLength: 0)
                Text("\(prompts.count)")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
            }

            ForEach(prompts.prefix(3)) { prompt in
                ApprovalPromptRow(prompt: prompt, onApprove: onApprove, onDeny: onDeny)
            }
        }
        .padding(12)
        .frame(width: 360)
        .background(theme.colors.surfaceElevated.opacity(0.96), in: RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 12)
    }
}

private struct ApprovalPromptRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let prompt: CodexApprovalPrompt
    let onApprove: (String) -> Void
    let onDeny: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: prompt.kind.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.colors.textSecondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.colors.textPrimary)
                        .lineLimit(1)
                    Text(prompt.detail)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            if let primary = prompt.primaryValue, !primary.isEmpty {
                Text(primary)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.colors.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
            }

            if let secondary = prompt.secondaryValue, !secondary.isEmpty {
                Text(secondary)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 8) {
                Button {
                    onDeny(prompt.id)
                } label: {
                    Label("Deny", systemImage: "xmark")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Deny")

                Spacer(minLength: 0)

                Button {
                    onApprove(prompt.id)
                } label: {
                    Label("Approve", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .help("Approve")
            }
        }
        .padding(10)
        .background(theme.colors.surface.opacity(0.58), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
    }
}

private struct InteractivePromptsPanel: View {
    @Environment(\.codexAgentTheme) private var theme

    let prompts: [CodexInteractivePrompt]
    let onSubmit: (String, [String: String]) -> Void
    let onAccept: (String) -> Void
    let onDecline: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.colors.accent)
                Text("Input needed")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Spacer(minLength: 0)
                Text("\(prompts.count)")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
            }

            ForEach(prompts.prefix(3)) { prompt in
                InteractivePromptRow(
                    prompt: prompt,
                    onSubmit: onSubmit,
                    onAccept: onAccept,
                    onDecline: onDecline
                )
            }
        }
        .padding(12)
        .frame(width: 360)
        .background(theme.colors.surfaceElevated.opacity(0.96), in: RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 12)
    }
}

private struct InteractivePromptRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let prompt: CodexInteractivePrompt
    let onSubmit: (String, [String: String]) -> Void
    let onAccept: (String) -> Void
    let onDecline: (String) -> Void
    @State private var answers: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: prompt.kind.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.colors.textSecondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.colors.textPrimary)
                        .lineLimit(1)
                    Text(prompt.detail)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
            }

            if prompt.kind == .userInput {
                ForEach(prompt.questions) { question in
                    questionEditor(question)
                }
            } else if let serverName = prompt.serverName {
                Text(serverName)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.colors.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
            }

            HStack(spacing: 8) {
                Button {
                    onDecline(prompt.id)
                } label: {
                    Label(prompt.kind == .userInput ? "Cancel" : "Decline", systemImage: "xmark")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer(minLength: 0)

                Button {
                    if prompt.kind == .userInput {
                        onSubmit(prompt.id, answers)
                    } else {
                        onAccept(prompt.id)
                    }
                } label: {
                    Label(prompt.kind == .userInput ? "Submit" : "Allow", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(prompt.kind == .userInput && !hasRequiredAnswers)
            }
        }
        .padding(10)
        .background(theme.colors.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
    }

    private var hasRequiredAnswers: Bool {
        guard !prompt.questions.isEmpty else { return true }
        return prompt.questions.allSatisfy { question in
            !(answers[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    @ViewBuilder
    private func questionEditor(_ question: CodexUserInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header = question.header {
                Text(header)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
            }
            Text(question.question)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)
                .lineLimit(3)

            if !question.options.isEmpty {
                FlexibleOptionButtons(
                    options: question.options,
                    selectedAnswer: answers[question.id],
                    onSelect: { answers[question.id] = $0 }
                )
            }

            if question.isSecret {
                SecureField("Answer", text: answerBinding(for: question.id))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            } else if question.isOtherAllowed || question.options.isEmpty {
                TextField("Answer", text: answerBinding(for: question.id))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(theme.colors.surfaceElevated.opacity(0.52), in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
    }

    private func answerBinding(for id: String) -> Binding<String> {
        Binding(
            get: { answers[id] ?? "" },
            set: { answers[id] = $0 }
        )
    }
}

private struct FlexibleOptionButtons: View {
    @Environment(\.codexAgentTheme) private var theme

    let options: [CodexUserInputOption]
    let selectedAnswer: String?
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(options, id: \.label) { option in
                Button {
                    onSelect(option.label)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: selectedAnswer == option.label ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11, weight: .semibold))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.colors.textPrimary)
                                .lineLimit(1)
                            if let description = option.description {
                                Text(description)
                                    .font(theme.fonts.caption)
                                    .foregroundStyle(theme.colors.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .background(
                    (selectedAnswer == option.label ? theme.colors.accent.opacity(0.16) : theme.colors.surface.opacity(0.72)),
                    in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                        .stroke(selectedAnswer == option.label ? theme.colors.accent.opacity(0.5) : theme.colors.border, lineWidth: 1)
                )
            }
        }
    }
}

private struct SearchChatsSheet: View {
    @Environment(\.codexAgentTheme) private var theme

    @Bindable var model: CodexChatModel
    let onClose: () -> Void
    let onSelect: (CodexThreadSearchResult) -> Void
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Search chats")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.colors.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.colors.textTertiary)
                TextField("Search previous chats", text: $query)
                    .textFieldStyle(.plain)
                    .font(theme.fonts.chat)
                    .foregroundStyle(theme.colors.textPrimary)
                    .focused($isFocused)
                    .onSubmit { runSearch(query) }
                if model.isSearchingChats {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 38)
            .background(theme.colors.surfaceElevated.opacity(0.82), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                    .stroke(theme.colors.border, lineWidth: 1)
            )

            Group {
                if let error = model.searchErrorMessage {
                    Text(error)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                } else if model.searchResults.isEmpty, !model.isSearchingChats {
                    Text("No matching chats")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.searchResults) { result in
                        SearchResultRow(result: result) {
                            onSelect(result)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 300)
        }
        .padding(18)
        .frame(width: 520, height: 430)
        .background(theme.colors.surface)
        .onAppear { isFocused = true }
        .onDisappear {
            searchTask?.cancel()
            model.clearSearchResults()
        }
        .onChange(of: query) { _, value in
            searchTask?.cancel()
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                model.clearSearchResults()
                return
            }
            searchTask = Task {
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
                await model.searchChats(query: trimmed)
            }
        }
    }

    private func runSearch(_ value: String) {
        searchTask?.cancel()
        searchTask = Task {
            await model.searchChats(query: value)
        }
    }
}

private struct SearchResultRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let result: CodexThreadSearchResult
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.colors.textTertiary)
                    .frame(width: 18, height: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.thread.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.colors.textPrimary)
                        .lineLimit(1)
                    Text(result.snippet.isEmpty ? result.thread.detail : result.snippet)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(2)
                    Text(projectLabel)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.colors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(theme.colors.surfaceElevated.opacity(0.34), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
    }

    private var projectLabel: String {
        guard let path = result.thread.workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return result.thread.id
        }
        return path
    }
}

private struct PluginsSheet: View {
    @Environment(\.codexAgentTheme) private var theme

    @Bindable var model: CodexChatModel
    let onClose: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.colors.textSecondary)
                Text("Plugins")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.colors.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Refresh")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.colors.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            HStack(spacing: 10) {
                Text("\(model.plugins.filter(\.installed).count) installed")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                Text("\(model.plugins.count) total")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                if model.isLoadingPlugins {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let error = model.pluginErrorMessage {
                Text(error)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.danger)
            } else if model.plugins.isEmpty, !model.isLoadingPlugins {
                Text("No plugins")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
            }

            if !model.pluginLoadErrors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.pluginLoadErrors, id: \.self) { error in
                        Text(error)
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.warning)
                            .lineLimit(2)
                    }
                }
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.plugins) { plugin in
                        PluginCatalogRow(plugin: plugin)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 340)
        }
        .padding(18)
        .frame(width: 580, height: 480)
        .background(theme.colors.surface)
    }
}

private struct PluginCatalogRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let plugin: CodexPluginSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: plugin.installed ? "checkmark.circle.fill" : "puzzlepiece.extension")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(plugin.installed ? theme.colors.success : theme.colors.textTertiary)
                    .frame(width: 18)
                Text(plugin.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
                if let version = plugin.localVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty {
                    Text(version)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                Text(plugin.statusLabel)
                    .font(theme.fonts.caption)
                    .foregroundStyle(plugin.installed ? theme.colors.success : theme.colors.textSecondary)
                    .lineLimit(1)
            }

            Text(plugin.detail)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                Text(plugin.marketplaceDisplayName)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(1)
                Text(plugin.sourceLabel)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(1)
                if let developer = plugin.developerName?.trimmingCharacters(in: .whitespacesAndNewlines), !developer.isEmpty {
                    Text(developer)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if !plugin.capabilities.isEmpty {
                Text(plugin.capabilities.prefix(4).joined(separator: " · "))
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(11)
        .background(theme.colors.surfaceElevated.opacity(0.78), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
    }
}

private struct MCPStatusSheet: View {
    @Environment(\.codexAgentTheme) private var theme

    @Bindable var model: CodexChatModel
    let onClose: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.colors.textSecondary)
                Text("MCP servers")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.colors.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Refresh")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.colors.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            if model.isLoadingMCPServers {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                }
            } else if let error = model.mcpErrorMessage {
                Text(error)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.danger)
            } else if model.mcpServers.isEmpty {
                Text("No MCP servers")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.mcpServers) { server in
                        MCPServerStatusRow(server: server)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 330)
        }
        .padding(18)
        .frame(width: 560, height: 460)
        .background(theme.colors.surface)
    }
}

private struct MCPServerStatusRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let server: CodexMCPServerStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: statusImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 18)
                Text(server.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
                if let version = server.version?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty {
                    Text(version)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                Text(server.authStatusLabel)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Text(server.startupStatus ?? "ready")
                    .font(theme.fonts.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                Text(server.inventorySummary)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                    .lineLimit(1)
                if let error = server.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                    Text(error)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.danger)
                        .lineLimit(1)
                }
            }

            if !previewEntries.isEmpty {
                Text(previewEntries.joined(separator: " · "))
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(2)
            } else if let detail = server.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                Text(detail)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(2)
            }
        }
        .padding(11)
        .background(theme.colors.surfaceElevated.opacity(0.78), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
    }

    private var statusImage: String {
        switch server.startupStatus {
        case "failed":
            return "exclamationmark.triangle.fill"
        case "starting":
            return "clock"
        case "cancelled":
            return "minus.circle"
        default:
            return "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch server.startupStatus {
        case "failed":
            return theme.colors.danger
        case "starting":
            return theme.colors.textSecondary
        case "cancelled":
            return theme.colors.textTertiary
        default:
            return theme.colors.success
        }
    }

    private var previewEntries: [String] {
        Array((server.tools + server.resources + server.resourceTemplates).prefix(4).map(\.displayName))
    }
}

private struct RenameChatSheet: View {
    @Environment(\.codexAgentTheme) private var theme

    @Binding var name: String
    let onCancel: () -> Void
    let onSave: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename chat")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.colors.textPrimary)

            TextField("Chat name", text: $name)
                .textFieldStyle(.plain)
                .font(theme.fonts.chat)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(theme.colors.surfaceElevated.opacity(0.82), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                        .stroke(theme.colors.border, lineWidth: 1)
                )
                .focused($isFocused)
                .onSubmit(onSave)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(theme.colors.surface)
        .onAppear { isFocused = true }
    }
}
