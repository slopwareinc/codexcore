import Foundation
import CodexCore

public struct CodexStatusPanelRateLimitRow: Identifiable, Equatable, Sendable {
    public var id: String { title }
    public var title: String
    public var usedPercent: Int?
    public var resetLabel: String

    public init(title: String, usedPercent: Int?, resetLabel: String) {
        self.title = title
        self.usedPercent = usedPercent
        self.resetLabel = resetLabel
    }

    public var usedLabel: String {
        usedPercent.map { "\($0)% used" } ?? "Usage unavailable"
    }

    public var fraction: Double {
        guard let usedPercent else { return 0 }
        return min(max(Double(usedPercent) / 100, 0), 1)
    }
}

public struct CodexStatusPanelModel: Equatable, Sendable {
    public static let noticeKind = "codex.status.panel"

    public var sessionID: String
    public var connectionLabel: String
    public var contextUsedLabel: String
    public var contextLeftLabel: String
    public var contextFraction: Double
    public var rateLimitRows: [CodexStatusPanelRateLimitRow]

    public init(
        sessionID: String,
        connectionLabel: String,
        contextUsedLabel: String,
        contextLeftLabel: String,
        contextFraction: Double,
        rateLimitRows: [CodexStatusPanelRateLimitRow]
    ) {
        self.sessionID = sessionID
        self.connectionLabel = connectionLabel
        self.contextUsedLabel = contextUsedLabel
        self.contextLeftLabel = contextLeftLabel
        self.contextFraction = min(max(contextFraction, 0), 1)
        self.rateLimitRows = rateLimitRows
    }

    public init(context: CodexChatStatusSummaryContext, rateLimits: CodexSchemaRateLimitSnapshot?) {
        let contextUsage = Self.contextUsage(from: context.tokenUsageSummary)
        let rows = Self.rateLimitRows(from: rateLimits)
        self.init(
            sessionID: context.currentThreadID?.nilIfBlank ?? "preparing",
            connectionLabel: context.connectionLabel,
            contextUsedLabel: contextUsage.usedLabel,
            contextLeftLabel: contextUsage.leftLabel,
            contextFraction: contextUsage.fraction,
            rateLimitRows: rows.isEmpty ? Self.fallbackRateLimitRows(summary: context.rateLimitSummary) : rows
        )
    }

    private var encodedMetadata: [String] {
        [
            "session=\(sessionID)",
            "connection=\(connectionLabel)",
            "contextUsed=\(contextUsedLabel)",
            "contextLeft=\(contextLeftLabel)",
            "contextFraction=\(contextFraction)"
        ] + rateLimitRows.map { row in
            "rate=\(row.title)|\(row.usedPercent.map(String.init) ?? "")|\(row.resetLabel)"
        }
    }

    private static func contextUsage(from summary: String?) -> (usedLabel: String, leftLabel: String, fraction: Double) {
        guard let summary,
              let match = summary.firstMatch(of: #/(\d+)\s*/\s*(\d+)\s+tokens/#),
              let used = Int(match.1),
              let limit = Int(match.2),
              limit > 0 else {
            return ("Context unavailable", "Unknown left", 0)
        }
        let left = max(0, limit - used)
        return ("\(used) tokens used", "\(left) tokens left", Double(used) / Double(limit))
    }

    private static func rateLimitRows(from snapshot: CodexSchemaRateLimitSnapshot?) -> [CodexStatusPanelRateLimitRow] {
        guard let snapshot else { return [] }
        return [
            snapshot.primary.map { rateLimitRow(title: title(for: $0, fallback: "5h limit"), window: $0) },
            snapshot.secondary.map { rateLimitRow(title: title(for: $0, fallback: "7d limit"), window: $0) }
        ].compactMap(\.self)
    }

    private static func fallbackRateLimitRows(summary: String?) -> [CodexStatusPanelRateLimitRow] {
        guard let summary = summary?.nilIfBlank else {
            return [unavailableRateLimitRow(title: "5h limit"), unavailableRateLimitRow(title: "7d limit")]
        }
        return [CodexStatusPanelRateLimitRow(title: "Rate limits", usedPercent: nil, resetLabel: summary)]
    }

    private static func rateLimitRow(title: String, window: CodexSchemaRateLimitWindow) -> CodexStatusPanelRateLimitRow {
        CodexStatusPanelRateLimitRow(title: title, usedPercent: window.usedPercent, resetLabel: resetLabel(for: window))
    }

    private static func unavailableRateLimitRow(title: String) -> CodexStatusPanelRateLimitRow {
        CodexStatusPanelRateLimitRow(title: title, usedPercent: nil, resetLabel: "Reset unavailable")
    }

    private static func title(for window: CodexSchemaRateLimitWindow, fallback: String) -> String {
        guard let minutes = window.windowDurationMins else { return fallback }
        switch minutes {
        case 300:
            return "5h limit"
        case 10_080:
            return "7d limit"
        default:
            if minutes % 60 == 0 { return "\(minutes / 60)h limit" }
            return "\(minutes)m limit"
        }
    }

    private static func resetLabel(for window: CodexSchemaRateLimitWindow) -> String {
        guard let description = CodexRateLimitWindowText.description(for: window) else {
            return "Reset unavailable"
        }
        return description.prefix(1).uppercased() + description.dropFirst()
    }

    private static func keyValue(_ metadata: String) -> (String, String)? {
        let pieces = metadata.split(separator: "=", maxSplits: 1).map(String.init)
        guard pieces.count == 2, pieces[0] != "rate" else { return nil }
        return (pieces[0], pieces[1])
    }

    private static func rateRow(_ metadata: String) -> CodexStatusPanelRateLimitRow? {
        guard metadata.hasPrefix("rate=") else { return nil }
        let payload = String(metadata.dropFirst(5))
        let pieces = payload.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 3 else { return nil }
        return CodexStatusPanelRateLimitRow(
            title: pieces[0],
            usedPercent: Int(pieces[1]),
            resetLabel: pieces[2]
        )
    }
}

public struct CodexMCPStatusPanelServerRow: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var displayName: String
    public var enabledLabel: String
    public var authLabel: String
    public var startupLabel: String
    public var inventorySummary: String

    public init(name: String, displayName: String, enabledLabel: String, authLabel: String, startupLabel: String, inventorySummary: String) {
        self.name = name
        self.displayName = displayName
        self.enabledLabel = enabledLabel
        self.authLabel = authLabel
        self.startupLabel = startupLabel
        self.inventorySummary = inventorySummary
    }

    public init(server: CodexMCPServerStatus) {
        self.init(
            name: server.name,
            displayName: server.displayName,
            enabledLabel: server.startupStatus == "disabled" ? "Disabled" : "Enabled",
            authLabel: server.authStatusLabel,
            startupLabel: server.error?.nilIfBlank ?? server.startupStatus?.nilIfBlank ?? "ready",
            inventorySummary: server.inventorySummary
        )
    }
}

public struct CodexMCPStatusPanelModel: Equatable, Sendable {
    public static let noticeKind = "codex.mcp.panel"

    public var title: String
    public var detail: String
    public var rows: [CodexMCPStatusPanelServerRow]

    public init(title: String = "MCP servers", detail: String, rows: [CodexMCPStatusPanelServerRow]) {
        self.title = title
        self.detail = detail
        self.rows = rows
    }

    public init(servers: [CodexMCPServerStatus], isLoading: Bool, errorMessage: String?) {
        if isLoading {
            self.init(detail: "Loading server status...", rows: [])
        } else if let errorMessage = errorMessage?.nilIfBlank {
            self.init(detail: errorMessage, rows: [])
        } else if servers.isEmpty {
            self.init(detail: "No MCP servers configured", rows: [])
        } else {
            self.init(detail: "\(servers.count) configured", rows: servers.map(CodexMCPStatusPanelServerRow.init(server:)))
        }
    }

    private var encodedMetadata: [String] {
        ["detail=\(detail)"] + rows.map { row in
            "server=\(row.name)|\(row.displayName)|\(row.enabledLabel)|\(row.authLabel)|\(row.startupLabel)|\(row.inventorySummary)"
        }
    }

    private static func keyValue(_ metadata: String) -> (String, String)? {
        let pieces = metadata.split(separator: "=", maxSplits: 1).map(String.init)
        guard pieces.count == 2, pieces[0] != "server" else { return nil }
        return (pieces[0], pieces[1])
    }

    private static func serverRow(_ metadata: String) -> CodexMCPStatusPanelServerRow? {
        guard metadata.hasPrefix("server=") else { return nil }
        let payload = String(metadata.dropFirst(7))
        let pieces = payload.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 6 else { return nil }
        return CodexMCPStatusPanelServerRow(
            name: pieces[0],
            displayName: pieces[1],
            enabledLabel: pieces[2],
            authLabel: pieces[3],
            startupLabel: pieces[4],
            inventorySummary: pieces[5]
        )
    }
}

public struct CodexStructuredPanelDismissalState: Equatable, Sendable {
    public private(set) var dismissedMessageIDs: Set<UUID>

    public init(dismissedMessageIDs: Set<UUID> = []) {
        self.dismissedMessageIDs = dismissedMessageIDs
    }

    public mutating func dismiss(messageID: UUID) {
        dismissedMessageIDs.insert(messageID)
    }

    public func isVisible(messageID: UUID) -> Bool {
        !dismissedMessageIDs.contains(messageID)
    }
}
