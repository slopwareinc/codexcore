import SwiftUI

/// Lightweight card renderers for structured transcript facts. Heavy product
/// widgets remain injectable and lazy; these cards are intentionally pure text.
struct CodexStructuredTranscriptCardViewV2: View {
    @Environment(\.codexAgentTheme) private var theme
    let card: CodexStructuredTranscriptCardV2
    @Binding private var isExpanded: Bool

    init(card: CodexStructuredTranscriptCardV2, isExpanded: Binding<Bool> = .constant(false)) {
        self.card = card
        self._isExpanded = isExpanded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard !card.steps.isEmpty || card.explanation?.isEmpty == false else { return }
                withAnimation(.snappy(duration: theme.animations.snappyDuration)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: icon)
                    Text(card.title)
                        .font(theme.fonts.caption.weight(.medium))
                    Spacer(minLength: 0)
                    Text(statusLabel)
                        .font(theme.fonts.micro)
                        .foregroundStyle(statusColor)
                    if hasDetails {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(theme.fonts.micro)
                    }
                }
                .foregroundStyle(theme.colors.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(card.title), \(statusLabel)")

            if isExpanded {
                if let explanation = card.explanation, !explanation.isEmpty {
                    Text(explanation)
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.textTertiary)
                        .textSelection(.enabled)
                }
                ForEach(card.steps) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(stepGlyph(step.status))
                            .foregroundStyle(stepColor(step.status))
                        Text(step.title)
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.textPrimary)
                        if let detail = step.detail, !detail.isEmpty {
                            Text(detail)
                                .font(theme.fonts.micro)
                                .foregroundStyle(theme.colors.textTertiary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.colors.surfaceElevated.opacity(0.48), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous)
                .stroke(theme.colors.border.opacity(0.65), lineWidth: 1)
        }
    }

    private var icon: String {
        switch card.kind {
        case .todo: "checklist"
        case .proposedPlan: "list.bullet.clipboard"
        case .planImplementation: "hammer"
        }
    }

    private var statusLabel: String {
        switch card.status {
        case .pending: "Pending"
        case .inProgress: "In progress"
        case .completed: "Complete"
        case .failed: "Failed"
        case .unknown: "Status unavailable"
        }
    }

    private var statusColor: Color {
        switch card.status {
        case .pending: theme.colors.textTertiary
        case .inProgress: theme.colors.running
        case .completed: theme.colors.success
        case .failed: theme.colors.danger
        case .unknown: theme.colors.warning
        }
    }

    private var hasDetails: Bool { !card.steps.isEmpty || card.explanation?.isEmpty == false }

    private func stepGlyph(_ status: CodexStructuredTranscriptCardStatusV2) -> String {
        switch status {
        case .pending: "○"
        case .inProgress: "◌"
        case .completed: "✓"
        case .failed: "!"
        case .unknown: "?"
        }
    }

    private func stepColor(_ status: CodexStructuredTranscriptCardStatusV2) -> Color {
        switch status {
        case .pending: theme.colors.textTertiary
        case .inProgress: theme.colors.running
        case .completed: theme.colors.success
        case .failed: theme.colors.danger
        case .unknown: theme.colors.warning
        }
    }
}

struct CodexApprovalReviewCardViewV2: View {
    @Environment(\.codexAgentTheme) private var theme
    let review: CodexApprovalReviewCardV2

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(review.title, systemImage: "hand.raised")
                .font(theme.fonts.caption.weight(.medium))
            HStack(spacing: 6) {
                Text(review.statusLabel)
                if let risk = review.riskLevel, !risk.isEmpty { Text("· \(risk)") }
            }
            .font(theme.fonts.micro)
            .foregroundStyle(theme.colors.textTertiary)
            if let rationale = review.rationale, !rationale.isEmpty {
                Text(rationale).font(theme.fonts.caption).textSelection(.enabled)
            }
        }
        .foregroundStyle(reviewColor)
        .padding(10)
        .background(reviewColor.opacity(0.08), in: RoundedRectangle(cornerRadius: theme.radii.medium, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(review.title), \(review.statusLabel)")
    }

    private var reviewColor: Color {
        switch review.status {
        case .inProgress: theme.colors.running
        case .approved: theme.colors.success
        case .denied, .timedOut: theme.colors.danger
        case .aborted, .unknown: theme.colors.warning
        }
    }
}

struct CodexHookActivityViewV2: View {
    @Environment(\.codexAgentTheme) private var theme
    let activity: CodexHookActivityV2

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(activity.label)
                Text(statusLabel).font(theme.fonts.micro)
            }
        } icon: {
            Image(systemName: "arrow.triangle.branch")
        }
        .font(theme.fonts.caption)
        .foregroundStyle(statusColor)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(activity.label), \(statusLabel)")
    }

    private var statusLabel: String {
        switch activity.status {
        case .inProgress: "in progress"
        case .completed: "completed"
        case .failed: "failed"
        case .declined: "declined"
        case .unknown: "status unavailable"
        }
    }

    private var statusColor: Color {
        switch activity.status {
        case .inProgress: theme.colors.running
        case .completed: theme.colors.success
        case .failed: theme.colors.danger
        case .declined, .unknown: theme.colors.warning
        }
    }
}

struct CodexTranscriptRecoveryViewV2: View {
    @Environment(\.codexAgentTheme) private var theme
    let notice: CodexTranscriptRecoveryNoticeV2

    var body: some View {
        Label(notice.message, systemImage: "arrow.clockwise")
            .font(theme.fonts.caption)
            .foregroundStyle(theme.colors.warning)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(notice.message)
    }
}
