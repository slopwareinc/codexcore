@testable import CodexCoreUI
import Foundation
import Testing

struct CodexSupplementalTranscriptTimelineTests {
    @Test func realtimeMessagesAndCanonicalWorkShareOneArrivalOrderedTimeline() {
        let oldTurn = turn("old")
        let firstWork = turn("first-work", answer: "Canonical result one")
        let secondWork = turn("second-work", answer: "Canonical result two")
        let firstVoice = voiceTurn("voice-one", user: "Question one", answer: "I’ll check.")
        let secondVoice = voiceTurn("voice-two", user: "Question two", answer: "Checking now.")
        let finalVoice = voiceTurn("voice-three", answer: "Done.")
        var presentation = CodexThreadUIPresentation(
            threadID: "thread",
            transcript: .init(turns: [oldTurn, firstWork, secondWork]),
            presentedAtByTurnID: [
                oldTurn.id: date(10),
                firstWork.id: date(30),
                secondWork.id: date(70),
            ]
        )

        CodexSupplementalTranscriptTimeline.merge(
            [firstVoice, secondVoice, finalVoice],
            presentedAtByTurnID: [
                firstVoice.id: date(20),
                secondVoice.id: date(50),
                finalVoice.id: date(80),
            ],
            fallbackPresentedAt: date(100),
            into: &presentation
        )

        #expect(presentation.transcript.turns.map(\.id) == [
            "old",
            "voice-one",
            "first-work",
            "voice-two",
            "second-work",
            "voice-three",
        ])
    }

    @Test func equalArrivalTimesPreserveCanonicalThenSupplementalSourceOrder() {
        let canonicalOne = turn("canonical-one")
        let canonicalTwo = turn("canonical-two")
        let voiceOne = voiceTurn("voice-one", user: "Hello")
        let voiceTwo = voiceTurn("voice-two", answer: "Hi")
        let sameDate = date(10)
        var presentation = CodexThreadUIPresentation(
            threadID: "thread",
            transcript: .init(turns: [canonicalOne, canonicalTwo]),
            presentedAtByTurnID: [
                canonicalOne.id: sameDate,
                canonicalTwo.id: sameDate,
            ]
        )

        CodexSupplementalTranscriptTimeline.merge(
            [voiceOne, voiceTwo],
            presentedAtByTurnID: [
                voiceOne.id: sameDate,
                voiceTwo.id: sameDate,
            ],
            fallbackPresentedAt: sameDate,
            into: &presentation
        )

        #expect(presentation.transcript.turns.map(\.id) == [
            "canonical-one",
            "canonical-two",
            "voice-one",
            "voice-two",
        ])
    }

    @Test func duplicateCanonicalAssistantEchoDoesNotHideCanonicalWork() {
        let canonicalEcho = turn("canonical-echo", answer: "I’ll check.")
        let canonicalWork = CodexTurnV2(
            id: "canonical-work",
            narrative: [.workGroup(.init(
                id: "work",
                rows: [.command(.init(
                    id: "command",
                    command: "df -h",
                    label: "Check disk space",
                    action: .read,
                    status: .completed
                ))]
            ))],
            status: .done(durationMs: 8_000)
        )
        let voice = voiceTurn("voice", user: "How much space?", answer: "I’ll check.")
        var presentation = CodexThreadUIPresentation(
            threadID: "thread",
            transcript: .init(turns: [canonicalEcho, canonicalWork]),
            presentedAtByTurnID: [
                canonicalEcho.id: date(20),
                canonicalWork.id: date(30),
            ]
        )

        CodexSupplementalTranscriptTimeline.merge(
            [voice],
            presentedAtByTurnID: [voice.id: date(10)],
            fallbackPresentedAt: date(40),
            into: &presentation
        )

        #expect(presentation.transcript.turns.map(\.id) == ["voice", "canonical-work"])
        #expect(presentation.transcript.turns.last?.narrative.isEmpty == false)
    }

    private func turn(_ id: String, answer: String? = nil) -> CodexTurnV2 {
        CodexTurnV2(
            id: id,
            finalAnswer: answer.map {
                CodexAssistantTextV2(id: "\(id)-answer", text: $0, isStreaming: false)
            },
            status: .done(durationMs: nil)
        )
    }

    private func voiceTurn(
        _ id: String,
        user: String? = nil,
        answer: String? = nil
    ) -> CodexTurnV2 {
        CodexTurnV2(
            id: id,
            userMessage: user.map {
                CodexUserMessageV2(id: "\(id)-user", text: $0)
            },
            finalAnswer: answer.map {
                CodexAssistantTextV2(id: "\(id)-answer", text: $0, isStreaming: false)
            },
            status: .done(durationMs: nil),
            presentationStyle: .realtimeVoice
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
