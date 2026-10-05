import XCTest
@testable import CodexCore
@testable import CodexCoreApp

@MainActor
final class CodexAppRuntimeNoticeFeaturesTests: XCTestCase {
    func testKnownTurnFactsAreSummarizedWithoutProviderPayloads() throws {
        let key = TurnKey(threadID: "chat", turnID: "turn")
        let turn = CanonicalTurn(key: key, moderationMetadata: .dictionary(["private": .string("secret moderation payload")]), extensions: [
            "model/verification": try CodexJSONValue(encoding: CodexSchemaModelVerificationNotification(threadID: "chat", turnID: "turn", verifications: [.trustedAccessForCyber])),
            "modelProvider/authRecoveryStarted": try CodexJSONValue(encoding: CodexSchemaAuthRecoveryNotification(message: "secret auth token", provider: "private provider", threadID: "chat", turnID: "turn")),
            "providerAuthRecoveryActive": .bool(true),
            "model/safetyBuffering/updated": try CodexJSONValue(encoding: CodexSchemaModelSafetyBufferingUpdatedNotification(model: "private model", reasons: ["secret reasons"], showBufferingUi: true, threadID: "chat", turnID: "turn", useCases: ["secret cases"])),
            "model/rerouted": try CodexJSONValue(encoding: CodexSchemaModelReroutedNotification(fromModel: "one", reason: .unrecognized("private reason"), threadID: "chat", toModel: "two", turnID: "turn"))
        ])
        let notices = CodexAppRuntimeNoticeFeatures.present(snapshot(turn), selection: .init(threadID: "chat", turnID: "turn"))
        XCTAssertEqual(notices.map(\.kind), [.verification, .authentication, .buffering, .moderation, .rerouting])
        let rendered = notices.map { $0.title + $0.detail }.joined()
        XCTAssertFalse(rendered.contains("secret"))
        XCTAssertFalse(rendered.contains("private"))
        XCTAssertTrue(rendered.contains("trusted-access"))
        XCTAssertTrue(rendered.contains("from one to two"))
    }

    func testNoticesDoNotLeakAcrossThreadOrTurnSelection() {
        let turn = CanonicalTurn(key: .init(threadID: "chat", turnID: "turn"), moderationMetadata: .dictionary([:]))
        let value = snapshot(turn)
        XCTAssertTrue(CodexAppRuntimeNoticeFeatures.present(value, selection: .init(threadID: "other", turnID: "turn")).isEmpty)
        XCTAssertTrue(CodexAppRuntimeNoticeFeatures.present(value, selection: .init(threadID: "chat", turnID: "other")).isEmpty)
        XCTAssertEqual(CodexAppRuntimeNoticeFeatures.present(value, selection: .init(threadID: "chat", turnID: nil)).count, 1)
    }

    func testBufferingStopsOnTerminalTurnAndFalseUiFlag() throws {
        for (status, show) in [(CanonicalTurnStatus.completed, true), (.inProgress, false)] {
            let turn = CanonicalTurn(key: .init(threadID: "chat", turnID: "turn"), status: status, extensions: [
                "model/safetyBuffering/updated": try CodexJSONValue(encoding: CodexSchemaModelSafetyBufferingUpdatedNotification(model: "model", reasons: [], showBufferingUi: show, threadID: "chat", turnID: "turn", useCases: []))
            ])
            XCTAssertTrue(CodexAppRuntimeNoticeFeatures.present(snapshot(turn), selection: .init(threadID: "chat", turnID: "turn")).isEmpty)
        }
    }

    func testStrictReviewEscalationHasAnActualScopedAppNotice() throws {
        let turn = CanonicalTurn(key: .init(threadID: "chat", turnID: "turn"), extensions: [
            "autoApprovalReview:strictReviewRequired": try CodexJSONValue(encoding:
                CodexSchemaStrictReviewRequiredNotification(startedAtMs: 100, threadID: "chat", turnID: "turn"))
        ])
        let notices = CodexAppRuntimeNoticeFeatures.present(snapshot(turn), selection: .init(threadID: "chat", turnID: "turn"))
        XCTAssertEqual(notices.map(\.kind), [.guardian])
        XCTAssertEqual(notices[0].severity, .warning)
        XCTAssertTrue(notices[0].detail.contains("pending approval"))
        XCTAssertTrue(CodexAppRuntimeNoticeFeatures.present(snapshot(turn), selection: .init(threadID: "chat", turnID: "other")).isEmpty)
    }

    func testDiagnosticsRespectConnectionAndThreadAndHideRawDetail() {
        let entries = [diagnostic(epoch: 1, ordinal: 1, threadID: nil), diagnostic(epoch: 1, ordinal: 2, threadID: "chat"),
                       diagnostic(epoch: 1, ordinal: 3, threadID: "other"), diagnostic(epoch: 2, ordinal: 4, threadID: nil)]
        let notices = CodexAppRuntimeNoticeFeatures.present(.init(connectionEpoch: 1, canonical: .init(), diagnostics: entries),
                                                            selection: .init(threadID: "chat", turnID: nil))
        XCTAssertEqual(notices.map(\.id), ["diagnostic:1:1", "diagnostic:1:2"])
        XCTAssertFalse(notices.map(\.detail).joined().contains("private native diagnostic"))
        XCTAssertTrue(notices.map(\.detail).joined().contains("user-facing warning"))
    }

    func testTypedDiagnosticFieldsRemainActionableAndBounded() {
        let contents: [CodexProtocolDiagnosticContent] = [
            .warning(message: "Check credentials"), .guardianWarning(message: "Review denied action"),
            .deprecationNotice(summary: "Replace old setting", details: "Use new_setting"),
            .configWarning(summary: "Invalid setting", details: String(repeating: "x", count: 4_000), path: "/tmp/config.toml\u{0000}")
        ]
        let entries = contents.enumerated().map { index, content in
            CodexProtocolDiagnosticEntry(cursor: .init(connectionEpoch: 1, ordinal: UInt64(index)), kind: .warning,
                                         method: "warning", detail: "raw payload must stay hidden", content: content)
        }
        let notices = CodexAppRuntimeNoticeFeatures.present(.init(connectionEpoch: 1, canonical: .init(), diagnostics: entries),
                                                            selection: .init(threadID: nil, turnID: nil))
        XCTAssertEqual(notices.count, 4)
        XCTAssertEqual(notices[0].detail, "Check credentials")
        XCTAssertEqual(notices[1].detail, "Review denied action")
        XCTAssertTrue(notices[2].detail.contains("Use new_setting"))
        XCTAssertTrue(notices[3].detail.contains("Location: /tmp/config.toml"))
        XCTAssertFalse(notices[3].detail.contains("\u{0000}"))
        XCTAssertLessThan(notices[3].detail.count, 1_400)
        XCTAssertFalse(notices.map(\.detail).joined().contains("raw payload"))
    }

    func testLateSelectionSnapshotCannotPublishIntoReplacementSelection() async throws {
        let provider = RuntimeNoticeTestProvider()
        let features = CodexAppRuntimeNoticeFeatures()
        await features.bind(provider)
        await features.select(threadID: "first", turnID: "turn")
        await features.select(threadID: "second", turnID: "turn")
        await provider.emit(snapshot(.init(key: .init(threadID: "first", turnID: "turn"), moderationMetadata: .dictionary([:]))), index: 1)
        await provider.emit(snapshot(.init(key: .init(threadID: "second", turnID: "turn"), moderationMetadata: .dictionary([:]))), index: 2)
        try await wait { features.notices.count == 1 }
        XCTAssertTrue(features.notices[0].id.contains("second"))
        await features.bind(nil)
        XCTAssertTrue(features.notices.isEmpty)
    }

    func testUnexpectedReplacementEpochCannotPublishWithoutHostRebind() async throws {
        let provider = RuntimeNoticeTestProvider()
        let features = CodexAppRuntimeNoticeFeatures()
        await features.bind(provider)
        await provider.emit(.init(connectionEpoch: 1, canonical: .init(), diagnostics: [diagnostic(epoch: 1, ordinal: 1, threadID: nil)]), index: 0)
        try await wait { features.notices.count == 1 }
        await provider.emit(.init(connectionEpoch: 2, canonical: .init(), diagnostics: [diagnostic(epoch: 2, ordinal: 2, threadID: nil)]), index: 0)
        await Task.yield()
        XCTAssertEqual(features.notices.map(\.id), ["diagnostic:1:1"])
        await features.bind(nil)
    }

    private func snapshot(_ turn: CanonicalTurn) -> CodexAppRuntimeNoticeSnapshot {
        .init(connectionEpoch: 1, canonical: .init(threads: [turn.key.threadID: .init(id: turn.key.threadID, turnOrder: [turn.key.turnID])], turns: [turn.key: turn]), diagnostics: [])
    }
    private func diagnostic(epoch: UInt64, ordinal: UInt64, threadID: String?) -> CodexProtocolDiagnosticEntry {
        .init(cursor: .init(connectionEpoch: epoch, ordinal: ordinal), kind: .warning, method: "warning",
              threadID: threadID.map { ThreadID($0) }, detail: "private native diagnostic", content: .warning(message: "user-facing warning"))
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 { if predicate() { return }; try await Task.sleep(for: .milliseconds(2)) }
        XCTFail("Runtime notice did not publish")
    }
}

private actor RuntimeNoticeTestProvider: CodexAppRuntimeNoticeProviding {
    private var streams: [AsyncThrowingStream<CodexAppRuntimeNoticeSnapshot, Error>.Continuation] = []
    func observe(_ selection: CodexAppRuntimeNoticeSelection) -> AsyncThrowingStream<CodexAppRuntimeNoticeSnapshot, Error> {
        let pair = AsyncThrowingStream<CodexAppRuntimeNoticeSnapshot, Error>.makeStream()
        streams.append(pair.continuation)
        return pair.stream
    }
    func emit(_ value: CodexAppRuntimeNoticeSnapshot, index: Int) { streams[index].yield(value) }
}
