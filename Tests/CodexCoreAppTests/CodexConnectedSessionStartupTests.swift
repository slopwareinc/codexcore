import CodexCore
@testable import CodexCoreApp
import CodexCoreUI
import Foundation
import Testing

@MainActor
@Suite("Connected session startup")
struct CodexConnectedSessionStartupTests {
    @Test("Slow integration inventory cannot block project discovery")
    func slowIntegrationInventoryDoesNotBlockProjects() async throws {
        let homeURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("codexcore-startup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let transport = StartupOrderingTransport(homePath: homeURL.path)
        let codex = try await Codex(
            transport: transport,
            config: .init(codexHome: CodexHome(path: homeURL.path))
        )
        let model = CodexCoreAppModel()
        model.codex = codex

        await model.refreshConnectedSession(using: codex)
        let inventoryStarted = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await transport.waitUntilInventoryStarts() }
            group.addTask {
                // This is a deadlock guard, not a startup performance budget.
                // Main-actor test suites execute concurrently under `swift test`.
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        let methods = await transport.requestMethods
        #expect(model.threadListSession.allChats.map(\.id) == ["thread-1"])
        #expect(model.threadListSession.recentProjects.contains { $0.workspacePath == "/tmp/project" })
        #expect(Array(methods.prefix(2)) == ["thread/list", "thread/list"])
        #expect(inventoryStarted)
        #expect(methods.contains("mcpServerStatus/list"))

        await model.disconnect()
    }

    @Test("Skills refresh cannot erase a concurrently loaded model catalog")
    func skillsRefreshPreservesLoadedModels() async throws {
        let homeURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("codexcore-config-race-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let transport = ConfigurationRefreshRaceTransport(homePath: homeURL.path)
        let codex = try await Codex(
            transport: transport,
            config: .init(codexHome: CodexHome(path: homeURL.path))
        )
        let model = CodexCoreAppModel()
        model.codex = codex

        let refresh = Task { @MainActor in
            await model.refreshSlashCommands(using: codex)
        }
        await transport.waitUntilSkillsRequestStarts()
        model.configurationSession.applyModelResponse(.init(data: [
            Self.schemaModel("gpt-5.6-sol", isDefault: true),
            Self.schemaModel("gpt-5.6-terra"),
            Self.schemaModel("gpt-5.6-luna"),
        ]))
        try await transport.finishSkillsRequest()
        await refresh.value

        #expect(model.modelOptions.map(\.id) == [
            "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
        ])
        await codex.close()
    }

    private static func schemaModel(
        _ id: String,
        isDefault: Bool = false
    ) -> CodexSchemaModel {
        CodexSchemaModel(
            defaultReasoningEffort: .init(.string("medium")),
            description: "\(id) description",
            displayName: id,
            hidden: false,
            id: id,
            isDefault: isDefault,
            model: id,
            supportedReasoningEfforts: [
                .init(description: "Low", reasoningEffort: .init(.string("low"))),
                .init(description: "Medium", reasoningEffort: .init(.string("medium"))),
                .init(description: "High", reasoningEffort: .init(.string("high"))),
            ]
        )
    }
}

private actor StartupOrderingTransport: CodexFrameTransport {
    private let homePath: String
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private(set) var requestMethods: [String] = []
    private var inventoryStarted = false
    private var inventoryStartWaiters: [CheckedContinuation<Bool, Never>] = []

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
        if method != "initialize" {
            requestMethods.append(method)
        }

        // Leave one integration inventory unresolved. `app/list`, plugin,
        // skill, and MCP inventories all run behind the same detached startup
        // boundary, so none of them may delay the sidebar's thread index.
        if method == "mcpServerStatus/list" {
            inventoryStarted = true
            let waiters = inventoryStartWaiters
            inventoryStartWaiters.removeAll(keepingCapacity: true)
            waiters.forEach { $0.resume(returning: true) }
            return
        }

        let result: CodexJSONValue
        switch method {
        case "initialize":
            result = .dictionary([
                "codexHome": .string(homePath),
                "platformFamily": .string("unix"),
                "platformOs": .string("macos"),
                "userAgent": .string("codex/test"),
            ])
        case "thread/list":
            result = .dictionary([
                "data": .array([.dictionary([
                    "cliVersion": .string("0.147.0"),
                    "createdAt": .int(1),
                    "cwd": .string("/tmp/project"),
                    "ephemeral": .bool(false),
                    "id": .string("thread-1"),
                    "modelProvider": .string("openai"),
                    "name": .string("Fast project"),
                    "preview": .string("Fast project"),
                    "sessionId": .string("session-1"),
                    "source": .string("cli"),
                    "status": .dictionary(["type": .string("idle")]),
                    "turns": .array([]),
                    "updatedAt": .int(1),
                ])]),
                "nextCursor": .null,
            ])
        case "mcpServerStatus/list":
            result = .dictionary([
                "data": .array([]),
                "nextCursor": .null,
            ])
        default:
            result = .dictionary([:])
        }
        continuation?.yield(try CodexJSONRPCCodec.encodeResult(id: id, result: result))
    }

    func close() async {
        continuation?.finish()
        continuation = nil
    }

    func waitUntilInventoryStarts() async -> Bool {
        if inventoryStarted { return true }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                inventoryStartWaiters.append(continuation)
            }
        } onCancel: {
            Task { await self.cancelInventoryStartWaiters() }
        }
    }

    private func cancelInventoryStartWaiters() {
        let waiters = inventoryStartWaiters
        inventoryStartWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume(returning: false) }
    }
}

private actor ConfigurationRefreshRaceTransport: CodexFrameTransport {
    private let homePath: String
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var pendingSkillsRequestID: CodexJSONRPCID?
    private var skillsRequestWaiters: [CheckedContinuation<Void, Never>] = []

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
        if method == "skills/list" {
            pendingSkillsRequestID = id
            let waiters = skillsRequestWaiters
            skillsRequestWaiters.removeAll(keepingCapacity: false)
            waiters.forEach { $0.resume() }
            return
        }
        let result: CodexJSONValue = method == "initialize"
            ? .dictionary([
                "codexHome": .string(homePath),
                "platformFamily": .string("unix"),
                "platformOs": .string("macos"),
                "userAgent": .string("codex/test"),
            ])
            : .dictionary([:])
        continuation?.yield(try CodexJSONRPCCodec.encodeResult(id: id, result: result))
    }

    func close() async {
        continuation?.finish()
        continuation = nil
    }

    func waitUntilSkillsRequestStarts() async {
        guard pendingSkillsRequestID == nil else { return }
        await withCheckedContinuation { skillsRequestWaiters.append($0) }
    }

    func finishSkillsRequest() throws {
        guard let id = pendingSkillsRequestID else { return }
        pendingSkillsRequestID = nil
        continuation?.yield(try CodexJSONRPCCodec.encodeResult(
            id: id,
            result: .dictionary(["data": .array([])])
        ))
    }
}
