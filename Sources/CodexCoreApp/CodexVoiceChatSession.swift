import AppKit
@preconcurrency import AVFoundation
import CodexCore
import Foundation
import Observation

struct CodexVoiceTranscriptEntry: Identifiable, Sendable, Equatable {
    let id: UUID
    var role: String
    var text: String
    var isFinal: Bool

    init(
        id: UUID = UUID(),
        role: String,
        text: String,
        isFinal: Bool
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.isFinal = isFinal
    }
}

@MainActor
@Observable
final class CodexVoiceChatSession {
    enum Phase: Sendable, Equatable {
        case inactive
        case starting
        case listening
        case speaking
        case failed(String)

        var isActive: Bool {
            switch self {
            case .inactive, .failed: false
            case .starting, .listening, .speaking: true
            }
        }
    }

    private(set) var phase: Phase = .inactive
    private(set) var threadID: String?
    private(set) var transcript: [CodexVoiceTranscriptEntry] = []
    private(set) var inputLevel: Float = 0
    private(set) var errorMessage: String?
    var isMuted = false {
        didSet {
            capture?.isMuted = isMuted
        }
    }
    var isOutputMuted = false {
        didSet {
            player?.isMuted = isOutputMuted
        }
    }

    private var codex: Codex?
    private var threadLease: CodexThreadLease?
    private var eventTask: Task<Void, Never>?
    private var capture: CodexVoiceAudioCapture?
    private var player: CodexVoiceAudioPlayer?
    private var partialEntryIDByRole: [String: UUID] = [:]

    var isActive: Bool { phase.isActive }

    func start(codex: Codex, threadLease: CodexThreadLease) async throws {
        await stop()
        phase = .starting
        errorMessage = nil
        transcript = []
        partialEntryIDByRole = [:]
        threadID = threadLease.id.rawValue
        self.codex = codex
        self.threadLease = threadLease

        let granted = await Self.requestMicrophoneAccess()
        guard granted else {
            throw CodexVoiceChatError.microphonePermissionDenied
        }

        let events = try await codex.session.observeRealtimeEvents(
            threadID: threadLease.id.rawValue
        )
        eventTask = Task { [weak self] in
            do {
                for try await event in events {
                    guard !Task.isCancelled else { return }
                    self?.receive(event)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.fail(error)
            }
        }

        _ = try await codex.threadRealtimeStart(.init(
            flushTranscriptTailOnSessionEnd: true,
            includeStartupContext: true,
            outputModality: .audio,
            threadID: threadLease.id.rawValue,
            version: .v3
        ))

        let capture = try CodexVoiceAudioCapture(
            codex: codex,
            threadID: threadLease.id.rawValue,
            onLevel: { [weak self] level in
                Task { @MainActor [weak self] in
                    self?.inputLevel = level
                }
            }
        )
        capture.isMuted = isMuted
        try capture.start()
        self.capture = capture
        player = CodexVoiceAudioPlayer { [weak self] isPlaying in
            Task { @MainActor [weak self] in
                guard let self, self.phase.isActive else { return }
                self.phase = isPlaying ? .speaking : .listening
            }
        }
        player?.isMuted = isOutputMuted
        phase = .listening
    }

    func stop() async {
        let activeCodex = codex
        let activeThreadID = threadID
        capture?.stop()
        capture = nil
        player?.stop()
        player = nil
        eventTask?.cancel()
        eventTask = nil
        inputLevel = 0

        if let activeCodex, let activeThreadID, phase.isActive {
            _ = try? await activeCodex.threadRealtimeStop(.init(threadID: activeThreadID))
        }
        if let threadLease {
            await threadLease.close()
        }
        threadLease = nil
        codex = nil
        phase = .inactive
    }

    func toggleMute() {
        isMuted.toggle()
    }

    func toggleOutputMute() {
        isOutputMuted.toggle()
    }

    private func receive(_ event: CodexRealtimeEvent) {
        switch event {
        case .started:
            phase = .listening
        case .transcriptDelta(let value):
            appendTranscriptDelta(role: value.role, delta: value.delta)
        case .transcriptDone(let value):
            finishTranscript(role: value.role, text: value.text)
        case .outputAudio(let value):
            do {
                try player?.enqueue(value.audio)
                phase = .speaking
            } catch {
                fail(error)
            }
        case .error(let value):
            fail(CodexVoiceChatError.server(value.message))
        case .closed(let value):
            capture?.stop()
            capture = nil
            player?.stop()
            player = nil
            let lease = threadLease
            threadLease = nil
            codex = nil
            if let lease {
                Task { await lease.close() }
            }
            phase = value.reason == nil
                ? .inactive
                : .failed(value.reason ?? "Voice chat closed")
        case .itemAdded, .sdp:
            break
        }
    }

    private func appendTranscriptDelta(role: String, delta: String) {
        guard !delta.isEmpty else { return }
        if let id = partialEntryIDByRole[role],
           let index = transcript.firstIndex(where: { $0.id == id }) {
            transcript[index].text += delta
            return
        }
        let entry = CodexVoiceTranscriptEntry(
            role: role,
            text: delta,
            isFinal: false
        )
        partialEntryIDByRole[role] = entry.id
        transcript.append(entry)
    }

    private func finishTranscript(role: String, text: String) {
        if let id = partialEntryIDByRole.removeValue(forKey: role),
           let index = transcript.firstIndex(where: { $0.id == id }) {
            transcript[index].text = text
            transcript[index].isFinal = true
        } else if !text.isEmpty {
            transcript.append(.init(role: role, text: text, isFinal: true))
        }
        if role.localizedCaseInsensitiveContains("assistant") {
            phase = .listening
        }
    }

    private func fail(_ error: Error) {
        let message = CodexErrorFormat.localizedDescription(error)
        errorMessage = message
        phase = .failed(message)
        capture?.stop()
        capture = nil
        player?.stop()
        player = nil
    }

    private static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) {
                    continuation.resume(returning: $0)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

enum CodexVoiceChatError: Error, LocalizedError {
    case microphonePermissionDenied
    case invalidAudioFormat
    case audioConversionFailed
    case invalidAudioData
    case server(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Microphone access is required for Voice chat."
        case .invalidAudioFormat:
            "The microphone audio format is unavailable."
        case .audioConversionFailed:
            "Microphone audio could not be converted."
        case .invalidAudioData:
            "Voice audio data was invalid."
        case .server(let message):
            message
        }
    }
}

private actor CodexVoiceAudioSender {
    let codex: Codex
    let threadID: String

    init(codex: Codex, threadID: String) {
        self.codex = codex
        self.threadID = threadID
    }

    func send(_ chunk: CodexSchemaThreadRealtimeAudioChunk) async {
        _ = try? await codex.threadRealtimeAppendAudio(.init(
            audio: chunk,
            threadID: threadID
        ))
    }
}

private final class CodexVoiceAudioCapture: @unchecked Sendable {
    var isMuted = false

    private let engine = AVAudioEngine()
    private let sender: CodexVoiceAudioSender
    private let onLevel: @Sendable (Float) -> Void
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

    init(
        codex: Codex,
        threadID: String,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws {
        sender = CodexVoiceAudioSender(codex: codex, threadID: threadID)
        self.onLevel = onLevel
    }

    func start() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let mono = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: inputFormat.sampleRate,
                channels: 1,
                interleaved: true
              ),
              let converter = AVAudioConverter(from: inputFormat, to: mono)
        else {
            throw CodexVoiceChatError.invalidAudioFormat
        }
        self.converter = converter
        outputFormat = mono

        input.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        outputFormat = nil
        onLevel(0)
    }

    private func consume(_ input: AVAudioPCMBuffer) {
        guard !isMuted, let converter, let outputFormat else { return }
        let capacity = AVAudioFrameCount(
            ceil(Double(input.frameLength) * outputFormat.sampleRate / input.format.sampleRate)
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: max(capacity, 1)
        ) else { return }

        let source = CodexVoiceConverterInput(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, state in
            guard !source.supplied else {
                state.pointee = .noDataNow
                return nil
            }
            source.supplied = true
            state.pointee = .haveData
            return source.buffer
        }
        guard conversionError == nil,
              status != .error,
              output.frameLength > 0,
              let buffer = output.audioBufferList.pointee.mBuffers.mData
        else { return }

        let byteCount = Int(output.audioBufferList.pointee.mBuffers.mDataByteSize)
        let data = Data(bytes: buffer, count: byteCount)
        onLevel(Self.level(fromPCM16: data))
        let chunk = CodexSchemaThreadRealtimeAudioChunk(
            data: data.base64EncodedString(),
            numChannels: 1,
            sampleRate: Int(outputFormat.sampleRate),
            samplesPerChannel: Int(output.frameLength)
        )
        Task { [sender] in await sender.send(chunk) }
    }

    private static func level(fromPCM16 data: Data) -> Float {
        guard data.count >= MemoryLayout<Int16>.size else { return 0 }
        return data.withUnsafeBytes { raw -> Float in
            let samples = raw.bindMemory(to: Int16.self)
            var sum: Double = 0
            for sample in samples {
                let normalized = Double(sample) / Double(Int16.max)
                sum += normalized * normalized
            }
            let rms = sqrt(sum / Double(samples.count))
            return Float(min(1, rms * 5))
        }
    }
}

private final class CodexVoiceConverterInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private final class CodexVoiceAudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let lock = NSLock()
    private let onPlaybackState: @Sendable (Bool) -> Void
    private var connectedFormat: AVAudioFormat?
    private var pendingBufferCount = 0
    var isMuted = false {
        didSet {
            node.volume = isMuted ? 0 : 1
        }
    }

    init(onPlaybackState: @escaping @Sendable (Bool) -> Void) {
        self.onPlaybackState = onPlaybackState
        engine.attach(node)
    }

    func enqueue(_ chunk: CodexSchemaThreadRealtimeAudioChunk) throws {
        guard let data = Data(base64Encoded: chunk.data),
              !data.isEmpty,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(chunk.sampleRate),
                channels: AVAudioChannelCount(chunk.numChannels),
                interleaved: true
              )
        else {
            throw CodexVoiceChatError.invalidAudioData
        }

        if connectedFormat?.sampleRate != format.sampleRate
            || connectedFormat?.channelCount != format.channelCount {
            if engine.isRunning { engine.stop() }
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            connectedFormat = format
            engine.prepare()
            try engine.start()
        }

        let frames = chunk.samplesPerChannel
            ?? data.count / MemoryLayout<Int16>.size / max(1, chunk.numChannels)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frames)
        ) else {
            throw CodexVoiceChatError.invalidAudioFormat
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard let destination = buffer.audioBufferList.pointee.mBuffers.mData else {
            throw CodexVoiceChatError.invalidAudioData
        }
        let destinationSize = Int(buffer.audioBufferList.pointee.mBuffers.mDataByteSize)
        data.copyBytes(
            to: destination.assumingMemoryBound(to: UInt8.self),
            count: min(destinationSize, data.count)
        )
        lock.lock()
        pendingBufferCount += 1
        let becameActive = pendingBufferCount == 1
        lock.unlock()
        if becameActive {
            onPlaybackState(true)
        }
        node.scheduleBuffer(buffer) { [weak self] in
            self?.bufferDidFinish()
        }
        if !node.isPlaying {
            node.play()
        }
    }

    func stop() {
        node.stop()
        engine.stop()
        lock.lock()
        let wasActive = pendingBufferCount > 0
        pendingBufferCount = 0
        lock.unlock()
        if wasActive {
            onPlaybackState(false)
        }
    }

    private func bufferDidFinish() {
        lock.lock()
        guard pendingBufferCount > 0 else {
            lock.unlock()
            return
        }
        pendingBufferCount -= 1
        let becameIdle = pendingBufferCount == 0
        lock.unlock()
        if becameIdle {
            onPlaybackState(false)
        }
    }
}
