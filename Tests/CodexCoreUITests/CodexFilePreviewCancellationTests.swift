import XCTest

@testable import CodexCoreUI

@MainActor
final class CodexFilePreviewCancellationTests: XCTestCase {
    func testSwitchingPreviewsCancelsObsoleteWorkAndDropsItsResult() async throws {
        let first = URL(fileURLWithPath: "/tmp/first.swift")
        let second = URL(fileURLWithPath: "/tmp/second.swift")
        let probe = PreviewLoadProbe()
        let model = CodexFilePreviewModel(loader: { file in
            await probe.started(file.fileURL)
            if file.fileURL == first {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch is CancellationError {
                    await probe.cancelled(file.fileURL)
                    return .text("stale", [])
                }
            }
            await probe.finished(file.fileURL)
            return .text(file.fileURL.lastPathComponent, [])
        })

        model.update(url: first)
        let started = await probe.waitForStart(first)
        XCTAssertTrue(started)
        model.update(url: second)

        let cancelled = await probe.waitForCancellation(first)
        XCTAssertTrue(cancelled)
        let finished = await probe.waitForFinish(second)
        XCTAssertTrue(finished)
        try await Task.sleep(for: .milliseconds(10))

        guard case let .text(text, _) = model.state else {
            return XCTFail("the current preview should publish the fresh result")
        }
        XCTAssertEqual(text, "second.swift")
    }

    func testUnmountCancelsOwnedPreviewLoad() async {
        let file = URL(fileURLWithPath: "/tmp/unmounted.swift")
        let probe = PreviewLoadProbe()
        var model: CodexFilePreviewModel? = CodexFilePreviewModel(loader: { file in
            await probe.started(file.fileURL)
            do {
                try await Task.sleep(for: .seconds(1))
            } catch is CancellationError {
                await probe.cancelled(file.fileURL)
            }
            return .text("obsolete", [])
        })

        model?.update(url: file)
        let started = await probe.waitForStart(file)
        XCTAssertTrue(started)
        model = nil

        let cancelled = await probe.waitForCancellation(file)
        XCTAssertTrue(cancelled)
    }
}

private actor PreviewLoadProbe {
    private var startedURLs: Set<URL> = []
    private var cancelledURLs: Set<URL> = []
    private var finishedURLs: Set<URL> = []

    func started(_ url: URL) { startedURLs.insert(url) }
    func cancelled(_ url: URL) { cancelledURLs.insert(url) }
    func finished(_ url: URL) { finishedURLs.insert(url) }

    func waitForStart(_ url: URL) async -> Bool {
        await wait { startedURLs.contains(url) }
    }

    func waitForCancellation(_ url: URL) async -> Bool {
        await wait { cancelledURLs.contains(url) }
    }

    func waitForFinish(_ url: URL) async -> Bool {
        await wait { finishedURLs.contains(url) }
    }

    private func wait(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }
}
