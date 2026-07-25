import Foundation

public extension Codex {
    func threadRealtimeStart(
        _ params: CodexSchemaThreadRealtimeStartParams
    ) async throws -> CodexSchemaThreadRealtimeStartResponse {
        try await perform(CodexRequest.threadRealtimeStart(params))
    }

    func threadRealtimeAppendAudio(
        _ params: CodexSchemaThreadRealtimeAppendAudioParams
    ) async throws -> CodexSchemaThreadRealtimeAppendAudioResponse {
        try await perform(CodexRequest.threadRealtimeAppendAudio(params))
    }

    func threadRealtimeAppendText(
        _ params: CodexSchemaThreadRealtimeAppendTextParams
    ) async throws -> CodexSchemaThreadRealtimeAppendTextResponse {
        try await perform(CodexRequest.threadRealtimeAppendText(params))
    }

    func threadRealtimeAppendSpeech(
        _ params: CodexSchemaThreadRealtimeAppendSpeechParams
    ) async throws -> CodexSchemaThreadRealtimeAppendSpeechResponse {
        try await perform(CodexRequest.threadRealtimeAppendSpeech(params))
    }

    func threadRealtimeStop(
        _ params: CodexSchemaThreadRealtimeStopParams
    ) async throws -> CodexSchemaThreadRealtimeStopResponse {
        try await perform(CodexRequest.threadRealtimeStop(params))
    }

    func threadRealtimeListVoices(
        _ params: CodexSchemaThreadRealtimeListVoicesParams = CodexSchemaThreadRealtimeListVoicesParams(.dictionary([:]))
    ) async throws -> CodexSchemaThreadRealtimeListVoicesResponse {
        try await perform(CodexRequest.threadRealtimeListVoices(params))
    }
}

public extension CodexSchemaThreadRealtimeStartParams {
    /// Builds the browser/webview-owned Frameless Bidi WebRTC shape used by
    /// current Codex desktop Voice.
    static func codexVoiceWebRTC(
        threadID: String,
        offerSDP: String,
        realtimeSessionID: String = UUID().uuidString,
        model: String = "gpt-live-1-codex",
        voice: CodexSchemaRealtimeVoice = .sol
    ) -> Self {
        Self(
            flushTranscriptTailOnSessionEnd: true,
            includeStartupContext: false,
            model: model,
            outputModality: .audio,
            realtimeSessionID: realtimeSessionID,
            threadID: threadID,
            transport: CodexSchemaThreadRealtimeStartTransport(.dictionary([
                "type": .string("webrtc"),
                "sdp": .string(offerSDP),
            ])),
            version: .v3,
            voice: voice
        )
    }
}
