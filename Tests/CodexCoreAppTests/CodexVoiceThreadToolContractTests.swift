import CodexCore
import XCTest

@testable import CodexCoreApp

@MainActor
final class CodexVoiceThreadToolContractTests: XCTestCase {
    func testVoiceBridgePublishesLifecycleAndCommunicationTools() throws {
        let names = CodexCoreAppModel.voiceTaskToolSpecs.compactMap { spec -> String? in
            guard case .dictionary(let object) = spec.rawValue,
                case .string(let name)? = object["name"]
            else { return nil }
            return name
        }

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
}
