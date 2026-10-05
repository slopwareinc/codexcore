import XCTest
import CodexCore
@testable import CodexCoreApp

@MainActor
final class CodexVoiceRuntimeFeaturesTests: XCTestCase {
    func testV3VoiceCatalogUsesV1FamilyAndRetainsUnknownFutureVoices() async {
        let session = CodexVoiceChatSession()
        session.selectedVoice = .sol
        let future = CodexSchemaRealtimeVoice.unrecognized("future-voice")
        await session.refreshVoices {
            .init(defaultV1: .marin, defaultV2: .sol, v1: [.marin, future, .marin], v2: [.sol])
        }
        XCTAssertEqual(session.availableVoices, [.marin, future])
        XCTAssertEqual(session.selectedVoice, .marin)
        XCTAssertNil(session.voiceCatalogError)
    }

    func testRealtimeSelectionIsEncodedWithoutAmbientChatOverrides() {
        let session = CodexVoiceChatSession()
        session.selectedVoice = .marin
        session.selectedModel = " custom-realtime-model "
        session.outputModality = .text
        let params = session.startParameters(threadID: "voice-thread", offerSDP: "offer")
        XCTAssertEqual(params.voice, .marin)
        XCTAssertEqual(params.model, "custom-realtime-model")
        XCTAssertEqual(params.outputModality, .text)
        XCTAssertEqual(params.version, .v3)
        XCTAssertEqual(params.threadID, "voice-thread")
        XCTAssertEqual(params.transport?.rawValue, .dictionary(["type": .string("webrtc"), "sdp": .string("offer")]))
    }

    func testCatalogResponseFromDisconnectedRuntimeCannotChangeNewChoices() async throws {
        let provider = VoiceCatalogTestProvider()
        let session = CodexVoiceChatSession()
        let refresh = Task { await session.refreshVoices { await provider.catalog() } }
        for _ in 0..<500 {
            if await provider.hasWaiter { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        session.invalidateVoiceCatalog()
        await session.refreshVoices { .init(defaultV1: .cove, defaultV2: .marin, v1: [.cove], v2: [.marin]) }
        await provider.release()
        await refresh.value
        XCTAssertEqual(session.availableVoices, [.cove])
        XCTAssertEqual(session.selectedVoice, .cove)
        XCTAssertFalse(session.isLoadingVoices)
        XCTAssertNil(session.voiceCatalogError)
    }

    func testItemOnlyTranscriptRendersStreamingAndCompletion() {
        var transcript = CodexVoiceTranscriptAccumulator()
        transcript.itemStarted(item("one", role: "assistant", text: ""))
        transcript.itemDelta(id: "one", delta: "Hello ")
        transcript.itemDelta(id: "one", delta: "world")
        XCTAssertEqual(transcript.entries.map(\.text), ["Hello world"])
        XCTAssertFalse(transcript.entries[0].isFinal)
        transcript.itemCompleted(item("one", role: "assistant", text: "Hello world!"))
        XCTAssertTrue(transcript.entries[0].isFinal)
        XCTAssertEqual(transcript.entries.map(\.text), ["Hello world!"])
    }

    func testMirroredItemAndSessionDeltasDoNotDuplicateText() {
        var transcript = CodexVoiceTranscriptAccumulator()
        transcript.sessionDelta(role: "assistant", delta: "Hello ")
        transcript.itemStarted(item("one", role: "assistant", text: ""))
        transcript.itemDelta(id: "one", delta: "Hello ")
        transcript.sessionDelta(role: "assistant", delta: "world")
        transcript.itemDelta(id: "one", delta: "world")
        transcript.itemCompleted(item("one", role: "assistant", text: "Hello world"))
        transcript.sessionDone(role: "assistant", text: "Hello world")
        XCTAssertEqual(transcript.entries.map(\.text), ["Hello world"])
    }

    func testRepeatedUtterancesRemainDistinctAfterInterveningMessages() {
        var transcript = CodexVoiceTranscriptAccumulator()
        transcript.sessionDone(role: "assistant", text: "Yes")
        transcript.sessionDone(role: "user", text: "Again?")
        transcript.sessionDone(role: "assistant", text: "Yes")
        XCTAssertEqual(transcript.entries.map(\.text), ["Yes", "Again?", "Yes"])
        transcript.itemStarted(item("a", role: "assistant", text: ""))
        transcript.itemCompleted(item("a", role: "assistant", text: "Yes"))
        transcript.itemStarted(item("b", role: "assistant", text: ""))
        transcript.itemCompleted(item("b", role: "assistant", text: "Yes"))
        XCTAssertEqual(transcript.entries.count, 5)
    }

    func testOverlappingItemsOfSameRoleKeepSeparateIdentities() {
        var transcript = CodexVoiceTranscriptAccumulator()
        transcript.itemStarted(item("a", role: "assistant", text: ""))
        transcript.itemStarted(item("b", role: "assistant", text: ""))
        transcript.itemDelta(id: "a", delta: "First")
        transcript.itemDelta(id: "b", delta: "Second")
        transcript.itemCompleted(item("a", role: "assistant", text: "First"))
        transcript.itemCompleted(item("b", role: "assistant", text: "Second"))
        XCTAssertEqual(transcript.entries.map(\.text), ["First", "Second"])
        XCTAssertTrue(transcript.entries.allSatisfy(\.isFinal))
    }

    func testCompletedItemMirrorCannotFinalizeNewerOverlappingItem() {
        var transcript = CodexVoiceTranscriptAccumulator()
        transcript.itemStarted(item("a", role: "assistant", text: ""))
        transcript.itemDelta(id: "a", delta: "First")
        transcript.itemStarted(item("b", role: "assistant", text: ""))
        transcript.itemDelta(id: "b", delta: "Second")
        transcript.itemCompleted(item("a", role: "assistant", text: "First"))
        transcript.sessionDone(role: "assistant", text: "First")
        XCTAssertEqual(transcript.entries.map(\.text), ["First", "Second"])
        XCTAssertFalse(transcript.entries[1].isFinal)
        transcript.itemCompleted(item("b", role: "assistant", text: "Second"))
        transcript.sessionDone(role: "assistant", text: "Second")
        XCTAssertEqual(transcript.entries.count, 2)
        XCTAssertTrue(transcript.entries.allSatisfy(\.isFinal))
    }

    private func item(_ id: String, role: String, text: String) -> CodexSchemaThreadRealtimeItem {
        .init(.dictionary(["id": .string(id), "realtimeSessionId": .string("session"), "type": .string("transcriptSegment"), "role": .string(role), "text": .string(text)]))
    }
}

private actor VoiceCatalogTestProvider {
    private var waiter: CheckedContinuation<CodexSchemaRealtimeVoicesList, Never>?
    var hasWaiter: Bool { waiter != nil }
    func catalog() async -> CodexSchemaRealtimeVoicesList { await withCheckedContinuation { waiter = $0 } }
    func release() {
        waiter?.resume(returning: .init(defaultV1: .juniper, defaultV2: .marin, v1: [.juniper], v2: [.marin]))
        waiter = nil
    }
}
