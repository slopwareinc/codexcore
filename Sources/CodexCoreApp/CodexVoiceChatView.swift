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
                Image(systemName: "phone.down.fill")
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

struct CodexVoiceDock: View {
    @Environment(\.codexAgentTheme) private var theme
    @Bindable var session: CodexVoiceChatSession
    let onToggleMute: () -> Void
    let onToggleOutputMute: () -> Void
    let onEnd: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if let latest = session.transcript.last, !latest.text.isEmpty {
                Text(latest.text)
                    .font(theme.fonts.chat)
                    .foregroundStyle(theme.colors.textPrimary)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 560)
            }

            HStack(spacing: 16) {
                Button(action: onToggleMute) {
                    Image(systemName: session.isMuted ? "mic.slash.fill" : "mic.fill")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(session.isMuted ? "Unmute microphone" : "Mute microphone")

                CodexVoiceOrb(
                    phase: session.phase,
                    level: session.isMuted ? 0 : session.inputLevel
                )
                .frame(width: 82, height: 82)

                Button(action: onToggleOutputMute) {
                    Image(systemName: session.isOutputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(session.isOutputMuted ? "Unmute speaker" : "Mute speaker")

                Button(role: .destructive, action: onEnd) {
                    Image(systemName: "phone.down.fill")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.colors.danger)
                .accessibilityLabel("End voice chat")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .codexGlass(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.20), radius: 18, y: 8)
    }
}

private struct CodexVoiceOrb: View {
    let phase: CodexVoiceChatSession.Phase
    let level: Float

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2
                let pulse = CGFloat((sin(time * 2.4) + 1) / 2)
                let activity = CGFloat(level)
                let haloRadius = radius * (0.76 + pulse * 0.10 + activity * 0.18)
                let halo = Path(ellipseIn: CGRect(
                    x: center.x - haloRadius,
                    y: center.y - haloRadius,
                    width: haloRadius * 2,
                    height: haloRadius * 2
                ))
                context.fill(
                    halo,
                    with: .radialGradient(
                        Gradient(colors: [
                            Color(red: 0.98, green: 0.52, blue: 0.70).opacity(0.78),
                            Color(red: 0.48, green: 0.38, blue: 0.98).opacity(0.30),
                            .clear,
                        ]),
                        center: center,
                        startRadius: 0,
                        endRadius: haloRadius
                    )
                )

                let coreRadius = radius * (0.48 + activity * 0.08)
                let core = Path(ellipseIn: CGRect(
                    x: center.x - coreRadius,
                    y: center.y - coreRadius,
                    width: coreRadius * 2,
                    height: coreRadius * 2
                ))
                context.fill(
                    core,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 1.0, green: 0.70, blue: 0.78),
                            Color(red: 0.56, green: 0.40, blue: 0.98),
                        ]),
                        startPoint: CGPoint(x: center.x - coreRadius, y: center.y - coreRadius),
                        endPoint: CGPoint(x: center.x + coreRadius, y: center.y + coreRadius)
                    )
                )
            }
        }
    }
}
