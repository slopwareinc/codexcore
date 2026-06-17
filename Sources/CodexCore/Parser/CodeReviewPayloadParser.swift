import Foundation

enum CodeReviewPayloadParser {
    static func parse(text: String) -> ConversationCodeReviewData? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}"), let parsed = parseJSON(trimmed) {
            return parsed
        }

        for candidate in extractFencedJSONCandidates(trimmed) {
            if let parsed = parseJSON(candidate) {
                return parsed
            }
        }

        for candidate in extractJSONObjectCandidates(trimmed) {
            if let parsed = parseJSON(candidate) {
                return parsed
            }
        }

        return nil
    }

    private static let priorityRegex = try! NSRegularExpression(
        pattern: "(?i)^\\[(p[0-3])\\]\\s*",
        options: []
    )

    private struct RawFinding: Decodable {
        let title: String
        let body: String
        let confidence_score: Double
        let priority: Int?
        let code_location: RawCodeLocation?
    }

    private struct RawCodeLocation: Decodable {
        let absolute_file_path: String
        let line_range: RawLineRange?
    }

    private struct RawLineRange: Decodable {
        let start: Int
        let end: Int
    }

    private struct RawPayload: Decodable {
        let findings: [RawFinding]
        let overall_correctness: String?
        let overall_explanation: String?
        let overall_confidence_score: Double?
    }

    private static func parseJSON(_ text: String) -> ConversationCodeReviewData? {
        guard let data = text.data(using: .utf8) else { return nil }
        guard let raw = try? JSONDecoder().decode(RawPayload.self, from: data) else {
            return nil
        }

        let findings = raw.findings.compactMap(parseFinding)
        guard !findings.isEmpty else { return nil }

        return ConversationCodeReviewData(
            findings: findings,
            overallCorrectness: raw.overall_correctness,
            overallExplanation: raw.overall_explanation?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? raw.overall_explanation : nil,
            overallConfidenceScore: raw.overall_confidence_score
        )
    }

    private static func parseFinding(_ finding: RawFinding) -> ConversationCodeReviewFinding? {
        let trimmedTitle = finding.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = finding.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty && !trimmedBody.isEmpty else { return nil }

        let range = NSRange(location: 0, length: trimmedTitle.utf16.count)
        let inferredPriority = priorityRegex.firstMatch(in: trimmedTitle, options: [], range: range).flatMap { match -> Int? in
            guard let pRange = Range(match.range(at: 1), in: trimmedTitle) else { return nil }
            return Int(trimmedTitle[pRange].lowercased().replacingOccurrences(of: "p", with: ""))
        }
        let normalizedTitle = priorityRegex.stringByReplacingMatches(
            in: trimmedTitle,
            options: [],
            range: range,
            withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        return ConversationCodeReviewFinding(
            title: normalizedTitle.isEmpty ? trimmedTitle : normalizedTitle,
            body: trimmedBody,
            confidenceScore: finding.confidence_score,
            priority: finding.priority ?? inferredPriority,
            codeLocation: finding.code_location.map(parseLocation)
        )
    }

    private static func parseLocation(_ location: RawCodeLocation) -> ConversationCodeReviewLocation {
        let range = location.line_range.map {
            ConversationCodeReviewLineRange(start: $0.start, end: max($0.start, $0.end))
        }
        return ConversationCodeReviewLocation(
            absoluteFilePath: normalizePath(location.absolute_file_path),
            lineRange: range
        )
    }

    private static func extractFencedJSONCandidates(_ text: String) -> [String] {
        var candidates: [String] = []
        for fence in MarkdownFence.parseAll(in: text) {
            appendJSONCandidates(
                from: fence.content,
                language: fence.language.lowercased(),
                to: &candidates
            )
        }
        return candidates
    }

    private static func appendJSONCandidates(from content: String, language: String, to candidates: inout [String]) {
        guard language.isEmpty || language == "json" else { return }

        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedContent.hasPrefix("{") && trimmedContent.hasSuffix("}") {
            candidates.append(trimmedContent)
        } else {
            candidates.append(contentsOf: extractJSONObjectCandidates(trimmedContent))
        }
    }

    private static func extractJSONObjectCandidates(_ text: String) -> [String] {
        let bytes = Array(text.utf8)
        var startIndex = 0
        var candidates: [String] = []

        while let relativeStart = text[text.index(text.startIndex, offsetBy: startIndex)...].firstIndex(of: "{") {
            let absoluteStart = text.distance(from: text.startIndex, to: relativeStart)
            var depth = 0
            var inString = false
            var isEscaped = false

            for index in absoluteStart..<bytes.count {
                let byte = bytes[index]
                if inString {
                    if isEscaped {
                        isEscaped = false
                        continue
                    }
                    if byte == 92 {
                        isEscaped = true
                    } else if byte == 34 {
                        inString = false
                    }
                    continue
                }

                if byte == 34 {
                    inString = true
                } else if byte == 123 {
                    depth += 1
                } else if byte == 125 {
                    if depth == 0 {
                        break
                    }
                    depth -= 1
                    if depth == 0 {
                        let startIdx = text.index(text.startIndex, offsetBy: absoluteStart)
                        let endIdx = text.index(text.startIndex, offsetBy: index)
                        candidates.append(String(text[startIdx...endIdx]))
                        break
                    }
                }
            }

            startIndex = absoluteStart + 1
        }

        return candidates
    }

    private static func normalizePath(_ path: String) -> String {
        var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
        if normalized.isEmpty { return "" }

        if normalized.hasPrefix("//?/") {
            normalized = String(normalized.dropFirst(4))
        } else if normalized.hasPrefix("/?/") {
            normalized = String(normalized.dropFirst(3))
        }

        let lower = normalized.lowercased()
        for prefix in ["//wsl$/", "//wsl.localhost/"] {
            if lower.hasPrefix(prefix) {
                let remainder = normalized.dropFirst(prefix.count)
                if let firstSlash = remainder.firstIndex(of: "/") {
                    return collapseRepeatedSlashes(String(remainder[firstSlash...]))
                }
                return "/"
            }
        }

        let driveRegex = try! NSRegularExpression(pattern: "(?i)^([a-z]):/(.*)$", options: [])
        let range = NSRange(location: 0, length: normalized.utf16.count)
        if let match = driveRegex.firstMatch(in: normalized, options: [], range: range),
           let dRange = Range(match.range(at: 1), in: normalized),
           let rRange = Range(match.range(at: 2), in: normalized) {
            let drive = normalized[dRange].lowercased()
            let rest = normalized[rRange]
            return collapseRepeatedSlashes("/mnt/\(drive)/\(rest)")
        }

        if normalized.hasPrefix("//") {
            return "//\(collapseRepeatedSlashes(String(normalized.dropFirst(2))))"
        }

        return collapseRepeatedSlashes(normalized)
    }

    private static func collapseRepeatedSlashes(_ path: String) -> String {
        var collapsed = ""
        var previousWasSlash = false

        for char in path {
            if char == "/" {
                if !previousWasSlash {
                    collapsed.append(char)
                }
                previousWasSlash = true
            } else {
                collapsed.append(char)
                previousWasSlash = false
            }
        }

        return collapsed
    }
}
