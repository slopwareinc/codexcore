import SwiftUI
import CodexCoreUI

/// Compact native-panel content. The panel itself owns z-order, display
/// persistence, pointer pass-through, and focus policy; this view only exposes
/// the actions for the one shared realtime Voice session.
struct CodexVoiceGlobalOverlayView: View {
    @Environment(\.codexAgentTheme) private var theme
    @Bindable var session: CodexVoiceChatSession
    let state: CodexVoicePresentationState
    let reduceMotion: Bool
    let onStartNew: () -> Void
    let onResume: () -> Void
    let onStop: () -> Void
    let onToggleMicrophone: () -> Void
    let onToggleOutput: () -> Void
    let onToggleCaptions: () -> Void
    let onToggleActivity: () -> Void
    let onOpenThread: () -> Void
    let onFocusComposer: () -> Void
    let onKeyboardInteraction: () -> Void
    let onEscape: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                CodexVoiceOrb(
                    phase: session.phase,
                    level: session.isMuted ? 0 : session.inputLevel,
                    reduceMotion: reduceMotion
                )
                .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(theme.fonts.label.weight(.semibold))
                        .foregroundStyle(theme.colors.textPrimary)
                    Text(statusText)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(action: onOpenThread) {
                    Image(systemName: "arrow.up.forward.app")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open associated Voice thread")
                .help("Open associated Voice thread")
                Button(action: onStop) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop Voice")
                .help("Stop Voice")
            }

            if state.captionsVisible, let caption {
                Text(caption)
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(theme.colors.surfaceElevated.opacity(0.62), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel("Latest Voice caption: \(caption)")
            }

            if state.activityVisible {
                HStack(spacing: 7) {
                    Image(systemName: "waveform")
                        .font(.caption2)
                    ProgressView(value: Double(session.isMuted ? 0 : session.inputLevel))
                        .progressViewStyle(.linear)
                        .tint(theme.colors.accent)
                    Text("Activity")
                        .font(theme.fonts.caption)
                }
                .foregroundStyle(theme.colors.textTertiary)
                .accessibilityLabel("Voice activity")
            }

            HStack(spacing: 7) {
                actionButton(
                    systemImage: session.isMuted ? "mic.slash.fill" : "mic.fill",
                    label: session.isMuted ? "Unmute microphone" : "Mute microphone",
                    action: onToggleMicrophone
                )
                actionButton(
                    systemImage: session.isOutputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    label: session.isOutputMuted ? "Unmute output" : "Mute output",
                    action: onToggleOutput
                )
                actionButton(
                    systemImage: state.captionsVisible ? "captions.bubble.fill" : "captions.bubble",
                    label: state.captionsVisible ? "Hide captions" : "Show captions",
                    action: onToggleCaptions
                )
                actionButton(
                    systemImage: state.activityVisible ? "waveform.path.ecg" : "waveform.path.ecg.rectangle",
                    label: state.activityVisible ? "Hide activity" : "Show activity",
                    action: onToggleActivity
                )
                Spacer(minLength: 0)
                Button(action: onFocusComposer) {
                    Label("Focus composer", systemImage: "text.cursor")
                        .font(theme.fonts.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Open Voice thread and focus composer")
                .help("Open Voice thread and focus composer")
            }

            if !session.isActive {
                HStack(spacing: 8) {
                    Button(action: onResume) {
                        Label("Retry Voice", systemImage: "arrow.clockwise")
                            .font(theme.fonts.caption)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Retry Voice on the same thread")
                    Button(action: onStartNew) {
                        Label("Start new", systemImage: "plus")
                            .font(theme.fonts.caption)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Start a new Voice thread")
                }
            }
        }
        .padding(14)
        .frame(minWidth: 280, idealWidth: 360, maxWidth: 560, minHeight: 140, idealHeight: 176, maxHeight: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voice chat overlay")
        .onExitCommand(perform: onEscape)
        .onTapGesture { onKeyboardInteraction() }
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
    }

    @ViewBuilder
    private func actionButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 27, height: 27)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private var title: String {
        switch state.phase {
        case .retryableFailure: "Voice needs attention"
        case .hidden: "Voice paused"
        default: "Voice active"
        }
    }

    private var statusText: String {
        switch state.phase {
        case .launching: "Connecting…"
        case .connected: "Connected"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case let .retryableFailure(message): message
        case .hidden: "Ready to resume"
        case .inactive, .stopped: "Stopped"
        case .handingOff: "Moving Voice surface…"
        }
    }

    private var caption: String? {
        session.transcript.last(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.text
    }
}

/// The official Voice bottom accessory contains only the orb and its compact
/// composer. Realtime utterances are projected by `CodexVoiceTranscriptProjection`
/// into the normal transcript above this view.
struct CodexVoiceConversationPanel: View {
    @Environment(\.codexAgentTheme) private var theme
    @Bindable var session: CodexVoiceChatSession
    var reduceMotion = false
    let onSendText: (String) -> Void
    let onToggleMute: () -> Void
    let onToggleOutputMute: () -> Void
    let onEnd: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            CodexVoiceOrb(
                phase: session.phase,
                level: session.isMuted ? 0 : session.inputLevel,
                reduceMotion: reduceMotion
            )
            .frame(width: 112, height: 112)
            .padding(.bottom, 18)

            CodexVoiceComposer(
                session: session,
                onSendText: onSendText,
                onToggleMute: onToggleMute,
                onToggleOutputMute: onToggleOutputMute,
                onEnd: onEnd
            )
        }
        .frame(maxWidth: theme.spacing.composerMaxWidth + 32)
        .padding(.horizontal, 14)
        .padding(.bottom, 22)
    }
}

private struct CodexVoiceComposer: View {
    @Environment(\.codexAgentTheme) private var theme
    @Bindable var session: CodexVoiceChatSession
    let onSendText: (String) -> Void
    let onToggleMute: () -> Void
    let onToggleOutputMute: () -> Void
    let onEnd: () -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Do anything", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(theme.fonts.chat)
                .foregroundStyle(theme.colors.textPrimary)
                .lineLimit(1...3)
                .focused($isFocused)
                .onSubmit(submit)

            HStack(spacing: 12) {
                Button(action: {}) {
                    Image(systemName: "plus")
                        .font(theme.fonts.actionIcon)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.colors.textSecondary)
                .accessibilityLabel("Add to voice chat")

                Label("Approve for me", systemImage: "shield.lefthalf.filled")
                    .font(theme.fonts.chipLabel)
                    .foregroundStyle(theme.colors.textTertiary)

                Spacer(minLength: 12)

                Button(action: onToggleOutputMute) {
                    Image(systemName: session.isOutputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.colors.textSecondary)
                .accessibilityLabel(session.isOutputMuted ? "Unmute speaker" : "Mute speaker")

                Button(action: onToggleMute) {
                    Image(systemName: session.isMuted ? "mic.slash.fill" : "mic.fill")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.colors.textSecondary)
                .accessibilityLabel(session.isMuted ? "Unmute microphone" : "Mute microphone")

                Button(action: onEnd) {
                    Image(systemName: "xmark")
                        .font(theme.fonts.label)
                        .foregroundStyle(Color.black.opacity(0.82))
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.94), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("End voice chat")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(minHeight: 94)
        .codexGlass(
            RoundedRectangle(cornerRadius: theme.radii.large, style: .continuous),
            role: .panel
        )
        .onAppear { isFocused = true }
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        onSendText(text)
    }
}

private struct CodexVoiceOrb: View {
    let phase: CodexVoiceChatSession.Phase
    let level: Float
    var reduceMotion = false

    var body: some View {
        Group {
            if reduceMotion {
                orbCanvas(time: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                    orbCanvas(time: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .shadow(color: Color(red: 0.34, green: 0.30, blue: 1).opacity(0.22), radius: 18, y: 8)
        .accessibilityHidden(true)
    }

    private func orbCanvas(time: TimeInterval) -> some View {
        Canvas { context, size in
                let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
                let circle = Path(ellipseIn: bounds)
                let activity = max(CGFloat(level), phaseActivity)
                let drift = CGFloat(sin(time * phaseSpeed))

                context.drawLayer { layer in
                    layer.clip(to: circle)
                    layer.fill(
                        circle,
                        with: .linearGradient(
                            Gradient(stops: [
                                .init(color: Color(red: 0.28, green: 0.24, blue: 0.98), location: 0),
                                .init(color: Color(red: 0.43, green: 0.38, blue: 1.0), location: 0.42),
                                .init(color: Color(red: 0.96, green: 0.97, blue: 1.0), location: 1),
                            ]),
                            startPoint: CGPoint(x: size.width * 0.34, y: 0),
                            endPoint: CGPoint(x: size.width * 0.62, y: size.height)
                        )
                    )

                    layer.addFilter(.blur(radius: 11))
                    let glowSize = size.width * (0.72 + activity * 0.16)
                    let glowRect = CGRect(
                        x: size.width * (0.06 + drift * 0.06),
                        y: size.height * (0.46 - activity * 0.08),
                        width: glowSize,
                        height: glowSize * 0.68
                    )
                    layer.fill(
                        Path(ellipseIn: glowRect),
                        with: .color(Color.white.opacity(0.94))
                    )

                    let violetRect = CGRect(
                        x: size.width * (0.42 - drift * 0.08),
                        y: size.height * 0.02,
                        width: size.width * 0.64,
                        height: size.height * 0.58
                    )
                    layer.fill(
                        Path(ellipseIn: violetRect),
                        with: .color(Color(red: 0.34, green: 0.28, blue: 1).opacity(0.72))
                    )
                }

                context.stroke(circle, with: .color(.white.opacity(0.30)), lineWidth: 1)
        }
    }

    private var phaseSpeed: Double {
        switch phase {
        case .speaking: 3.8
        case .thinking: 2.6
        case .starting: 2.1
        case .listening: 1.8
        case .inactive, .failed: 1.2
        }
    }

    private var phaseActivity: CGFloat {
        switch phase {
        case .speaking: 0.5
        case .thinking: 0.26
        case .starting: 0.18
        case .listening: 0.1
        case .inactive, .failed: 0
        }
    }
}
