import CodexCoreUI
import Foundation

extension CodexVoiceChatSession {
    /// Projects every live Voice utterance through the same turn model consumed
    /// by the normal AppKit transcript. The orb/composer remain a separate
    /// bottom accessory; captions do not.
    var transcriptTurns: [CodexTurnV2] {
        struct Draft {
            var id: String
            var user: CodexUserMessageV2?
            var answer: CodexAssistantTextV2?
            var userIsFinal = true
        }

        var drafts: [Draft] = []
        var current: Draft?

        func finishCurrent() {
            guard let value = current else { return }
            drafts.append(value)
            current = nil
        }

        for entry in transcript {
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if entry.role.localizedCaseInsensitiveContains("user") {
                finishCurrent()
                let identifier = entry.id.uuidString.lowercased()
                current = Draft(
                    id: "realtime-voice:\(identifier)",
                    user: .init(
                        id: "realtime-voice-user:\(identifier)",
                        text: text,
                        rawText: text
                    ),
                    answer: nil,
                    userIsFinal: entry.isFinal
                )
            } else if entry.role.localizedCaseInsensitiveContains("assistant") {
                if current?.answer != nil {
                    finishCurrent()
                }
                let identifier = entry.id.uuidString.lowercased()
                if current == nil {
                    current = Draft(
                        id: "realtime-voice:\(identifier)",
                        user: nil,
                        answer: nil
                    )
                }
                current?.answer = .init(
                    id: "realtime-voice-assistant:\(identifier)",
                    text: text,
                    isStreaming: !entry.isFinal
                )
            }
        }
        finishCurrent()

        var coalescedDrafts: [Draft] = []
        for draft in drafts {
            if let last = coalescedDrafts.last,
               last.user?.text == draft.user?.text,
               last.answer?.text == draft.answer?.text {
                if draft.answer?.isStreaming == false {
                    coalescedDrafts[coalescedDrafts.count - 1].answer?.isStreaming = false
                }
                continue
            }
            coalescedDrafts.append(draft)
        }

        var turns = coalescedDrafts.map { draft in
            CodexTurnV2(
                id: draft.id,
                userMessage: draft.user,
                finalAnswer: draft.answer,
                status: .done(durationMs: nil),
                presentationStyle: .realtimeVoice
            )
        }
        guard !turns.isEmpty else { return turns }

        let lastDraft = coalescedDrafts[turns.count - 1]
        let isSettledListeningTurn = phase == .listening
            && lastDraft.userIsFinal
            && lastDraft.answer?.isStreaming == false
        if phase.isActive, !isSettledListeningTurn {
            turns[turns.count - 1].status = .working(since: nil)
            switch phase {
            case .starting:
                turns[turns.count - 1].liveTail = "Connecting"
            case .thinking:
                turns[turns.count - 1].liveTail = "Thinking"
            case .listening where !lastDraft.userIsFinal:
                turns[turns.count - 1].liveTail = "Listening"
            case .inactive, .listening, .speaking, .failed:
                break
            }
        }
        return turns
    }
}
