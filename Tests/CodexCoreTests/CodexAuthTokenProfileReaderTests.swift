import Foundation
import XCTest
@testable import CodexCore

final class CodexAuthTokenProfileReaderTests: XCTestCase {
    func testDisplayNameReadsTopLevelNameFromIDToken() throws {
        let token = try jwt(payload: [
            "name": "Pranjal Paliwal",
            "email": "paliwal.pranjal83@gmail.com"
        ])
        let authJSON = """
        {"tokens":{"id_token":"\(token)"}}
        """

        XCTAssertEqual(
            CodexAuthTokenProfileReader.displayName(authJSONData: Data(authJSON.utf8)),
            "Pranjal Paliwal"
        )
    }

    func testDisplayNameFallsBackToProfileName() throws {
        let token = try jwt(payload: [
            "name": "   ",
            "https://api.openai.com/profile": ["name": "Profile Name"]
        ])
        let authJSON = """
        {"tokens":{"id_token":"\(token)"}}
        """

        XCTAssertEqual(
            CodexAuthTokenProfileReader.displayName(authJSONData: Data(authJSON.utf8)),
            "Profile Name"
        )
    }

    func testAsyncDisplayNameReadsAuthFileOffCaller() async throws {
        let token = try jwt(payload: ["name": "Async Profile"])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let json = "{\"tokens\":{\"id_token\":\"\(token)\"}}"
        try Data(json.utf8).write(to: url)

        let displayName = await CodexAuthTokenProfileReader.displayNameAsync(
            authFileURL: url
        )

        XCTAssertEqual(displayName, "Async Profile")
    }

    private func jwt(payload: [String: Any]) throws -> String {
        let header = try base64URLString(["alg": "none", "typ": "JWT"])
        let payload = try base64URLString(payload)
        return "\(header).\(payload).signature"
    }

    private func base64URLString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
