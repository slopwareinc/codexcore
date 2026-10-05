import Foundation
import Testing
@testable import CodexCore
@testable import CodexCoreApp

@MainActor
struct CodexAppRuntimeWorkflowTests {
    @Test func laterBindWinsWhileOldWatchCleanupWaits() async {
        let old = RuntimeWorkflowFixture(), middle = RuntimeWorkflowFixture(), newest = RuntimeWorkflowFixture()
        let features = CodexAppFileFeatures()
        await features.bind(old)
        await features.startWatching("/old")
        await old.hold(.fsUnwatch)
        let binding = Task { await features.bind(middle) }
        await old.waitForHold()
        await features.bind(newest)
        await old.release()
        await binding.value
        await features.browse("/new")
        #expect(await newest.calls.contains(.fsReadDirectory))
        #expect(await !middle.calls.contains(.fsReadDirectory))
        #expect(features.directory == "/new")
    }

    @Test func delayedWatchStartCannotReplaceNewWatchAndIsUnregisteredAgain() async {
        let provider = RuntimeWorkflowFixture()
        let features = CodexAppFileFeatures()
        await features.bind(provider)
        await provider.hold(.fsWatch)
        let first = Task { await features.startWatching("/old") }
        await provider.waitForHold()
        await features.startWatching("/new")
        #expect(features.watchingPath == "/new")
        await provider.release()
        await first.value
        #expect(features.watchingPath == "/new")
        #expect(await provider.calls.filter { $0 == .fsUnwatch }.count == 2)
        await features.bind(nil)
    }

    @Test func delayedSearchStartCannotUpdateReplacementSearch() async {
        let provider = RuntimeWorkflowFixture()
        let features = CodexAppFileFeatures()
        await features.bind(provider)
        await provider.hold(.fuzzyFileSearchSessionStart)
        let first = Task { await features.search(query: "old", roots: ["/repo"]) }
        await provider.waitForHold()
        await features.search(query: "new", roots: ["/repo"])
        await provider.release()
        await first.value
        let updates = await provider.parameters.filter { $0.method == .fuzzyFileSearchSessionUpdate }
        #expect(updates.count == 1)
        #expect(updates.first?.fields["query"] == .string("new"))
        await features.bind(nil)
    }

    @Test func mutationFailureRemainsVisibleWithoutAnUnrelatedReload() async {
        let provider = RuntimeWorkflowFixture()
        let features = CodexAppFileFeatures()
        await features.bind(provider)
        await features.browse("/repo")
        await provider.fail(.fsRemove)
        await features.remove("/repo/file", recursive: false)
        #expect(features.error == "fixture failure")
        #expect(await provider.calls.filter { $0 == .fsReadDirectory }.count == 1)
        #expect(features.directory == "/repo")
    }

    @Test func immutableSaveContentsAreSentEvenAfterEditorChanges() async {
        let provider = RuntimeWorkflowFixture()
        let features = CodexAppFileFeatures()
        await features.bind(provider)
        features.text = "later edits"
        await features.save(path: "/confirmed", contents: "reviewed contents")
        let write = await provider.parameters.last
        #expect(write?.fields["path"] == .string("/confirmed"))
        #expect(write?.fields["dataBase64"] == .string(Data("reviewed contents".utf8).base64EncodedString()))
    }

    @Test func importNormalStreamEndClearsSpinnerAndReportsReconciliation() async {
        let provider = RuntimeWorkflowFixture()
        let features = CodexAppImportFeatures()
        features.bind(provider)
        await features.detect(source: nil, folders: ["/repo"], includeHome: false)
        await features.startImport(indices: [0], source: nil)
        #expect(features.isImporting)
        await provider.finishImports()
        await waitUntil { !features.isImporting }
        #expect(!features.isImporting)
        #expect(features.error?.contains("ended before completion") == true)
    }

    @Test func earlyImportCompletionSurvivesStreamEndBeforeRPCResponse() async {
        let provider = RuntimeWorkflowFixture()
        let features = CodexAppImportFeatures()
        features.bind(provider)
        await features.detect(source: nil, folders: ["/repo"], includeHome: false)
        await provider.hold(.externalAgentConfigImport)
        let importing = Task { await features.startImport(indices: [0], source: nil) }
        await provider.waitForHold()
        await provider.completeImport()
        await provider.finishImports()
        await waitUntil { !features.isImporting }
        await provider.release()
        await importing.value
        #expect(features.completion?.importID == "import")
        #expect(!features.isImporting)
        #expect(features.error == nil)
    }

    @Test func projectReadsDoNotNotifyHostAndAcceptedMutationRetainsFactsOnReloadFailure() async {
        let provider = RuntimeWorkflowFixture()
        let features = CodexAppProjectFeatures()
        features.bind(provider)
        var callbacks = 0
        features.onChanged = { callbacks += 1 }
        await features.refresh()
        await features.read("project")
        #expect(callbacks == 0)
        await provider.fail(.projectList)
        await features.update(id: "project", name: "Renamed", roots: ["/repo"])
        #expect(callbacks == 1)
        #expect(features.selectedProject?.name == "Renamed")
        #expect(features.error?.contains("saved") == true)
    }
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<5_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("The expected import state did not arrive.")
    }
}

private actor RuntimeWorkflowFixture: CodexAppFileRuntimeProviding, CodexAppImportRuntimeProviding {
    struct Recorded: Sendable { let method: CodexAppServerClientMethod; let fields: [String: CodexJSONValue] }
    private(set) var calls: [CodexAppServerClientMethod] = []
    private(set) var parameters: [Recorded] = []
    private var heldMethod: CodexAppServerClientMethod?
    private var gate: CheckedContinuation<Void, Never>?
    private var failingMethod: CodexAppServerClientMethod?
    private let importPair = AsyncThrowingStream<CodexExternalAgentConfigImportEvent, Error>.makeStream()
    private var retainedStreams: [AsyncThrowingStream<CodexSchemaFSChangedNotification, Error>.Continuation] = []
    private var retainedSearches: [AsyncThrowingStream<CodexFuzzyFileSearchEvent, Error>.Continuation] = []

    func hold(_ method: CodexAppServerClientMethod) { heldMethod = method }
    func fail(_ method: CodexAppServerClientMethod) { failingMethod = method }
    func waitForHold() async {
        for _ in 0..<5_000 { if gate != nil { return }; try? await Task.sleep(for: .milliseconds(2)) }
        Issue.record("The expected request did not reach its suspension point.")
    }
    func release() { gate?.resume(); gate = nil }
    func changes(watchID: String) -> AsyncThrowingStream<CodexSchemaFSChangedNotification, Error> {
        let pair = AsyncThrowingStream<CodexSchemaFSChangedNotification, Error>.makeStream()
        retainedStreams.append(pair.continuation)
        return pair.stream
    }
    func searches(sessionID: String) -> AsyncThrowingStream<CodexFuzzyFileSearchEvent, Error> {
        let pair = AsyncThrowingStream<CodexFuzzyFileSearchEvent, Error>.makeStream()
        retainedSearches.append(pair.continuation)
        return pair.stream
    }
    func observeImports() -> AsyncThrowingStream<CodexExternalAgentConfigImportEvent, Error> { importPair.stream }
    func finishImports() { importPair.continuation.finish() }
    func completeImport() { importPair.continuation.yield(.completed(.init(importID: "import", itemTypeResults: []))) }

    func perform<Response: Decodable & Sendable>(_ request: CodexAppServerRequest<Response>) async throws -> Response {
        calls.append(request.method)
        let fields = try request.encodeParameters()?.objectValue ?? [:]
        parameters.append(.init(method: request.method, fields: fields))
        if heldMethod == request.method {
            heldMethod = nil
            await withCheckedContinuation { gate = $0 }
        }
        if failingMethod == request.method { throw Failure() }
        let value: CodexJSONValue
        switch request.method {
        case .fsReadDirectory: value = try CodexJSONValue(encoding: CodexSchemaFSReadDirectoryResponse(entries: []))
        case .fsWatch: value = .dictionary(["path": fields["path"] ?? .string("/repo")])
        case .externalAgentConfigDetect:
            value = try CodexJSONValue(encoding: CodexSchemaExternalAgentConfigDetectResponse(items: [.init(description: "settings", itemType: .cONFIG)]))
        case .externalAgentConfigImport: value = .dictionary(["importId": .string("import")])
        case .externalAgentConfigImportReadHistories: value = .dictionary(["connectors": .array([]), "data": .array([])])
        case .projectList: value = .dictionary(["data": .array([])])
        case .projectRead, .projectUpdate:
            let name = CodexJSONCoercion.string(in: fields, keys: ["name"]) ?? "Project"
            value = try CodexJSONValue(encoding: CodexSchemaProjectReadResponse(project: .init(createdAt: 1, id: "project", metadata: [:], name: name, position: 0, roots: [.init(path: .init(.string("/repo")))], updatedAt: 2)))
        default: value = .dictionary([:])
        }
        return try value.decode(Response.self)
    }
    struct Failure: LocalizedError { var errorDescription: String? { "fixture failure" } }
}
