import CodexCore
import Foundation

/// Safe textual summary for MCP content blocks. It intentionally avoids
/// `CodexJSONValue.description`: structured payloads stay behind a bounded,
/// typed summary and hosts may provide a separate debug inspector if needed.
public enum CodexMCPContentPresentationV2 {
    public static func summary(_ blocks: [CodexMCPContentBlockV2]) -> String? {
        let lines = blocks.compactMap(line(for:))
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    public static func line(for block: CodexMCPContentBlockV2) -> String? {
        switch block {
        case .text(let text):
            return bounded(text)
        case .image(_, _, let alt):
            return alt.map { "Image: \(bounded($0))" } ?? "Image"
        case .audio:
            return "Audio"
        case .resource(let uri, _, let text):
            if let text, !text.isEmpty { return "Resource: \(bounded(uri)) — \(bounded(text))" }
            return "Resource: \(bounded(uri))"
        case .resourceLink(let uri, let name, _):
            return "Resource: \(bounded(name ?? uri))"
        case .structured(let fields):
            let keys = fields.keys.sorted().prefix(12).joined(separator: ", ")
            return keys.isEmpty ? "Structured result" : "Structured result · \(keys)"
        case .widget(let id, let uri, _):
            let label = id ?? uri ?? "MCP widget"
            return "Interactive widget: \(bounded(label))"
        case .unknown(let type):
            return "Unsupported MCP content type: \(bounded(type))"
        }
    }

    public static func toolDetail(
        arguments: CodexJSONValue?,
        blocks: [CodexMCPContentBlockV2]
    ) -> String? {
        var sections: [String] = []
        if arguments != nil { sections.append("Arguments supplied") }
        if let content = summary(blocks) { sections.append("Result\n\(content)") }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    private static func bounded(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count > 20_000 else { return trimmed }
        return String(trimmed.prefix(20_000)) + "\n… content truncated"
    }
}

/// Presentation-only lifecycle for an MCP App host.  The canonical widget
/// carries only URI/metadata; this value controls lazy mounting, visibility,
/// and bounded retained preview bytes.
public struct CodexMCPAppHostLifecycle: Sendable, Equatable {
    public var widget: CodexMCPWidgetV2
    public private(set) var state: CodexMCPWidgetV2.State
    public private(set) var isVisible: Bool
    public private(set) var retainedPreviewBytes: Int
    public let retentionLimitBytes: Int

    public init(
        widget: CodexMCPWidgetV2,
        retentionLimitBytes: Int = 1_048_576
    ) {
        self.widget = widget
        self.state = .disabled
        self.isVisible = false
        self.retainedPreviewBytes = 0
        self.retentionLimitBytes = max(0, retentionLimitBytes)
    }

    public var shouldPerformLayout: Bool {
        isVisible && state != .disabled
    }

    public var isSandboxed: Bool { widget.isSandboxed }

    public mutating func reveal() {
        isVisible = true
        if state == .disabled { state = .loading }
    }

    public mutating func hide() {
        isVisible = false
        retainedPreviewBytes = min(retainedPreviewBytes, retentionLimitBytes)
    }

    public mutating func markReady(retainedPreviewBytes: Int = 0) {
        state = .ready
        self.retainedPreviewBytes = min(max(0, retainedPreviewBytes), retentionLimitBytes)
    }

    public mutating func markFailed() {
        state = .failed
        retainedPreviewBytes = 0
    }

    public mutating func reset() {
        state = .disabled
        isVisible = false
        retainedPreviewBytes = 0
    }
}
