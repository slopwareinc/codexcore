import XCTest
@testable import CodexCore

final class AppServerProtocolMethodTests: XCTestCase {
    func testGeneratedMethodCountsMatchCurrentAppServerSchema() {
        XCTAssertEqual(CodexAppServerClientMethod.allCases.count, CodexAppServerProtocolInventory.clientMethodCount)
        XCTAssertEqual(CodexAppServerNotificationMethod.allCases.count, CodexAppServerProtocolInventory.notificationMethodCount)
        XCTAssertEqual(CodexAppServerServerRequestMethod.allCases.count, CodexAppServerProtocolInventory.serverRequestMethodCount)

        XCTAssertEqual(CodexAppServerClientMethod.allCases.count, 108)
        XCTAssertEqual(CodexAppServerNotificationMethod.allCases.count, 64)
        XCTAssertEqual(CodexAppServerServerRequestMethod.allCases.count, 10)
    }

    func testGeneratedMethodsAreUnique() {
        XCTAssertEqual(Set(CodexAppServerClientMethod.allCases.map(\.rawValue)).count, 108)
        XCTAssertEqual(Set(CodexAppServerNotificationMethod.allCases.map(\.rawValue)).count, 64)
        XCTAssertEqual(Set(CodexAppServerServerRequestMethod.allCases.map(\.rawValue)).count, 10)
    }

    func testCorePythonSDKMethodsArePresent() {
        XCTAssertTrue(CodexAppServerClientMethod.allCases.contains(.initialize))
        XCTAssertTrue(CodexAppServerClientMethod.allCases.contains(.accountLoginStart))
        XCTAssertTrue(CodexAppServerClientMethod.allCases.contains(.threadStart))
        XCTAssertTrue(CodexAppServerClientMethod.allCases.contains(.threadResume))
        XCTAssertTrue(CodexAppServerClientMethod.allCases.contains(.threadFork))
        XCTAssertTrue(CodexAppServerClientMethod.allCases.contains(.threadArchive))
        XCTAssertTrue(CodexAppServerClientMethod.allCases.contains(.turnStart))
        XCTAssertTrue(CodexAppServerClientMethod.allCases.contains(.turnInterrupt))
        XCTAssertTrue(CodexAppServerClientMethod.allCases.contains(.turnSteer))
        XCTAssertTrue(CodexAppServerClientMethod.allCases.contains(.modelList))
        XCTAssertTrue(CodexAppServerClientMethod.allCases.contains(.commandExec))
    }

    func testCoreNotificationAndServerRequestMethodsArePresent() {
        XCTAssertTrue(CodexAppServerNotificationMethod.allCases.contains(.turnStarted))
        XCTAssertTrue(CodexAppServerNotificationMethod.allCases.contains(.turnCompleted))
        XCTAssertTrue(CodexAppServerNotificationMethod.allCases.contains(.itemCompleted))
        XCTAssertTrue(CodexAppServerNotificationMethod.allCases.contains(.accountLoginCompleted))
        XCTAssertTrue(CodexAppServerNotificationMethod.allCases.contains(.commandExecOutputDelta))

        XCTAssertTrue(CodexAppServerServerRequestMethod.allCases.contains(.itemCommandExecutionRequestApproval))
        XCTAssertTrue(CodexAppServerServerRequestMethod.allCases.contains(.itemToolRequestUserInput))
        XCTAssertTrue(CodexAppServerServerRequestMethod.allCases.contains(.mcpServerElicitationRequest))
        XCTAssertTrue(CodexAppServerServerRequestMethod.allCases.contains(.accountChatgptAuthTokensRefresh))
    }
}
