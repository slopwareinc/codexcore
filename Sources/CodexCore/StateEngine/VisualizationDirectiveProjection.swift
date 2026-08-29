import Foundation

struct CodexVisualizationDirective: Sendable, Equatable {
    let path: String
    let title: String?
    let isWide: Bool
}

enum CodexVisualizationDirectiveProjection {
    static func directives(in text: String) -> [CodexVisualizationDirective] {
        CodexInlineDirectiveParser.split(text: text).compactMap { partition in
            guard let directive = partition.directive,
                  directive.name == "codex-inline-vis" else { return nil }
            return make(
                path: directive.attributes["path"] ?? directive.attributes["file"],
                title: directive.attributes["title"],
                isWide: directive.attributes["mode"] == "wide"
            )
        }
    }

    static func isVisualizationHTMLPath(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard normalized.lowercased().hasSuffix(".html") else { return false }
        return normalized.contains("/visualizations/")
            || normalized.hasPrefix("visualizations/")
            || normalized.hasPrefix(".codex/visualizations/")
            || normalized.hasPrefix(".codexcore/visualizations/")
    }

    private static func make(
        path: String?,
        title: String?,
        isWide: Bool
    ) -> CodexVisualizationDirective? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              path.utf8.count <= 4_096,
              !path.contains("\n"),
              !path.contains("\r"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard name.range(
            of: #"^[a-z0-9]+(?:-[a-z0-9]+)*\.html$"#,
            options: .regularExpression
        ) != nil else { return nil }
        let boundedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(
            path: path,
            title: boundedTitle?.utf8.count ?? 0 <= 512 ? boundedTitle?.nilIfBlank : nil,
            isWide: isWide
        )
    }
}
