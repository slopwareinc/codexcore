@testable import CodexCoreUI
import Foundation
import Testing

@MainActor
struct CodexT3SidebarRowTests {
    @Test func projectMonogramMatchesUpstreamExamples() {
        let fixtures = [
            ("Nebula", "NA"), ("Silver Orchard", "SO"),
            ("Quiet Lantern Workshop", "QW"), ("m7forge", "M7"),
            ("M7 Forge", "M7"), ("X", "XX"), ("---", "PR"),
            ("Ｔ３ Ｃｏｄｅ", "T3"), ("文書", "文書"),
        ]
        for (name, expected) in fixtures {
            #expect(CodexT3ProjectIdentity(projectName: name).monogram == expected)
        }
        #expect(CodexT3ProjectIdentity(projectName: "Nebula").colorIndex == CodexT3ProjectIdentity(projectName: "  NEBULA  ").colorIndex)
    }

    @Test func relativeLabelsUseDaysBeyondOneWeekAndBoundMissingOrInvalidValues() {
        let now: TimeInterval = 1_000_000
        let fixtures: [(TimeInterval, String)] = [
            (-1, "now"), (0, "now"), (59, "now"), (60, "1m"),
            (3_599, "59m"), (3_600, "1h"), (86_399, "23h"),
            (86_400, "1d"), (604_800, "7d"), (864_000, "10d"),
        ]
        for (elapsed, expected) in fixtures {
            #expect(CodexT3SidebarThreadRow.recencyLabel(timestamp: now - elapsed, now: now) == expected)
        }
        #expect(CodexT3SidebarThreadRow.recencyLabel(timestamp: nil, now: now).isEmpty)
        #expect(CodexT3SidebarThreadRow.recencyLabel(timestamp: .nan, now: now).isEmpty)
        #expect(CodexT3SidebarThreadRow.recencyLabel(timestamp: 0, now: .infinity).isEmpty)
        #expect(CodexT3SidebarThreadRow.recencyLabel(timestamp: -.greatestFiniteMagnitude, now: .greatestFiniteMagnitude).isEmpty)
    }

    @Test func approvalAndInputTakePrecedenceOverRunningStatus() {
        let summary = CodexThreadSummary(id: "thread", title: "Live task")
        #expect(CodexT3SidebarThreadStatus.resolve(row: .init(summary: summary, liveStatus: .running, attention: .approval)) == .approval)
        #expect(CodexT3SidebarThreadStatus.resolve(row: .init(summary: summary, liveStatus: .running, attention: .input)) == .input)
        #expect(CodexT3SidebarThreadStatus.resolve(row: .init(summary: summary, liveStatus: .running)) == .working)
        #expect(CodexT3SidebarThreadStatus.resolve(row: .init(summary: summary, liveStatus: .failed)) == .failed)
        #expect(CodexT3SidebarThreadStatus.resolve(row: .init(summary: summary, hasUnreadWhileInactive: true)) == .ready)
    }

    @Test func backgroundWorkRecedesWhileActionRequiredRowsKeepProminence() {
        #expect(CodexT3SidebarThreadStatus.working.shouldRecede(isActive: false, isSelected: false, isUnread: true))
        #expect(!CodexT3SidebarThreadStatus.working.shouldRecede(isActive: true, isSelected: false, isUnread: false))
        #expect(!CodexT3SidebarThreadStatus.working.shouldRecede(isActive: false, isSelected: true, isUnread: false))
        #expect(!CodexT3SidebarThreadStatus.input.shouldRecede(isActive: false, isSelected: false, isUnread: false))
        #expect(CodexT3SidebarThreadStatus.ready.shouldRecede(isActive: false, isSelected: false, isUnread: false))
        #expect(!CodexT3SidebarThreadStatus.ready.shouldRecede(isActive: false, isSelected: false, isUnread: true))
        #expect(CodexT3SidebarThreadStatus.approval.shouldRecede(isActive: false, isSelected: false, isUnread: false))
        #expect(!CodexT3SidebarThreadStatus.failed.shouldRecede(isActive: false, isSelected: false, isUnread: false))
    }
}
