import SwiftUI
import CodexCore

public struct CodexTurnPlanPanel: View {
    @Environment(\.codexAgentTheme) private var theme

    public let steps: [TurnPlanStep]
    public let explanation: String?
    public init(
        steps: [TurnPlanStep],
        explanation: String?
    ) {
        self.steps = steps
        self.explanation = explanation
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(theme.fonts.label)
                    .foregroundStyle(theme.colors.accent)
                Text("Plan")
                    .font(theme.fonts.label)
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
                        .font(theme.fonts.micro)
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

        }
        .padding(12)
        .frame(width: 360)
        .codexGlass(
            RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous),
            role: .panel
        )
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

}

public struct CodexPlanSummaryPage: View {
    @Environment(\.codexAgentTheme) private var theme

    public let plan: CodexPlanSummary

    public init(plan: CodexPlanSummary) {
        self.plan = plan
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: "list.bullet.rectangle")
                        .foregroundStyle(theme.colors.accent)
                    Text("Plan")
                        .font(theme.fonts.panelTitle)
                        .foregroundStyle(theme.colors.textPrimary)
                    Spacer(minLength: 0)
                    Text(plan.progressLabel)
                        .font(theme.fonts.code)
                        .foregroundStyle(theme.colors.textTertiary)
                }

                if let explanation = plan.explanation?.nilIfBlank {
                    Text(explanation)
                        .font(theme.fonts.body)
                        .foregroundStyle(theme.colors.textSecondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: statusImage(step.status))
                                .font(theme.fonts.actionIcon)
                                .foregroundStyle(statusColor(step.status))
                                .frame(width: 20)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(step.step)
                                    .font(theme.fonts.body)
                                    .foregroundStyle(step.status == .completed ? theme.colors.textTertiary : theme.colors.textPrimary)
                                    .strikethrough(step.status == .completed, color: theme.colors.textTertiary)
                                Text(statusLabel(step.status))
                                    .font(theme.fonts.caption)
                                    .foregroundStyle(theme.colors.textTertiary)
                            }
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Step \(index + 1) of \(plan.steps.count), \(statusLabel(step.status)): \(step.step)")
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
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

    private func statusLabel(_ status: TurnPlanStepStatus) -> String {
        switch status {
        case .pending: return "Pending"
        case .inProgress: return "In progress"
        case .completed: return "Completed"
        }
    }
}

public struct CodexApprovalRequestsPanel: View {
    @Environment(\.codexAgentTheme) private var theme

    public let prompts: [CodexApprovalPrompt]
    public let onApprove: (CodexServerRequestKey) -> Void
    public let onDeny: (CodexServerRequestKey) -> Void
    public let onDecision: (CodexServerRequestKey, CodexCommandApprovalDecision) -> Void

    public init(
        prompts: [CodexApprovalPrompt],
        onApprove: @escaping (CodexServerRequestKey) -> Void,
        onDeny: @escaping (CodexServerRequestKey) -> Void
    ) {
        self.prompts = prompts
        self.onApprove = onApprove
        self.onDeny = onDeny
        self.onDecision = { id, decision in
            if decision.isApproval { onApprove(id) } else { onDeny(id) }
        }
    }

    public init(
        prompts: [CodexApprovalPrompt],
        onDecision: @escaping (CodexServerRequestKey, CodexCommandApprovalDecision) -> Void
    ) {
        self.prompts = prompts
        self.onApprove = { id in onDecision(id, .accept) }
        self.onDeny = { id in onDecision(id, .decline) }
        self.onDecision = onDecision
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(theme.fonts.label)
                    .foregroundStyle(theme.colors.warning)
                Text("Approval needed")
                    .font(theme.fonts.label)
                    .foregroundStyle(theme.colors.textPrimary)
                Spacer(minLength: 0)
                Text("\(prompts.count)")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
            }

            ForEach(prompts.prefix(3)) { prompt in
                CodexApprovalPromptRow(
                    prompt: prompt,
                    onApprove: onApprove,
                    onDeny: onDeny,
                    onDecision: onDecision
                )
            }
        }
        .padding(12)
        .frame(width: 360)
        .codexGlass(
            RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous),
            role: .panel
        )
    }
}

private struct CodexApprovalPromptRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let prompt: CodexApprovalPrompt
    let onApprove: (CodexServerRequestKey) -> Void
    let onDeny: (CodexServerRequestKey) -> Void
    let onDecision: (CodexServerRequestKey, CodexCommandApprovalDecision) -> Void

    init(
        prompt: CodexApprovalPrompt,
        onApprove: @escaping (CodexServerRequestKey) -> Void,
        onDeny: @escaping (CodexServerRequestKey) -> Void,
        onDecision: @escaping (CodexServerRequestKey, CodexCommandApprovalDecision) -> Void
    ) {
        self.prompt = prompt
        self.onApprove = onApprove
        self.onDeny = onDeny
        self.onDecision = onDecision
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: prompt.kind.systemImage)
                    .font(theme.fonts.caption.weight(.semibold))
                    .foregroundStyle(theme.colors.textSecondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.title)
                        .font(theme.fonts.label)
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
                    .font(theme.fonts.code)
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

            ForEach(Array(prompt.contextLines.enumerated()), id: \.offset) { _, context in
                Text(context)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            if prompt.kind == .command {
                Menu {
                    ForEach(Array(prompt.commandDecisions.enumerated()), id: \.offset) { _, decision in
                        Button(prompt.label(for: decision)) {
                            onDecision(prompt.id, decision)
                        }
                    }
                } label: {
                    Label("Choose action", systemImage: "checkmark.shield")
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help("Respond to this command approval")
            } else {
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
        }
        .padding(10)
        .background(theme.colors.surface.opacity(0.58), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.border, lineWidth: 1)
        )
    }
}

public struct CodexInteractivePromptsPanel: View {
    @Environment(\.codexAgentTheme) private var theme

    public let prompts: [CodexInteractivePrompt]
    public let onSubmit: (CodexServerRequestKey, [String: String]) -> Void
    public let onAccept: (CodexServerRequestKey) -> Void
    public let onDecline: (CodexServerRequestKey) -> Void

    public init(
        prompts: [CodexInteractivePrompt],
        onSubmit: @escaping (CodexServerRequestKey, [String: String]) -> Void,
        onAccept: @escaping (CodexServerRequestKey) -> Void,
        onDecline: @escaping (CodexServerRequestKey) -> Void
    ) {
        self.prompts = prompts
        self.onSubmit = onSubmit
        self.onAccept = onAccept
        self.onDecline = onDecline
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble")
                    .font(theme.fonts.label)
                    .foregroundStyle(theme.colors.accent)
                Text("Input needed")
                    .font(theme.fonts.label)
                    .foregroundStyle(theme.colors.textPrimary)
                Spacer(minLength: 0)
                if prompts.count > 1 {
                    Text("\(prompts.count) requests")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                }
            }

            if let prompt = prompts.first {
                CodexInteractivePromptRow(
                    prompt: prompt,
                    onSubmit: onSubmit,
                    onAccept: onAccept,
                    onDecline: onDecline
                )
                .id(prompt.id)
            }
        }
        .padding(12)
        .frame(width: 360)
        .codexGlass(
            RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous),
            role: .panel
        )
    }
}

private struct CodexInteractivePromptRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let prompt: CodexInteractivePrompt
    let onSubmit: (CodexServerRequestKey, [String: String]) -> Void
    let onAccept: (CodexServerRequestKey) -> Void
    let onDecline: (CodexServerRequestKey) -> Void
    @State private var progress = CodexInteractivePromptProgress()
    @State private var otherQuestionIDs: Set<String> = []

    init(
        prompt: CodexInteractivePrompt,
        onSubmit: @escaping (CodexServerRequestKey, [String: String]) -> Void,
        onAccept: @escaping (CodexServerRequestKey) -> Void,
        onDecline: @escaping (CodexServerRequestKey) -> Void
    ) {
        self.prompt = prompt
        self.onSubmit = onSubmit
        self.onAccept = onAccept
        self.onDecline = onDecline
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: prompt.kind.systemImage)
                    .font(theme.fonts.caption.weight(.semibold))
                    .foregroundStyle(theme.colors.textSecondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.title)
                        .font(theme.fonts.label)
                        .foregroundStyle(theme.colors.textPrimary)
                        .lineLimit(1)
                    if prompt.questions.isEmpty {
                        Text(prompt.detail)
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.textSecondary)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
            }

            if prompt.kind == .userInput || prompt.requiresElicitationForm {
                if let question = currentQuestion {
                    HStack {
                        Text("Question \(progress.questionIndex + 1) of \(prompt.questions.count)")
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.textTertiary)
                        Spacer(minLength: 0)
                    }
                    questionEditor(question)
                }
            } else if let serverName = prompt.serverName {
                Text(serverName)
                    .font(theme.fonts.code)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.colors.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
            }

            HStack(spacing: 8) {
                if progress.questionIndex > 0 {
                    Button {
                        progress.moveBack()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button {
                        onDecline(prompt.id)
                    } label: {
                        Label(prompt.kind == .userInput ? "Cancel" : "Decline", systemImage: "xmark")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer(minLength: 0)

                Button {
                    if prompt.kind == .userInput || prompt.requiresElicitationForm {
                        if progress.isLastQuestion(count: prompt.questions.count) {
                            onSubmit(prompt.id, progress.answers)
                        } else {
                            progress.moveForward(count: prompt.questions.count)
                        }
                    } else {
                        onAccept(prompt.id)
                    }
                } label: {
                    Label(primaryActionTitle, systemImage: primaryActionSystemImage)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(
                    prompt.kind == .mcpElicitation
                        && progress.isLastQuestion(count: prompt.questions.count)
                        && (!prompt.canAcceptElicitation || !prompt.isElicitationSubmissionValid(answers: progress.answers))
                )
                .disabled((prompt.kind == .userInput || prompt.requiresElicitationForm) && !hasCurrentAnswer)
            }
        }
        .padding(10)
        .background(theme.colors.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
    }

    private var currentQuestion: CodexUserInputQuestion? {
        progress.currentQuestion(in: prompt.questions)
    }

    private var hasCurrentAnswer: Bool {
        guard let currentQuestion else { return true }
        return progress.hasAnswer(for: currentQuestion.id)
    }

    private var primaryActionTitle: String {
        guard prompt.kind == .userInput || prompt.requiresElicitationForm else { return "Allow" }
        return progress.isLastQuestion(count: prompt.questions.count) ? "Submit" : "Next"
    }

    private var primaryActionSystemImage: String {
        primaryActionTitle == "Next" ? "chevron.right" : "checkmark"
    }

    @ViewBuilder
    private func questionEditor(_ question: CodexUserInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header = question.header {
                Text(header)
                    .font(theme.fonts.caption.weight(.semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(1)
            }
            Text(question.question)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textSecondary)
                .lineLimit(3)

            if !question.options.isEmpty {
                CodexFlexibleOptionButtons(
                    options: question.options,
                    selectedAnswer: progress.answers[question.id],
                    onSelect: {
                        otherQuestionIDs.remove(question.id)
                        progress.answers[question.id] = $0
                    }
                )

                if question.isOtherAllowed {
                    Button {
                        otherQuestionIDs.insert(question.id)
                        progress.answers[question.id] = ""
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: otherQuestionIDs.contains(question.id) ? "checkmark.circle.fill" : "circle")
                                .font(theme.fonts.micro)
                            Text("Other")
                                .font(theme.fonts.chipLabel)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .background(
                        (otherQuestionIDs.contains(question.id) ? theme.colors.accent.opacity(0.16) : theme.colors.surface.opacity(0.72)),
                        in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                    )
                }
            }

            if question.isSecret {
                SecureField("Answer", text: answerBinding(for: question.id))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            } else if question.options.isEmpty || otherQuestionIDs.contains(question.id) {
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
            get: { progress.answers[id] ?? "" },
            set: { progress.answers[id] = $0 }
        )
    }
}

struct CodexInteractivePromptProgress: Equatable {
    var questionIndex = 0
    var answers: [String: String] = [:]

    func currentQuestion(in questions: [CodexUserInputQuestion]) -> CodexUserInputQuestion? {
        guard questions.indices.contains(questionIndex) else { return nil }
        return questions[questionIndex]
    }

    func hasAnswer(for questionID: String) -> Bool {
        !(answers[questionID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func isLastQuestion(count: Int) -> Bool {
        count == 0 || questionIndex >= count - 1
    }

    mutating func moveForward(count: Int) {
        guard !isLastQuestion(count: count) else { return }
        questionIndex += 1
    }

    mutating func moveBack() {
        questionIndex = max(0, questionIndex - 1)
    }
}

private struct CodexFlexibleOptionButtons: View {
    @Environment(\.codexAgentTheme) private var theme

    let options: [CodexUserInputOption]
    let selectedAnswer: String?
    let onSelect: (String) -> Void

    init(options: [CodexUserInputOption], selectedAnswer: String?, onSelect: @escaping (String) -> Void) {
        self.options = options
        self.selectedAnswer = selectedAnswer
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(options, id: \.label) { option in
                Button {
                    onSelect(option.label)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: selectedAnswer == option.label ? "checkmark.circle.fill" : "circle")
                            .font(theme.fonts.micro)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.label)
                                .font(theme.fonts.chipLabel)
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
