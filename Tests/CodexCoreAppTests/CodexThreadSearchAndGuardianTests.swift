import Foundation
import Testing
@testable import CodexCore
@testable import CodexCoreApp

@MainActor
struct CodexThreadSearchAndGuardianTests {
    @Test func deniedReviewRetainsExactTurnItemAndActionWithProtocolFieldConversion() throws {
        let review = try #require(CodexGuardianDeniedReview(notification: notification(command), threadID: "thread", turnID: "turn"))
        let event = try #require(review.event?.objectValue)
        #expect(event["id"] == .string("review"))
        #expect(event["turn_id"] == .string("turn"))
        #expect(event["target_item_id"] == .string("item"))
        #expect(event["status"] == .string("denied"))
        #expect(event["rationale"] == .string("Review rationale"))
        #expect(event["action"]?.objectValue?["source"] == .string("unified_exec"))
        #expect(event["action"]?.objectValue?["command"] == .string("printf test"))
    }

    @Test func allKnownActionArmsConvertWithoutGuessingUnknownActions() throws {
        let values: [(CodexJSONValue, String)] = [
            (command, "command"),
            (.dictionary(["type": .string("execve"), "source": .string("shell"), "program": .string("/bin/echo"), "argv": .array([.string("echo"), .string("test")]), "cwd": .string("/tmp")]), "execve"),
            (.dictionary(["type": .string("writeStdin"), "approvalId": .string("child"), "processId": .string("process"), "stdin": .string("yes\n"), "cwd": .string("/tmp")]), "write_stdin"),
            (.dictionary(["type": .string("applyPatch"), "cwd": .string("/tmp"), "files": .array([.string("/tmp/file")])]), "apply_patch"),
            (.dictionary(["type": .string("networkAccess"), "target": .string("example.com:80"), "host": .string("example.com"), "port": .int(80), "protocol": .string("socks5Tcp")]), "network_access"),
            (.dictionary(["type": .string("mcpToolCall"), "server": .string("server"), "toolName": .string("write"), "connectorId": .string("connector"), "connectorName": .string("Service"), "toolTitle": .string("Write")]), "mcp_tool_call"),
            (.dictionary(["type": .string("requestPermissions"), "reason": .string("Inspect"), "permissions": .dictionary(["network": .null, "fileSystem": .dictionary(["read": .array([.string("/tmp/file")]), "globScanMaxDepth": .int(2)])])]), "request_permissions"),
        ]
        for (value, type) in values {
            let review = try #require(CodexGuardianDeniedReview(notification: notification(value), threadID: "thread", turnID: "turn"))
            let action = try #require(review.event?.objectValue?["action"]?.objectValue)
            #expect(action["type"] == .string(type))
            if type == "write_stdin" {
                #expect(action["approval_id"] == .string("child"))
                #expect(action["cwd"] == .string("file:///tmp"))
                #expect(action["stdin"] == .string("yes\n"))
            }
            if type == "mcp_tool_call" { #expect(action["tool_name"] == .string("write")); #expect(action["connector_id"] == .string("connector")) }
            if type == "network_access" { #expect(action["protocol"] == .string("socks5_tcp")) }
            if type == "request_permissions" {
                let fileSystem = action["permissions"]?.objectValue?["file_system"]?.objectValue
                #expect(fileSystem?["glob_scan_max_depth"] == .int(2))
                #expect(fileSystem?["entries"] == .array([.dictionary(["access": .string("read"), "path": .dictionary(["type": .string("path"), "path": .string("file:///tmp/file")])])]))
            }
        }
        let unknown = try #require(CodexGuardianDeniedReview(notification: notification(.dictionary(["type": .string("futureAction"), "payload": .string("exact")])), threadID: "thread", turnID: "turn"))
        #expect(unknown.event == nil)
        #expect(unknown.unavailableReason != nil)
        #expect(CodexGuardianDeniedReview(notification: notification(command), threadID: "other", turnID: "turn") == nil)
        #expect(CodexGuardianDeniedReview(notification: notification(command), threadID: "thread", turnID: "other") == nil)
    }

    @Test func explicitApprovalConsumesOnlyThatRetainedReviewAfterSuccess() async throws {
        let review = try #require(CodexGuardianDeniedReview(notification: notification(command), threadID: "thread", turnID: "turn"))
        let provider = InspectorFixture(reviews: [review])
        let features = CodexThreadFeatureController()
        features.bind(provider: provider, threadID: "thread")
        await features.activate(.approvals)
        await provider.failNextApproval()
        await features.approveDeniedActionConfirmed(review)
        #expect(features.deniedReviews.count == 1)
        #expect(features.errorMessage != nil)
        await features.approveDeniedActionConfirmed(review)
        #expect(features.deniedReviews.isEmpty)
        let params = await provider.approvals
        #expect(params.count == 2)
        #expect(params.last?.threadID == "thread")
        #expect(params.last?.event == review.event)
        await features.approveDeniedActionConfirmed(review)
        #expect(await provider.approvals.count == 2)
        features.bind(provider: provider, threadID: "replacement")
        await features.approveDeniedActionConfirmed(review)
        #expect(await provider.approvals.count == 2)
    }

    @Test func occurrencePagesKeepMultipleMatchesPerItemAndExactNavigationCursor() async {
        let first = occurrence(start: 0), nextMatch = occurrence(start: 5)
        let provider = InspectorFixture(pages: [.init(data: [first], nextCursor: "next"), .init(data: [first, nextMatch])])
        let features = CodexThreadFeatureController()
        features.bind(provider: provider, threadID: "thread")
        var opened: CodexSchemaThreadSearchOccurrence?
        features.onOpenOccurrence = { thread, occurrence in #expect(thread == "thread"); opened = occurrence }
        await features.findOccurrences(" test ")
        await features.loadMore()
        #expect(features.occurrences.count == 2)
        #expect(features.searchQuery == "test")
        #expect(features.occurrenceCursor == nil)
        await features.openOccurrence(nextMatch)
        #expect(opened?.turnCursor == "exact-turn-cursor")
        #expect(opened?.itemID == "item")
    }

    @Test func loadedThreadInventoryPaginatesAndStopsRepeatedCursors() async {
        let provider = InspectorFixture(loaded: [.init(data: ["one"], nextCursor: "next"), .init(data: ["one", "two"], nextCursor: "next")])
        let features = CodexThreadFeatureController()
        features.bind(provider: provider, threadID: "thread")
        await features.loadLoadedThreads()
        await features.loadLoadedThreads(append: true)
        #expect(features.loadedThreadIDs == ["one", "two"])
        #expect(features.loadedCursor == nil)
        #expect(features.errorMessage?.contains("repeated") == true)
    }

    @Test func refreshedHistoryRejectsDelayedOldTurnPage() async throws {
        let provider = TurnPaginationFixture()
        let features = CodexThreadFeatureController()
        features.bind(provider: provider, threadID: "thread")
        await features.activate(.history)
        #expect(features.turns.map(\.id) == ["initial"])
        let oldPage = Task { await features.loadMoreTurns() }
        try await provider.waitForPage()
        await features.refresh()
        await provider.releasePage()
        await oldPage.value
        #expect(features.turns.map(\.id) == ["refreshed"])
        #expect(features.turnsCursor == "new-cursor")
        #expect(!features.isLoading)
    }

    @Test func queuePagesProduceOneCompleteReorderPermutation() async {
        let provider = QueuePaginationFixture(pages: [.init(data: [queued("one"), queued("two")], nextCursor: "next"), .init(data: [queued("three")])])
        let features = CodexThreadFeatureController()
        features.bind(provider: provider, threadID: "thread")
        await features.activate(.queue)
        #expect(features.queueIsComplete)
        #expect(features.queue.map(\.id) == ["one", "two", "three"])
        await features.moveQueuedSubmission(id: "two", offset: 1)
        #expect(await provider.reorders == [["one", "three", "two"]])
        #expect(features.queue.map(\.id) == ["one", "three", "two"])
    }

    @Test func repeatedQueueCursorPreventsPartialReorder() async {
        let provider = QueuePaginationFixture(pages: [.init(data: [queued("one"), queued("two")], nextCursor: "next"), .init(data: [queued("three")], nextCursor: "next")])
        let features = CodexThreadFeatureController()
        features.bind(provider: provider, threadID: "thread")
        await features.activate(.queue)
        #expect(!features.queueIsComplete)
        #expect(features.errorMessage != nil)
        await features.moveQueuedSubmission(id: "one", offset: 1)
        #expect(await provider.reorders.isEmpty)
    }

    private func queued(_ id: String) -> CodexSchemaQueuedSubmission {
        .init(clientUserMessageID: id, id: id, input: [])
    }

    private var command: CodexJSONValue { .dictionary(["type": .string("command"), "source": .string("unifiedExec"), "command": .string("printf test"), "cwd": .string("/tmp")]) }
    private func notification(_ action: CodexJSONValue) -> CodexJSONValue {
        .dictionary(["threadId": .string("thread"), "turnId": .string("turn"), "reviewId": .string("review"), "targetItemId": .string("item"), "startedAtMs": .int(1), "completedAtMs": .int(2), "decisionSource": .string("agent"), "action": action, "review": .dictionary(["status": .string("denied"), "riskLevel": .string("high"), "userAuthorization": .string("low"), "rationale": .string("Review rationale")])])
    }
    private func occurrence(start: Int) -> CodexSchemaThreadSearchOccurrence {
        .init(itemID: "item", snippet: "test test", snippetMatchRange: .init(end: start + 4, start: start), turnCursor: "exact-turn-cursor", turnID: "turn")
    }
}

private actor InspectorFixture: CodexThreadFeatureProvider {
    let reviews: [CodexGuardianDeniedReview]
    private var pages: [CodexSchemaThreadSearchOccurrencesResponse]
    private var loaded: [CodexSchemaThreadLoadedListResponse]
    private var failsApproval = false
    private(set) var approvals: [CodexSchemaThreadApproveGuardianDeniedActionParams] = []
    init(reviews: [CodexGuardianDeniedReview] = [], pages: [CodexSchemaThreadSearchOccurrencesResponse] = [], loaded: [CodexSchemaThreadLoadedListResponse] = []) {
        self.reviews = reviews; self.pages = pages; self.loaded = loaded
    }
    func failNextApproval() { failsApproval = true }
    func deniedReviews(threadID: String) -> [CodexGuardianDeniedReview] { threadID == "thread" ? reviews : [] }
    func perform(_ request: CodexThreadFeatureRequest) throws -> CodexThreadFeatureResponse {
        switch request {
        case .approveGuardian(let params):
            approvals.append(params)
            if failsApproval { failsApproval = false; throw CodexThreadFeatureError.invalidSettings("approval failed") }
            return .mutation
        case .occurrences: return .occurrences(pages.isEmpty ? .init(data: []) : pages.removeFirst())
        case .loaded: return .loaded(loaded.isEmpty ? .init(data: []) : loaded.removeFirst())
        default: return .mutation
        }
    }
}

private actor TurnPaginationFixture: CodexThreadFeatureProvider {
    private var firstPages = 0
    private var pageGate: CheckedContinuation<Void, Never>?
    func waitForPage() async throws {
        for _ in 0..<1_000 { if pageGate != nil { return }; try await Task.sleep(for: .milliseconds(2)) }
        throw PageTimeout()
    }
    func releasePage() { pageGate?.resume(); pageGate = nil }
    func perform(_ request: CodexThreadFeatureRequest) async throws -> CodexThreadFeatureResponse {
        switch request {
        case .timeline: return .timeline(.init(data: []))
        case .turns(let params):
            if params.cursor != nil {
                await withCheckedContinuation { pageGate = $0 }
                return .turns(.init(data: [.init(id: "stale", items: [], status: .completed)]))
            }
            firstPages += 1
            return .turns(.init(data: [.init(id: firstPages == 1 ? "initial" : "refreshed", items: [], status: .completed)], nextCursor: firstPages == 1 ? "old-cursor" : "new-cursor"))
        default: return .mutation
        }
    }
    private struct PageTimeout: Error {}
}

private actor QueuePaginationFixture: CodexThreadFeatureProvider {
    private var pages: [CodexSchemaThreadQueueListResponse]
    private var inventory: [CodexSchemaQueuedSubmission] = []
    private(set) var reorders: [[String]] = []
    init(pages: [CodexSchemaThreadQueueListResponse]) { self.pages = pages }
    func perform(_ request: CodexThreadFeatureRequest) throws -> CodexThreadFeatureResponse {
        switch request {
        case .queue(let params):
            guard !pages.isEmpty else { return .queue(.init(data: inventory)) }
            let page = pages.removeFirst()
            if params.cursor == nil { inventory = [] }
            inventory += page.data
            return .queue(page)
        case .reorderQueue(let params):
            reorders.append(params.queuedSubmissionIDs)
            inventory = params.queuedSubmissionIDs.compactMap { id in inventory.first { $0.id == id } }
            return .mutation
        default: return .mutation
        }
    }
}
