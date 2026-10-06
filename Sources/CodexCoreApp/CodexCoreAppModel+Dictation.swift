import CodexCoreUI

@MainActor
extension CodexCoreAppModel {
    func startDictation() {
        guard !voiceSession.isActive else { return }
        prepareComposerEdit()
        let origin = composerEditOrigin
        dictationSession.start { [weak self] completion in
            self?.applyDictationCompletion(completion, origin: origin)
        }
    }

    func stopDictationAndInsert() {
        dictationSession.stop(.insert)
    }

    func stopDictationAndSend() {
        dictationSession.stop(.send)
    }

    func retryDictation() {
        dictationSession.retry()
    }

    func abortDictation() {
        dictationSession.abort()
    }

    func applyDictationCompletion(_ completion: CodexDictationCompletion, origin: CodexComposerEditOrigin) {
        guard let id = composerDraftID(for: origin), id == composerSession.activeDraftID else { return }
        draft = Self.joinDictationTranscript(completion.text, to: draft)
        guard completion.action == .send else { return }
        Task {
            guard composerDraftID(for: origin) == composerSession.activeDraftID else { return }
            await sendDraft()
        }
    }

    static func joinDictationTranscript(_ transcript: String, to existingDraft: String) -> String {
        let transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return existingDraft }
        guard !existingDraft.isEmpty else { return transcript }
        if existingDraft.last?.isWhitespace == true {
            return existingDraft + transcript
        }
        return existingDraft + " " + transcript
    }
}
