import Foundation
import OSLog
import Dispatch

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
        let traceLine = "[CodexTrace] \(line)"
        print(traceLine)
        logger.notice("\(line, privacy: .public)")
        appendToTraceFile(traceLine)
    }

    public static var traceFilePath: String {
        traceFileURL.path
    }

    private static func makeID() -> String {
        String(UUID().uuidString.prefix(8))
    }

    private static func appendToTraceFile(_ line: String) {
        traceFileQueue.sync {
            do {
                let url = traceFileURL
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let timestamp = ISO8601DateFormatter().string(from: Date())
                let data = "\(timestamp) \(line)\n".data(using: .utf8) ?? Data()
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: url, options: .atomic)
                }
            } catch {
                print("[CodexTrace] file_write_failed=\(sanitize(String(describing: error)))")
            }
        }
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
    private static let traceFileQueue = DispatchQueue(label: "com.slopware.codexcore.performance-trace")
    private static var traceFileURL: URL {
        let logsDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs", directoryHint: .isDirectory)
            .appending(path: "CodexCore", directoryHint: .isDirectory)
        return logsDirectory.appending(path: "performance-trace.log")
    }
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
