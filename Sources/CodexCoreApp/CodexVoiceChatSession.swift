import AppKit
@preconcurrency import AVFoundation
import CodexCore
import Foundation
import Observation

struct CodexVoiceTranscriptEntry: Identifiable, Codable, Sendable, Equatable {
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

    private(set) var phase: Phase = .inactive
    private(set) var threadID: String?
    private(set) var transcript: [CodexVoiceTranscriptEntry] = []
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
    private var partialEntryIDByRole: [String: UUID] = [:]
    private var logSessionID = UUID().uuidString

    var isActive: Bool { phase.isActive }

    func start(codex: Codex, threadID: String) async throws {
        await stop()
        logSessionID = UUID().uuidString
        phase = .starting
        errorMessage = nil
        transcript = []
        partialEntryIDByRole = [:]
        self.threadID = threadID
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
        let response = try await codex.threadRealtimeStart(.codexVoiceWebRTC(
            threadID: threadID,
            offerSDP: offerSDP
        ))
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

    func sendText(_ rawText: String) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let codex, let threadID, phase.isActive else { return }
        transcript.append(.init(role: "user", text: text, isFinal: true))
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
            appendTranscriptDelta(role: value.role, delta: value.delta)
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
        case .itemAdded(let value):
            log(
                "protocol.event.item_added",
                fields: ["item": CodexVoiceLog.encodedJSON(value.item)]
            )
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
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = transcript.lastIndex(where: {
                $0.role.localizedCaseInsensitiveCompare(role) == .orderedSame
                    && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
            }) {
                transcript[index].text = text
                transcript[index].isFinal = true
            } else {
                transcript.append(.init(role: role, text: text, isFinal: true))
            }
        }
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
