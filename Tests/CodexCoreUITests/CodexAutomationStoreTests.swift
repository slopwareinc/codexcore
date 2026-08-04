import XCTest
@testable import CodexCoreUI

final class CodexAutomationStoreTests: XCTestCase {
    func testPausedHeartbeatFileRoundTripsWithoutResuming() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let automationDirectory = directory.appendingPathComponent("oss-crypto-role-scout", isDirectory: true)
        try FileManager.default.createDirectory(at: automationDirectory, withIntermediateDirectories: true)
        let contents = #"""
        version = 1
        id = "oss-crypto-role-scout"
        kind = "heartbeat"
        name = "OSS crypto role scout"
        prompt = "Find roles with = signs, \n escapes, and \"quotes\"."
        status = "PAUSED"
        rrule = "FREQ=HOURLY;INTERVAL=1"
        target_thread_id = "019eec0e-1b6b-7a01-9aeb-c19c60128504"
        created_at = 1782079587802
        updated_at = 1782143863785
        """#
        try contents.write(
            to: automationDirectory.appendingPathComponent("automation.toml"),
            atomically: true,
            encoding: .utf8
        )

        let store = CodexAutomationFileStore(directoryURL: directory)
        let loaded = await store.load()
        let automation = try XCTUnwrap(loaded.automations.first)

        XCTAssertTrue(loaded.errors.isEmpty)
        XCTAssertEqual(automation.status, .disabled)
        XCTAssertEqual(automation.prompt, "Find roles with = signs, \n escapes, and \"quotes\".")
        XCTAssertEqual(automation.createdAt, Date(timeIntervalSince1970: 1_782_079_587.802))
        XCTAssertEqual(automation.schedule.rrule, "FREQ=DAILY;BYHOUR=9;BYMINUTE=0")

        try store.save(automation)
        let saved = try String(
            contentsOf: automationDirectory.appendingPathComponent("automation.toml"),
            encoding: .utf8
        )
        XCTAssertTrue(saved.contains("kind = \"heartbeat\""))
        XCTAssertTrue(saved.contains("status = \"PAUSED\""))
        XCTAssertTrue(saved.contains("rrule = \"FREQ=HOURLY;INTERVAL=1\""))
        XCTAssertTrue(saved.contains("created_at = 1782079587802"))
        XCTAssertTrue(saved.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("updated_at = ") })
        XCTAssertFalse(saved.contains("kind = \"schedule\""))
    }

    func testMultilineBasicStringAndEqualsSignsAreParsed() throws {
        let contents = #"""
        version = 1
        id = "multiline"
        kind = "heartbeat"
        name = "Multiline"
        prompt = """
        First line
        A markdown heading = `value`
        A quoted "value" stays quoted.
        """
        status = "ACTIVE"
        rrule = "FREQ=HOURLY;INTERVAL=1"
        created_at = 1000
        updated_at = 2000
        """#

        let automation = try XCTUnwrap(CodexAutomationFileStore.decode(contents))

        XCTAssertEqual(automation.id, "multiline")
        XCTAssertEqual(
            automation.prompt,
            "First line\nA markdown heading = `value`\nA quoted \"value\" stays quoted.\n"
        )
        XCTAssertEqual(automation.status, .enabled)
    }

    func testSavePreservesUnknownTomlKeys() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let automationDirectory = directory.appendingPathComponent("with-unknown", isDirectory: true)
        try FileManager.default.createDirectory(at: automationDirectory, withIntermediateDirectories: true)
        let contents = #"""
        version = 1
        id = "with-unknown"
        kind = "heartbeat"
        name = "Unknown fields"
        prompt = "Keep this prompt"
        status = "ACTIVE"
        rrule = "FREQ=DAILY;BYHOUR=9;BYMINUTE=0"
        created_at = 1000
        updated_at = 2000
        owner = "codex"
        metadata = { source = "fixture", revision = 3 }
        """#
        let decoded = try XCTUnwrap(CodexAutomationFileStore.decode(contents))
        let directRoundTrip = CodexAutomationFileStore.encode(decoded)
        XCTAssertTrue(directRoundTrip.contains("owner = \"codex\""))
        XCTAssertTrue(directRoundTrip.contains("metadata = { revision = 3, source = \"fixture\" }"))
        try contents.write(
            to: automationDirectory.appendingPathComponent("automation.toml"),
            atomically: true,
            encoding: .utf8
        )

        let store = CodexAutomationFileStore(directoryURL: directory)
        let loaded = await store.load()
        var automation = try XCTUnwrap(loaded.automations.first)
        automation.name = "Edited name"
        try store.save(automation)

        let saved = try String(
            contentsOf: automationDirectory.appendingPathComponent("automation.toml"),
            encoding: .utf8
        )
        XCTAssertTrue(saved.contains("owner = \"codex\""))
        XCTAssertTrue(saved.contains("metadata = { revision = 3, source = \"fixture\" }"))
        XCTAssertTrue(saved.contains("name = \"Edited name\""))
    }

    func testAsyncLoadReturnsReadableAutomationsAndPerFileErrors() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeAutomation(
            id: "valid",
            to: directory,
            contents: #"""
            version = 1
            id = "valid"
            kind = "heartbeat"
            name = "Valid"
            prompt = "Read me"
            status = "ACTIVE"
            rrule = "FREQ=DAILY;BYHOUR=9;BYMINUTE=0"
            created_at = 1000
            updated_at = 1000
            """#
        )
        try writeAutomation(
            id: "invalid",
            to: directory,
            contents: "id = \"invalid\"\nname = \"Missing prompt\"\nprompt = \"unterminated\n"
        )

        let unreadableDirectory = directory.appendingPathComponent("unreadable", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadableDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: unreadableDirectory.appendingPathComponent("automation.toml", isDirectory: true),
            withIntermediateDirectories: true
        )

        let result = await CodexAutomationFileStore(directoryURL: directory).load()

        XCTAssertEqual(result.automations.map(\.id), ["valid"])
        XCTAssertEqual(result.errors.count, 2)
        XCTAssertEqual(result.errors.filter { $0.kind == .parse }.count, 1)
        XCTAssertEqual(result.errors.filter { $0.kind == .fileRead }.count, 1)
        XCTAssertTrue(result.errors.allSatisfy { $0.url.lastPathComponent == "automation.toml" })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-automation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeAutomation(id: String, to directory: URL, contents: String) throws {
        let automationDirectory = directory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: automationDirectory, withIntermediateDirectories: true)
        try contents.write(
            to: automationDirectory.appendingPathComponent("automation.toml"),
            atomically: true,
            encoding: .utf8
        )
    }
}
