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
        if call.namespace == "codex_app" {
            switch call.tool {
            case "create_thread":
                if call.status == .inProgress { return "Creating chat" }
                return threadReference(call) == nil ? "Created chat" : "Chat created"
            case "send_message_to_thread":
                return call.status == .inProgress ? "Sending message to chat" : "Sent message to chat"
            case "read_thread":
                return call.status == .inProgress ? "Reading chat" : "Read chat"
            case "list_threads":
                return call.status == .inProgress ? "Listing chats" : "Listed chats"
            default: break
            }
        }
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
        if value.contains("thread") { return "bubble.left.and.bubble.right" }
        if value.contains("issue") || value.contains("pull_request") { return "arrow.triangle.branch" }
        return "wrench.and.screwdriver"
    }

    static func threadReference(_ call: CodexProductToolCallV2) -> CodexThreadReferenceV2? {
        guard call.namespace == "codex_app" else { return nil }
        if call.tool == "read_thread" || call.tool == "send_message_to_thread" {
            guard case .dictionary(let arguments)? = call.arguments,
                  case .string(let threadID)? = arguments["threadId"]
            else { return nil }
            let hostID: String? = if case .string(let value)? = arguments["hostId"] { value } else { nil }
            return .init(hostID: hostID, threadID: threadID)
        }
        guard call.tool == "create_thread", call.success == true else { return nil }
        for item in call.contentItems {
            guard case .dictionary(let object) = item,
                  case .string(let type)? = object["type"], type == "inputText",
                  case .string(let text)? = object["text"],
                  let data = text.data(using: .utf8),
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let threadID = result["threadId"] as? String
            else { continue }
            return .init(hostID: result["hostId"] as? String, threadID: threadID)
        }
        return nil
    }

    static func accessibilityLabel(_ call: CodexProductToolCallV2) -> String {
        let label = label(call)
        return threadReference(call) == nil ? label : "\(label). Open chat"
    }
}
