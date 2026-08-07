import Foundation
import XCTest
@testable import CodexCore

final class CodexDeepLinkRouterTests: XCTestCase {
    private let router = CodexDeepLinkRouter()

    func testThreadRouteProducesPendingThreadRequest() throws {
        let request = try router.request(for: XCTUnwrap(URL(string: "codex://thread/thread-123")))

        XCTAssertEqual(request, .thread(id: "thread-123"))
        XCTAssertEqual(request.threadID, "thread-123")
        XCTAssertNil(request.projectPath)
    }

    func testProjectRouteDecodesWorkspacePath() throws {
        let url = try XCTUnwrap(URL(string: "codex://project/%2FUsers%2Fme%2FCodexCore"))

        let request = try router.request(for: url)

        XCTAssertEqual(request, .project(path: "/Users/me/CodexCore"))
        XCTAssertEqual(request.projectPath, "/Users/me/CodexCore")
        XCTAssertNil(request.threadID)
    }

    func testUnsupportedRouteIsRejectedExplicitly() throws {
        let url = try XCTUnwrap(URL(string: "codex://settings/preferences"))

        XCTAssertThrowsError(try router.request(for: url)) { error in
            XCTAssertEqual(error as? CodexDeepLinkRouter.Error, .unsupportedRoute("settings"))
        }
    }

    func testUnsupportedSchemeIsRejected() throws {
        let url = try XCTUnwrap(URL(string: "https://thread/thread-123"))

        XCTAssertThrowsError(try router.route(url)) { error in
            XCTAssertEqual(error as? CodexDeepLinkRouter.Error, .unsupportedScheme("https"))
        }
    }

    func testLaunchAndNewChatRoutesAreSupported() throws {
        let launch = try router.request(for: XCTUnwrap(URL(string: "codex://launch")))
        XCTAssertEqual(launch, .launch)

        let newChat = try router.request(for: XCTUnwrap(URL(string: "codex://new?prompt=hello%20world")))
        XCTAssertEqual(newChat, .newChat(path: nil, prompt: "hello world"))

        let thread = try router.request(for: XCTUnwrap(URL(string: "codex://threads/thread-123")))
        XCTAssertEqual(thread, .thread(id: "thread-123"))
    }

    func testUnsupportedNewRouteQueryIsRejected() throws {
        let url = try XCTUnwrap(URL(string: "codex://new?command=rm%20-rf"))
        XCTAssertThrowsError(try router.request(for: url))
        XCTAssertNil(try? router.request(for: XCTUnwrap(URL(string: "codex-dev://launch"))))
        XCTAssertNil(try? router.request(for: XCTUnwrap(URL(string: "https://chatgpt.com/share/abc"))))
    }

    func testMalformedAndExtraPathComponentsAreRejected() throws {
        let missingID = try XCTUnwrap(URL(string: "codex://thread"))
        let extraComponent = try XCTUnwrap(URL(string: "codex://thread/thread-123/turn-1"))

        XCTAssertThrowsError(try router.request(for: missingID)) { error in
            XCTAssertEqual(error as? CodexDeepLinkRouter.Error, .missingIdentifier("thread"))
        }
        XCTAssertThrowsError(try router.request(for: extraComponent)) { error in
            XCTAssertEqual(error as? CodexDeepLinkRouter.Error, .unsupportedRoute(extraComponent.absoluteString))
        }
    }

    func testFinderFilesFoldersAndSkillsBecomeRequests() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-open-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("notes.txt")
        let skill = directory.appendingPathComponent("review.skill")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: file)
        try Data("skill".utf8).write(to: skill)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(router.request(forFileURL: directory), .folder(path: directory.standardizedFileURL.path))
        XCTAssertEqual(router.request(forFileURL: file), .file(path: file.standardizedFileURL.path))
        XCTAssertEqual(router.request(forFileURL: skill), .skill(path: skill.standardizedFileURL.path))
        XCTAssertNil(router.request(forFileURL: directory.appendingPathComponent("missing")))
    }

    func testQueuePreservesOrderAndDrains() {
        var queue = CodexPendingOpenRequestQueue()
        queue.append(.launch)
        queue.append(.thread(id: "thread-1"))

        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.drain(), [.launch, .thread(id: "thread-1")])
        XCTAssertTrue(queue.isEmpty)
    }
}
