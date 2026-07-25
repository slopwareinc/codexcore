import Foundation
import OSLog

@MainActor
enum CodexVoiceLog {
    enum Level {
        case info
        case notice
        case error
    }

    private static let preferredFileURL = FileManager.default.urls(
        for: .libraryDirectory,
        in: .userDomainMask
    )[0]
        .appendingPathComponent("Logs/CodexCore/voice.jsonl")
    private static let fallbackFileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexCore/voice.jsonl")
    private(set) static var fileURL = preferredFileURL

    private static let logger = Logger(
        subsystem: "com.slopware.codexcore",
        category: "voice"
    )
    private static let maximumFileSize = 25 * 1_024 * 1_024

    static func write(
        _ event: String,
        level: Level = .info,
        fields: [String: String] = [:]
    ) {
        var record = fields
        record["event"] = event
        record["level"] = switch level {
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        }
        record["timestamp"] = ISO8601DateFormatter().string(from: Date())

        let line: String
        if let data = try? JSONSerialization.data(
            withJSONObject: record,
            options: [.sortedKeys]
        ), let encoded = String(data: data, encoding: .utf8) {
            line = encoded
        } else {
            line = #"{"event":"voice.log.encoding_failed"}"#
        }

        switch level {
        case .info:
            logger.info("\(line, privacy: .public)")
        case .notice:
            logger.notice("\(line, privacy: .public)")
        case .error:
            logger.error("\(line, privacy: .public)")
        }
        appendToFile(line)
    }

    static func encodedJSON<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else {
            return "<encoding failed>"
        }
        return text
    }

    private static func appendToFile(_ line: String) {
        let candidates = fileURL == fallbackFileURL
            ? [fallbackFileURL]
            : [preferredFileURL, fallbackFileURL]
        var lastError: Error?
        for candidate in candidates {
            do {
                try append(line, to: candidate)
                fileURL = candidate
                return
            } catch {
                lastError = error
            }
        }
        if let lastError {
            logger.error(
                "voice log file write failed: \(String(describing: lastError), privacy: .public)"
            )
        }
    }

    private static func append(_ line: String, to destination: URL) throws {
        let manager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        if let size = try manager.attributesOfItem(
            atPath: destination.path
        )[.size] as? NSNumber,
           size.intValue >= maximumFileSize {
            let previousURL = destination.appendingPathExtension("previous")
            if manager.fileExists(atPath: previousURL.path) {
                try manager.removeItem(at: previousURL)
            }
            try manager.moveItem(at: destination, to: previousURL)
        }
        if !manager.fileExists(atPath: destination.path) {
            try Data().write(to: destination, options: .atomic)
        }
        let handle = try FileHandle(forWritingTo: destination)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(line)\n".utf8))
        try handle.close()
    }
}
