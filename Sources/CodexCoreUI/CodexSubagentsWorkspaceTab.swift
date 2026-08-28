import Foundation
import Observation
import SwiftUI
import CodexCore

/// Metadata shown by one row in the Subagents workspace tab.
///
/// A row intentionally has no transcript. Child detail is owned by
/// `CodexSubagentPresentationCoordinator` and is retained only while this row
/// is selected. Keeping the list value transcript-free makes the memory rule
/// visible at this seam instead of relying on every caller to remember it.
public struct CodexSubagentsWorkspaceRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let title: String
    public let prompt: String
    public let status: CodexSubagentState.Status
    public let createdAt: Date
    public let completedAt: Date?

    public init(_ subagent: CodexSubagentState) {
        id = subagent.id
        name = subagent.name
        title = subagent.title
        prompt = subagent.prompt
        status = subagent.status
        createdAt = subagent.createdAt
        completedAt = subagent.completedAt
    }

    public var isActive: Bool { status == .running }
    public var isDone: Bool { !isActive }

    public var statusSummary: String {
        switch status {
        case .running: "Working"
        case .completed: "Completed"
        case .closed: "Closed"
        case .failed: "Failed"
        }
    }
}

/// The stable, transcript-free master-list projection for Subagents.
public struct CodexSubagentsWorkspaceSnapshot: Equatable, Sendable {
    public let active: [CodexSubagentsWorkspaceRow]
    public let done: [CodexSubagentsWorkspaceRow]
    public let selectedThreadID: String?

    public init(
        active: [CodexSubagentsWorkspaceRow],
        done: [CodexSubagentsWorkspaceRow],
        selectedThreadID: String?
    ) {
        self.active = active
        self.done = done
        self.selectedThreadID = selectedThreadID
    }

    public var allRows: [CodexSubagentsWorkspaceRow] { active + done }

    public var statusSummary: String {
        let activeCount = active.count
        let doneCount = done.count
        if activeCount == 0, doneCount == 0 { return "No subagents" }
        if activeCount == 0 {
            return doneCount == 1 ? "1 done" : String(doneCount) + " done"
        }
        if doneCount == 0 {
            return activeCount == 1 ? "1 active" : String(activeCount) + " active"
        }
        return String(activeCount) + " active · " + String(doneCount) + " done"
    }

    public func row(id: String) -> CodexSubagentsWorkspaceRow? {
        allRows.first { $0.id == id }
    }
}

/// Row-level changes used by the master list. SwiftUI receives stable row IDs;
/// this value makes the one-row update contract directly testable as well.
public struct CodexSubagentsWorkspaceListDiff: Equatable, Sendable {
    public let insertedIDs: [String]
    public let removedIDs: [String]
    public let updatedIDs: [String]

    public init(
        insertedIDs: [String] = [],
        removedIDs: [String] = [],
        updatedIDs: [String] = []
    ) {
        self.insertedIDs = insertedIDs
        self.removedIDs = removedIDs
        self.updatedIDs = updatedIDs
    }

    public var isEmpty: Bool {
        insertedIDs.isEmpty && removedIDs.isEmpty && updatedIDs.isEmpty
    }
}

public enum CodexSubagentsWorkspaceProjection {
    public static func snapshot(
        subagents: [CodexSubagentState],
        selectedThreadID: String? = nil
    ) -> CodexSubagentsWorkspaceSnapshot {
        var seen = Set<String>()
        let rows = subagents.compactMap { subagent -> CodexSubagentsWorkspaceRow? in
            guard seen.insert(subagent.id).inserted else { return nil }
            return CodexSubagentsWorkspaceRow(subagent)
        }
        return CodexSubagentsWorkspaceSnapshot(
            active: rows.filter(\.isActive),
            done: rows.filter(\.isDone),
            selectedThreadID: selectedThreadID
        )
    }

    public static func diff(
        from old: CodexSubagentsWorkspaceSnapshot,
        to new: CodexSubagentsWorkspaceSnapshot
    ) -> CodexSubagentsWorkspaceListDiff {
        let oldRows = Dictionary(
            old.allRows.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let newRows = Dictionary(
            new.allRows.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let oldIDs = Set(oldRows.keys)
        let newIDs = Set(newRows.keys)
        let inserted = new.allRows.map(\.id).filter { !oldIDs.contains($0) }
        let removed = old.allRows.map(\.id).filter { !newIDs.contains($0) }
        let updated = new.allRows.map(\.id).filter { id in
            guard let oldRow = oldRows[id], let newRow = newRows[id] else { return false }
            return oldRow != newRow
        }
        return .init(insertedIDs: inserted, removedIDs: removed, updatedIDs: updated)
    }
}

/// Stable accessibility vocabulary for the master/detail surface.
public enum CodexSubagentsWorkspaceAccessibility {
    public static let masterIdentifier = "subagents.master"
    public static let backToMasterLabel = "Back to subagents"

    public static func rowIdentifier(_ threadID: String) -> String {
        "subagent.row." + threadID
    }

    public static func rowLabel(_ row: CodexSubagentsWorkspaceRow) -> String {
        row.name + ", " + row.statusSummary
    }

    public static let rowHint = "Show subagent transcript"
}

/// Presentation state persisted with the one Subagents workspace tab.
public struct CodexSubagentsWorkspaceTabState: Codable, Equatable, Hashable, Sendable {
    public var selectedThreadID: String?

    public init(selectedThreadID: String? = nil) {
        self.selectedThreadID = selectedThreadID
    }

    public init(_ state: CodexWorkspaceTabState) {
        self = Self.decode(state.data)
    }

    public var workspaceTabState: CodexWorkspaceTabState {
        .init(data: Self.encode(self))
    }

    public static func selectedThreadID(in state: CodexWorkspaceTabState) -> String? {
        Self(state).selectedThreadID
    }

    private static func encode(_ state: Self) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(state)) ?? Data()
    }

    private static func decode(_ data: Data) -> Self {
        guard !data.isEmpty,
              let state = try? JSONDecoder().decode(Self.self, from: data)
        else { return .init() }
        return state
    }
}

/// The registered adapter for the single Subagents workspace tab.
///
/// The coordinator remains the canonical child presentation owner. This
/// adapter contributes only workspace-tab identity and the master/detail view;
/// selecting a row delegates to the coordinator, which acquires the one exact
/// child lease and cancels any obsolete projection.
@MainActor
public struct CodexSubagentsWorkspaceTabAdapter: CodexWorkspaceTabAdapter {
    public static let resourceKey = "codex.subagents"
    public static let routeAdapterID = "codex.subagents"
    public static let routeVersion = 1

    public let parentThreadID: String
    public let coordinator: CodexSubagentPresentationCoordinator
    public let selectedThreadID: String?
    private let onSelectionChanged: (String?) -> Void

    public init(
        parentThreadID: String,
        coordinator: CodexSubagentPresentationCoordinator,
        selectedThreadID: String? = nil,
        onSelectionChanged: @escaping (String?) -> Void = { _ in }
    ) {
        self.parentThreadID = parentThreadID
        self.coordinator = coordinator
        self.selectedThreadID = selectedThreadID
        self.onSelectionChanged = onSelectionChanged
    }

    public init(
        parentThreadID: ThreadID,
        coordinator: CodexSubagentPresentationCoordinator,
        selectedThreadID: String? = nil,
        onSelectionChanged: @escaping (String?) -> Void = { _ in }
    ) {
        self.init(
            parentThreadID: parentThreadID.rawValue,
            coordinator: coordinator,
            selectedThreadID: selectedThreadID,
            onSelectionChanged: onSelectionChanged
        )
    }

    public var workspaceTabRegistration: CodexWorkspaceTabRegistration {
        let state = CodexSubagentsWorkspaceTabState(
            selectedThreadID: selectedThreadID
        ).workspaceTabState
        return CodexWorkspaceTabRegistration(
            resourceKey: Self.resourceKey,
            title: "Subagents",
            systemImage: "person.2",
            lifetime: .pinned,
            durableRoute: .init(
                adapterID: Self.routeAdapterID,
                version: Self.routeVersion,
                resourceID: parentThreadID
            ),
            initialState: state,
            reopenState: state
        ) { tabState in
            AnyView(
                CodexSubagentsWorkspaceTabView(
                    coordinator: coordinator,
                    tabState: tabState,
                    onSelectionChanged: onSelectionChanged
                )
            )
        }
    }
}

/// Official-style master/detail presentation for the Subagents workspace tab.
@MainActor
public struct CodexSubagentsWorkspaceTabView: View {
    @Environment(\.codexAgentTheme) private var theme
    @State private var coordinator: CodexSubagentPresentationCoordinator
    @Binding private var tabState: CodexWorkspaceTabState
    private let onSelectionChanged: (String?) -> Void

    public init(
        coordinator: CodexSubagentPresentationCoordinator,
        tabState: Binding<CodexWorkspaceTabState>,
        onSelectionChanged: @escaping (String?) -> Void = { _ in }
    ) {
        _coordinator = State(initialValue: coordinator)
        _tabState = tabState
        self.onSelectionChanged = onSelectionChanged
    }

    public var body: some View {
        let state = CodexSubagentsWorkspaceTabState(tabState)
        let snapshot = CodexSubagentsWorkspaceProjection.snapshot(
            subagents: coordinator.panelSubagents,
            selectedThreadID: state.selectedThreadID
        )
        let selected = selectedState(id: state.selectedThreadID)

        Group {
            if let selected {
                detail(selected)
            } else {
                master(snapshot)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.colors.surface)
        .onAppear { restoreSelection(state.selectedThreadID, hasRows: !snapshot.allRows.isEmpty) }
        .onChange(of: tabState) { _, nextState in
            let next = CodexSubagentsWorkspaceTabState(nextState)
            restoreSelection(next.selectedThreadID, hasRows: !coordinator.panelSubagents.isEmpty)
        }
        .onChange(of: coordinator.changeRevision) { _, _ in
            let next = CodexSubagentsWorkspaceTabState(tabState)
            restoreSelection(next.selectedThreadID, hasRows: !coordinator.panelSubagents.isEmpty)
        }
        .onDisappear {
            // Closing/removing the workspace tab must release the selected
            // child lease. The durable tab state remains intact so a restored
            // tab can lazily reacquire it when its detail is shown again.
            if coordinator.selectedSubagentThreadID != nil {
                coordinator.selectTranscript(nil)
                onSelectionChanged(nil)
            }
        }
    }

    private func master(_ snapshot: CodexSubagentsWorkspaceSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Subagents")
                        .font(theme.fonts.body.weight(.semibold))
                        .foregroundStyle(theme.colors.textPrimary)
                    Spacer(minLength: 8)
                    Text(snapshot.statusSummary)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Subagents")
                .accessibilityValue(snapshot.statusSummary)

                if !snapshot.active.isEmpty {
                    section("Active", rows: snapshot.active)
                }
                if !snapshot.done.isEmpty {
                    section("Done", rows: snapshot.done)
                }
                if snapshot.allRows.isEmpty {
                    Text("Subagents will appear here when this task delegates work.")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .padding(.vertical, 16)
                        .accessibilityLabel("No subagents")
                }
            }
            .padding(16)
        }
        .accessibilityIdentifier(CodexSubagentsWorkspaceAccessibility.masterIdentifier)
    }

    private func section(
        _ title: String,
        rows: [CodexSubagentsWorkspaceRow]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(theme.fonts.caption.weight(.semibold))
                .foregroundStyle(theme.colors.textTertiary)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            ForEach(rows) { row in
                rowButton(row)
            }
        }
    }

    private func rowButton(_ row: CodexSubagentsWorkspaceRow) -> some View {
        Button {
            select(row.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: row.isActive ? "person.crop.circle.badge.clock" : "person.crop.circle")
                    .foregroundStyle(row.isActive ? theme.colors.running : theme.colors.textSecondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.name)
                        .font(theme.fonts.body)
                        .foregroundStyle(theme.colors.textPrimary)
                        .lineLimit(1)
                    Text(row.title)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(row.statusSummary)
                    .font(theme.fonts.micro)
                    .foregroundStyle(row.isActive ? theme.colors.running : theme.colors.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.colors.surfaceElevated.opacity(0.45), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(CodexSubagentsWorkspaceAccessibility.rowLabel(row))
        .accessibilityValue(row.title)
        .accessibilityHint(CodexSubagentsWorkspaceAccessibility.rowHint)
        .accessibilityIdentifier(CodexSubagentsWorkspaceAccessibility.rowIdentifier(row.id))
    }

    private func detail(_ subagent: CodexSubagentState) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    select(nil)
                } label: {
                    Label("Back to subagents", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.colors.textSecondary)
                .accessibilityLabel(CodexSubagentsWorkspaceAccessibility.backToMasterLabel)
                .accessibilityHint("Return to the active and done subagent lists")

                Spacer(minLength: 8)
                CodexSubagentsStatusBadge(status: subagent.status)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            VStack(alignment: .leading, spacing: 6) {
                Text(subagent.name)
                    .font(theme.fonts.body.weight(.semibold))
                    .foregroundStyle(theme.colors.textPrimary)
                if subagent.title != subagent.name {
                    Text(subagent.title)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                }
                if !subagent.prompt.isEmpty {
                    Text(subagent.prompt)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            CodexTranscriptViewV2(
                transcript: subagent.transcript,
                bottomContentInset: 16
            ) {
                Text(subagent.emptyTranscriptMessage)
                    .font(theme.fonts.chat)
                    .foregroundStyle(theme.colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 20)
            }
            .id("subagent-transcript-\(subagent.id)")
            .accessibilityIdentifier("subagent.transcript.\(subagent.id)")
        }
    }

    private func selectedState(id: String?) -> CodexSubagentState? {
        guard let id else { return nil }
        return coordinator.panelSubagents.first { $0.id == id }
    }

    private func select(_ id: String?) {
        tabState = CodexSubagentsWorkspaceTabState(
            selectedThreadID: id
        ).workspaceTabState
        coordinator.selectTranscript(id.map { ThreadID($0) })
        onSelectionChanged(id)
    }

    private func restoreSelection(_ id: String?, hasRows: Bool) {
        guard let id else {
            if coordinator.selectedSubagentThreadID != nil {
                coordinator.selectTranscript(nil)
                onSelectionChanged(nil)
            }
            return
        }
        if selectedState(id: id) != nil {
            if coordinator.selectedSubagentThreadID != ThreadID(id) {
                coordinator.selectTranscript(ThreadID(id))
                onSelectionChanged(id)
            }
        } else if hasRows {
            // The persisted child no longer exists. Drop the stale selection so
            // closing/reopening the tab returns to its master list.
            tabState = CodexSubagentsWorkspaceTabState().workspaceTabState
            coordinator.selectTranscript(nil)
            onSelectionChanged(nil)
        }
    }
}

private struct CodexSubagentsStatusBadge: View {
    @Environment(\.codexAgentTheme) private var theme
    let status: CodexSubagentState.Status

    var body: some View {
        CodexStatusChip(
            color: color,
            label: label,
            isStreaming: status == .running
        )
    }

    private var label: String {
        switch status {
        case .running: "Working"
        case .completed: "Completed"
        case .closed: "Closed"
        case .failed: "Failed"
        }
    }

    private var color: Color {
        switch status {
        case .running: theme.colors.running
        case .completed: theme.colors.success
        case .closed: theme.colors.textTertiary
        case .failed: theme.colors.danger
        }
    }
}
