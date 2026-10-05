import CodexCore
import Foundation

/// Readable MCP activity facts adapted from T3 Code's CodexToolPresentation.
/// Metadata affects display only; raw tool inputs/results and MCP App identity
/// stay separate. The projection performs no icon lookup, fetch, or navigation.
public struct CodexMCPToolPresentationV2: Sendable, Equatable {
    public var sourceName: String
    public var title: String
    public var symbolName: String
    public var pageURL: String?

    public init(sourceName: String, title: String, symbolName: String = "puzzlepiece.extension", pageURL: String? = nil) {
        self.sourceName = sourceName
        self.title = title
        self.symbolName = symbolName
        self.pageURL = pageURL
    }

    static func project(payload: [String: CodexJSONValue]) -> Self {
        let app = payload["appContext"]?.objectValue ?? [:]
        let metadata = payload["result"]?.objectValue?["_meta"]?.objectValue ?? [:]
        let surface = metadata["codex/toolSurface"]?.objectValue ?? [:]
        let source = metadata["source"]?.objectValue ?? [:]
        let server = displayText(payload["server"]) ?? "Tool"
        let tool = displayText(payload["tool"]) ?? "Tool"
        let title = displayText(app["actionName"]) ?? readableName(tool)

        switch surface["kind"] {
        case .string("browserUse"):
            let name = browserName(app["appName"])
                ?? browserName(surface["browserFamily"])
                ?? browserName(surface["backend"]) ?? "Browser"
            let screenshot = surface["screenshot"]?.objectValue ?? [:]
            let browserUse = metadata["browser_use"]?.objectValue ?? [:]
            let openTabs: [CodexJSONValue]
            if case .array(let tabs) = surface["openTabs"] { openTabs = tabs } else { openTabs = [] }
            let latestTabURL = openTabs.reversed().lazy.compactMap { httpURL($0.objectValue?["url"]) }.first
            return .init(
                sourceName: name, title: title, symbolName: "globe",
                pageURL: httpURL(screenshot["pageUrl"]) ?? httpURL(browserUse["url"]) ?? latestTabURL
            )
        case .string("computerUse"):
            let nativeApp = surface["app"]?.objectValue ?? [:]
            let args = payload["arguments"]?.objectValue ?? [:]
            let nativeName: String?
            if nativeApp["kind"] == .string("displayName") {
                nativeName = displayText(nativeApp["displayName"])
            } else if nativeApp["kind"] == .string("appId"), let appID = displayText(nativeApp["appId"]) {
                nativeName = knownAppName(appID)
            } else { nativeName = nil }
            return .init(
                sourceName: displayText(app["appName"])
                    ?? displayText(args["appName"]) ?? displayText(args["application"])
                    ?? displayText(args["app"]) ?? nativeName ?? "Computer Use",
                title: title, symbolName: "desktopcomputer"
            )
        default:
            return .init(
                sourceName: displayText(app["appName"]) ?? displayText(source["name"]) ?? readableName(server),
                title: title
            )
        }
    }

    private static func displayText(_ value: CodexJSONValue?) -> String? {
        guard case .string(let raw) = value, raw.utf8.count <= 1_024 else { return nil }
        let text = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty, text.count <= 160 else { return nil }
        return text
    }

    private static func readableName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    }

    private static func httpURL(_ value: CodexJSONValue?) -> String? {
        guard case .string(let raw) = value, raw.utf8.count <= 4_096,
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let parts = URLComponents(string: raw),
              parts.scheme?.lowercased() == "http" || parts.scheme?.lowercased() == "https",
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil,
              let url = parts.url?.absoluteString, url.utf8.count <= 4_096 else { return nil }
        return url
    }

    private static func browserName(_ value: CodexJSONValue?) -> String? {
        guard let name = displayText(value) else { return nil }
        let lower = name.lowercased()
        if lower.contains("chrome") || lower == "chromium" { return "Chrome" }
        if lower.contains("edge") { return "Microsoft Edge" }
        if lower.contains("firefox") { return "Firefox" }
        if lower.contains("safari") { return "Safari" }
        if lower == "arc" || lower.contains("arc browser") { return "Arc" }
        if lower == "iab" || lower.contains("in-app") { return "Browser" }
        return name
    }

    private static func knownAppName(_ appID: String) -> String? {
        switch appID.lowercased() {
        case "com.apple.finder": "Finder"
        case "com.apple.safari": "Safari"
        case "com.google.chrome": "Chrome"
        case "com.microsoft.edgemac": "Microsoft Edge"
        case "org.mozilla.firefox": "Firefox"
        case "company.thebrowser.browser": "Arc"
        default: nil
        }
    }
}
