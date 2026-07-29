import Foundation
import Testing
@testable import CodexCoreApp

@MainActor
@Suite("Composer dictation")
struct CodexComposerDictationSessionTests {
    @Test("Draft insertion matches official whitespace behavior")
    func joinsTranscriptIntoDraft() {
        #expect(CodexCoreAppModel.joinDictationTranscript(" hello ", to: "") == "hello")
        #expect(CodexCoreAppModel.joinDictationTranscript("world", to: "hello") == "hello world")
        #expect(CodexCoreAppModel.joinDictationTranscript("world", to: "hello ") == "hello world")
        #expect(CodexCoreAppModel.joinDictationTranscript(" ", to: "hello") == "hello")
    }

    @Test("Stop transcribes and inserts")
    func stopTranscribesAndInserts() async {
        let clock = TestDictationClock(now: 10)
        var recording: TestDictationRecording?
        let transcriber = SequencedDictationTranscriber(results: [.success("  dictated text  ")])
        let session = makeSession(
            transcriber: transcriber,
            now: { clock.read() },
            recorder: { recording = $0 }
        )
        var completion: CodexDictationCompletion?

        session.start { completion = $0 }
        #expect(await eventually { session.state.phase == .recording })
        clock.advance(by: 0.4)
        session.stop(.insert)

        #expect(await eventually { completion != nil })
        #expect(completion == CodexDictationCompletion(text: "dictated text", action: .insert))
        #expect(recording?.didStop == true)
        #expect(recording.map { !FileManager.default.fileExists(atPath: $0.fileURL.path) } == true)
    }

    @Test("A pending insert stop can be upgraded to send")
    func sendUpgradesPendingInsert() async {
        let clock = TestDictationClock(now: 20)
        let transcriber = GatedDictationTranscriber()
        let session = makeSession(transcriber: transcriber, now: { clock.read() })
        var completion: CodexDictationCompletion?

        session.start { completion = $0 }
        #expect(await eventually { session.state.phase == .recording })
        clock.advance(by: 0.4)
        session.stop(.insert)
        #expect(await eventually { transcriber.hasRequest })
        session.stop(.send)
        transcriber.resolve(.success("send this"))

        #expect(await eventually { completion != nil })
        #expect(completion?.action == .send)
    }

    @Test("Short recordings are discarded without transcription")
    func shortRecordingIsDiscarded() async {
        let clock = TestDictationClock(now: 30)
        let transcriber = SequencedDictationTranscriber(results: [.success("unused")])
        let session = makeSession(transcriber: transcriber, now: { clock.read() })
        var completion: CodexDictationCompletion?

        session.start { completion = $0 }
        #expect(await eventually { session.state.phase == .recording })
        clock.advance(by: 0.1)
        session.stop(.insert)

        #expect(session.state.phase == .idle)
        #expect(completion == nil)
        #expect(transcriber.callCount == 0)
    }

    @Test("Retry retains the original send intent")
    func retryPreservesIntent() async {
        let clock = TestDictationClock(now: 40)
        let transcriber = SequencedDictationTranscriber(
            results: [
                .failure(.transcriptionUnavailable),
                .success("retry worked"),
            ]
        )
        let session = makeSession(transcriber: transcriber, now: { clock.read() })
        var completion: CodexDictationCompletion?

        session.start { completion = $0 }
        #expect(await eventually { session.state.phase == .recording })
        clock.advance(by: 0.4)
        session.stop(.send)
        #expect(await eventually { session.state.phase == .retry })
        #expect(session.state.errorMessage == "Unable to transcribe audio")

        session.retry()
        #expect(await eventually { completion != nil })
        #expect(completion == CodexDictationCompletion(text: "retry worked", action: .send))
        #expect(transcriber.callCount == 2)
    }

    @Test("Abort releases recording and never completes")
    func abortCleansUp() async {
        let transcriber = SequencedDictationTranscriber(results: [.success("unused")])
        var recording: TestDictationRecording?
        let session = makeSession(
            transcriber: transcriber,
            now: { 50 },
            recorder: { recording = $0 }
        )
        var completion: CodexDictationCompletion?

        session.start { completion = $0 }
        #expect(await eventually { session.state.phase == .recording })
        session.abort()

        #expect(session.state.phase == .idle)
        #expect(recording?.didCancel == true)
        #expect(recording.map { !FileManager.default.fileExists(atPath: $0.fileURL.path) } == true)
        #expect(completion == nil)
    }

    @Test("Permission denial maps to the official error")
    func permissionDenied() async {
        let session = CodexComposerDictationSession(
            transcriber: SequencedDictationTranscriber(results: []),
            recorderFactory: { TestDictationRecording(fileURL: $0) },
            requestPermission: { throw CodexDictationError.microphonePermissionDenied }
        )

        session.start { _ in }

        #expect(await eventually { session.state.phase == .idle && session.state.errorMessage != nil })
        #expect(session.state.errorMessage == "Allow microphone access to use dictation")
    }

    @Test("The duration cap stops and transcribes")
    func durationCapAutoStops() async {
        let clock = TestDictationClock(now: 0, step: 0.02)
        let transcriber = SequencedDictationTranscriber(results: [.success("time limit")])
        let session = CodexComposerDictationSession(
            transcriber: transcriber,
            recorderFactory: { TestDictationRecording(fileURL: $0) },
            requestPermission: {},
            now: { clock.read() },
            minimumDuration: 0,
            maximumDuration: 0.01,
            meterInterval: .milliseconds(1)
        )
        var completion: CodexDictationCompletion?

        session.start { completion = $0 }

        #expect(await eventually { completion != nil })
        #expect(completion == CodexDictationCompletion(text: "time limit", action: .insert))
    }

    private func makeSession(
        transcriber: any CodexDictationTranscribing,
        now: @escaping @MainActor () -> TimeInterval,
        recorder onRecorder: @escaping @MainActor (TestDictationRecording) -> Void = { _ in }
    ) -> CodexComposerDictationSession {
        CodexComposerDictationSession(
            transcriber: transcriber,
            recorderFactory: { url in
                let recorder = TestDictationRecording(fileURL: url)
                onRecorder(recorder)
                return recorder
            },
            requestPermission: {},
            now: now,
            meterInterval: .seconds(60)
        )
    }

    private func eventually(
        _ predicate: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }
}

@MainActor
private final class TestDictationClock {
    private var now: TimeInterval
    private let step: TimeInterval

    init(now: TimeInterval, step: TimeInterval = 0) {
        self.now = now
        self.step = step
    }

    func read() -> TimeInterval {
        defer { now += step }
        return now
    }

    func advance(by interval: TimeInterval) {
        now += interval
    }
}

@MainActor
private final class TestDictationRecording: CodexDictationRecording {
    let fileURL: URL
    private(set) var didStop = false
    private(set) var didCancel = false

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func start() throws {
        try Data([0x00]).write(to: fileURL)
    }

    func stop() {
        didStop = true
    }

    func cancel() {
        didCancel = true
        try? FileManager.default.removeItem(at: fileURL)
    }

    func sampleLevel() -> Double {
        0.5
    }
}

@MainActor
private final class SequencedDictationTranscriber: CodexDictationTranscribing {
    private var results: [Result<String, CodexDictationError>]
    private(set) var callCount = 0

    init(results: [Result<String, CodexDictationError>]) {
        self.results = results
    }

    func transcribe(audioFileURL _: URL) async throws -> String {
        callCount += 1
        guard !results.isEmpty else {
            throw CodexDictationError.transcriptionUnavailable
        }
        return try results.removeFirst().get()
    }
}

@MainActor
private final class GatedDictationTranscriber: CodexDictationTranscribing {
    private var continuation: CheckedContinuation<Result<String, CodexDictationError>, Never>?
    private(set) var hasRequest = false

    func transcribe(audioFileURL _: URL) async throws -> String {
        hasRequest = true
        let result = await withCheckedContinuation { continuation = $0 }
        return try result.get()
    }

    func resolve(_ result: Result<String, CodexDictationError>) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}
