import CodexCore
import SwiftUI

/// Presentation vocabulary shared by the compact Summary and the workspace
/// New Tab page. The inventory remains the only source of resource rows.
public enum CodexThreadResourcePresentation {
    public static let orderedKinds: [CodexThreadResourceKind] = [
        .plan,
        .subagent,
        .editedFile,
        .outputFile,
        .generatedImage,
        .visualization,
        .artifact,
        .source,
        .webActivity,
        .mcpResource,
        .mcpApp,
        .backgroundTerminal,
        .review,
        .pullRequest,
        .sideChat,
    ]

    public static func sectionTitle(for kind: CodexThreadResourceKind) -> String {
        switch kind {
        case .plan: "Plans"
        case .subagent: "Subagents"
        case .editedFile: "Edited files"
        case .outputFile: "Output files"
        case .generatedImage: "Generated images"
        case .visualization: "Visualizations"
        case .artifact: "Artifacts"
        case .source: "Sources"
        case .webActivity: "Web activity"
        case .mcpResource: "MCP resources"
        case .mcpApp: "MCP apps"
        case .backgroundTerminal: "Background processes"
        case .review: "Reviews"
        case .pullRequest: "Pull requests"
        case .sideChat: "Side chats"
        case .unknown: "Other resources"
        }
    }

    public static func systemImage(for kind: CodexThreadResourceKind) -> String {
        switch kind {
        case .plan: "list.bullet.rectangle"
        case .subagent: "person.2"
        case .editedFile: "pencil.line"
        case .outputFile: "doc.text.arrow.up"
        case .generatedImage: "photo"
        case .visualization: "chart.xyaxis.line"
        case .artifact: "shippingbox"
        case .source: "link"
        case .webActivity: "globe"
        case .mcpResource: "externaldrive.connected.to.line.below"
        case .mcpApp: "square.stack.3d.up"
        case .backgroundTerminal: "terminal"
        case .review: "doc.text.magnifyingglass"
        case .pullRequest: "arrow.triangle.pull"
        case .sideChat: "rectangle.split.2x1"
        case .unknown: "questionmark.circle"
        }
    }

    public static func accessibilityLabel(for resource: CodexThreadResource) -> String {
        let status = switch resource.status {
        case .available: "available"
        case .inProgress: "in progress"
        case .completed: "completed"
        case .failed: "failed"
        case .unknown(let value): value
        }
        if let detail = resource.detail?.nilIfBlank {
            return "\(resource.title), \(status), \(detail)"
        }
        return "\(resource.title), \(status)"
    }
}

/// A single inventory row. It intentionally accepts a typed request rather
/// than a string callback so Summary and New Tab cannot drift in their routing.
public struct CodexThreadResourceRow: View {
    @Environment(\.codexAgentTheme) private var theme

    public let resource: CodexThreadResource
    public let onOpen: (CodexWorkspaceTabRequest) -> Void
    public let opener: CodexWorkspaceTabOpener
    public let secondaryAction: (() -> Void)?
    public let secondaryActionLabel: String?

    public init(
        resource: CodexThreadResource,
        onOpen: @escaping (CodexWorkspaceTabRequest) -> Void,
        opener: CodexWorkspaceTabOpener = .summary,
        secondaryAction: (() -> Void)? = nil,
        secondaryActionLabel: String? = nil
    ) {
        self.resource = resource
        self.onOpen = onOpen
        self.opener = opener
        self.secondaryAction = secondaryAction
        self.secondaryActionLabel = secondaryActionLabel
    }

    public var body: some View {
        Button {
            onOpen(resource.workspaceTabRequest(opener: opener))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: CodexThreadResourcePresentation.systemImage(for: resource.kind))
                    .font(theme.fonts.actionIcon)
                    .foregroundStyle(theme.colors.textSecondary)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(resource.title)
                        .font(theme.fonts.body)
                        .foregroundStyle(theme.colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail = resource.detail?.nilIfBlank {
                        Text(detail)
                            .font(theme.fonts.micro)
                            .foregroundStyle(theme.colors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if let secondaryAction {
                    Button(action: secondaryAction) {
                        Image(systemName: "xmark.circle")
                            .font(theme.fonts.micro)
                            .foregroundStyle(theme.colors.danger)
                    }
                    .buttonStyle(.plain)
                    .help(secondaryActionLabel ?? "More actions")
                    .accessibilityLabel(secondaryActionLabel ?? "More actions")
                } else {
                    statusIcon
                }
            }
            .frame(minHeight: 36)
            .padding(.horizontal, 4)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Open \(resource.title)")
        .accessibilityLabel(CodexThreadResourcePresentation.accessibilityLabel(for: resource))
        .accessibilityHint("Opens in the workspace")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch resource.status {
        case .inProgress:
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(theme.fonts.micro)
                .foregroundStyle(theme.colors.danger)
                .accessibilityHidden(true)
        case .completed:
            Image(systemName: "checkmark.circle")
                .font(theme.fonts.micro)
                .foregroundStyle(theme.colors.success)
                .accessibilityHidden(true)
        case .available, .unknown:
            Image(systemName: "chevron.right")
                .font(theme.fonts.micro)
                .foregroundStyle(theme.colors.textTertiary)
                .accessibilityHidden(true)
        }
    }
}

/// Compact Summary projection. No empty per-category placeholders are emitted;
/// a category exists only when the shared inventory contains a resource.
public struct CodexThreadResourceSummaryView: View {
    @Environment(\.codexAgentTheme) private var theme

    public let inventory: CodexThreadResourceInventory?
    public let onOpen: (CodexWorkspaceTabRequest) -> Void
    public let opener: CodexWorkspaceTabOpener
    public let excludedKinds: Set<CodexThreadResourceKind>

    public init(
        inventory: CodexThreadResourceInventory?,
        onOpen: @escaping (CodexWorkspaceTabRequest) -> Void,
        opener: CodexWorkspaceTabOpener = .summary,
        excludedKinds: Set<CodexThreadResourceKind> = []
    ) {
        self.inventory = inventory
        self.onOpen = onOpen
        self.opener = opener
        self.excludedKinds = excludedKinds
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let inventory, !inventory.resources.isEmpty {
                ForEach(CodexThreadResourcePresentation.orderedKinds, id: \.self) { kind in
                    let resources = inventory.resources(of: kind)
                    if !resources.isEmpty && !excludedKinds.contains(kind) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(CodexThreadResourcePresentation.sectionTitle(for: kind))
                                .font(theme.fonts.body)
                                .foregroundStyle(theme.colors.textTertiary)
                            ForEach(resources) { resource in
                                CodexThreadResourceRow(resource: resource, onOpen: onOpen, opener: opener)
                            }
                        }
                    }
                }
                let unknownResources = inventory.resources.filter {
                    !CodexThreadResourceKind.allCases.contains($0.kind)
                }
                if !unknownResources.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Other resources")
                            .font(theme.fonts.body)
                            .foregroundStyle(theme.colors.textTertiary)
                        ForEach(unknownResources) { resource in
                            CodexThreadResourceRow(resource: resource, onOpen: onOpen, opener: opener)
                        }
                    }
                }
            } else {
                Text("No thread resources yet")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.textTertiary)
                    .accessibilityLabel("No thread resources yet")
            }
        }
    }
}

/// Workspace side-panel New Tab. Tool launchers remain available alongside
/// the projected resources, while every resource row uses the same request
/// callback as Summary.
public struct CodexThreadResourceNewTabView: View {
    @Environment(\.codexAgentTheme) private var theme

    public let inventory: CodexThreadResourceInventory?
    public let onOpen: (CodexWorkspaceTabRequest) -> Void
    public let onOpenTool: (String) -> Void

    public init(
        inventory: CodexThreadResourceInventory?,
        onOpen: @escaping (CodexWorkspaceTabRequest) -> Void,
        onOpenTool: @escaping (String) -> Void
    ) {
        self.inventory = inventory
        self.onOpen = onOpen
        self.onOpenTool = onOpenTool
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Tab")
                        .font(theme.fonts.panelTitle)
                        .foregroundStyle(theme.colors.textPrimary)
                    Text("Open a thread resource or workspace tool.")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                }

                CodexThreadResourceSummaryView(
                    inventory: inventory,
                    onOpen: onOpen,
                    opener: .newTab
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Workspace tools")
                        .font(theme.fonts.body)
                        .foregroundStyle(theme.colors.textTertiary)
                    ForEach(CodexWorkspaceToolCatalog.launcherOptions) { option in
                        CodexThreadResourceToolRow(option: option) {
                            onOpenTool(option.id)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(theme.colors.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New thread resource tab")
    }
}

private struct CodexThreadResourceToolRow: View {
    @Environment(\.codexAgentTheme) private var theme

    let option: CodexWorkspaceToolOption
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: option.systemImage)
                    .font(theme.fonts.label)
                    .foregroundStyle(option.isEnabled ? theme.colors.textSecondary : theme.colors.textTertiary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.title)
                        .font(theme.fonts.label)
                        .foregroundStyle(option.isEnabled ? theme.colors.textPrimary : theme.colors.textTertiary)
                    Text(option.detail)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if option.isEnabled {
                    Image(systemName: "chevron.right")
                        .font(theme.fonts.caption.weight(.semibold))
                        .foregroundStyle(theme.colors.textTertiary)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                theme.colors.surfaceElevated.opacity(option.isEnabled ? theme.effects.textDimOpacity : 0.28),
                in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                    .stroke(theme.colors.border.opacity(option.isEnabled ? 1 : 0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!option.isEnabled)
        .accessibilityLabel(option.isEnabled ? "Open \(option.title)" : "\(option.title). \(option.detail)")
    }
}

/// Compatibility seed for hosts that have not yet supplied a canonical
/// snapshot. Production passes the canonical projection; this tiny adapter
/// keeps the reusable Summary initializer useful for previews and fixtures.
enum CodexThreadResourceFallbackInventory {
    static func make(
        threadID: ThreadID,
        workspaceSummary: CodexWorkspaceSummaryContext?,
        subagents: [CodexSubagentState],
        sideChat: CodexSideChatState?,
        review: CodexGitReviewSession?
    ) -> CodexThreadResourceInventory? {
        var resources: [CodexThreadResource] = []
        let origin = CodexThreadResourceOrigin(threadID: threadID)

        if let plan = workspaceSummary?.plan {
            resources.append(.init(
                id: "plan:\(threadID.rawValue):current",
                kind: .plan,
                title: plan.explanation?.nilIfBlank ?? "Plan",
                detail: plan.progressLabel,
                status: .available,
                origin: origin
            ))
        }
        for subagent in subagents where subagent.isVisibleInFloatingSummary {
            resources.append(.init(
                id: "subagent:\(threadID.rawValue):\(subagent.id)",
                kind: .subagent,
                title: subagent.floatingSummaryTitle,
                status: .init(rawValue: subagent.status.rawValue),
                origin: origin,
                metadata: .init(childThreadID: ThreadID(subagent.id))
            ))
        }
        if let sideChat {
            resources.append(.init(
                id: "side-chat:\(threadID.rawValue):\(sideChat.id)",
                kind: .sideChat,
                title: sideChat.title,
                origin: origin,
                metadata: .init(sourceID: sideChat.id)
            ))
        }
        for source in workspaceSummary?.sourceFiles ?? [] {
            resources.append(.init(
                id: "source:\(threadID.rawValue):\(source.id)",
                kind: .source,
                title: source.displayName,
                detail: source.path,
                origin: origin,
                metadata: .init(path: source.path)
            ))
        }
        if let terminals = workspaceSummary?.backgroundTerminals {
            for terminal in terminals.terminals {
                resources.append(.init(
                    id: "background-terminal:\(threadID.rawValue):\(terminal.processID)",
                    kind: .backgroundTerminal,
                    title: terminal.command,
                    detail: terminal.cwd.stringValue,
                    status: .inProgress,
                    origin: origin,
                    metadata: .init(
                        processID: terminal.processID,
                        command: terminal.command,
                        cwd: terminal.cwd.stringValue,
                        sourceID: terminal.itemID
                    )
                ))
            }
        }
        if let review {
            let stats = review.commitStats
            resources.append(.init(
                id: "review:\(threadID.rawValue):workspace",
                kind: .review,
                title: stats.isEmpty ? "Review" : "Changes",
                detail: stats.isEmpty
                    ? review.snapshot.branchName
                    : "\(review.snapshot.branchName) · +\(stats.addedLines) -\(stats.removedLines)",
                origin: origin,
                metadata: .init(sourceID: review.snapshot.revision.sourceID)
            ))
            if review.snapshot.pullRequestExists {
                resources.append(.init(
                    id: "pull-request:\(threadID.rawValue):\(review.snapshot.branchName)",
                    kind: .pullRequest,
                    title: "Pull request",
                    detail: review.snapshot.branchName,
                    origin: origin,
                    metadata: .init(branch: review.snapshot.branchName)
                ))
            }
        }
        guard !resources.isEmpty else { return nil }
        return .init(
            threadID: threadID,
            key: .init(canonicalRevision: .zero),
            resources: resources
        )
    }
}

private extension CodexJSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value.nilIfBlank
    }
}
