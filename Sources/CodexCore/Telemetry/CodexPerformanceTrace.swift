import Foundation
import OSLog

public struct CodexPerformanceTrace: Sendable, Equatable {
    public let id: String
    public let label: String

    public init(label: String, id: String? = nil) {
        self.id = id ?? Self.makeID()
        self.label = label
    }

    @discardableResult
    public func begin(
        _ name: String,
        metadata: [String: String] = [:]
    ) -> CodexPerformanceTraceSpan {
        Self.emit(traceID: id, label: label, name: name, event: "start", elapsedMS: nil, metadata: metadata)
        return CodexPerformanceTraceSpan(traceID: id, label: label, name: name, startedAt: Date())
    }

    public func event(
        _ name: String,
        metadata: [String: String] = [:]
    ) {
        Self.emit(traceID: id, label: label, name: name, event: "event", elapsedMS: nil, metadata: metadata)
    }

    fileprivate static func emit(
        traceID: String,
        label: String,
        name: String,
        event: String,
        elapsedMS: Double?,
        metadata: [String: String]
    ) {
        var parts = [
            "trace=\(sanitize(traceID))",
            "label=\(sanitize(label))",
            "span=\(sanitize(name))",
            "event=\(sanitize(event))"
        ]
        if let elapsedMS {
            parts.append(String(format: "elapsed_ms=%.1f", elapsedMS))
        }
        for key in metadata.keys.sorted() {
            guard let value = metadata[key] else { continue }
            parts.append("\(sanitize(key))=\(sanitize(value))")
        }
        let line = parts.joined(separator: " ")
        print("[CodexTrace] \(line)")
        logger.notice("\(line, privacy: .public)")
    }

    private static func makeID() -> String {
        String(UUID().uuidString.prefix(8))
    }

    private static func sanitize(_ value: String) -> String {
        let compact = value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: " ")
        if compact.count <= 160 {
            return compact
        }
        return "\(compact.prefix(157))..."
    }

    private static let logger = Logger(subsystem: "com.slopware.codexcore", category: "performance")
}

public struct CodexPerformanceTraceSpan: Sendable {
    public let traceID: String
    public let label: String
    public let name: String
    public let startedAt: Date

    public func end(metadata: [String: String] = [:]) {
        CodexPerformanceTrace.emit(
            traceID: traceID,
            label: label,
            name: name,
            event: "end",
            elapsedMS: Date().timeIntervalSince(startedAt) * 1000,
            metadata: metadata
        )
    }
}
