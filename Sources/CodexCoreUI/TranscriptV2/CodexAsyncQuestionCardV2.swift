import SwiftUI

/// Nonblocking questions from `agentMessage.delivery == async`.
/// Responses leave this view only after the user chooses the visible send action.
public struct CodexAsyncQuestionCardV2: View {
    @Environment(\.codexAgentTheme) private var theme
    public let model: CodexAsyncQuestionV2
    private let onSubmitUserMessage: ((String) async -> CodexTranscriptUserMessageReceipt)?
    private let onStageUserMessage: ((String) -> Void)?
    @State private var localState = CodexAsyncQuestionPresentationState()
    private let presentationState: CodexAsyncQuestionPresentationState?

    public init(
        model: CodexAsyncQuestionV2,
        onSubmitUserMessage: ((String) async -> CodexTranscriptUserMessageReceipt)? = nil,
        onStageUserMessage: ((String) -> Void)? = nil
    ) {
        self.model = model
        self.onSubmitUserMessage = onSubmitUserMessage
        self.onStageUserMessage = onStageUserMessage
        self.presentationState = nil
    }

    init(
        model: CodexAsyncQuestionV2,
        presentationState: CodexAsyncQuestionPresentationState,
        onSubmitUserMessage: ((String) async -> CodexTranscriptUserMessageReceipt)? = nil,
        onStageUserMessage: ((String) -> Void)? = nil
    ) {
        self.model = model
        self.onSubmitUserMessage = onSubmitUserMessage
        self.onStageUserMessage = onStageUserMessage
        self.presentationState = presentationState
    }

    private var state: CodexAsyncQuestionPresentationState { presentationState ?? localState }
    private var drafts: [String: CodexAsyncQuestionAnswerDraft] {
        get { state.drafts }
        nonmutating set { state.drafts = newValue }
    }
    private var questionIndex: Int {
        get { state.questionIndex }
        nonmutating set { state.questionIndex = newValue }
    }
    private var isCollapsed: Bool {
        get { state.isCollapsed }
        nonmutating set { state.isCollapsed = newValue }
    }

    public var body: some View {
        if let question = activeQuestion {
            VStack(alignment: .leading, spacing: theme.spacing.md) {
                Button {
                    isCollapsed.toggle()
                } label: {
                    HStack(spacing: theme.spacing.sm) {
                        Image(systemName: "questionmark.bubble")
                        Text("Question").font(theme.fonts.label)
                        if isCollapsed {
                            Text(question.title)
                                .font(theme.fonts.body)
                                .foregroundStyle(theme.colors.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: theme.spacing.sm)
                        if model.questions.count > 1 {
                            Text("\(questionIndex + 1)/\(model.questions.count)")
                                .font(theme.fonts.caption.monospacedDigit())
                                .foregroundStyle(theme.colors.textTertiary)
                        }
                        Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                            .font(theme.fonts.caption)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed ? "Show question and options" : "Hide question and options")

                if !isCollapsed {
                    ScrollView {
                        VStack(alignment: .leading, spacing: theme.spacing.md) {
                            if !model.prompt.isEmpty, model.prompt != question.title {
                                Text(model.prompt)
                                    .font(theme.fonts.body)
                                    .foregroundStyle(theme.colors.textSecondary)
                                    .textSelection(.enabled)
                            }
                            Text(question.title)
                                .font(theme.fonts.body)
                                .textSelection(.enabled)
                            LazyVStack(spacing: theme.spacing.xxs) {
                                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                                    optionButton(option, index: index, question: question)
                                }
                                HStack(spacing: theme.spacing.sm) {
                                    Button("Other") {
                                        var draft = drafts[question.id] ?? .init()
                                        draft.usesCustomAnswer = true
                                        drafts[question.id] = draft
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .accessibilityValue(drafts[question.id]?.usesCustomAnswer == true ? "Selected" : "Not selected")
                                    TextField("Other answer…", text: customAnswerBinding(for: question))
                                        .textFieldStyle(.roundedBorder)
                                        .font(theme.fonts.body)
                                        .accessibilityLabel("Custom answer to \(question.title)")
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 240)
                    .disabled(model.isStreaming || !state.submissionStatus.canSubmit)
                    actions(for: question)
                }
                if let message = submissionStatusMessage {
                    Text(message)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                        .textSelection(.enabled)
                }
            }
            .foregroundStyle(theme.colors.textPrimary)
            .padding(theme.spacing.lg)
            .background(theme.colors.surface, in: RoundedRectangle(cornerRadius: theme.radii.large))
            .overlay(RoundedRectangle(cornerRadius: theme.radii.large).stroke(theme.colors.border, lineWidth: 1))
            .onChange(of: model.id) { _, _ in
                if presentationState == nil { localState = .init() }
            }
        }
    }

    private var activeQuestion: CodexAsyncQuestionV2.Question? {
        guard model.questions.indices.contains(questionIndex) else { return nil }
        return model.questions[questionIndex]
    }

    private var submissionStatusMessage: String? {
        switch state.submissionStatus {
        case .idle: nil
        case .submitting: "Sending answer…"
        case .accepted: "Answer submitted."
        case .staged: "Answer added to the chat draft."
        case .retainedForRetry(let message): "\(message) Your answer is saved in the follow-up queue."
        case .rejected(let message): message
        }
    }

    private func optionButton(_ option: String, index: Int, question: CodexAsyncQuestionV2.Question) -> some View {
        let draft = drafts[question.id] ?? .init()
        let selected = !draft.usesCustomAnswer && draft.selectedOption == option
        return Button {
            var draft = drafts[question.id] ?? .init()
            draft.selectOption(option)
            drafts[question.id] = draft
        } label: {
            HStack(spacing: theme.spacing.sm) {
                Text(option).font(theme.fonts.body)
                Spacer(minLength: theme.spacing.sm)
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(theme.colors.accent)
                } else {
                    Text("\(index + 1)")
                        .font(theme.fonts.caption.monospacedDigit())
                        .foregroundStyle(theme.colors.textTertiary)
                }
            }
            .padding(.horizontal, theme.spacing.md)
            .padding(.vertical, theme.spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? theme.colors.accentSoft : .clear, in: RoundedRectangle(cornerRadius: theme.radii.small))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private func customAnswerBinding(for question: CodexAsyncQuestionV2.Question) -> Binding<String> {
        Binding(
            get: { drafts[question.id]?.customAnswer ?? "" },
            set: { value in
                var draft = drafts[question.id] ?? .init()
                draft.editCustomAnswer(value)
                drafts[question.id] = draft
            }
        )
    }

    private func actions(for question: CodexAsyncQuestionV2.Question) -> some View {
        HStack {
            if questionIndex > 0 {
                Button("Back") { questionIndex -= 1 }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Spacer(minLength: theme.spacing.sm)
            if questionIndex + 1 < model.questions.count {
                Button("Next") {
                    questionIndex += 1
                    isCollapsed = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(drafts[question.id]?.answer == nil || model.isStreaming || !state.submissionStatus.canSubmit)
            } else if onSubmitUserMessage != nil || onStageUserMessage != nil {
                Button(onSubmitUserMessage == nil ? "Add answer to chat" : "Send answer") {
                    let answers = drafts.compactMapValues(\.answer)
                    guard let message = model.answerMessage(answers: answers), state.beginSubmission() else { return }
                    let submissionState = state
                    if let onSubmitUserMessage {
                        Task { submissionState.completeSubmission(await onSubmitUserMessage(message)) }
                    } else {
                        onStageUserMessage?(message)
                        submissionState.completeStaging()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!state.submissionStatus.canSubmit || model.answerMessage(answers: drafts.compactMapValues(\.answer)) == nil)
            }
        }
    }
}
