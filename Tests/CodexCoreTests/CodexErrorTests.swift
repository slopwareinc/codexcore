import XCTest
@testable import CodexCore

final class CodexErrorTests: XCTestCase {
    func testJSONRPCErrorMappingAndRetryClassification() {
        XCTAssertEqual(mapJSONRPCError(code: -32700, message: "parse").kind, .parse)
        XCTAssertEqual(mapJSONRPCError(code: -32600, message: "invalid request").kind, .invalidRequest)
        XCTAssertEqual(mapJSONRPCError(code: -32601, message: "missing").kind, .methodNotFound)
        XCTAssertEqual(mapJSONRPCError(code: -32602, message: "bad params").kind, .invalidParams)
        XCTAssertEqual(mapJSONRPCError(code: -32603, message: "internal").kind, .internalRpc)

        let overloadData: CodexJSONValue = .dictionary([
            "codexErrorInfo": .string("server_overloaded")
        ])
        let busy = mapJSONRPCError(
            code: -32000,
            message: "server busy",
            data: overloadData
        )
        XCTAssertEqual(busy.kind, .serverBusy)
        XCTAssertTrue(isRetryableError(busy))

        let retryLimit = mapJSONRPCError(
            code: -32000,
            message: "retry limit reached",
            data: overloadData
        )
        XCTAssertEqual(retryLimit.kind, .retryLimitExceeded)
        XCTAssertTrue(isRetryableError(retryLimit))

        let canonicalWireError = CodexJSONRPCErrorObject(
            code: -32000,
            message: "server overloaded",
            data: overloadData
        )
        XCTAssertTrue(isRetryableError(canonicalWireError))

        let generic = mapJSONRPCError(
            code: -32000,
            message: "other",
            data: .dictionary([:])
        )
        XCTAssertEqual(generic.kind, .codexRpc)
        XCTAssertFalse(isRetryableError(generic))
        XCTAssertFalse(isRetryableError(CodexJSONRPCErrorObject(
            code: -32000,
            message: "other",
            data: .dictionary([:])
        )))
    }

    func testTurnSteerRaceClassificationMatchesAppServerErrors() {
        XCTAssertEqual(
            classifyCodexTurnSteerRace(CodexJSONRPCErrorObject(
                code: -32602,
                message: "no active turn to steer"
            )),
            .noActiveTurn
        )
        XCTAssertEqual(
            classifyCodexTurnSteerRace(CodexJSONRPCErrorObject(
                code: -32602,
                message: "expected active turn id `turn-old` but found `turn-current`"
            )),
            .expectedTurnMismatch(actualTurnID: "turn-current")
        )
        XCTAssertNil(classifyCodexTurnSteerRace(CodexJSONRPCErrorObject(
            code: -32602,
            message: "cannot steer a review turn"
        )))
    }

    func testOfficialAppServerOverloadIsRetryableWithoutLegacyErrorData() {
        let mapped = mapJSONRPCError(
            code: -32_001,
            message: "Server overloaded; retry later."
        )
        XCTAssertEqual(mapped.kind, .serverBusy)
        XCTAssertTrue(isRetryableError(mapped))

        let wireError = CodexJSONRPCErrorObject(
            code: -32_001,
            message: "Server overloaded; retry later."
        )
        XCTAssertTrue(isRetryableError(wireError))
    }

    func testCodexErrorFormattingUsesLocalizedDescriptions() {
        let localized = LocalizedFixtureError()
        XCTAssertEqual(
            (localized as any CodexError).localizedDescription,
            "Friendly fixture failure"
        )
        XCTAssertEqual(
            CodexErrorFormat.localizedDescription(localized),
            "Friendly fixture failure"
        )

        let plainCodex = PlainCodexFixtureError()
        XCTAssertEqual(
            (plainCodex as any CodexError).localizedDescription,
            "PlainCodexFixtureError()"
        )
        XCTAssertEqual(
            CodexErrorFormat.localizedDescription(plainCodex),
            "PlainCodexFixtureError()"
        )

        let longDescription = CodexErrorFormat.localizedDescription(LongFixtureError())
        XCTAssertEqual(longDescription.count, 201)
        XCTAssertFalse(longDescription.hasSuffix("..."))
        XCTAssertTrue(longDescription.hasSuffix("…"))
    }
}

private struct LocalizedFixtureError: CodexError, LocalizedError {
    var errorDescription: String? { "Friendly fixture failure" }
}

private struct PlainCodexFixtureError: CodexError {}

private struct LongFixtureError: Error, LocalizedError {
    var errorDescription: String? { String(repeating: "x", count: 240) }
}
