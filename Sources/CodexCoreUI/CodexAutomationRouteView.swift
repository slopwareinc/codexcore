import SwiftUI
import CodexCore

public struct CodexAutomationRouteView: View {
    @Environment(\.codexAgentTheme) private var theme

    public let automations: [CodexAutomation]
    public let onAction: (CodexAutomationRouteAction) -> Void
    @State private var session = CodexAutomationRouteSession()
    @State private var editorAutomation: CodexAutomation?
    @State private var deletionCandidate: CodexAutomation?

    public init(
        automations: [CodexAutomation] = [],
        onAction: @escaping (CodexAutomationRouteAction) -> Void
    ) {
        self.automations = automations
        self.onAction = onAction
    }

    private var state: CodexAutomationRouteState {
        CodexAutomationRouteState(mode: session.state.mode, automations: automations)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.colors.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if state.showsEmptyState {
                        emptyState
                    } else {
                        dashboard
                        templates(title: "Create another automation")
                    }
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.colors.surface)
        .sheet(item: $editorAutomation) { automation in
            CodexAutomationEditor(automation: automation) { saved in
                onAction(.save(saved))
                editorAutomation = nil
            } onCancel: {
                editorAutomation = nil
            }
            .codexAgentTheme(theme)
        }
        .confirmationDialog(
            "Delete \(deletionCandidate?.name ?? "automation")?",
            isPresented: Binding(
                get: { deletionCandidate != nil },
                set: { if !$0 { deletionCandidate = nil } }
            )
        ) {
            if let deletionCandidate {
                Button("Delete automation", role: .destructive) {
                    onAction(.delete(id: deletionCandidate.id))
                    self.deletionCandidate = nil
                }
            }
            Button("Cancel", role: .cancel) { deletionCandidate = nil }
        } message: {
            Text("Its schedule and local history will be removed. Existing chats are kept.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: CodexAppRoute.automations.systemImage)
                .font(theme.fonts.sheetTitle)
                .foregroundStyle(theme.colors.textSecondary)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    Text(state.headerTitle)
                        .font(theme.fonts.routeTitle)
                        .foregroundStyle(theme.colors.textPrimary)
                    Button(state.learnMoreTitle) { onAction(.learnMore) }
                        .buttonStyle(.plain)
                        .font(theme.fonts.caption.weight(.semibold))
                        .foregroundStyle(theme.colors.accent)
                }
                Text(state.description)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
            Spacer(minLength: 20)
            segmentedControls
            Menu {
                Button("New scheduled automation", systemImage: "calendar.badge.plus") {
                    editorAutomation = CodexAutomation(name: "New automation", prompt: "")
                }
                Button("Create via chat", systemImage: "bubble.left.and.bubble.right") {
                    perform(.createViaChat)
                }
            } label: {
                Label(state.newAutomationOptionsTitle, systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.colors.accent)
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 20)
    }

    private var segmentedControls: some View {
        HStack(spacing: 3) {
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
                            state.mode == mode ? theme.colors.surfaceElevated : Color.clear,
                            in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(theme.colors.surfaceSunken.opacity(0.6), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.radii.medium).stroke(theme.colors.border, lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(state.emptyTitle)
                    .font(theme.fonts.routeTitle)
                    .foregroundStyle(theme.colors.textPrimary)
                Text("Choose a starting point. Nothing runs until you review and enable its schedule.")
                    .font(theme.fonts.chat)
                    .foregroundStyle(theme.colors.textSecondary)
            }
            templates(title: nil)
        }
        .padding(.top, 8)
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Your automations")
                    .font(theme.fonts.sheetTitle)
                    .foregroundStyle(theme.colors.textPrimary)
                Spacer()
                Text("\(automations.filter(\.isEnabled).count) active")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
            }
            LazyVStack(spacing: 10) {
                ForEach(automations) { automation in
                    CodexAutomationRow(
                        automation: automation,
                        onRun: { onAction(.runNow(id: automation.id)) },
                        onToggle: { onAction(.toggle(id: automation.id)) },
                        onEdit: { editorAutomation = automation },
                        onDelete: { deletionCandidate = automation }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func templates(title: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(theme.fonts.panelTitle)
                    .foregroundStyle(theme.colors.textPrimary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(state.templates) { template in
                    CodexAutomationTemplateButton(template: template) { perform(.template(template)) }
                }
                Button { perform(.createViaChat) } label: {
                    templateCard(icon: "bubble.left.and.bubble.right", title: "Create via chat", description: "Describe what you need and let Codex help shape the schedule")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func templateCard(icon: String, title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(theme.fonts.panelTitle)
                .foregroundStyle(theme.colors.accent)
            Text(title).font(theme.fonts.label).foregroundStyle(theme.colors.textPrimary)
            Text(description).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary).lineLimit(2)
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(theme.colors.surfaceElevated.opacity(0.7), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.radii.medium).stroke(theme.colors.border, lineWidth: 1))
    }

    private func selectMode(_ mode: CodexAutomationRouteMode) {
        switch mode {
        case .viewTemplates: session.viewTemplates()
        case .createViaChat: perform(.createViaChat)
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

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: template.systemImage)
                    .font(theme.fonts.panelTitle)
                    .foregroundStyle(theme.colors.accent)
                Text(template.title).font(theme.fonts.label).foregroundStyle(theme.colors.textPrimary)
                Text(template.description).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary).lineLimit(2)
            }
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .background(theme.colors.surfaceElevated.opacity(0.7), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: theme.radii.medium).stroke(theme.colors.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(template.title)
    }
}

private struct CodexAutomationRow: View {
    @Environment(\.codexAgentTheme) private var theme
    let automation: CodexAutomation
    let onRun: () -> Void
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(statusColor.opacity(0.14))
                Image(systemName: automation.status == .running ? "arrow.trianglehead.2.clockwise.rotate.90" : "clock.arrow.circlepath")
                    .foregroundStyle(statusColor)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(automation.name).font(theme.fonts.chat.weight(.semibold)).foregroundStyle(theme.colors.textPrimary)
                    Text(automation.statusLabel)
                        .font(theme.fonts.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                }
                Text(automation.schedule.summary)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textSecondary)
                if let error = automation.lastError {
                    Text(error).font(theme.fonts.caption).foregroundStyle(.red).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Button("Run now", action: onRun)
                .buttonStyle(.bordered)
                .disabled(automation.status == .running)
            Toggle("Enabled", isOn: Binding(get: { automation.status != .disabled }, set: { _ in onToggle() }))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(automation.status == .running)
            Menu {
                Button("Edit", systemImage: "pencil", action: onEdit)
                Button(automation.status == .disabled ? "Enable" : "Disable", systemImage: automation.status == .disabled ? "play" : "pause", action: onToggle)
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 34)
        }
        .padding(14)
        .background(theme.colors.surfaceElevated.opacity(0.56), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.radii.medium).stroke(theme.colors.border, lineWidth: 1))
    }

    private var statusColor: Color {
        switch automation.status {
        case .enabled: theme.colors.accent
        case .disabled: theme.colors.textTertiary
        case .running: .orange
        case .failed: .red
        }
    }
}

private struct CodexAutomationEditor: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var automation: CodexAutomation
    let onSave: (CodexAutomation) -> Void
    let onCancel: () -> Void

    init(automation: CodexAutomation, onSave: @escaping (CodexAutomation) -> Void, onCancel: @escaping () -> Void) {
        _automation = State(initialValue: automation)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Automation").font(theme.fonts.sheetTitle).foregroundStyle(theme.colors.textPrimary)
                    Text("Codex starts a fresh background chat on this schedule.").font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary)
                }
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(.plain)
                Button("Save") { onSave(automation) }
                    .buttonStyle(.borderedProminent)
                    .disabled(automation.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || automation.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Name").font(theme.fonts.label)
                TextField("Daily brief", text: $automation.name).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Instructions").font(theme.fonts.label)
                TextEditor(text: $automation.prompt)
                    .font(theme.fonts.chat)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 130)
                    .background(theme.colors.surfaceSunken.opacity(0.5), in: RoundedRectangle(cornerRadius: theme.radii.small))
                    .overlay(RoundedRectangle(cornerRadius: theme.radii.small).stroke(theme.colors.border, lineWidth: 1))
            }
            HStack(spacing: 14) {
                Picker("Schedule", selection: $automation.schedule.frequency) {
                    ForEach(CodexAutomationFrequency.allCases) { Text($0.title).tag($0) }
                }
                if automation.schedule.frequency == .weekly {
                    Picker("Day", selection: $automation.schedule.weekday) {
                        ForEach(Array(Calendar.current.weekdaySymbols.enumerated()), id: \.offset) { index, day in
                            Text(day).tag(index + 1)
                        }
                    }
                }
                Picker("Hour", selection: $automation.schedule.hour) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                Picker("Minute", selection: $automation.schedule.minute) {
                    ForEach([0, 15, 30, 45], id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
            }
            Toggle("Enabled", isOn: Binding(
                get: { automation.status != .disabled },
                set: { automation.status = $0 ? .enabled : .disabled }
            ))
        }
        .padding(24)
        .frame(width: 620)
        .background(theme.colors.surface)
    }
}
