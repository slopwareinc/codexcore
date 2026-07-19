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
