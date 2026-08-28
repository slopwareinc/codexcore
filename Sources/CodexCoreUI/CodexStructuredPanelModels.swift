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
    public var threadUsage: CodexThreadUsagePresentation?
    public var isLoadingThreadUsage: Bool
    public var threadUsageError: String?

    public init(
        sessionID: String,
        connectionLabel: String,
        contextUsedLabel: String,
        contextLeftLabel: String,
        contextFraction: Double,
        rateLimitRows: [CodexStatusPanelRateLimitRow],
        threadUsage: CodexThreadUsagePresentation? = nil,
        isLoadingThreadUsage: Bool = false,
        threadUsageError: String? = nil
    ) {
        self.sessionID = sessionID
        self.connectionLabel = connectionLabel
        self.contextUsedLabel = contextUsedLabel
        self.contextLeftLabel = contextLeftLabel
        self.contextFraction = min(max(contextFraction, 0), 1)
        self.rateLimitRows = rateLimitRows
        self.threadUsage = threadUsage
        self.isLoadingThreadUsage = isLoadingThreadUsage
        self.threadUsageError = threadUsageError
    }

    public init(
        context: CodexChatStatusSummaryContext,
        rateLimits: CodexSchemaRateLimitSnapshot?,
        threadUsage: CodexSchemaThreadUsage? = nil,
        isLoadingThreadUsage: Bool = false,
        threadUsageError: String? = nil
    ) {
        let contextUsage = Self.contextUsage(from: context.tokenUsageSummary)
        let rows = Self.rateLimitRows(from: rateLimits)
        self.init(
            sessionID: context.currentThreadID?.nilIfBlank ?? "preparing",
            connectionLabel: context.connectionLabel,
            contextUsedLabel: contextUsage.usedLabel,
            contextLeftLabel: contextUsage.leftLabel,
            contextFraction: contextUsage.fraction,
            rateLimitRows: rows.isEmpty ? Self.fallbackRateLimitRows(summary: context.rateLimitSummary) : rows,
            threadUsage: threadUsage.map(CodexThreadUsagePresentation.init),
            isLoadingThreadUsage: isLoadingThreadUsage,
            threadUsageError: threadUsageError
        )
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

}

public struct CodexThreadUsageBreakdownRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var credits: String

    init(group: CodexSchemaThreadUsageBreakdownGroup, index: Int) {
        id = "\(index):\(group.model ?? "unknown"):\(group.reasoningEffort ?? "unknown"):\(group.speed ?? "unknown")"
        title = group.model ?? "Unknown model"
        detail = [
            group.reasoningEffort.map { "\($0) reasoning" },
            group.speed,
            group.totalTokens.map { "\($0) tokens" },
        ].compactMap { $0 }.joined(separator: " · ")
        credits = CodexThreadUsagePresentation.creditsLabel(
            micros: group.estimatedUsageCreditsMicros
        )
    }
}

public struct CodexThreadUsagePresentation: Equatable, Sendable {
    public var threadID: String
    public var creditsLabel: String
    public var usdLabel: String?
    public var groups: [CodexThreadUsageBreakdownRow]

    public init(_ usage: CodexSchemaThreadUsage) {
        threadID = usage.threadID
        creditsLabel = Self.creditsLabel(micros: usage.estimatedUsageCreditsMicros)
        usdLabel = usage.estimatedUsageUsdMicros.map {
            "$\(Self.decimalMicros($0)) estimated"
        }
        groups = usage.groups.enumerated().map {
            CodexThreadUsageBreakdownRow(group: $0.element, index: $0.offset)
        }
    }

    static func creditsLabel(micros: Int) -> String {
        "\(decimalMicros(micros)) credits"
    }

    static func decimalMicros(_ micros: Int) -> String {
        let negative = micros < 0
        let magnitude = micros.magnitude
        let whole = magnitude / 1_000_000
        let remainder = magnitude % 1_000_000
        let sign = negative ? "-" : ""
        guard remainder != 0 else { return "\(sign)\(whole)" }
        let fraction = String(format: "%06llu", remainder)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
        return "\(sign)\(whole).\(fraction)"
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
            enabledLabel: server.enabled.map { $0 ? "Enabled" : "Disabled" } ?? "Configuration unknown",
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

}
