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
    private static let logger = Logger(
        subsystem: "com.slopware.codexcore",
        category: "voice"
    )
    private static let maximumFileSize = 25 * 1_024 * 1_024
    private static let fileWriter = CodexVoiceLogFileWriter(
        preferredURL: preferredFileURL,
        fallbackURL: fallbackFileURL,
        maximumFileSize: maximumFileSize,
        logger: logger
    )
    static var fileURL: URL { fileWriter.fileURL }

    static func sanitizedFields(_ fields: [String: String]) -> [String: String] {
        let sensitiveTokens = [
            "transcript", "text", "delta", "audio", "sdp", "response",
            "token", "authorization", "apikey", "api_key", "secret", "credential"
        ]
        return fields.filter { key, _ in
            let normalized = key.lowercased()
            return !sensitiveTokens.contains(where: normalized.contains)
                && normalized != "item"
                && normalized != "payload"
        }
    }

    static func write(
        _ event: String,
        level: Level = .info,
        fields: [String: String] = [:]
    ) {
        // Voice telemetry is intentionally metadata-only. In particular, do
        // not persist transcript text, audio/SDP, auth material, or protocol
        // response bodies even when a call site supplies them for debugging.
        var record = sanitizedFields(fields)
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
        fileWriter.enqueue(line)
    }

    static func encodedJSON<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else {
            return "<encoding failed>"
        }
        return text
    }

}

/// Serializes voice log persistence away from the main actor. The queue keeps
/// event order intact while allowing telemetry call sites to return without
/// waiting on directory, metadata, rotation, or file-write I/O.
final class CodexVoiceLogFileWriter: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.slopware.codexcore.voice-log",
        qos: .utility
    )
    private let preferredURL: URL
    private let fallbackURL: URL
    private let maximumFileSize: Int
    private let logger: Logger
    private var activeURL: URL

    init(
        preferredURL: URL,
        fallbackURL: URL,
        maximumFileSize: Int,
        logger: Logger
    ) {
        self.preferredURL = preferredURL
        self.fallbackURL = fallbackURL
        self.maximumFileSize = maximumFileSize
        self.logger = logger
        self.activeURL = preferredURL
    }

    var fileURL: URL {
        queue.sync { activeURL }
    }

    func enqueue(_ line: String) {
        queue.async { [self] in
            let candidates = activeURL == fallbackURL
                ? [fallbackURL]
                : [preferredURL, fallbackURL]
            var lastError: Error?
            for candidate in candidates {
                do {
                    try append(line, to: candidate)
                    activeURL = candidate
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
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
    }

    private func append(_ line: String, to destination: URL) throws {
        let manager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        if manager.fileExists(atPath: destination.path),
           let size = try manager.attributesOfItem(
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
