import Foundation

public enum CodexOperationDiagnosticKind: Sendable, Hashable {
    case warning
    case unknownMethod
    case unmatchedOperation
    case unmatchedResponse
    case lateServerRequestResolution
    case malformedOperation
    case bufferOverflow
}

public enum CodexDiagnosticSeverity: String, Codable, Sendable, Hashable {
    case info
    case warning
    case error
}

/// Bounded metadata for a protocol frame that could not be applied normally.
/// Raw notification parameters are deliberately never retained here.
public struct CodexOperationDiagnostic: Sendable, Equatable {
    public let cursor: CodexWireCursor
    public let kind: CodexOperationDiagnosticKind
    public let severity: CodexDiagnosticSeverity
    public let method: String
    public let threadID: ThreadID?
    public let keyDescription: String?
    public let detail: String?
    public let content: CodexProtocolDiagnosticContent?

    public var id: CodexWireCursor { cursor }

    public init(
        cursor: CodexWireCursor,
        kind: CodexOperationDiagnosticKind,
        severity: CodexDiagnosticSeverity? = nil,
        method: String,
        threadID: ThreadID? = nil,
        keyDescription: String? = nil,
        detail: String? = nil,
        content: CodexProtocolDiagnosticContent? = nil
    ) {
        self.cursor = cursor
        self.kind = kind
        self.severity = severity ?? kind.defaultSeverity
        self.method = method
        self.threadID = threadID
        self.keyDescription = keyDescription
        self.detail = detail
        self.content = content
    }
}

public struct CodexOperationDiagnosticsSnapshot: Sendable, Equatable {
    public let entries: [CodexOperationDiagnostic]
    public let totalRecordedCount: UInt64
    public let evictedCount: UInt64

    public init(
        entries: [CodexOperationDiagnostic],
        totalRecordedCount: UInt64,
        evictedCount: UInt64
    ) {
        self.entries = entries
        self.totalRecordedCount = totalRecordedCount
        self.evictedCount = evictedCount
    }

    public static let empty = Self(
        entries: [],
        totalRecordedCount: 0,
        evictedCount: 0
    )
}

private extension CodexOperationDiagnosticKind {
    var defaultSeverity: CodexDiagnosticSeverity {
        switch self {
        case .warning:
            .warning
        case .malformedOperation, .bufferOverflow:
            .error
        case .unknownMethod, .unmatchedOperation, .unmatchedResponse,
             .lateServerRequestResolution:
            .info
        }
    }
}

/// Bounded, sanitized diagnostics owned synchronously by `CodexSession`.
/// Raw protocol parameters never enter this ring.
struct CodexProtocolDiagnosticRing {
    struct Limits: Sendable, Hashable {
        let maximumEntries: Int
        let maximumTextUTF8Bytes: Int

        init(maximumEntries: Int = 128, maximumTextUTF8Bytes: Int = 256) {
            precondition(maximumEntries > 0)
            precondition(maximumTextUTF8Bytes > 0)
            self.maximumEntries = maximumEntries
            self.maximumTextUTF8Bytes = maximumTextUTF8Bytes
        }
    }

    let limits: Limits

    private var entries: [CodexOperationDiagnostic?]
    private var head = 0
    private var count = 0
    private var totalRecordedCount: UInt64 = 0
    private var evictedCount: UInt64 = 0

    init(limits: Limits = .init()) {
        self.limits = limits
        self.entries = Array(repeating: nil, count: limits.maximumEntries)
    }

    mutating func record(
        kind: CodexOperationDiagnosticKind,
        method: String,
        cursor: CodexWireCursor,
        keyDescription: String? = nil,
        detail: String? = nil
    ) {
        append(CodexOperationDiagnostic(
            cursor: cursor,
            kind: kind,
            method: truncate(method),
            keyDescription: keyDescription.map(truncate),
            detail: detail.map(truncate)
        ))
    }

    func snapshot() -> CodexOperationDiagnosticsSnapshot {
        var retained: [CodexOperationDiagnostic] = []
        retained.reserveCapacity(count)
        for offset in 0..<count {
            let index = (head + offset) % entries.count
            if let entry = entries[index] {
                retained.append(entry)
            }
        }
        return .init(
            entries: retained,
            totalRecordedCount: totalRecordedCount,
            evictedCount: evictedCount
        )
    }
}

private extension CodexProtocolDiagnosticRing {
    mutating func append(_ diagnostic: CodexOperationDiagnostic) {
        if totalRecordedCount < UInt64.max {
            totalRecordedCount += 1
        }

        if count < entries.count {
            entries[(head + count) % entries.count] = diagnostic
            count += 1
        } else {
            entries[head] = diagnostic
            head = (head + 1) % entries.count
            if evictedCount < UInt64.max {
                evictedCount += 1
            }
        }
    }

    func truncate(_ value: String) -> String {
        guard value.utf8.count > limits.maximumTextUTF8Bytes else { return value }

        var scalars = String.UnicodeScalarView()
        var bytes = 0
        for scalar in value.unicodeScalars {
            let scalarBytes = String(scalar).utf8.count
            guard bytes + scalarBytes <= limits.maximumTextUTF8Bytes else { break }
            scalars.append(scalar)
            bytes += scalarBytes
        }
        return String(scalars)
    }
}
