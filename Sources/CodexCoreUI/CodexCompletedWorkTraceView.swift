import SwiftUI

public struct CodexCompletedWorkTraceView: View {
    @Environment(\.codexAgentTheme) private var theme

    private let trace: CodexCompletedWorkTrace
    @State private var isExpanded: Bool

    public init(trace: CodexCompletedWorkTrace) {
        self.trace = trace
        self._isExpanded = State(initialValue: !trace.isCollapsedByDefault)
    }

    public var body: some View {
        CodexCollapsibleCard(
            isExpanded: $isExpanded,
            background: theme.colors.surface.opacity(0.42),
            border: trace.hasFailure ? theme.colors.danger.opacity(0.38) : theme.colors.border.opacity(0.58),
            maxWidth: theme.spacing.cardMaxWidth
        ) { isExpanded, toggle in
            Button(action: toggle) {
                HStack(spacing: 9) {
                    Image(systemName: trace.hasFailure ? "exclamationmark.triangle" : "clock")
                        .font(theme.fonts.caption)
                        .foregroundStyle(trace.hasFailure ? theme.colors.danger : theme.colors.textTertiary)
                        .frame(width: 16, height: 16)

                    Text(trace.title)
                        .font(theme.fonts.label)
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(trace.countLabel)
                        .font(theme.fonts.micro)
                        .foregroundStyle(theme.colors.textTertiary)
                        .lineLimit(1)

                    Image(systemName: "chevron.right")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } body: {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(trace.groups) { group in
                    CodexCompletedWorkGroupView(group: group)
                }
            }
            .padding(8)
        }
        .accessibilityLabel("\(trace.title), \(trace.countLabel)")
    }
}

private struct CodexCompletedWorkGroupView: View {
    @Environment(\.codexAgentTheme) private var theme

    let group: CodexCompletedWorkTrace.Group
    @State private var isExpanded: Bool

    init(group: CodexCompletedWorkTrace.Group) {
        self.group = group
        self._isExpanded = State(initialValue: !group.isCollapsedByDefault)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: theme.animations.snappyDuration)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: iconName)
                        .font(theme.fonts.caption)
                        .foregroundStyle(group.hasFailure ? theme.colors.danger : theme.colors.textTertiary)
                        .frame(width: 16, height: 16)

                    Text(group.title)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(group.operations.count == 1 ? "1 item" : "\(group.operations.count) items")
                        .font(theme.fonts.micro)
                        .foregroundStyle(theme.colors.textTertiary)

                    Image(systemName: "chevron.right")
                        .font(theme.fonts.micro)
                        .foregroundStyle(theme.colors.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(group.operations) { operation in
                        CodexCompletedWorkOperationView(operation: operation)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .background(theme.colors.surfaceElevated.opacity(0.18), in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                .stroke(theme.colors.border.opacity(0.42), lineWidth: 1)
        )
    }

    private var iconName: String {
        switch group.kind {
        case .command:
            return "terminal"
        case .read:
            return "doc.text.magnifyingglass"
        case .edit:
            return "square.and.pencil"
        case .tool:
            return "wrench.and.screwdriver"
        case .plan:
            return "checklist"
        case .reasoning:
            return "brain.head.profile"
        case .notice:
            return "exclamationmark.circle"
        }
    }
}

private struct CodexCompletedWorkOperationView: View {
    @Environment(\.codexAgentTheme) private var theme

    let operation: CodexCompletedWorkTrace.Operation
    @State private var isExpanded: Bool

    init(operation: CodexCompletedWorkTrace.Operation) {
        self.operation = operation
        self._isExpanded = State(initialValue: !operation.isCollapsedByDefault)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard operation.detail != nil else { return }
                withAnimation(.snappy(duration: theme.animations.snappyDuration)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(operation.isFailure ? theme.colors.danger : theme.colors.textTertiary.opacity(0.58))
                        .frame(width: 5, height: 5)

                    Text(operation.title)
                        .font(theme.fonts.code)
                        .foregroundStyle(theme.colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 8)

                    if operation.isFailure || !operation.status.isEmpty {
                        Text(operation.status)
                            .font(theme.fonts.micro)
                            .foregroundStyle(operation.isFailure ? theme.colors.danger : theme.colors.textTertiary)
                            .lineLimit(1)
                    }

                    Image(systemName: "chevron.right")
                        .font(theme.fonts.micro)
                        .foregroundStyle(theme.colors.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .opacity(operation.detail == nil ? 0.22 : 1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Opening the operation reveals its detail directly — no extra
            // nested "diff" / "stdout" disclosure to click through.
            if isExpanded, let detail = operation.detail {
                ScrollView(.vertical, showsIndicators: true) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(detail)
                            .font(theme.fonts.code)
                            .foregroundStyle(operation.isFailure ? theme.colors.danger : theme.colors.codeText)
                            .padding(8)
                            .fixedSize(horizontal: true, vertical: true)
                    }
                }
                .frame(maxHeight: 220)
                .background(theme.colors.codeBackground, in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
    }
}

private extension CodexCompletedWorkTrace {
    var hasFailure: Bool {
        groups.contains(where: \.hasFailure)
    }

    var countLabel: String {
        let count = groups.reduce(0) { $0 + $1.operations.count }
        return count == 1 ? "1 item" : "\(count) items"
    }
}

private extension CodexCompletedWorkTrace.Group {
    var hasFailure: Bool {
        operations.contains(where: \.isFailure)
    }
}
