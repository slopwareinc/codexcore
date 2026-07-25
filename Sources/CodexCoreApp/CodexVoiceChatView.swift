import SwiftUI
import CodexCoreUI

struct CodexVoiceMiniControl: View {
    @Environment(\.codexAgentTheme) private var theme
    @Bindable var session: CodexVoiceChatSession
    let onOpen: () -> Void
    let onEnd: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 9) {
                    CodexVoiceOrb(
                        phase: session.phase,
                        level: session.isMuted ? 0 : session.inputLevel
                    )
                    .frame(width: 34, height: 34)
                    Text(session.isMuted ? "Voice muted" : "Voice active")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.colors.textPrimary)
                }
            }
            .buttonStyle(.plain)

            Button(role: .destructive, action: onEnd) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End voice chat")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .codexGlass(Capsule())
        .shadow(color: .black.opacity(0.24), radius: 18, y: 8)
    }
}

/// The official Voice bottom accessory contains only the orb and its compact
/// composer. Realtime utterances are projected by `CodexVoiceTranscriptProjection`
/// into the normal transcript above this view.
struct CodexVoiceConversationPanel: View {
    @Environment(\.codexAgentTheme) private var theme
    @Bindable var session: CodexVoiceChatSession
    let onSendText: (String) -> Void
    let onToggleMute: () -> Void
    let onToggleOutputMute: () -> Void
    let onEnd: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            CodexVoiceOrb(
                phase: session.phase,
                level: session.isMuted ? 0 : session.inputLevel
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
                        .font(.system(size: 16, weight: .regular))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.colors.textSecondary)
                .accessibilityLabel("Add to voice chat")

                Label("Approve for me", systemImage: "shield.lefthalf.filled")
                    .font(.system(size: 12, weight: .medium))
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
                        .font(.system(size: 14, weight: .semibold))
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
        .background(
            theme.colors.surfaceElevated.opacity(0.86),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(theme.colors.border.opacity(0.44), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 16, y: 8)
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

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
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
        .shadow(color: Color(red: 0.34, green: 0.30, blue: 1).opacity(0.22), radius: 18, y: 8)
        .accessibilityHidden(true)
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
