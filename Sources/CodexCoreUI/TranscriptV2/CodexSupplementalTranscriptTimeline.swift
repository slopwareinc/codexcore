import Foundation

/// Composes UI-owned realtime messages with canonical protocol turns without
/// flattening either source. Arrival time is presentation metadata: canonical
/// state remains authoritative, and canonical work rows retain their normal
/// expandable rendering.
enum CodexSupplementalTranscriptTimeline {
    static func merge(
        _ supplementalTurns: [CodexTurnV2],
        presentedAtByTurnID supplementalPresentedAtByTurnID: [String: Date],
        fallbackPresentedAt: Date,
        into presentation: inout CodexThreadUIPresentation
    ) {
        guard !supplementalTurns.isEmpty else { return }

        var seenSupplementalSignatures: Set<String> = []
        var additions = supplementalTurns.filter { turn in
            let signature = [
                turn.userMessage?.text ?? "",
                turn.finalAnswer?.text ?? "",
            ].joined(separator: "\u{1f}")
            return seenSupplementalSignatures.insert(signature).inserted
        }

        let supplementalAnswersWithUser = Set(additions.compactMap { turn -> String? in
            guard turn.userMessage != nil else { return nil }
            return normalizedAnswer(turn.finalAnswer?.text)
        })
        if !supplementalAnswersWithUser.isEmpty {
            presentation.transcript.turns.removeAll { turn in
                guard isSimpleAssistantOnlyTurn(turn),
                      let answer = normalizedAnswer(turn.finalAnswer?.text)
                else { return false }
                return supplementalAnswersWithUser.contains(answer)
            }
        }

        let canonicalAnswers = Set(presentation.transcript.turns.compactMap {
            normalizedAnswer($0.finalAnswer?.text)
        })
        additions.removeAll { turn in
            guard turn.userMessage == nil,
                  let answer = normalizedAnswer(turn.finalAnswer?.text)
            else { return false }
            return canonicalAnswers.contains(answer)
        }

        let canonicalIDs = Set(presentation.transcript.turns.map(\.id))
        additions.removeAll { canonicalIDs.contains($0.id) }
        for turn in additions {
            presentation.presentedAtByTurnID[turn.id] =
                supplementalPresentedAtByTurnID[turn.id] ?? fallbackPresentedAt
        }

        let merged = presentation.transcript.turns + additions
        let originalOrdinal = Dictionary(
            uniqueKeysWithValues: merged.enumerated().map { ($0.element.id, $0.offset) }
        )
        presentation.transcript.turns = merged.sorted { lhs, rhs in
            let lhsDate = presentation.presentedAtByTurnID[lhs.id] ?? fallbackPresentedAt
            let rhsDate = presentation.presentedAtByTurnID[rhs.id] ?? fallbackPresentedAt
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }
            return (originalOrdinal[lhs.id] ?? 0) < (originalOrdinal[rhs.id] ?? 0)
        }
    }

    private static func normalizedAnswer(_ text: String?) -> String? {
        guard let value = text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !value.isEmpty
        else { return nil }
        return value
    }

    private static func isSimpleAssistantOnlyTurn(_ turn: CodexTurnV2) -> Bool {
        turn.userMessage == nil
            && turn.steeredMessages.isEmpty
            && turn.conversationSegments.allSatisfy {
                $0.steeredMessage == nil && $0.narrative.isEmpty
            }
            && turn.finalAnswer != nil
    }
}
