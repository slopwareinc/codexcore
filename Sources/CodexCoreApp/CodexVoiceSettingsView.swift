import SwiftUI
import CodexCore
import CodexCoreUI

struct CodexVoiceSettingsView: View {
    @Environment(\.codexAgentTheme) private var theme
    @Bindable var session: CodexVoiceChatSession
    var onRefreshVoices: () async -> Void
    @State private var speech = ""

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            Label("Realtime Voice", systemImage: "waveform").font(theme.fonts.panelTitle)
            Text("Voice, model, and output changes apply when the next Voice session starts.")
                .font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary)
            TextField("Realtime model", text: $session.selectedModel).textFieldStyle(.roundedBorder)
            Picker("Voice", selection: $session.selectedVoice) {
                ForEach(session.availableVoices, id: \.self) { voice in
                    Text(voice.rawValue.capitalized).tag(voice)
                }
            }
            Picker("Output", selection: $session.outputModality) {
                Text("Audio and captions").tag(CodexSchemaRealtimeOutputModality.audio)
                Text("Text only").tag(CodexSchemaRealtimeOutputModality.text)
            }.pickerStyle(.segmented)
            Button(session.isLoadingVoices ? "Reading voices…" : "Refresh runtime voices") {
                Task { await onRefreshVoices() }
            }.disabled(session.isLoadingVoices)
            if let error = session.voiceCatalogError { CodexErrorBanner(message: error) }
            if session.isActive {
                HStack {
                    TextField("Text to speak in the active session", text: $speech).textFieldStyle(.roundedBorder)
                    Button("Speak") {
                        let value = speech
                        speech = ""
                        Task { await session.sendSpeech(value) }
                    }.disabled(speech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(theme.spacing.lg)
        .background(theme.colors.surface, in: RoundedRectangle(cornerRadius: theme.radii.large))
        .overlay(RoundedRectangle(cornerRadius: theme.radii.large).stroke(theme.colors.border, lineWidth: 1))
    }
}
