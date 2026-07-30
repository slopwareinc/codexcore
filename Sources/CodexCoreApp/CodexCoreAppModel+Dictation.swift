import CodexCoreUI

@MainActor
extension CodexCoreAppModel {
    func startDictation() {
        guard !voiceSession.isActive else { return }
        dictationSession.start { [weak self] completion in
            self?.applyDictationCompletion(completion)
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

    private func applyDictationCompletion(_ completion: CodexDictationCompletion) {
        draft = Self.joinDictationTranscript(completion.text, to: draft)
        guard completion.action == .send else { return }
        Task { await sendDraft() }
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
