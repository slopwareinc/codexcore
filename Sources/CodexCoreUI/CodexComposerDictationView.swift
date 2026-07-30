import SwiftUI

struct ComposerMicrophoneButton: View {
    @Environment(\.codexAgentTheme) private var theme
    let phase: CodexComposerDictationState.Phase
    let actions: CodexComposerDictationActions?
    @State private var longPressStarted = false

    var body: some View {
        Button {
            if longPressStarted {
                longPressStarted = false
                actions?.stopAndInsert()
                return
            }
            switch phase {
            case .retry:
                actions?.retry()
            case .idle:
                actions?.start()
            case .starting, .recording:
                actions?.stopAndInsert()
            case .transcribing:
                break
            }
        } label: {
            Image(systemName: phase == .retry ? "arrow.clockwise" : "mic")
                .font(theme.fonts.chat)
                .foregroundStyle(theme.colors.textSecondary)
                .frame(width: theme.spacing.iconLarge, height: theme.spacing.iconLarge)
        }
        .buttonStyle(.plain)
        .disabled(actions == nil || phase == .transcribing)
        .onLongPressGesture(
            minimumDuration: 0.15,
            maximumDistance: 12,
            pressing: { isPressing in
                if !isPressing, longPressStarted {
                    longPressStarted = false
                    actions?.stopAndInsert()
                }
            },
            perform: {
                guard phase == .idle else { return }
                longPressStarted = true
                actions?.start()
            }
        )
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }

    private var help: String {
        guard actions != nil else { return "Dictation is unavailable" }
        return phase == .retry ? "Retry dictation" : "Click to dictate or hold"
    }

    private var accessibilityLabel: String {
        phase == .retry ? "Retry dictation" : "Dictate"
    }
}

struct ComposerDictationFooter: View {
    @Environment(\.codexAgentTheme) private var theme
    let state: CodexComposerDictationState
    let actions: CodexComposerDictationActions
    let isCompact: Bool

    var body: some View {
        HStack(spacing: isCompact ? 7 : 10) {
            Image(systemName: "plus")
                .font(theme.fonts.chat)
                .foregroundStyle(theme.colors.textTertiary.opacity(0.45))
                .frame(width: theme.spacing.iconLarge, height: theme.spacing.iconLarge)

            ComposerDictationWaveform(levels: state.waveformLevels)
                .frame(maxWidth: .infinity)

            Text(Self.formattedDuration(state.duration))
                .font(theme.fonts.caption.monospacedDigit())
                .foregroundStyle(theme.colors.textSecondary)
                .frame(minWidth: 34, alignment: .trailing)

            if state.phase == .transcribing || state.phase == .starting {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: theme.spacing.iconLarge, height: theme.spacing.iconLarge)
            } else {
                Button(action: actions.stopAndInsert) {
                    Image(systemName: "stop.fill")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textPrimary)
                        .frame(width: theme.spacing.iconLarge + 2, height: theme.spacing.iconLarge + 2)
                        .background(theme.colors.surfaceSunken, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Transcribe and insert")

                Button(action: actions.stopAndSend) {
                    Image(systemName: "arrow.up")
                        .font(theme.fonts.label.weight(.semibold))
                        .foregroundStyle(theme.colors.canvas)
                        .frame(width: theme.spacing.iconLarge + 4, height: theme.spacing.iconLarge + 4)
                        .background(theme.colors.textPrimary, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Transcribe and send")
                .accessibilityLabel("Transcribe and send")
            }
        }
        .frame(minHeight: theme.spacing.iconLarge + 4)
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

private struct ComposerDictationWaveform: View {
    @Environment(\.codexAgentTheme) private var theme
    let levels: [Double]

    var body: some View {
        GeometryReader { proxy in
            let barCount = max(8, min(32, Int(proxy.size.width / 5)))
            let visibleLevels = Array(levels.suffix(barCount))
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    let offset = barCount - visibleLevels.count
                    let level = index >= offset ? visibleLevels[index - offset] : 0.08
                    Capsule()
                        .fill(theme.colors.accent.opacity(0.82))
                        .frame(
                            width: 2,
                            height: max(3, proxy.size.height * min(1, max(0.08, level)))
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 22)
        .accessibilityHidden(true)
    }
}

struct ComposerDictationErrorBanner: View {
    @Environment(\.codexAgentTheme) private var theme
    let message: String
    let onDismiss: (@MainActor () -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
            Text(message)
                .lineLimit(2)
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss dictation error")
            }
        }
        .font(theme.fonts.caption)
        .foregroundStyle(theme.colors.danger)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            theme.colors.danger.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }
}
