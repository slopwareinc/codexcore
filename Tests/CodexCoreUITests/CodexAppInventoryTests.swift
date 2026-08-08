import CodexCore
@testable import CodexCoreUI
import Foundation
import Testing

@Suite("App inventory session")
struct CodexAppInventoryTests {
    @Test("Catalog optionals and installed runtime state remain distinct")
    func appJoinPreservesTruthfulState() {
        let catalog = [
            CodexSchemaAppInfo(
                description: "Read repositories",
                id: "github",
                isAccessible: nil,
                isEnabled: false,
                name: "GitHub"
            ),
            CodexSchemaAppInfo(id: "slack", isAccessible: true, name: "Slack")
        ]
        let installed = [
            CodexSchemaInstalledApp(callable: true, enabled: true, id: "github", runtimeName: "github_runtime")
        ]

        var session = CodexIntegrationCatalogSession()
        let activity = session.applyAppResponses(catalog: catalog, installed: installed)

        #expect(activity == .init(title: "Loaded apps", detail: "2 available"))
        #expect(session.apps[0].isAccessible == nil)
        #expect(session.apps[0].isEnabled == false)
        #expect(session.apps[0].isInstalled)
        #expect(session.apps[0].runtimeEnabled == true)
        #expect(session.apps[0].runtimeCallable == true)
        #expect(session.apps[1].isEnabled == nil)
        #expect(!session.apps[1].isInstalled)
        #expect(session.apps[1].runtimeEnabled == nil)
        #expect(session.apps[1].runtimeCallable == nil)
    }

    @Test("App refresh paginates the catalog and joins installed apps by id")
    func refreshPaginatesAndJoinsByID() async throws {
        let homeURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("codexcore-app-inventory-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let transport = AppInventoryTransport(homePath: homeURL.path)
        let codex = try await Codex(
            transport: transport,
            config: .init(codexHome: CodexHome(path: homeURL.path))
        )
        defer { Task { await codex.close() } }
        var session = CodexIntegrationCatalogSession()

        let activity = await session.refreshApps(
            using: codex,
            threadID: "thread-1",
            errorMessage: { String(describing: $0) }
        )

        #expect(activity == .init(title: "Loaded apps", detail: "2 available"))
        #expect(session.apps.map(\.id) == ["github", "slack"])
        #expect(session.apps.map(\.runtimeEnabled) == [true, nil])
        #expect(await transport.appListCursors == [nil, "page-2"])
        #expect(await transport.installedRequestCount == 1)
    }
}

private actor AppInventoryTransport: CodexFrameTransport {
    private let homePath: String
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private(set) var appListCursors: [String?] = []
    private(set) var installedRequestCount = 0

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
              let rawID = object["id"] else { return }
        let id = try CodexJSONRPCID(jsonValue: rawID)
        let params = CodexJSONCoercion.dictionary(from: object["params"]) ?? [:]
        let result: CodexJSONValue
        switch method {
        case "initialize":
            result = .dictionary([
                "codexHome": .string(homePath),
                "platformFamily": .string("unix"),
                "platformOs": .string("macos"),
                "userAgent": .string("codex/test")
            ])
        case "app/list":
            let cursor = CodexJSONCoercion.flatString(from: params["cursor"])
            appListCursors.append(cursor)
            if cursor == nil {
                result = .dictionary([
                    "data": .array([.dictionary(["id": .string("github"), "name": .string("GitHub"), "isEnabled": .bool(false)])]),
                    "nextCursor": .string("page-2")
                ])
            } else {
                result = .dictionary([
                    "data": .array([.dictionary(["id": .string("slack"), "name": .string("Slack")])]),
                    "nextCursor": .null
                ])
            }
        case "app/installed":
            installedRequestCount += 1
            result = .dictionary([
                "apps": .array([.dictionary([
                    "id": .string("github"),
                    "enabled": .bool(true),
                    "callable": .bool(false),
                    "runtimeName": .string("github_runtime")
                ])])
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
}
