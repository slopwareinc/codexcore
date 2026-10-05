import AppKit
@preconcurrency import AVFoundation
import CodexCore
import Foundation
import Observation

struct CodexVoiceTranscriptEntry: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let receivedAt: Date
    var role: String
    var text: String
    var isFinal: Bool

    init(
        id: UUID = UUID(),
        receivedAt: Date = Date(),
        role: String,
        text: String,
        isFinal: Bool
    ) {
        self.id = id
        self.receivedAt = receivedAt
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
        case thinking
        case speaking
        case failed(String)

        var isActive: Bool {
            switch self {
            case .inactive, .failed: false
            case .starting, .listening, .thinking, .speaking: true
            }
        }
    }

    private(set) var phase: Phase = .inactive {
        didSet { onPhaseChanged?(phase) }
    }
    private(set) var threadID: String?
    private var transcriptAccumulator = CodexVoiceTranscriptAccumulator()
    var transcript: [CodexVoiceTranscriptEntry] { transcriptAccumulator.entries }
    var selectedVoice: CodexSchemaRealtimeVoice = .sol
    var selectedModel = "gpt-live-1-codex"
    var outputModality: CodexSchemaRealtimeOutputModality = .audio
    private(set) var availableVoices: [CodexSchemaRealtimeVoice] = [.sol]
    private(set) var voiceCatalogError: String?
    private(set) var isLoadingVoices = false
    private(set) var inputLevel: Float = 0
    private(set) var errorMessage: String?
    var isMuted = false {
        didSet {
            webRTC?.setMicrophoneMuted(isMuted)
        }
    }
    var isOutputMuted = false {
        didSet {
            webRTC?.setOutputMuted(isOutputMuted)
        }
    }

    private var codex: Codex?
    private var eventTask: Task<Void, Never>?
    private var webRTC: CodexVoiceWebRTCTransport?
    private var voiceCatalogGeneration: UInt64 = 0
    private var logSessionID = UUID().uuidString

    /// AppKit presentation owners use this seam to move the existing session
    /// between the main-thread and global overlay surfaces. It never creates a
    /// second transport or thread.
    var onPhaseChanged: (@MainActor (Phase) -> Void)?

    var isActive: Bool { phase.isActive }

    func refreshVoices(codex: Codex) async {
        await refreshVoices { try await codex.threadRealtimeListVoices().voices }
    }

    /// Called when the host connection ends. A slow catalog response from that
    /// runtime must not overwrite choices for its replacement connection.
    func invalidateVoiceCatalog() {
        voiceCatalogGeneration &+= 1
        isLoadingVoices = false
        voiceCatalogError = nil
        availableVoices = [selectedVoice]
    }

    func refreshVoices(_ fetch: @Sendable () async throws -> CodexSchemaRealtimeVoicesList) async {
        guard !isLoadingVoices else { return }
        voiceCatalogGeneration &+= 1
        let generation = voiceCatalogGeneration
        isLoadingVoices = true
        voiceCatalogError = nil
        defer { if generation == voiceCatalogGeneration { isLoadingVoices = false } }
        do {
            let catalog = try await fetch()
            guard generation == voiceCatalogGeneration, !Task.isCancelled else { return }
            // The pinned runtime validates V3 against the v1 catalog (see
            // core/src/realtime_conversation.rs::validate_realtime_voice).
            // Preserve unknown future voice names returned by that catalog.
            var seen = Set<CodexSchemaRealtimeVoice>()
            availableVoices = ([catalog.defaultV1] + catalog.v1).filter { seen.insert($0).inserted }
            if !availableVoices.contains(selectedVoice) { selectedVoice = catalog.defaultV1 }
        } catch {
            guard generation == voiceCatalogGeneration else { return }
            voiceCatalogError = "Voice choices could not be loaded. The selected voice will be validated by the runtime."
        }
    }

    func startParameters(threadID: String, offerSDP: String) -> CodexSchemaThreadRealtimeStartParams {
        let model = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return .codexVoiceWebRTC(
            threadID: threadID, offerSDP: offerSDP,
            model: model.isEmpty ? "gpt-live-1-codex" : model,
            voice: selectedVoice, outputModality: outputModality
        )
    }

    func start(codex: Codex, threadID: String) async throws {
        await stop()
        logSessionID = UUID().uuidString
        self.threadID = threadID
        phase = .starting
        errorMessage = nil
        transcriptAccumulator.reset()
        self.codex = codex
        log(
            "session.start.requested",
            level: .notice,
            fields: ["logFile": CodexVoiceLog.fileURL.path]
        )

        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        log(
            "microphone.authorization.current",
            fields: ["status": String(describing: authorizationStatus)]
        )
        let granted = await Self.requestMicrophoneAccess()
        log(
            "microphone.authorization.resolved",
            level: granted ? .notice : .error,
            fields: ["granted": String(granted)]
        )
        guard granted else {
            throw CodexVoiceChatError.microphonePermissionDenied
        }

        let transport = CodexVoiceWebRTCTransport(threadID: threadID) { [weak self] level in
            self?.inputLevel = level
        }
        log("webrtc.offer.prepare.begin")
        let offerSDP = try await transport.prepareOffer()
        log(
            "webrtc.offer.prepare.complete",
            fields: [
                "sdp": offerSDP,
                "sdpBytes": String(offerSDP.utf8.count),
            ]
        )
        transport.setMicrophoneMuted(isMuted)
        transport.setOutputMuted(isOutputMuted)
        webRTC = transport

        log("protocol.observer.register.begin")
        let events = try await codex.session.observeRealtimeEvents(
            threadID: threadID
        )
        log("protocol.observer.register.complete")
        eventTask = Task { [weak self] in
            do {
                for try await event in events {
                    guard !Task.isCancelled else { return }
                    self?.receive(event)
                }
            } catch is CancellationError {
                self?.log("protocol.observer.cancelled")
                return
            } catch {
                self?.log(
                    "protocol.observer.failed",
                    level: .error,
                    fields: ["error": String(describing: error)]
                )
                self?.fail(error)
            }
        }

        log("protocol.start.request.begin", level: .notice)
        let response = try await codex.threadRealtimeStart(startParameters(threadID: threadID, offerSDP: offerSDP))
        log(
            "protocol.start.request.complete",
            level: .notice,
            fields: ["response": CodexVoiceLog.encodedJSON(response)]
        )
    }

    func stop() async {
        let activeCodex = codex
        let activeThreadID = threadID
        log(
            "session.stop.requested",
            level: .notice,
            fields: ["transcript": CodexVoiceLog.encodedJSON(transcript)]
        )
        webRTC?.stop()
        webRTC = nil
        eventTask?.cancel()
        eventTask = nil
        inputLevel = 0

        if let activeCodex, let activeThreadID, phase.isActive {
            do {
                let response = try await activeCodex.threadRealtimeStop(
                    .init(threadID: activeThreadID)
                )
                log(
                    "protocol.stop.request.complete",
                    fields: ["response": CodexVoiceLog.encodedJSON(response)]
                )
            } catch {
                log(
                    "protocol.stop.request.failed",
                    level: .error,
                    fields: ["error": String(describing: error)]
                )
            }
        }
        codex = nil
        phase = .inactive
        log("session.stop.complete", level: .notice)
    }

    func toggleMute() {
        isMuted.toggle()
    }

    func toggleOutputMute() {
        isOutputMuted.toggle()
    }

    /// Records a recoverable failure while retaining the associated thread so
    /// the caller can retry the same Voice task. This is intentionally distinct
    /// from `stop()`, which is the user-requested terminal action.
    func markFailed(_ error: Error) {
        fail(error)
    }

    /// Drops a failed/stopped session identity before the overlay starts a
    /// completely new Voice task. `stop()` intentionally keeps `threadID` for
    /// retry, so this explicit path prevents a failed new-thread allocation
    /// from accidentally exposing the previous Voice task as retryable.
    func resetForNewSession() async {
        await stop()
        threadID = nil
        transcriptAccumulator.reset()
        errorMessage = nil
    }

    func sendText(_ rawText: String) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let codex, let threadID, phase.isActive else { return }
        transcriptAccumulator.appendLocalText(text)
        phase = .thinking
        do {
            log(
                "protocol.append_text.request.begin",
                fields: ["text": text]
            )
            let response = try await codex.threadRealtimeAppendText(.init(
                role: .user,
                text: text,
                threadID: threadID
            ))
            log(
                "protocol.append_text.request.complete",
                fields: ["response": CodexVoiceLog.encodedJSON(response)]
            )
        } catch {
            log(
                "protocol.append_text.request.failed",
                level: .error,
                fields: ["error": String(describing: error)]
            )
            fail(error)
        }
    }

    func sendSpeech(_ rawText: String) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let codex, let threadID, phase.isActive else { return }
        do {
            _ = try await codex.threadRealtimeAppendSpeech(.init(text: text, threadID: threadID))
        } catch { fail(error) }
    }

    private func receive(_ event: CodexRealtimeEvent) {
        switch event {
        case .started(let value):
            log(
                "protocol.event.started",
                level: .notice,
                fields: [
                    "realtimeSessionID": value.realtimeSessionID ?? "",
                    "version": value.version.rawValue,
                ]
            )
            phase = .listening
        case .transcriptDelta(let value):
            log(
                "protocol.event.transcript.delta",
                fields: [
                    "role": value.role,
                    "delta": value.delta,
                ]
            )
            transcriptAccumulator.sessionDelta(role: value.role, delta: value.delta)
            if value.role.localizedCaseInsensitiveContains("assistant") {
                phase = .speaking
            }
            log(
                "transcript.current",
                fields: ["transcript": CodexVoiceLog.encodedJSON(transcript)]
            )
        case .transcriptDone(let value):
            log(
                "protocol.event.transcript.done",
                level: .notice,
                fields: [
                    "role": value.role,
                    "text": value.text,
                ]
            )
            finishTranscript(role: value.role, text: value.text)
            log(
                "transcript.current",
                level: .notice,
                fields: ["transcript": CodexVoiceLog.encodedJSON(transcript)]
            )
        case .outputAudio(let value):
            log(
                "protocol.event.output_audio",
                fields: [
                    "base64Bytes": String(value.audio.data.utf8.count),
                    "itemID": value.audio.itemID ?? "",
                    "numChannels": String(value.audio.numChannels),
                    "sampleRate": String(value.audio.sampleRate),
                    "samplesPerChannel": value.audio.samplesPerChannel.map(String.init) ?? "",
                ]
            )
        case .error(let value):
            log(
                "protocol.event.error",
                level: .error,
                fields: ["message": value.message]
            )
            fail(CodexVoiceChatError.server(value.message))
        case .closed(let value):
            log(
                "protocol.event.closed",
                level: value.reason == nil ? .notice : .error,
                fields: [
                    "reason": value.reason ?? "",
                    "transcript": CodexVoiceLog.encodedJSON(transcript),
                ]
            )
            webRTC?.stop()
            webRTC = nil
            codex = nil
            phase = value.reason == nil
                ? .inactive
                : .failed(value.reason ?? "Voice chat closed")
        case .sdp(let value):
            log(
                "protocol.event.sdp",
                level: .notice,
                fields: [
                    "sdp": value.sdp,
                    "sdpBytes": String(value.sdp.utf8.count),
                ]
            )
            webRTC?.applyAnswer(value.sdp)
        case .itemAdded:
            // Item payloads can contain arbitrary transcript or audio content;
            // keep the telemetry event metadata-only.
            log("protocol.event.item_added")
        case .itemStarted(let value):
            transcriptAccumulator.itemStarted(value.item)
            log("protocol.event.item.started")
        case .itemTranscriptDelta(let value):
            transcriptAccumulator.itemDelta(id: value.itemID, delta: value.delta)
            log(
                "protocol.event.item.transcript_delta",
                fields: [
                    "itemID": value.itemID,
                    "deltaBytes": String(value.delta.utf8.count),
                ]
            )
        case .itemCompleted(let value):
            transcriptAccumulator.itemCompleted(value.item)
            log("protocol.event.item.completed")
        }
    }

    private func finishTranscript(role: String, text: String) {
        transcriptAccumulator.sessionDone(role: role, text: text)
        if role.localizedCaseInsensitiveContains("assistant") {
            phase = .listening
        } else if role.localizedCaseInsensitiveContains("user") {
            phase = .thinking
        }
    }

    private func fail(_ error: Error) {
        let message = CodexErrorFormat.localizedDescription(error)
        log(
            "session.failed",
            level: .error,
            fields: [
                "error": String(describing: error),
                "message": message,
                "transcript": CodexVoiceLog.encodedJSON(transcript),
            ]
        )
        errorMessage = message
        phase = .failed(message)
        eventTask?.cancel()
        eventTask = nil
        webRTC?.stop()
        webRTC = nil
    }

    private func log(
        _ event: String,
        level: CodexVoiceLog.Level = .info,
        fields: [String: String] = [:]
    ) {
        var enriched = fields
        enriched["logSessionID"] = logSessionID
        enriched["threadID"] = threadID ?? ""
        enriched["phase"] = String(describing: phase)
        CodexVoiceLog.write(event, level: level, fields: enriched)
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
