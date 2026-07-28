import Foundation
import SwiftUI

struct CodexInlineActivityViewV2: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.codexAgentTheme) private var theme
    @State private var shimmerPosition: CGFloat = -1
    @State private var isExpanded = false

    let activity: CodexInlineActivityV2

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if hasExpandableContent {
                Button {
                    withAnimation(.snappy(duration: theme.animations.snappyDuration)) {
                        isExpanded.toggle()
                    }
                } label: {
                    activityLabel
                }
                .buttonStyle(.plain)
                .accessibilityValue(accessibilityStatus)
            } else {
                activityLabel
                    .accessibilityValue(accessibilityStatus)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let imagePath {
                        CodexTranscriptImageThumbnail(
                            path: imagePath,
                            label: URL(fileURLWithPath: imagePath).lastPathComponent,
                            side: 160,
                            aspectRatio: CodexTranscriptImageSource.aspectRatio(imagePath) ?? 1
                        )
                    }
                    if let detail {
                        Text(detail)
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 22)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .task(id: isAnimating) {
            guard isAnimating else {
                shimmerPosition = 0
                return
            }
            shimmerPosition = -1
            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                shimmerPosition = 2
            }
        }
    }

    private var activityLabel: some View {
        HStack(spacing: 7) {
            if let systemImage = activity.systemImage, !systemImage.isEmpty {
                Image(systemName: systemImage)
                    .font(theme.fonts.caption)
            }
            Text(activity.label)
                .lineLimit(2)
            if hasExpandableContent {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(theme.fonts.micro)
            }
        }
        .font(theme.fonts.caption)
        .foregroundStyle(foregroundStyle)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(activity.label)
    }

    private var detail: String? {
        let value = activity.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private var imagePath: String? {
        let value = activity.imagePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private var hasExpandableContent: Bool {
        detail != nil || imagePath != nil
    }

    private var isAnimating: Bool {
        activity.status == .inProgress && !reduceMotion
    }

    private var foregroundStyle: LinearGradient {
        let color = theme.colors.textTertiary
        guard isAnimating else {
            return LinearGradient(colors: [color, color], startPoint: .leading, endPoint: .trailing)
        }
        return LinearGradient(
            colors: [color.opacity(0.52), color, color.opacity(0.52)],
            startPoint: UnitPoint(x: shimmerPosition - 0.42, y: 0.5),
            endPoint: UnitPoint(x: shimmerPosition + 0.42, y: 0.5)
        )
    }

    private var accessibilityStatus: String {
        switch activity.status {
        case .inProgress: "In progress"
        case .completed: "Completed"
        case .failed: "Failed"
        case .declined: "Declined"
        case .unknown: "Unknown status"
        }
    }
}

enum CodexProductToolPresentationV2 {
    static func label(_ call: CodexProductToolCallV2) -> String {
        let words = call.tool
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map(String.init)
        guard let first = words.first else { return "Use tool" }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst())
            .joined(separator: " ")
    }

    static func systemImage(_ call: CodexProductToolCallV2) -> String {
        let value = ([call.namespace, call.tool].compactMap { $0 })
            .joined(separator: " ")
            .lowercased()
        if value.contains("github") { return "point.3.connected.trianglepath.dotted" }
        if value.contains("search") || value.contains("research") { return "magnifyingglass" }
        if value.contains("read") { return "book" }
        if value.contains("issue") || value.contains("pull_request") { return "arrow.triangle.branch" }
        return "wrench.and.screwdriver"
    }
}
