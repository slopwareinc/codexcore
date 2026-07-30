import AVFoundation
import CodexCoreUI
import Foundation
import Observation
import Speech

enum CodexDictationAction: Int, Sendable {
    case insert
    case send

    static func strongest(_ lhs: Self?, _ rhs: Self) -> Self {
        guard let lhs else { return rhs }
        return lhs.rawValue >= rhs.rawValue ? lhs : rhs
    }
}

struct CodexDictationCompletion: Equatable, Sendable {
    var text: String
    var action: CodexDictationAction
}

@MainActor
protocol CodexDictationTranscribing {
    func transcribe(audioFileURL: URL) async throws -> String
}

@MainActor
protocol CodexDictationRecording: AnyObject {
    var fileURL: URL { get }
    func start() throws
    func stop()
    func cancel()
    func sampleLevel() -> Double
}

@MainActor
@Observable
final class CodexComposerDictationSession {
    typealias CompletionHandler = @MainActor (CodexDictationCompletion) -> Void
    typealias RecorderFactory = @MainActor (URL) throws -> any CodexDictationRecording
    typealias PermissionRequester = @MainActor () async throws -> Void

    private(set) var state = CodexComposerDictationState()

    private let transcriber: any CodexDictationTranscribing
    private let recorderFactory: RecorderFactory
    private let requestPermission: PermissionRequester
    private let now: @MainActor () -> TimeInterval
    private let minimumDuration: TimeInterval
    private let maximumDuration: TimeInterval
    private let meterInterval: Duration

    private var recorder: (any CodexDictationRecording)?
    private var startedAt: TimeInterval?
    private var pendingAction: CodexDictationAction?
    private var activeAudioURL: URL?
    private var completionHandler: CompletionHandler?
    private var startTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(
        transcriber: (any CodexDictationTranscribing)? = nil,
        recorderFactory: RecorderFactory? = nil,
        requestPermission: PermissionRequester? = nil,
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        minimumDuration: TimeInterval = 0.25,
        maximumDuration: TimeInterval = 595,
        meterInterval: Duration = .milliseconds(50)
    ) {
        self.transcriber = transcriber ?? CodexSpeechDictationTranscriber()
        self.recorderFactory = recorderFactory ?? { try CodexAVAudioDictationRecording(fileURL: $0) }
        self.requestPermission = requestPermission ?? Self.requestCapturePermissions
        self.now = now
        self.minimumDuration = minimumDuration
        self.maximumDuration = maximumDuration
        self.meterInterval = meterInterval
    }

    func start(onCompletion: @escaping CompletionHandler) {
        guard state.phase == .idle || state.phase == .retry else { return }
        discardActiveAudio()
        completionHandler = onCompletion
        pendingAction = nil
        state = CodexComposerDictationState(phase: .starting)
        generation &+= 1
        let activeGeneration = generation

        startTask?.cancel()
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await requestPermission()
                guard !Task.isCancelled, generation == activeGeneration else { return }
                let fileURL = Self.temporaryAudioURL()
                activeAudioURL = fileURL
                let activeRecorder = try recorderFactory(fileURL)
                try activeRecorder.start()
                guard generation == activeGeneration else {
                    activeRecorder.cancel()
                    Self.removeFileIfPresent(fileURL)
                    activeAudioURL = nil
                    return
                }
                recorder = activeRecorder
                startedAt = now()
                state = CodexComposerDictationState(phase: .recording)
                startTask = nil
                startMetering(generation: activeGeneration)
                if let action = pendingAction {
                    stop(action)
                }
            } catch {
                failStart(error)
            }
        }
    }

    func stop(_ requestedAction: CodexDictationAction) {
        pendingAction = .strongest(pendingAction, requestedAction)
        switch state.phase {
        case .starting:
            return
        case .recording:
            finishRecording()
        case .transcribing:
            return
        case .idle, .retry:
            pendingAction = nil
        }
    }

    func retry() {
        guard state.phase == .retry, let activeAudioURL else { return }
        state.phase = .transcribing
        state.errorMessage = nil
        beginTranscription(
            audioFileURL: activeAudioURL,
            action: pendingAction ?? .insert
        )
    }

    func abort() {
        generation &+= 1
        startTask?.cancel()
        transcriptionTask?.cancel()
        meterTask?.cancel()
        startTask = nil
        transcriptionTask = nil
        meterTask = nil
        recorder?.cancel()
        if let recorder {
            Self.removeFileIfPresent(recorder.fileURL)
        }
        if let activeAudioURL {
            Self.removeFileIfPresent(activeAudioURL)
        }
        self.activeAudioURL = nil
        recorder = nil
        startedAt = nil
        pendingAction = nil
        completionHandler = nil
        discardActiveAudio()
        state = CodexComposerDictationState()
    }

    func dismissError() {
        state.errorMessage = nil
    }

    private func finishRecording() {
        guard let recorder else { return }
        meterTask?.cancel()
        meterTask = nil
        recorder.stop()
        self.recorder = nil

        let duration = max(0, now() - (startedAt ?? now()))
        startedAt = nil
        state.duration = duration
        let action = pendingAction ?? .insert
        pendingAction = action

        guard duration >= minimumDuration else {
            Self.removeFileIfPresent(recorder.fileURL)
            resetAfterCompletion()
            return
        }

        state.phase = .transcribing
        beginTranscription(audioFileURL: recorder.fileURL, action: action)
    }

    private func beginTranscription(
        audioFileURL: URL,
        action: CodexDictationAction
    ) {
        generation &+= 1
        let activeGeneration = generation
        transcriptionTask?.cancel()
        transcriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let transcript = try await transcriber.transcribe(audioFileURL: audioFileURL)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !Task.isCancelled, generation == activeGeneration else { return }
                Self.removeFileIfPresent(audioFileURL)
                activeAudioURL = nil
                let resolvedAction = pendingAction ?? action
                let handler = completionHandler
                resetAfterCompletion()
                guard !transcript.isEmpty else { return }
                handler?(CodexDictationCompletion(text: transcript, action: resolvedAction))
            } catch is CancellationError {
                return
            } catch {
                guard generation == activeGeneration else { return }
                let presentation = CodexDictationError.presentation(for: error)
                transcriptionTask = nil
                if presentation.retryable {
                    activeAudioURL = audioFileURL
                    state = CodexComposerDictationState(
                        phase: .retry,
                        duration: state.duration,
                        errorMessage: presentation.message
                    )
                } else {
                    Self.removeFileIfPresent(audioFileURL)
                    activeAudioURL = nil
                    pendingAction = nil
                    completionHandler = nil
                    state = CodexComposerDictationState(errorMessage: presentation.message)
                }
            }
        }
    }

    private func startMetering(generation activeGeneration: UInt64) {
        meterTask?.cancel()
        meterTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, generation == activeGeneration, state.phase == .recording {
                let elapsed = max(0, now() - (startedAt ?? now()))
                state.duration = elapsed
                if let recorder {
                    state.waveformLevels.append(recorder.sampleLevel())
                    if state.waveformLevels.count > 32 {
                        state.waveformLevels.removeFirst(state.waveformLevels.count - 32)
                    }
                }
                if elapsed >= maximumDuration {
                    stop(.insert)
                    return
                }
                do {
                    try await Task.sleep(for: meterInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func failStart(_ error: Error) {
        let presentation = CodexDictationError.presentation(for: error)
        if let recorder {
            recorder.cancel()
            Self.removeFileIfPresent(recorder.fileURL)
        }
        if let activeAudioURL {
            Self.removeFileIfPresent(activeAudioURL)
        }
        self.activeAudioURL = nil
        recorder = nil
        startTask = nil
        pendingAction = nil
        state = CodexComposerDictationState(errorMessage: presentation.message)
    }

    private func resetAfterCompletion() {
        transcriptionTask = nil
        pendingAction = nil
        activeAudioURL = nil
        completionHandler = nil
        state = CodexComposerDictationState()
    }

    private func discardActiveAudio() {
        if let activeAudioURL {
            Self.removeFileIfPresent(activeAudioURL)
        }
        activeAudioURL = nil
    }

    private static func temporaryAudioURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-dictation-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
    }

    private static func removeFileIfPresent(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func requestCapturePermissions() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) {
                    continuation.resume(returning: $0)
                }
            }
            guard granted else {
                throw CodexDictationError.microphonePermissionDenied
            }
        case .denied, .restricted:
            throw CodexDictationError.microphonePermissionDenied
        @unknown default:
            throw CodexDictationError.microphonePermissionDenied
        }

        let speechAuthorization = SFSpeechRecognizer.authorizationStatus()
        let resolvedAuthorization: SFSpeechRecognizerAuthorizationStatus
        if speechAuthorization == .notDetermined {
            resolvedAuthorization = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization {
                    continuation.resume(returning: $0)
                }
            }
        } else {
            resolvedAuthorization = speechAuthorization
        }
        guard resolvedAuthorization == .authorized else {
            throw CodexDictationError.speechPermissionDenied
        }
    }
}

@MainActor
private final class CodexAVAudioDictationRecording: NSObject, CodexDictationRecording {
    let fileURL: URL
    private let recorder: AVAudioRecorder

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        self.recorder = try AVAudioRecorder(
            url: fileURL,
            settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
        )
        super.init()
        recorder.isMeteringEnabled = true
    }

    func start() throws {
        guard recorder.prepareToRecord(), recorder.record() else {
            throw CodexDictationError.microphoneUnavailable
        }
    }

    func stop() {
        recorder.stop()
    }

    func cancel() {
        recorder.stop()
        recorder.deleteRecording()
    }

    func sampleLevel() -> Double {
        recorder.updateMeters()
        let linear = pow(10, Double(recorder.averagePower(forChannel: 0)) / 20)
        return min(1, max(0.08, sqrt(linear)))
    }
}

@MainActor
private final class CodexSpeechDictationTranscriber: CodexDictationTranscribing {
    func transcribe(audioFileURL: URL) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable else {
            throw CodexDictationError.transcriptionUnavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: audioFileURL)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let operation = CodexSpeechRecognitionOperation()
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    operation.start(
                        recognizer: recognizer,
                        request: request,
                        continuation: continuation
                    )
                }
            } onCancel: {
                operation.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexDictationError.transcriptionUnavailable
        }
    }
}

private final class CodexSpeechRecognitionOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String, Error>?
    private var completed = false

    func start(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechRecognitionRequest,
        continuation: CheckedContinuation<String, Error>
    ) {
        let shouldStart = lock.withLock {
            guard !completed else { return false }
            self.continuation = continuation
            return true
        }
        guard shouldStart else {
            continuation.resume(throwing: CancellationError())
            return
        }
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let error {
                self?.finish(.failure(error))
            } else if let result, result.isFinal {
                self?.finish(.success(result.bestTranscription.formattedString))
            }
        }
        let shouldCancel = lock.withLock {
            if completed { return true }
            self.task = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        let payload = lock.withLock {
            completionPayload(.failure(CancellationError()))
        }
        payload.task?.cancel()
        payload.continuation?.resume(with: payload.result)
    }

    private func finish(_ result: Result<String, Error>) {
        let payload = lock.withLock {
            completionPayload(result)
        }
        payload.continuation?.resume(with: payload.result)
    }

    private typealias CompletionPayload = (
        task: SFSpeechRecognitionTask?,
        continuation: CheckedContinuation<String, Error>?,
        result: Result<String, Error>
    )

    private func completionPayload(_ result: Result<String, Error>) -> CompletionPayload {
        guard !completed else { return (nil, nil, result) }
        completed = true
        let payload = (task, continuation, result)
        task = nil
        continuation = nil
        return payload
    }
}

enum CodexDictationError: Error, LocalizedError, Equatable {
    case microphonePermissionDenied
    case speechPermissionDenied
    case microphoneUnavailable
    case transcriptionUnavailable

    var errorDescription: String? {
        Self.presentation(for: self).message
    }

    static func presentation(for error: Error) -> (message: String, retryable: Bool) {
        guard let error = error as? CodexDictationError else {
            return ("Unable to start dictation", false)
        }
        switch error {
        case .microphonePermissionDenied:
            return ("Allow microphone access to use dictation", false)
        case .speechPermissionDenied:
            return ("Allow speech recognition access to use dictation", false)
        case .microphoneUnavailable:
            return ("Close other apps using the microphone", false)
        case .transcriptionUnavailable:
            return ("Unable to transcribe audio", true)
        }
    }
}
