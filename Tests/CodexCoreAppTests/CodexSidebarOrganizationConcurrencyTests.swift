import CodexCore
@testable import CodexCoreApp
import CodexCoreUI
import Foundation
import Testing

@MainActor
@Suite("Sidebar organization concurrency")
struct CodexSidebarOrganizationConcurrencyTests {
    @Test("Archived results merge into the latest active/project/search session")
    func archivedRefreshPreservesConcurrentSessionUpdates() async throws {
        let homeURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("codexcore-sidebar-race-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let transport = SidebarOrganizationTransport(homePath: homeURL.path)
        let codex = try await Codex(
            transport: transport,
            config: .init(codexHome: CodexHome(path: homeURL.path))
        )
        let model = CodexCoreAppModel(
            clipboardService: CodexNoopClipboardService(),
            preferenceStore: SidebarPreferenceStore()
        )
        model.codex = codex

        var initial = model.threadListSession
        initial.applyThreadList(
            currentRaw: Self.rawList(id: "before", title: "Before", cwd: "/tmp/before"),
            allRaw: Self.rawList(id: "before", title: "Before", cwd: "/tmp/before"),
            currentWorkspacePath: "/tmp/before"
        )
        initial.applyProjectList(.init(data: [Self.project(id: "before-project", path: "/tmp/before", position: 0)]))
        _ = initial.applyLocalSearch(query: "before")
        model.threadListSession = initial

        let refresh = Task { @MainActor in
            await model.refreshArchivedSidebarChats()
        }
        await transport.waitForArchivedRequest()

        var concurrent = model.threadListSession
        concurrent.applyThreadList(
            currentRaw: Self.rawList(id: "after", title: "After", cwd: "/tmp/after"),
            allRaw: Self.rawList(id: "after", title: "After", cwd: "/tmp/after"),
            currentWorkspacePath: "/tmp/after"
        )
        concurrent.applyProjectList(.init(data: [Self.project(id: "after-project", path: "/tmp/after", position: 0)]))
        _ = concurrent.applyLocalSearch(query: "after")
        model.threadListSession = concurrent

        try await transport.completeArchivedRequest()
        await refresh.value

        #expect(model.threadListSession.allChats.map(\.id) == ["after"])
        #expect(model.threadListSession.serverProjects.map(\.serverID) == ["after-project"])
        #expect(model.threadListSession.searchResults.map(\.id) == ["after"])
        #expect(model.threadListSession.archivedChats.map(\.id) == ["archived"])

        await codex.close()
    }

    @Test("An older failed project move cannot roll back a newer local/server order")
    func overlappingProjectMovesKeepNewestOrder() async throws {
        let homeURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("codexcore-sidebar-project-race-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let transport = SidebarOrganizationTransport(homePath: homeURL.path)
        let codex = try await Codex(
            transport: transport,
            config: .init(codexHome: CodexHome(path: homeURL.path))
        )
        let model = CodexCoreAppModel(
            clipboardService: CodexNoopClipboardService(),
            preferenceStore: SidebarPreferenceStore()
        )
        model.codex = codex

        var list = model.threadListSession
        list.applyProjectList(.init(data: [
            Self.project(id: "alpha-project", path: "/tmp/alpha", position: 0),
            Self.project(id: "beta-project", path: "/tmp/beta", position: 1),
            Self.project(id: "gamma-project", path: "/tmp/gamma", position: 2),
        ]))
        model.threadListSession = list

        model.moveSidebarProject(
            "/tmp/gamma",
            relativeTo: "/tmp/alpha",
            placement: .before
        )
        await transport.waitForProjectMoveCount(1)

        model.moveSidebarProject(
            "/tmp/beta",
            relativeTo: "/tmp/gamma",
            placement: .before
        )
        try await transport.completeProjectMove(at: 0, failure: true)
        await transport.waitForProjectMoveCount(2)
        try await transport.completeProjectMove(at: 1, failure: false)
        await Task.yield()

        #expect(model.sidebarNavigationSession.projectOrder == ["/tmp/beta", "/tmp/gamma", "/tmp/alpha"])
        #expect(model.sidebarActionError == nil)

        await codex.close()
    }

    private static func rawList(id: String, title: String, cwd: String) -> CodexJSONValue {
        .dictionary(["data": .array([.dictionary([
            "id": .string(id),
            "name": .string(title),
            "preview": .string(title),
            "cwd": .string(cwd),
        ])])])
    }

    private static func project(id: String, path: String, position: Int) -> CodexSchemaProject {
        CodexSchemaProject(
            createdAt: 1,
            id: id,
            metadata: [:],
            name: id,
            position: position,
            roots: [.init(path: .init(.string(path)))],
            updatedAt: 1
        )
    }
}

private actor SidebarOrganizationTransport: CodexFrameTransport {
    private let homePath: String
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var archivedRequestID: CodexJSONRPCID?
    private var archivedWaiters: [CheckedContinuation<Void, Never>] = []
    private var projectMoveRequestIDs: [CodexJSONRPCID] = []
    private var projectMoveWaiters: [CheckedContinuation<Void, Never>] = []

    init(homePath: String) {
        self.homePath = homePath
    }

    func open() async throws -> AsyncThrowingStream<Data, Error> {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }

    func write(_ frame: Data) async throws {
        let value = try JSONDecoder().decode(CodexJSONValue.self, from: frame)
        guard case .dictionary(let object) = value,
              case .string(let method)? = object["method"],
              let rawID = object["id"]
        else { return }
        let id = try CodexJSONRPCID(jsonValue: rawID)
        let params: [String: CodexJSONValue]
        if case .dictionary(let dictionary)? = object["params"] {
            params = dictionary
        } else {
            params = [:]
        }

        switch method {
        case "initialize":
            try sendResult(id: id, result: .dictionary([
                "codexHome": .string(homePath),
                "platformFamily": .string("unix"),
                "platformOs": .string("macos"),
                "userAgent": .string("codex/sidebar-test"),
            ]))
        case "thread/list":
            if case .bool(true) = params["archived"] {
                archivedRequestID = id
                let waiters = archivedWaiters
                archivedWaiters.removeAll(keepingCapacity: false)
                waiters.forEach { $0.resume() }
            } else {
                try sendResult(id: id, result: .dictionary(["data": .array([]), "nextCursor": .null]))
            }
        case "project/move":
            projectMoveRequestIDs.append(id)
            let waiters = projectMoveWaiters
            projectMoveWaiters.removeAll(keepingCapacity: false)
            waiters.forEach { $0.resume() }
        default:
            try sendResult(id: id, result: .dictionary([:]))
        }
    }

    func close() async {
        continuation?.finish()
        continuation = nil
    }

    func waitForArchivedRequest() async {
        if archivedRequestID != nil { return }
        await withCheckedContinuation { archivedWaiters.append($0) }
    }

    func completeArchivedRequest() throws {
        guard let id = archivedRequestID else { return }
        archivedRequestID = nil
        try sendResult(id: id, result: .dictionary(["data": .array([.dictionary([
            "cliVersion": .string("test"),
            "createdAt": .int(1),
            "cwd": .string("/tmp/archived"),
            "ephemeral": .bool(false),
            "id": .string("archived"),
            "modelProvider": .string("openai"),
            "name": .string("Archived"),
            "preview": .string("Archived"),
            "sessionId": .string("archived-session"),
            "source": .string("cli"),
            "status": .dictionary(["type": .string("idle")]),
            "turns": .array([]),
            "updatedAt": .int(1),
        ])]), "nextCursor": .null]))
    }

    func waitForProjectMoveCount(_ count: Int) async {
        if projectMoveRequestIDs.count >= count { return }
        await withCheckedContinuation { projectMoveWaiters.append($0) }
    }

    func completeProjectMove(at index: Int, failure: Bool) throws {
        guard projectMoveRequestIDs.indices.contains(index) else { return }
        let id = projectMoveRequestIDs[index]
        if failure {
            let frame = try CodexJSONRPCCodec.encodeError(
                id: id,
                error: .init(code: -1, message: "project move failed")
            )
            continuation?.yield(frame)
        } else {
            try sendResult(id: id, result: .dictionary([:]))
        }
    }

    private func sendResult(id: CodexJSONRPCID, result: CodexJSONValue) throws {
        continuation?.yield(try CodexJSONRPCCodec.encodeResult(id: id, result: result))
    }
}

private final class SidebarPreferenceStore: CodexStringListPreferenceStore, @unchecked Sendable {
    private var values: [String: [String]] = [:]

    func loadStrings(forKey key: String) -> [String] { values[key] ?? [] }

    func saveStrings(_ strings: [String], forKey key: String) {
        values[key] = strings
    }

    func hasStrings(forKey key: String) -> Bool { values[key] != nil }
}
