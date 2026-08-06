import CodexCore
import XCTest

@testable import CodexCoreApp

@MainActor
final class CodexVoiceThreadToolContractTests: XCTestCase {
    func testNormalThreadsPublishThreadToolsWithoutVoiceLifecycleTool() throws {
        let tools = CodexCoreAppModel.threadTaskToolSpecs.compactMap(toolMetadata)
        let names = Set(tools.map(\.name))

        XCTAssertTrue(names.contains("create_thread"))
        XCTAssertTrue(names.contains("list_threads"))
        XCTAssertTrue(names.contains("send_message_to_thread"))
        XCTAssertFalse(names.contains("end_realtime_voice_call"))
        XCTAssertTrue(tools.allSatisfy { $0.namespace == "codex_app" })
    }

    func testVoiceBridgePublishesLifecycleAndCommunicationTools() throws {
        let tools = CodexCoreAppModel.voiceTaskToolSpecs.compactMap { spec -> (String, String?)? in
            guard case .dictionary(let object) = spec.rawValue,
                case .string(let name)? = object["name"]
            else { return nil }
            let namespace: String? = if case .string(let value)? = object["namespace"] {
                value
            } else {
                nil
            }
            return (name, namespace)
        }
        let names = tools.map(\.0)

        XCTAssertTrue(
            Set([
                "fork_thread",
                "get_thread_status",
                "wait_threads",
                "interrupt_thread",
                "set_thread_archived",
                "send_message_to_thread",
            ]).isSubset(of: Set(names)))
        XCTAssertEqual(names.count, Set(names).count)
        XCTAssertTrue(tools.allSatisfy { $0.1 == "codex_app" })
        XCTAssertTrue(names.contains("end_realtime_voice_call"))
    }

    func testNormalThreadsUseExplicitRequestMultiAgentMode() throws {
        let app = CodexCoreAppModel()
        let start = app.threadStartParameters()

        XCTAssertEqual(
            start.multiAgentMode?.rawValue,
            .string("explicitRequestOnly")
        )

        let turn = app.turnStartParameters(
            threadID: ThreadID("thread-1"),
            input: [.text("delegate this")],
            clientUserMessageID: "message-1"
        )
        XCTAssertEqual(
            turn.multiAgentMode?.rawValue,
            .string("explicitRequestOnly")
        )
    }

    func testWaitContractIsBoundedAndHostAwareResultDeliveryIsDocumented() throws {
        let spec = try XCTUnwrap(
            CodexCoreAppModel.voiceTaskToolSpecs.first { spec in
                guard case .dictionary(let object) = spec.rawValue,
                    case .string(let name)? = object["name"]
                else { return false }
                return name == "wait_threads"
            })
        guard case .dictionary(let object) = spec.rawValue,
            case .dictionary(let input)? = object["inputSchema"],
            case .dictionary(let properties)? = input["properties"],
            case .dictionary(let ids)? = properties["threadIds"],
            case .int(let maxItems)? = ids["maxItems"],
            case .dictionary(let timeout)? = properties["timeoutSeconds"],
            case .int(let maximum)? = timeout["maximum"]
        else { return XCTFail("Malformed wait_threads schema") }
        XCTAssertEqual(maxItems, 8)
        XCTAssertEqual(maximum, 120)
    }

    private struct ToolMetadata {
        let name: String
        let namespace: String?
    }

    private func toolMetadata(
        _ spec: CodexSchemaDynamicToolSpec
    ) -> ToolMetadata? {
        guard case .dictionary(let object) = spec.rawValue,
              case .string(let name)? = object["name"]
        else { return nil }
        let namespace: String? = if case .string(let value)? = object["namespace"] {
            value
        } else {
            nil
        }
        return ToolMetadata(name: name, namespace: namespace)
    }
}
