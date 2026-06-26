import Foundation

public extension Codex {
    func threadRealtimeStart(
        _ params: CodexSchemaThreadRealtimeStartParams
    ) async throws -> CodexSchemaThreadRealtimeStartResponse {
        let encoded = try CodexJSONValue(encoding: params)
        guard let object = encoded.objectValue else {
            throw CodexJSONBridgeError.paramsMustBeObject(encoded)
        }
        return try await appServerRequest(
            .threadRealtimeStart,
            params: object,
            response: CodexSchemaThreadRealtimeStartResponse.self
        )
    }

    func threadRealtimeAppendAudio(
        _ params: CodexSchemaThreadRealtimeAppendAudioParams
    ) async throws -> CodexSchemaThreadRealtimeAppendAudioResponse {
        let encoded = try CodexJSONValue(encoding: params)
        guard let object = encoded.objectValue else {
            throw CodexJSONBridgeError.paramsMustBeObject(encoded)
        }
        return try await appServerRequest(
            .threadRealtimeAppendAudio,
            params: object,
            response: CodexSchemaThreadRealtimeAppendAudioResponse.self
        )
    }

    func threadRealtimeAppendText(
        _ params: CodexSchemaThreadRealtimeAppendTextParams
    ) async throws -> CodexSchemaThreadRealtimeAppendTextResponse {
        let encoded = try CodexJSONValue(encoding: params)
        guard let object = encoded.objectValue else {
            throw CodexJSONBridgeError.paramsMustBeObject(encoded)
        }
        return try await appServerRequest(
            .threadRealtimeAppendText,
            params: object,
            response: CodexSchemaThreadRealtimeAppendTextResponse.self
        )
    }

    func threadRealtimeAppendSpeech(
        _ params: CodexSchemaThreadRealtimeAppendSpeechParams
    ) async throws -> CodexSchemaThreadRealtimeAppendSpeechResponse {
        let encoded = try CodexJSONValue(encoding: params)
        guard let object = encoded.objectValue else {
            throw CodexJSONBridgeError.paramsMustBeObject(encoded)
        }
        return try await appServerRequest(
            .threadRealtimeAppendSpeech,
            params: object,
            response: CodexSchemaThreadRealtimeAppendSpeechResponse.self
        )
    }

    func threadRealtimeStop(
        _ params: CodexSchemaThreadRealtimeStopParams
    ) async throws -> CodexSchemaThreadRealtimeStopResponse {
        let encoded = try CodexJSONValue(encoding: params)
        guard let object = encoded.objectValue else {
            throw CodexJSONBridgeError.paramsMustBeObject(encoded)
        }
        return try await appServerRequest(
            .threadRealtimeStop,
            params: object,
            response: CodexSchemaThreadRealtimeStopResponse.self
        )
    }

    func threadRealtimeListVoices(
        _ params: CodexSchemaThreadRealtimeListVoicesParams = CodexSchemaThreadRealtimeListVoicesParams(.dictionary([:]))
    ) async throws -> CodexSchemaThreadRealtimeListVoicesResponse {
        let encoded = try CodexJSONValue(encoding: params)
        guard let object = encoded.objectValue else {
            throw CodexJSONBridgeError.paramsMustBeObject(encoded)
        }
        return try await appServerRequest(
            .threadRealtimeListVoices,
            params: object,
            response: CodexSchemaThreadRealtimeListVoicesResponse.self
        )
    }
}
