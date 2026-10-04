import Foundation
import XCTest
@testable import CodexCoreUI

final class CodexImageResourceLoaderTests: XCTestCase {
    private func loader() -> CodexImageResourceLoader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageResourceTestProtocol.self]
        return CodexImageResourceLoader(configuration: configuration)
    }

    func testChunkedResponseAtBudgetIsPreserved() async throws {
        let data = try await loader().data(from: URL(string: "https://image.test/ok")!, maximumBytes: 8)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "abcdefgh")
    }

    func testRejectsOversizedDeclaredAndChunkedResponses() async throws {
        for path in ["declared", "ok"] {
            do {
                _ = try await loader().data(from: URL(string: "https://image.test/\(path)")!, maximumBytes: 7)
                XCTFail("Oversized response should fail")
            } catch let error as CodexImageResourceLoader.Failure {
                XCTAssertEqual(error, .byteLimitExceeded)
            }
        }
    }

    func testRejectsHTTPErrorBeforeDecodingImageBody() async throws {
        do {
            _ = try await loader().data(from: URL(string: "https://image.test/error")!, maximumBytes: 8)
            XCTFail("An HTTP error must not become an image")
        } catch let error as CodexImageResourceLoader.Failure { XCTAssertEqual(error, .httpStatus(503)) }
    }

    func testConcurrentResponsesKeepBodiesAndBudgetsIsolated() async throws {
        let loader = loader()
        let results = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<20 {
                group.addTask {
                    do {
                        let data = try await loader.data(
                            from: URL(string: "https://image.test/ok?request=\(index)")!,
                            maximumBytes: index.isMultiple(of: 2) ? 8 : 3
                        )
                        return index.isMultiple(of: 2) && data == Data("abcdefgh".utf8)
                    } catch let error as CodexImageResourceLoader.Failure {
                        return !index.isMultiple(of: 2) && error == .byteLimitExceeded
                    } catch { return false }
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(results.count, 20)
        XCTAssertTrue(results.allSatisfy { $0 })
    }

    func testCancellationStopsStalledDownload() async throws {
        let loader = loader()
        let started = ContinuousClock.now
        let task = Task { try await loader.data(from: URL(string: "https://image.test/stall")!, maximumBytes: 8) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled request must fail")
        } catch is CancellationError {}
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
    }
}

private final class ImageResourceTestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "image.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/stall" { return }
        let response = HTTPURLResponse(url: url, statusCode: url.path == "/error" ? 503 : 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: url.path == "/declared" ? ["Content-Length": "8"] : [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("abcd".utf8))
        client?.urlProtocol(self, didLoad: Data("efgh".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
