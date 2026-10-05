import AppKit
import SwiftUI
import CodexCore
import CodexCoreUI

struct CodexThreadFeaturesSheet: View {
    @Environment(\.codexAgentTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Bindable var controller: CodexThreadFeatureController
    var modelOptions: [CodexModelSelection] = []
    var projects: [CodexProjectSummary] = []
    var plugins: [CodexPluginSummary] = []
    @State private var confirmation: Confirmation?
    @State private var confirmationContext = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chat features").font(theme.fonts.sheetTitle)
                    Text(controller.thread?.name ?? controller.threadID ?? "No chat selected")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(1).textSelection(.enabled)
                }
                Spacer()
                if controller.isLoading || controller.isMutating { CodexSpinner(size: .small) }
                Button { Task { await controller.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }.disabled(controller.isLoading || controller.isMutating)
                    .accessibilityLabel("Refresh chat features")
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)

            Picker("Feature", selection: Binding(
                get: { controller.section },
                set: { section in Task { await controller.activate(section) } }
            )) {
                ForEach(CodexThreadFeatureSection.allCases) { section in Text(section.rawValue).tag(section) }
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error = controller.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(theme.colors.danger).textSelection(.enabled)
                    }
                    if let activity = controller.activityMessage {
                        Label(activity, systemImage: "checkmark.circle")
                            .foregroundStyle(theme.colors.success)
                    }
                    if controller.threadID == nil {
                        empty("Select a connected chat to inspect its features.")
                    } else {
                        switch controller.section {
                        case .attachments: attachments
                        case .memory: memory
                        case .history: history
                        case .settings: settings
                        case .queue: queue
                        case .goal: goal
                        case .search: search
                        case .approvals: approvals
                        }
                    }
                }.font(theme.fonts.caption).padding(20)
            }
        }
        .foregroundStyle(theme.colors.textPrimary)
        .background(theme.colors.surface)
        .frame(minWidth: 650, idealWidth: 740, minHeight: 540, idealHeight: 650)
        .task(id: controller.threadID) { await controller.activate(controller.section) }
        .onDisappear { controller.dismiss() }
        .alert(item: $confirmation) { value in
            Alert(
                title: Text(value.title),
                message: Text(value.message),
                primaryButton: value.isDestructive ? .destructive(Text(value.action)) { confirm(value) } : .default(Text(value.action)) { confirm(value) },
                secondaryButton: .cancel()
            )
        }
    }

    private var search: some View {
        VStack(alignment: .leading, spacing: 16) {
            description("Find in this chat", "Search every persisted turn. Results retain their exact item and turn location.")
            HStack {
                TextField("Search conversation", text: $controller.searchDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await controller.findOccurrences(controller.searchDraft) } }
                Button("Find") { Task { await controller.findOccurrences(controller.searchDraft) } }
                    .disabled(controller.searchDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.isLoading)
            }
            if !controller.searchQuery.isEmpty, controller.occurrences.isEmpty, !controller.isLoading {
                empty("No matches for “" + controller.searchQuery + "”.")
            }
            LazyVStack(spacing: 10) {
                ForEach(Array(controller.occurrences.enumerated()), id: \.offset) { _, value in
                    card {
                        Text(value.snippet).textSelection(.enabled)
                        Text("Turn " + value.turnID + " · Item " + value.itemID)
                            .font(theme.fonts.caption.monospaced()).foregroundStyle(theme.colors.textSecondary)
                        if controller.onOpenOccurrence != nil {
                            Button("Open match") { Task { await controller.openOccurrence(value); dismiss() } }
                        }
                    }
                }
            }
            if controller.occurrenceCursor != nil {
                Button("Load more matches") { Task { await controller.loadMore() } }.disabled(controller.isLoading)
            }
        }
    }

    private var approvals: some View {
        VStack(alignment: .leading, spacing: 16) {
            description("Denied actions", "Review the exact action denied by Codex Guardian. Approval records permission for that action when Codex continues.")
            if controller.deniedReviews.isEmpty && !controller.isLoading { empty("No retained denied actions in this chat.") }
            LazyVStack(spacing: 10) {
                ForEach(controller.deniedReviews) { review in
                    card {
                        Text(review.summary).font(theme.fonts.label).textSelection(.enabled)
                        if let rationale = review.rationale { Text(rationale).foregroundStyle(theme.colors.textSecondary).textSelection(.enabled) }
                        Text("Turn " + review.turnID + " · Review " + review.reviewID)
                            .font(theme.fonts.caption.monospaced()).foregroundStyle(theme.colors.textSecondary)
                        if let item = review.targetItemID { Text("Item " + item).font(theme.fonts.caption.monospaced()).textSelection(.enabled) }
                        CodexThreadJSONDisclosure(title: "Reviewed action", value: review.action)
                        if let reason = review.unavailableReason { Text(reason).foregroundStyle(theme.colors.textSecondary) }
                        Button("Approve this action…") { ask(.approveGuardian(review)) }
                            .disabled(review.event == nil || controller.isMutating)
                    }
                }
            }
        }
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: 16) {
            description("Durable resources", "These resources belong to the chat and survive reopening. Images and audio sent with a message are separate inputs.")
            card {
                Picker("Resource", selection: $controller.resourceDraft.kind) {
                    ForEach(CodexThreadResourceKind.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField("Title (optional)", text: $controller.resourceDraft.title)
                HStack {
                    TextField(controller.resourceDraft.kind == .file ? "Absolute path" : "https://…", text: $controller.resourceDraft.location)
                    if controller.resourceDraft.kind == .file {
                        Button("Choose…") { chooseResource() }
                    }
                }
                HStack {
                    Spacer()
                    Button("Attach resource") { Task { await controller.addResource() } }
                        .disabled(controller.isMutating || controller.resourceDraft.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if controller.attachments.isEmpty && !controller.isLoading { empty("No durable attachments.") }
            LazyVStack(spacing: 10) {
                ForEach(controller.attachments, id: \.id) { attachment in
                    card {
                        HStack(alignment: .top) {
                            Image(systemName: attachment.attachmentType == "pull_request" ? "arrow.triangle.pull" : "paperclip")
                                .foregroundStyle(theme.colors.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(attachmentTitle(attachment)).font(theme.fonts.label)
                                Text(attachment.identityKey).foregroundStyle(theme.colors.textSecondary)
                                    .textSelection(.enabled)
                                Text(attachment.attachmentType).foregroundStyle(theme.colors.textTertiary)
                            }
                            Spacer()
                            Button("Open") { openResource(attachment) }
                                .disabled(resourceURL(attachment) == nil)
                            Button { ask(.removeAttachment(attachment)) } label: {
                                Image(systemName: "trash")
                            }.disabled(controller.isMutating).accessibilityLabel("Remove \(attachmentTitle(attachment))")
                        }
                        CodexThreadJSONDisclosure(title: "Resource details", value: attachment.payload)
                    }
                }
            }
            if controller.attachmentCursor != nil {
                Button("Load more attachments") { Task { await controller.loadMore() } }.disabled(controller.isLoading)
            }
        }
    }

    private var memory: some View {
        VStack(alignment: .leading, spacing: 16) {
            description("Codex memory", "Inspect consolidation readiness and control whether this chat participates in memory.")
            card {
                if let status = controller.memoryStatus {
                    LabeledContent("Consolidated chats", value: String(status.v2ConsolidatedThreads))
                    LabeledContent("Memory readiness", value: status.v2Ready ? "Ready" : "Not ready")
                } else { empty("Memory status has not loaded.") }
                Divider()
                LabeledContent("This chat", value: controller.memoryMode?.rawValue.capitalized ?? "Mode not reported")
                HStack {
                    Button("Enable for this chat") { Task { await controller.setMemoryMode(.enabled) } }
                    Button("Disable for this chat") { Task { await controller.setMemoryMode(.disabled) } }
                }.disabled(controller.isMutating)
            }
            card {
                Text("Reset all Codex memory").font(theme.fonts.label)
                Text("This clears memory in the active Codex home across chats. Conversation history remains owned by Codex.")
                    .foregroundStyle(theme.colors.textSecondary)
                Button("Reset memory…", role: .destructive) { ask(.resetMemory) }
                    .disabled(controller.isMutating)
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 16) {
            description("Thread timeline", "Codex supplies the timeline and turn history. Reverting removes the selected turn and the turns after it from this chat.")
            if controller.timeline.isEmpty && !controller.isLoading { empty("No timeline events reported.") }
            LazyVStack(spacing: 10) {
                ForEach(controller.timeline) { event in
                    card {
                        Text(event.title).font(theme.fonts.label)
                        Text(event.detail).foregroundStyle(theme.colors.textSecondary).lineLimit(4).textSelection(.enabled)
                        CodexThreadJSONDisclosure(title: "Event details", value: event.raw)
                    }
                }
            }
            if controller.timelineCursor != nil {
                Button("Load more timeline events") { Task { await controller.loadMore() } }.disabled(controller.isLoading)
            }
            if !controller.turns.isEmpty {
                Text("Turn history").font(theme.fonts.label)
                LazyVStack(spacing: 10) {
                    ForEach(controller.turns, id: \.id) { turn in
                        card {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(turn.id).font(theme.fonts.caption.monospaced()).textSelection(.enabled)
                                    Text(turn.status.rawValue).foregroundStyle(theme.colors.textSecondary)
                                }
                                Spacer()
                                Button("Revert before this turn…", role: .destructive) { ask(.revert(turn.id)) }
                                    .disabled(controller.isMutating || turn.status == .inProgress)
                            }
                        }
                    }
                }
                if controller.turnsCursor != nil {
                    Button("Load older turns") { Task { await controller.loadMoreTurns() } }.disabled(controller.isLoading)
                }
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            description("Chat defaults", "These defaults apply to subsequent turns. The composer changes an active turn's model, reasoning, and speed directly.")
            card {
                if modelOptions.isEmpty {
                    TextField("Model override (blank preserves current value)", text: $controller.settingsDraft.model)
                } else {
                    Picker("Model", selection: $controller.settingsDraft.model) {
                        Text("Keep runtime default").tag("")
                        if !controller.settingsDraft.model.isEmpty,
                           !modelOptions.contains(where: { ($0.modelIdentifier ?? $0.id) == controller.settingsDraft.model }) {
                            Text(controller.settingsDraft.model).tag(controller.settingsDraft.model)
                        }
                        ForEach(modelOptions) { model in Text(model.displayName).tag(model.modelIdentifier ?? model.id) }
                    }
                }
                Picker("Reasoning", selection: $controller.settingsDraft.effort) {
                    Text("Keep current value").tag("")
                    ForEach(["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"], id: \.self) { Text($0.capitalized).tag($0) }
                }
                Picker("Personality", selection: $controller.settingsDraft.personality) {
                    Text("Keep current value").tag("")
                    ForEach(CodexSchemaPersonality.allCases, id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
                }
                TextField("Service tier (blank preserves current value)", text: $controller.settingsDraft.serviceTier)
                if !plugins.isEmpty {
                    Toggle("Set disabled plugins for this chat", isOn: $controller.settingsDraft.updatesDisabledPlugins)
                    if controller.settingsDraft.updatesDisabledPlugins {
                        ForEach(plugins) { plugin in
                            Toggle("Disable \(plugin.name)", isOn: Binding(
                                get: { controller.settingsDraft.disabledPluginIDs.contains(plugin.id) },
                                set: { disabled in
                                    if disabled { controller.settingsDraft.disabledPluginIDs.insert(plugin.id) }
                                    else { controller.settingsDraft.disabledPluginIDs.remove(plugin.id) }
                                }
                            ))
                        }
                    }
                }
                Button("Save chat defaults") { Task { await controller.saveSettings() } }.disabled(controller.isMutating || controller.isLoading)
            }
            card {
                Text("Chat metadata").font(theme.fonts.label)
                Picker("Daybreak", selection: $controller.settingsDraft.daybreak) {
                    Text("Keep current value").tag("")
                    Text("Enabled").tag("enabled")
                    Text("Disabled").tag("disabled")
                }
                Picker("Project", selection: $controller.settingsDraft.projectID) {
                    Text("Keep current project").tag("")
                    if let id = controller.thread?.projectID,
                       !projects.contains(where: { $0.serverID == id }) { Text(id).tag(id) }
                    ForEach(projects.filter { $0.serverID != nil }) { project in
                        Text(project.displayName).tag(project.serverID!)
                    }
                }
                Button("Save metadata") { Task { await controller.saveMetadata() } }.disabled(controller.isMutating || controller.isLoading)
            }
            card {
                Text("Loaded chats").font(theme.fonts.label)
                Text("Chats currently loaded by the connected Codex runtime.").foregroundStyle(theme.colors.textSecondary)
                Button("Refresh loaded chats") { Task { await controller.loadLoadedThreads() } }.disabled(controller.isLoadingLoaded)
                ForEach(controller.loadedThreadIDs, id: \.self) { id in
                    HStack { Text(id).font(theme.fonts.caption.monospaced()).textSelection(.enabled); if id == controller.threadID { Text("Selected").foregroundStyle(theme.colors.textSecondary) } }
                }
                if controller.loadedCursor != nil {
                    Button("Load more loaded chats") { Task { await controller.loadLoadedThreads(append: true) } }.disabled(controller.isLoadingLoaded)
                }
            }
            card {
                Text("Permanently delete chat").font(theme.fonts.label)
                Text("Deletion removes the chat from Codex. Archive it from the chat menu if you want to restore it later.")
                    .foregroundStyle(theme.colors.textSecondary)
                Button("Delete chat…", role: .destructive) { ask(.deleteThread) }
                    .disabled(controller.isMutating)
            }
        }
    }

    private var queue: some View {
        VStack(alignment: .leading, spacing: 16) {
            description("Queued follow-ups", "Codex persists and dispatches this queue. Move messages in order or explicitly start one when the runtime permits it.")
            if controller.queue.isEmpty && !controller.isLoading { empty("No queued messages.") }
            LazyVStack(spacing: 10) {
                ForEach(Array(controller.queue.enumerated()), id: \.element.id) { index, value in
                    card {
                        Text("Message \(index + 1)").font(theme.fonts.label)
                        Text(queueText(value)).foregroundStyle(theme.colors.textSecondary).lineLimit(6).textSelection(.enabled)
                        HStack {
                            Button { Task { await controller.moveQueuedSubmission(id: value.id, offset: -1) } } label: {
                                Image(systemName: "arrow.up")
                            }.disabled(index == 0 || controller.isMutating || controller.isLoading || !controller.queueIsComplete).accessibilityLabel("Move message up")
                            Button { Task { await controller.moveQueuedSubmission(id: value.id, offset: 1) } } label: {
                                Image(systemName: "arrow.down")
                            }.disabled(index == controller.queue.count - 1 || controller.isMutating || controller.isLoading || !controller.queueIsComplete).accessibilityLabel("Move message down")
                            Spacer()
                            Button("Start now") { Task { await controller.startQueuedSubmission(id: value.id) } }.disabled(controller.isMutating)
                        }
                    }
                }
            }
        }
    }

    private var goal: some View {
        VStack(alignment: .leading, spacing: 16) {
            description("Goal pursuit", "Set a persistent objective, inspect runtime usage, and pause or resume its continuation.")
            if let goal = controller.goal {
                card {
                    LabeledContent("Status", value: goal.status.rawValue)
                    LabeledContent("Tokens used", value: String(goal.tokensUsed))
                    LabeledContent("Token budget", value: goal.tokenBudget.map(String.init) ?? "No budget reported")
                    LabeledContent("Time used", value: "\(goal.timeUsedSeconds) seconds")
                    HStack {
                        Button(goal.status == .paused ? "Resume goal" : "Pause goal") {
                            Task { await controller.setGoalPaused(goal.status != .paused) }
                        }
                        Button("Clear goal…", role: .destructive) { ask(.clearGoal) }
                    }.disabled(controller.isMutating)
                }
            } else if !controller.isLoading { empty("No goal set for this chat.") }
            card {
                Text("Objective").font(theme.fonts.label)
                TextEditor(text: $controller.goalDraft.objective).frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
                TextField("Token budget (optional positive number)", text: $controller.goalDraft.tokenBudget)
                Text("Leaving the budget blank preserves an existing budget; Codex does not expose a clear-budget parameter.")
                    .foregroundStyle(theme.colors.textTertiary)
                Button(controller.goal == nil ? "Start goal" : "Save and resume goal") { Task { await controller.saveGoal() } }
                    .disabled(controller.isMutating || controller.isLoading)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(theme.colors.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.colors.border, lineWidth: 1))
    }

    private func description(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(theme.fonts.label)
            Text(detail).foregroundStyle(theme.colors.textSecondary)
        }
    }

    private func empty(_ value: String) -> some View { Text(value).foregroundStyle(theme.colors.textTertiary).padding(.vertical, 12) }

    private func attachmentTitle(_ value: CodexSchemaThreadAttachment) -> String {
        CodexJSONCoercion.string(in: value.payload.objectValue ?? [:], keys: ["title", "name"]) ?? value.attachmentType.capitalized
    }

    private func resourceURL(_ value: CodexSchemaThreadAttachment) -> URL? {
        let object = value.payload.objectValue ?? [:]
        if case .string(let path)? = object["path"], path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        guard case .string(let raw)? = object["url"], let url = URL(string: raw),
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    private func openResource(_ value: CodexSchemaThreadAttachment) { if let url = resourceURL(value) { NSWorkspace.shared.open(url) } }

    private func chooseResource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            controller.resourceDraft.location = url.path
            if controller.resourceDraft.title.isEmpty { controller.resourceDraft.title = url.lastPathComponent }
        }
    }

    private func queueText(_ value: CodexSchemaQueuedSubmission) -> String {
        value.input.compactMap { input in
            let object = input.rawValue.objectValue ?? [:]
            return CodexJSONCoercion.string(in: object, keys: ["text", "path", "image_url", "name", "type"])
        }.joined(separator: "\n")
    }

    private func ask(_ value: Confirmation) {
        confirmationContext = controller.contextVersion
        confirmation = value
    }

    private func confirm(_ value: Confirmation) {
        guard confirmationContext == controller.contextVersion else { return }
        Task {
            switch value {
            case .resetMemory: await controller.resetMemoryConfirmed()
            case .deleteThread: await controller.deleteThreadConfirmed(); if controller.threadID == nil { dismiss() }
            case .revert(let turn): await controller.revertConfirmed(beforeTurnID: turn)
            case .removeAttachment(let attachment): await controller.removeAttachment(attachment)
            case .clearGoal: await controller.clearGoalConfirmed()
            case .approveGuardian(let review): await controller.approveDeniedActionConfirmed(review)
            }
        }
    }

    private enum Confirmation: Identifiable {
        case resetMemory, deleteThread, clearGoal, revert(String), removeAttachment(CodexSchemaThreadAttachment), approveGuardian(CodexGuardianDeniedReview)
        var id: String { title }
        var isDestructive: Bool { if case .approveGuardian = self { false } else { true } }
        var title: String {
            switch self {
            case .resetMemory: "Reset all Codex memory?"
            case .deleteThread: "Permanently delete this chat?"
            case .revert: "Revert this chat's history?"
            case .removeAttachment: "Remove this attachment?"
            case .clearGoal: "Clear this chat's goal?"
            case .approveGuardian: "Approve this denied action?"
            }
        }
        var message: String {
            switch self {
            case .resetMemory: "Memory for every chat in the active Codex home will be reset."
            case .deleteThread: "Codex will permanently delete the selected chat. This cannot be undone."
            case .revert(let turn): "Turn \(turn) and all turns after it will be removed from the selected chat. This does not revert workspace files."
            case .removeAttachment(let attachment): "Remove \(attachment.identityKey) from this chat? The resource itself is preserved."
            case .clearGoal: "Codex will stop pursuing this objective. Conversation history is preserved."
            case .approveGuardian(let review): "Approve exactly “" + review.summary + "” from turn " + review.turnID + ", review " + review.reviewID + ". Codex can retry this action when it continues."
            }
        }
        var action: String {
            switch self {
            case .resetMemory: "Reset memory"
            case .deleteThread: "Delete chat"
            case .revert: "Revert history"
            case .removeAttachment: "Remove"
            case .clearGoal: "Clear goal"
            case .approveGuardian: "Approve action"
            }
        }
    }
}

/// Unknown timeline/resource fields remain inspectable, with serialization only
/// when the user expands this disclosure.
private struct CodexThreadJSONDisclosure: View {
    let title: String
    let value: CodexJSONValue
    @State private var isExpanded = false
    @State private var text = ""
    var body: some View {
        DisclosureGroup(title, isExpanded: $isExpanded) {
            Text(text).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.onChange(of: isExpanded) { _, expanded in
            guard expanded else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            text = (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "Details unavailable"
        }
    }
}
