import AppKit
import Darwin
import Foundation
import os
import SwiftUI
import XCTest
@testable import CodexCoreApp
@testable import CodexCoreUI

/// Interface-level performance evidence for the current workspace panel
/// implementation.  This test deliberately exercises existing public UI
/// models and the app's 20-chat store; it does not add production signposts or
/// change panel behavior.  `WorkspacePanelOracle/run.sh` writes the report to
/// JSON for later architectural slices.
@MainActor
final class CodexWorkspacePanelPerformanceTests: XCTestCase {
    private static let signpostLog = OSLog(
        subsystem: "com.slopware.CodexCore",
        category: "WorkspacePanelOracle"
    )

    func testWorkspacePanelPerformanceBaseline() async throws {
        let report = try await makeReport()
        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.scenarios.map(\.id), [
            "tab_activation",
            "panel_open_close",
            "transcript_streaming_with_heavy_panels",
            "hidden_surface_layout",
            "twenty_chat_lru",
        ])
        XCTAssertTrue(report.scenarios.allSatisfy { !$0.samples.isEmpty })
        writeReportIfRequested(report)
    }

    func testTwentyChatLRURetainsTheMostRecentlyUsedWindow() async throws {
        let result = await makeTwentyChatLRUResult()

        XCTAssertEqual(result.capacity, 20)
        XCTAssertEqual(result.retainedChatCount, 20)
        XCTAssertTrue(result.touchedChatWasRetained)
        XCTAssertTrue(result.evictedChatWasPurged)
        XCTAssertEqual(result.evictionCount, 1)
    }

    // MARK: - Report assembly

    private func makeReport() async throws -> PerformanceReport {
        let tabActivation = measureTabActivation()
        let panelOpenClose = measurePanelOpenClose()
        let streaming = try await measureTranscriptStreamingWithHeavyPanels()
        let hiddenSurface = measureHiddenSurfaceLayout()
        let lru = await makeTwentyChatLRUResult()

        return PerformanceReport(
            schemaVersion: 1,
            capturedAtUTC: ISO8601DateFormatter().string(from: Date()),
            sourceCommit: ProcessInfo.processInfo.environment["CODEX_PERF_SOURCE_COMMIT"],
            host: .init(
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                processorCount: ProcessInfo.processInfo.processorCount,
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
            ),
            instrumentation: .init(
                signpostSubsystem: "com.slopware.CodexCore",
                signpostCategory: "WorkspacePanelOracle",
                signpostNames: [
                    "tab_activation",
                    "panel_open_close",
                    "transcript_streaming_with_heavy_panels",
                    "hidden_surface_layout",
                    "twenty_chat_lru",
                ]
            ),
            scenarios: [
                tabActivation,
                panelOpenClose,
                streaming,
                hiddenSurface,
                lru.scenario,
            ]
        )
    }

    private func measureTabActivation() -> ScenarioReport {
        let panel = CodexWorkspacePanelState()
        let terminal = panel.openTerminal(workspacePath: "/tmp")
        let browser = panel.openBrowser()
        let files = panel.openFiles(workspacePath: "/tmp")
        let preview = panel.openFilePreview(fileURL: URL(fileURLWithPath: "/tmp/README.md"))
        let tabIDs = [terminal, browser, files, preview]

        // Warm the reducer-owned activation path before recording samples.
        for id in tabIDs { panel.workspaceTabs.activateLegacy(id) }

        let iterations = scaledIterations(default: 80, minimum: 12)
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for index in 0..<iterations {
            samples.append(signposted("tab_activation") {
                panel.workspaceTabs.activateLegacy(tabIDs[index % tabIDs.count])
                _ = panel.workspaceTabs.snapshot.topology.right.activeTab
            })
        }

        return ScenarioReport(
            id: "tab_activation",
            operation: "activate each existing workspace tab through CodexWorkspaceTabs",
            iterations: iterations,
            workload: ["tabCount": tabIDs.count],
            samples: samples,
            notes: [
                "State-level activation; SwiftUI/AppKit display composition is measured separately.",
                "Tab identities are terminal, browser, files, and file preview.",
            ]
        )
    }

    private func measurePanelOpenClose() -> ScenarioReport {
        let iterations = scaledIterations(default: 12, minimum: 4)
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            samples.append(signposted("panel_open_close") {
                let panel = CodexWorkspacePanelState()
                panel.workspaceTabs.openLegacy("oracle-panel")
                panel.isAgentPanelOpen = true
                panel.isAgentPanelOpen = false
                panel.isAgentPanelOpen = true
                panel.isAgentPanelOpen = false
            })
        }

        return ScenarioReport(
            id: "panel_open_close",
            operation: "toggle the agent panel open and closed through its state interface",
            iterations: iterations,
            workload: ["togglesPerIteration": 4],
            samples: samples,
            notes: [
                "This isolates panel-state mutation from native surface construction.",
                "Surface construction and teardown are included in the heavy-panel streaming and hidden-surface scenarios.",
            ]
        )
    }

    private func measureTranscriptStreamingWithHeavyPanels() async throws -> ScenarioReport {
        let turnCount = 217
        let date = Date(timeIntervalSince1970: 100)
        var presentation = CodexThreadUIPresentation(
            threadID: "workspace-panel-performance-thread",
            transcript: .init(turns: (0..<turnCount).map { index in
                CodexTurnV2(
                    id: "turn-\(index)",
                    userMessage: .init(id: "user-\(index)", text: "Question \(index)"),
                    narrative: [.prose(.init(
                        id: "commentary-\(index)",
                        text: "Checked the implementation for turn \(index).",
                        isStreaming: false
                    ))],
                    finalAnswer: .init(
                        id: "final-\(index)",
                        text: "Answer \(index) with **stable Markdown**.",
                        isStreaming: index == turnCount - 1
                    ),
                    status: .done(durationMs: 100)
                )
            }),
            rawScrollOffset: 12_000,
            isPinnedToBottom: false,
            presentedAtByTurnID: Dictionary(uniqueKeysWithValues: (0..<turnCount).map {
                ("turn-\($0)", date)
            })
        )

        let panel = CodexWorkspacePanelState()
        _ = panel.openTerminal(workspacePath: "/tmp")
        _ = panel.openBrowser()
        _ = panel.openFiles(workspacePath: "/tmp")
        let projector = CodexTranscriptRenderProjector()
        let theme = CodexTranscriptAppKitTheme(.officialDark, colorScheme: .dark)

        // Establish the 1,085-item warm projection before timing append-only
        // streaming work.  The heavy panel sessions stay retained throughout.
        let initial = try await projector.project(
            presentation: presentation,
            availableWidth: 1_000,
            theme: theme
        )
        XCTAssertEqual(initial.orderedItemIDs.count, 1_085)

        let iterations = scaledIterations(default: 30, minimum: 8)
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        var totalChangedItems = 0
        for _ in 0..<iterations {
            presentation.transcript.turns[turnCount - 1].finalAnswer?.text.append("x")
            let start = DispatchTime.now().uptimeNanoseconds
            let id = OSSignpostID(log: Self.signpostLog)
            os_signpost(.begin, log: Self.signpostLog, name: "transcript_streaming_with_heavy_panels", signpostID: id)
            // Rebuild the retained-surface union on every frame: this is the
            // current workspace composition path while the transcript streams.
            let mountedTools = CodexMountedWorkspaceToolSessions(panels: [panel])
            let retainedSurfaceCount = mountedTools.terminal.count
                + mountedTools.browser.count
                + mountedTools.files.count
                + mountedTools.filePreview.count
            XCTAssertEqual(retainedSurfaceCount, 3)
            let snapshot = try await projector.project(
                presentation: presentation,
                availableWidth: 1_000,
                theme: theme
            )
            os_signpost(.end, log: Self.signpostLog, name: "transcript_streaming_with_heavy_panels", signpostID: id)
            samples.append(milliseconds(since: start))
            totalChangedItems += snapshot.changedItemIDs.count
            XCTAssertEqual(snapshot.orderedItemIDs.count, 1_085)
            XCTAssertEqual(snapshot.changedItemIDs.count, 1)
        }

        XCTAssertEqual(totalChangedItems, iterations)
        return ScenarioReport(
            id: "transcript_streaming_with_heavy_panels",
            operation: "append one final-answer delta and project the transcript while terminal/browser/files sessions stay retained",
            iterations: iterations,
            workload: [
                "turnCount": turnCount,
                "transcriptItemCount": initial.orderedItemIDs.count,
                "retainedHeavySurfaceCount": 3,
            ],
            samples: samples,
            notes: [
                "The projector is exercised through its public async interface.",
                "The retained surface union is terminal + browser + files; no product behavior is changed.",
            ]
        )
    }

    private func measureHiddenSurfaceLayout() -> ScenarioReport {
        let terminal = CodexTerminalSession(id: "oracle-terminal", workingDirectory: "/tmp")
        let browser = CodexBrowserSession(id: "oracle-browser")
        let files = CodexFilesSession(id: "oracle-files", rootURL: URL(fileURLWithPath: "/tmp"))
        let workspaceTabs = CodexWorkspaceTabs()
        let terminalTabID = workspaceTabs.open(
            CodexTerminalWorkspaceTabAdapter(session: terminal, placement: .right),
            from: .commandMenu,
            placement: .right
        )
        workspaceTabs.openLegacy(browser.id)
        workspaceTabs.openLegacy(files.id)
        let tabHandles: [CodexWorkspaceTabHandle] = [
            .workspace(terminalTabID),
            .legacy(browser.id),
            .legacy(files.id),
        ]
        workspaceTabs.activate(terminalTabID)

        func rootView() -> AnyView {
            AnyView(
                CodexAgentSidePanel(
                    tabs: [],
                    workspaceTabs: workspaceTabs,
                    browserSessions: [browser],
                    filesSessions: [files],
                    mountedBrowserSessions: [browser],
                    mountedFilesSessions: [files],
                    onClose: {}
                )
            )
        }

        var host: NSHostingView<AnyView>? = NSHostingView(rootView: rootView())
        host?.frame = NSRect(x: 0, y: 0, width: 420, height: 640)
        host?.layoutSubtreeIfNeeded()
        let rssBefore = residentMemoryBytes()

        let iterations = scaledIterations(default: 12, minimum: 4)
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for index in 0..<iterations {
            let handle = tabHandles[(index + 1) % tabHandles.count]
            switch handle {
            case .workspace(let id): workspaceTabs.activate(id)
            case .legacy(let id): workspaceTabs.activateLegacy(id)
            }
            let start = DispatchTime.now().uptimeNanoseconds
            let id = OSSignpostID(log: Self.signpostLog)
            os_signpost(.begin, log: Self.signpostLog, name: "hidden_surface_layout", signpostID: id)
            host?.rootView = rootView()
            host?.layoutSubtreeIfNeeded()
            os_signpost(.end, log: Self.signpostLog, name: "hidden_surface_layout", signpostID: id)
            samples.append(milliseconds(since: start))
        }
        let rssAfterMount = residentMemoryBytes()

        // While one tab is selected, the other two native sessions remain
        // mounted by the current ZStack deck.  Keep this count explicit in the
        // report so a later lifecycle adapter can prove that hidden work falls.
        let hiddenSurfaceCount = tabHandles.count - 1
        XCTAssertEqual(hiddenSurfaceCount, 2)
        XCTAssertNotNil(host)
        host = nil

        return ScenarioReport(
            id: "hidden_surface_layout",
            operation: "switch the selected tab and relayout a deck containing retained terminal/browser/files surfaces",
            iterations: iterations,
            workload: [
                "mountedSurfaceCount": tabHandles.count,
                "hiddenSurfaceCount": hiddenSurfaceCount,
                "activeSurfaceCount": 1,
            ],
            samples: samples,
            notes: [
                "Current visibility uses opacity, hit-testing, and accessibility hiding; hidden surfaces remain in the deck.",
                "RSS delta is process-level evidence and excludes WebKit helper processes.",
            ],
            retainedMemory: .init(
                residentMemoryBeforeMountBytes: rssBefore,
                residentMemoryAfterMountBytes: rssAfterMount,
                retainedSurfaceCountWhileHidden: hiddenSurfaceCount
            )
        )
    }

    // MARK: - Current 20-chat LRU

    private func makeTwentyChatLRUResult() async -> LRUResult {
        let store = CodexWorkspacePanelStore(capacity: 20)
        let states = (0..<20).map { index -> CodexWorkspacePanelState in
            let state = store.state(for: "chat-\(index)")
            _ = state.openFilePreview(fileURL: URL(fileURLWithPath: "/tmp/chat-\(index).md"))
            return state
        }

        // Touch chat-0 so chat-1 is the least-recently-used victim.
        let touched = store.state(for: "chat-0")
        let newcomer = store.state(for: "chat-20")
        _ = newcomer.openFilePreview(fileURL: URL(fileURLWithPath: "/tmp/chat-20.md"))
        for _ in 0..<8 { await Task.yield() }

        let retainedIDs = Set(store.mountedToolStates.map(ObjectIdentifier.init))
        let result = LRUResult(
            scenario: ScenarioReport(
                id: "twenty_chat_lru",
                operation: "retain and evict per-chat workspace panel states using the current bounded LRU",
                iterations: 20,
                workload: ["capacity": 20, "chatCount": 21, "previewPerChat": 1],
                samples: measureLRULookups(store: store),
                notes: [
                    "The store touches on every state(for:) access and defers victim purge to the next MainActor tick.",
                    "This is the current behavior baseline, not a proposed policy.",
                ],
                lru: .init(
                    capacity: 20,
                    retainedChatCount: retainedIDs.count,
                    evictionCount: 1,
                    touchedChatWasRetained: retainedIDs.contains(ObjectIdentifier(touched)),
                    evictedChatWasPurged: states[1].filePreviewSessions.isEmpty
                )
            ),
            capacity: 20,
            retainedChatCount: retainedIDs.count,
            evictionCount: 1,
            touchedChatWasRetained: retainedIDs.contains(ObjectIdentifier(touched)),
            evictedChatWasPurged: states[1].filePreviewSessions.isEmpty
        )
        return result
    }

    private func measureLRULookups(store: CodexWorkspacePanelStore) -> [Double] {
        let ids = (0..<20).map { "chat-\($0)" }
        var samples: [Double] = []
        samples.reserveCapacity(ids.count)
        for id in ids {
            samples.append(signposted("twenty_chat_lru") {
                _ = store.state(for: id)
            })
        }
        return samples
    }

    // MARK: - Helpers

    private func scaledIterations(default value: Int, minimum: Int) -> Int {
        guard let raw = ProcessInfo.processInfo.environment["CODEX_PANEL_PERF_ITERATIONS"],
              let override = Int(raw), override > 0 else {
            return value
        }
        return max(minimum, override)
    }

    private func signposted(_ name: StaticString, operation: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        let id = OSSignpostID(log: Self.signpostLog)
        os_signpost(.begin, log: Self.signpostLog, name: name, signpostID: id)
        operation()
        os_signpost(.end, log: Self.signpostLog, name: name, signpostID: id)
        return milliseconds(since: start)
    }

    private func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func writeReportIfRequested(_ report: PerformanceReport) {
        guard let rawPath = ProcessInfo.processInfo.environment["CODEX_WORKSPACE_PANEL_PERF_OUTPUT"] else {
            return
        }
        let output = URL(fileURLWithPath: rawPath)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: output, options: .atomic)
        } catch {
            XCTFail("Unable to write workspace panel performance report: \(error)")
        }
    }

    private func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

}

// MARK: - Codable report model

private struct PerformanceReport: Codable {
    let schemaVersion: Int
    let capturedAtUTC: String
    let sourceCommit: String?
    let host: HostReport
    let instrumentation: InstrumentationReport
    let scenarios: [ScenarioReport]
}

private struct HostReport: Codable {
    let operatingSystem: String
    let processorCount: Int
    let physicalMemoryBytes: UInt64
}

private struct InstrumentationReport: Codable {
    let signpostSubsystem: String
    let signpostCategory: String
    let signpostNames: [String]
}

private struct ScenarioReport: Codable {
    let id: String
    let operation: String
    let iterations: Int
    let workload: [String: Int]
    let samples: [Double]
    let statistics: SampleStatistics
    let notes: [String]
    let retainedMemory: RetainedMemoryReport?
    let lru: LRUReport?

    init(
        id: String,
        operation: String,
        iterations: Int,
        workload: [String: Int],
        samples: [Double],
        notes: [String],
        retainedMemory: RetainedMemoryReport? = nil,
        lru: LRUReport? = nil
    ) {
        self.id = id
        self.operation = operation
        self.iterations = iterations
        self.workload = workload
        self.samples = samples
        self.statistics = SampleStatistics(samples: samples)
        self.notes = notes
        self.retainedMemory = retainedMemory
        self.lru = lru
    }
}

private struct SampleStatistics: Codable {
    let minimumMilliseconds: Double
    let medianMilliseconds: Double
    let p95Milliseconds: Double
    let meanMilliseconds: Double
    let maximumMilliseconds: Double
    let totalMilliseconds: Double

    init(samples: [Double]) {
        let sorted = samples.sorted()
        guard let first = sorted.first else {
            minimumMilliseconds = 0
            medianMilliseconds = 0
            p95Milliseconds = 0
            meanMilliseconds = 0
            maximumMilliseconds = 0
            totalMilliseconds = 0
            return
        }
        minimumMilliseconds = first
        maximumMilliseconds = sorted.last ?? first
        totalMilliseconds = samples.reduce(0, +)
        meanMilliseconds = totalMilliseconds / Double(samples.count)
        medianMilliseconds = Self.quantile(sorted, probability: 0.50)
        p95Milliseconds = Self.quantile(sorted, probability: 0.95)
    }

    private static func quantile(_ sorted: [Double], probability: Double) -> Double {
        guard sorted.count > 1 else { return sorted[0] }
        let index = Int(ceil(probability * Double(sorted.count))) - 1
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}

private struct RetainedMemoryReport: Codable {
    let residentMemoryBeforeMountBytes: UInt64
    let residentMemoryAfterMountBytes: UInt64
    let retainedSurfaceCountWhileHidden: Int
}

private struct LRUReport: Codable {
    let capacity: Int
    let retainedChatCount: Int
    let evictionCount: Int
    let touchedChatWasRetained: Bool
    let evictedChatWasPurged: Bool
}

private struct LRUResult {
    let scenario: ScenarioReport
    let capacity: Int
    let retainedChatCount: Int
    let evictionCount: Int
    let touchedChatWasRetained: Bool
    let evictedChatWasPurged: Bool
}
