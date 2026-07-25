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
            webRTC?.setMicrophoneMuted(isMuted)
        }
    }
    var isOutputMuted = false {
        didSet {
            webRTC?.setOutputMuted(isOutputMuted)
        }
    }

    private var codex: Codex?
    private var threadLease: CodexThreadLease?
    private var eventTask: Task<Void, Never>?
    private var webRTC: CodexVoiceWebRTCTransport?
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

        let transport = CodexVoiceWebRTCTransport { [weak self] level in
            self?.inputLevel = level
        }
        let offerSDP = try await transport.prepareOffer()
        transport.setMicrophoneMuted(isMuted)
        transport.setOutputMuted(isOutputMuted)
        webRTC = transport

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

        _ = try await codex.threadRealtimeStart(.codexVoiceWebRTC(
            threadID: threadLease.id.rawValue,
            offerSDP: offerSDP
        ))
    }

    func stop() async {
        let activeCodex = codex
        let activeThreadID = threadID
        webRTC?.stop()
        webRTC = nil
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
            // WebRTC owns model audio. PCM notifications are only used by
            // websocket clients.
            _ = value
        case .error(let value):
            fail(CodexVoiceChatError.server(value.message))
        case .closed(let value):
            webRTC?.stop()
            webRTC = nil
            let lease = threadLease
            threadLease = nil
            codex = nil
            if let lease {
                Task { await lease.close() }
            }
            phase = value.reason == nil
                ? .inactive
                : .failed(value.reason ?? "Voice chat closed")
        case .sdp(let value):
            webRTC?.applyAnswer(value.sdp)
        case .itemAdded:
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
        webRTC?.stop()
        webRTC = nil
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
