import CodexCore
import Foundation

final class ToolCallMarkdownParser {
    private static let bulletRegex = makeRegex(pattern: "^(?:[-*•]\\s+|\\d+\\.\\s+)")

    func parse(text: String) -> [ToolCallCardModel] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let blocks = splitH3Blocks(trimmed)
        var cards: [ToolCallCardModel] = []

        for block in blocks {
            if let card = parseSingleBlock(block) {
                cards.append(card)
            }
        }
        return cards
    }

    // MARK: - Private Implementations

    private struct RawSection {
        var label: String?
        var content: String
    }

    private let leadingKeySet: Set<String> = [
        "status", "tool", "duration", "path", "kind", "query", "targets", "exit code", "directory", "approval", "error", "cwd", "working directory"
    ]

    private let namedSectionSet: Set<String> = [
        "command", "arguments", "result", "output", "targets", "prompt", "action", "progress", "error"
    ]

    private func isLeadingKey(_ normalized: String) -> Bool {
        leadingKeySet.contains(normalized)
    }

    private func isNamedSection(_ normalized: String) -> Bool {
        namedSectionSet.contains(normalized)
    }

    private func normalizeToken(_ s: String) -> String {
        let lower = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let replaced = lower.replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
        return replaced.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func splitH3Blocks(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [String] = []
        var current: [String] = []
        var fenceTracker = MarkdownFenceTracker()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let inFence = fenceTracker.consume(trimmedLine: trimmed)

            if !inFence && trimmed.hasPrefix("### ") && !current.isEmpty {
                let content = current.joined(separator: "\n")
                let c = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !c.isEmpty {
                    blocks.append(c)
                }
                current.removeAll()
            }
            current.append(line)
        }

        if !current.isEmpty {
            let content = current.joined(separator: "\n")
            let c = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !c.isEmpty {
                blocks.append(c)
            }
        }

        return blocks
    }

    private func parseSystemEnvelope(_ text: String) -> (title: String, body: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("### ") else { return nil }

        guard let firstNewlineRange = trimmed.range(of: "\n") else {
            let title = trimmed.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : (title, "")
        }

        let title = trimmed[trimmed.startIndex..<firstNewlineRange.lowerBound]
            .dropFirst(4)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed[firstNewlineRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return title.isEmpty ? nil : (title, String(body))
    }

    private func parseKeyValueLine(_ line: String) -> (key: String, value: String)? {
        guard let separatorIndex = line.firstIndex(of: ":") else { return nil }
        let key = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private func parseSectionHeader(_ line: String) -> (key: String, value: String)? {
        guard let (key, value) = parseKeyValueLine(line) else { return nil }
        if isNamedSection(normalizeToken(key)) {
            return (key, value)
        }
        return nil
    }

    private func splitNamedSections(_ text: String) -> [RawSection] {
        let lines = text.components(separatedBy: "\n")
        var sections: [RawSection] = []
        var currentLabel: String? = nil
        var buffer: [String] = []
        var sawNamedSection = false
        var fenceTracker = MarkdownFenceTracker()

        func flush() {
            let content = buffer.joined(separator: "\n")
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty || currentLabel != nil {
                sections.append(RawSection(label: currentLabel, content: trimmed))
            }
            buffer.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let inFence = fenceTracker.consume(trimmedLine: trimmed)

            if !inFence {
                if let (label, inlineValue) = parseSectionHeader(trimmed) {
                    sawNamedSection = true
                    flush()
                    currentLabel = label
                    if !inlineValue.isEmpty {
                        buffer.append(inlineValue)
                    }
                    continue
                }
            }

            buffer.append(line)
        }
        flush()

        if !sawNamedSection {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return [RawSection(label: nil, content: trimmed)]
        }

        return sections
    }

    private func splitTopLevel(_ text: String, separator: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var chunks: [String] = []
        var current: [String] = []
        var fenceTracker = MarkdownFenceTracker()

        func flush() {
            let content = current.joined(separator: "\n")
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                chunks.append(trimmed)
            }
            current.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let inFence = fenceTracker.consume(trimmedLine: trimmed)

            if !inFence && trimmed == separator {
                flush()
                continue
            }
            current.append(line)
        }
        flush()

        return chunks
    }

    private func parseTargetItems(_ content: String) -> [String] {
        var items: [String] = []
        for rawLine in content.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let range = NSRange(location: 0, length: line.utf16.count)
            let deBulleted = Self.bulletRegex.stringByReplacingMatches(in: line, options: [], range: range, withTemplate: "")

            for candidate in deBulleted.components(separatedBy: ",") {
                let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty {
                    items.append(normalized)
                }
            }
        }
        return items
    }

    private func parseFileChangeSections(_ remainder: String) -> (sections: [ToolCallSection], paths: [String]) {
        let chunks = splitTopLevel(remainder, separator: "---")
        var sections: [ToolCallSection] = []
        var paths: [String] = []

        for (idx, chunk) in chunks.enumerated() {
            let lines = chunk.components(separatedBy: "\n")
            var cursor = 0
            var entryMetadata: [ToolCallKeyValue] = []

            while cursor < lines.count {
                let trimmed = lines[cursor].trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    cursor += 1
                    break
                }
                if let (key, value) = parseKeyValueLine(trimmed) {
                    let nk = normalizeToken(key)
                    if nk == "path" || nk == "kind" {
                        if nk == "path" && !value.isEmpty {
                            paths.append(value)
                        }
                        entryMetadata.append(ToolCallKeyValue(key: key, value: value))
                        cursor += 1
                        continue
                    }
                }
                break
            }

            if !entryMetadata.isEmpty {
                sections.append(.kv(label: "Change \(idx + 1)", entries: entryMetadata))
            }

            let content = lines[cursor...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }

            if let fence = MarkdownFence.parseSingle(content) {
                let language = normalizeToken(fence.language)
                if language == "diff" {
                    sections.append(.diff(label: "Diff", content: fence.content))
                } else if language == "json" {
                    sections.append(.json(label: "Content", content: fence.content))
                } else if language == "text" || language.isEmpty {
                    sections.append(.text(label: "Content", content: fence.content))
                } else {
                    sections.append(.code(label: "Content", language: fence.language, content: fence.content))
                }
            } else {
                sections.append(.text(label: "Content", content: content))
            }
        }

        return (sections, paths)
    }

    private func appendSection(
        raw: RawSection,
        kind: ToolCallKind,
        primary: inout [ToolCallSection],
        aux: inout [ToolCallSection]
    ) {
        let content = raw.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        if let label = raw.label {
            let capitalized = capitalizeFirst(label)
            let nk = normalizeToken(label)
            switch nk {
            case "command":
                primary.append(makeCodeLike(label: "Command", content: content, fallbackLanguage: "bash"))
            case "arguments":
                primary.append(makeJsonLike(label: "Arguments", content: content))
            case "result":
                primary.append(makeJsonLike(label: "Result", content: content))
            case "output":
                primary.append(makeOutputLike(label: "Output", content: content))
            case "action":
                primary.append(makeJsonLike(label: "Action", content: content))
            case "prompt":
                primary.append(.text(label: "Prompt", content: content))
            case "progress":
                let items = content.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !items.isEmpty {
                    aux.append(.list(label: "Progress", items: items))
                }
            case "targets":
                let items = parseTargetItems(content)
                if !items.isEmpty {
                    aux.append(.list(label: "Targets", items: items))
                } else {
                    primary.append(.text(label: "Targets", content: content))
                }
            case "error":
                primary.append(makeOutputLike(label: "Error", content: content))
            default:
                primary.append(.text(label: capitalized, content: content))
            }
            return
        }

        // Unlabeled section
        switch kind {
        case .commandOutput:
            primary.append(makeOutputLike(label: "Output", content: content))
        case .fileDiff:
            if let fence = MarkdownFence.parseSingle(content) {
                if normalizeToken(fence.language) == "diff" {
                    primary.append(.diff(label: "Diff", content: fence.content))
                } else {
                    primary.append(.diff(label: "Diff", content: content))
                }
            } else {
                primary.append(.diff(label: "Diff", content: content))
            }
        case .mcpToolProgress:
            let items = content.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !items.isEmpty {
                aux.append(.list(label: "Progress", items: items))
            }
        default:
            if let fence = MarkdownFence.parseSingle(content) {
                let language = normalizeToken(fence.language)
                if language == "json" {
                    primary.append(.json(label: "Details", content: fence.content))
                } else if language == "diff" {
                    primary.append(.diff(label: "Diff", content: fence.content))
                } else if language == "text" || language.isEmpty {
                    primary.append(.text(label: "Details", content: fence.content))
                } else {
                    primary.append(.code(label: "Details", language: fence.language, content: fence.content))
                }
            } else {
                primary.append(.text(label: "Details", content: content))
            }
        }
    }

    private func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first else { return "" }
        return first.uppercased() + s.dropFirst()
    }

    private func makeCodeLike(label: String, content: String, fallbackLanguage: String) -> ToolCallSection {
        if let fence = MarkdownFence.parseSingle(content) {
            let language = fence.language.isEmpty ? fallbackLanguage : fence.language
            return .code(label: label, language: language, content: fence.content)
        }
        return .code(label: label, language: fallbackLanguage, content: content)
    }

    private func makeJsonLike(label: String, content: String) -> ToolCallSection {
        if let fence = MarkdownFence.parseSingle(content) {
            let lang = normalizeToken(fence.language)
            if lang == "json" || lang.isEmpty {
                return .json(label: label, content: fence.content)
            }
            if lang == "diff" {
                return .diff(label: label, content: fence.content)
            }
            return .code(label: label, language: fence.language, content: fence.content)
        }
        if looksLikeJson(content) {
            return .json(label: label, content: content)
        }
        return .text(label: label, content: content)
    }

    private func makeOutputLike(label: String, content: String) -> ToolCallSection {
        if let fence = MarkdownFence.parseSingle(content) {
            let lang = normalizeToken(fence.language)
            if lang == "diff" {
                return .diff(label: label, content: fence.content)
            }
            if lang == "json" {
                return .json(label: label, content: fence.content)
            }
            if lang == "text" || lang.isEmpty {
                return .text(label: label, content: fence.content)
            }
            return .code(label: label, language: fence.language, content: fence.content)
        }
        return .text(label: label, content: content)
    }

    private func looksLikeJson(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return false }
        guard "{[\"-0123456789tfn".contains(first) else { return false }

        guard let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) != nil
    }

    private struct ParsedBody {
        let metadata: [ToolCallKeyValue]
        let primarySections: [ToolCallSection]
        let auxSections: [ToolCallSection]
        let filePaths: [String]

        func metadataValue(forKey key: String) -> String? {
            let searchKey = Self.normalizedMetadataKey(key)
            return metadata.first(where: {
                Self.normalizedMetadataKey($0.key) == searchKey
            })?.value
        }

        private static func normalizedMetadataKey(_ key: String) -> String {
            key.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func parseBody(body: String, kind: ToolCallKind) -> ParsedBody {
        let lines = body.components(separatedBy: "\n")
        var index = 0
        var metadata: [ToolCallKeyValue] = []
        var filePaths: [String] = []
        var auxSections: [ToolCallSection] = []

        // Parse leading metadata
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if metadata.isEmpty {
                    index += 1
                    continue
                }
                index += 1
                break
            }
            if parseSectionHeader(trimmed) != nil {
                break
            }
            guard let (key, value) = parseKeyValueLine(trimmed) else {
                break
            }
            let nk = normalizeToken(key)
            guard isLeadingKey(nk) else {
                break
            }

            if nk == "targets" {
                var targetContent = value
                if targetContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    var cursor = index + 1
                    var extraLines: [String] = []
                    while cursor < lines.count {
                        let nextTrimmed = lines[cursor].trimmingCharacters(in: .whitespacesAndNewlines)
                        if nextTrimmed.isEmpty || parseSectionHeader(nextTrimmed) != nil {
                            break
                        }
                        extraLines.append(nextTrimmed)
                        cursor += 1
                    }
                    if !extraLines.isEmpty {
                        targetContent = extraLines.joined(separator: "\n")
                        index = cursor - 1
                    }
                }
                let items = parseTargetItems(targetContent)
                if !items.isEmpty {
                    auxSections.append(.list(label: "Targets", items: items))
                }
            } else {
                if nk == "path" && !value.isEmpty {
                    filePaths.append(value)
                }
                metadata.append(ToolCallKeyValue(key: key, value: value))
            }
            index += 1
        }

        let remainder = lines[index...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var primarySections: [ToolCallSection] = []

        if !remainder.isEmpty {
            switch kind {
            case .fileChange:
                let (secs, paths) = parseFileChangeSections(remainder)
                primarySections.append(contentsOf: secs)
                filePaths.append(contentsOf: paths)
            default:
                let rawSections = splitNamedSections(remainder)
                for raw in rawSections {
                    appendSection(raw: raw, kind: kind, primary: &primarySections, aux: &auxSections)
                }
            }
        }

        // McpToolProgress fallback
        if kind == .mcpToolProgress && auxSections.isEmpty && !remainder.isEmpty {
            let items = remainder.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !items.isEmpty {
                auxSections.append(.list(label: "Progress", items: items))
            }
        }

        return ParsedBody(
            metadata: metadata,
            primarySections: primarySections,
            auxSections: auxSections,
            filePaths: filePaths
        )
    }

    private func stripShellWrapper(_ command: String) -> String {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers = ["/bin/zsh -lc '", "/bin/bash -lc '"]
        for wrapper in wrappers {
            if value.hasPrefix(wrapper) && value.hasSuffix("'") {
                return String(value.dropFirst(wrapper.count).dropLast())
            }
        }
        return value
    }

    private func commandSummary(_ sections: [ToolCallSection]) -> String? {
        for section in sections {
            let isCommand: Bool
            let content: String
            switch section {
            case .code(let label, _, let code):
                isCommand = normalizeToken(label) == "command"
                content = code
            case .text(let label, let text):
                isCommand = normalizeToken(label) == "command"
                content = text
            default:
                continue
            }
            guard isCommand else { continue }

            let firstLine = content.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })
            if let line = firstLine {
                return line
            }
        }
        return nil
    }

    private func collaborationTargetSummary(_ body: ParsedBody) -> String? {
        for section in body.auxSections {
            switch section {
            case .list(let label, let items):
                guard normalizeToken(label) == "targets" else { continue }
                guard let first = items.first else { return nil }
                if items.count > 1 {
                    return "\(first) +\(items.count - 1)"
                }
                return first
            default:
                continue
            }
        }
        return nil
    }

    private func basename(_ path: String) -> String {
        guard let last = path.split(separator: "/").last else { return path }
        return String(last)
    }

    private func summaryFor(
        kind: ToolCallKind,
        title: String,
        body: ParsedBody
    ) -> String {
        switch kind {
        case .commandExecution, .commandOutput:
            if let cmd = commandSummary(body.primarySections) {
                return stripShellWrapper(cmd)
            }
        case .fileChange, .fileDiff:
            if let first = body.filePaths.first {
                let base = basename(first)
                if body.filePaths.count > 1 {
                    return "\(base) +\(body.filePaths.count - 1) files"
                }
                return base.isEmpty ? first : base
            }
        case .mcpToolCall, .mcpToolProgress:
            if let tool = body.metadataValue(forKey: "tool"), !tool.isEmpty {
                return tool
            }
        case .webSearch:
            if let query = body.metadataValue(forKey: "query"), !query.isEmpty {
                return query
            }
        case .imageView:
            if let path = body.metadataValue(forKey: "path"), !path.isEmpty {
                let base = basename(path)
                return base.isEmpty ? path : base
            }
        case .collaboration:
            if let ts = collaborationTargetSummary(body), !ts.isEmpty {
                return ts
            }
            if let tool = body.metadataValue(forKey: "tool"), !tool.isEmpty {
                return tool
            }
        default:
            break
        }
        return title
    }

    private func parseDuration(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }

        if s.hasSuffix("ms") {
            let msText = s.dropLast(2).trimmingCharacters(in: .whitespacesAndNewlines)
            if let ms = Double(msText) {
                return formatDuration(ms: Int(ms))
            }
        }

        if s.hasSuffix("s") && !s.hasSuffix("minutes") && !s.hasSuffix("minute") {
            let secText = s.dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
            if let sec = Double(secText) {
                return formatDuration(ms: Int(sec * 1000))
            }
        }

        if s.hasSuffix("minutes") || s.hasSuffix("minute") {
            let minText = s.replacingOccurrences(of: "minutes", with: "").replacingOccurrences(of: "minute", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let mins = Double(minText) {
                return formatDuration(ms: Int(mins * 60 * 1000))
            }
        }

        if let mIdx = s.firstIndex(of: "m") {
            let before = s[..<mIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            if s.suffix(from: mIdx).hasPrefix("ms") == false {
                if let mins = Double(before) {
                    var totalMs = mins * 60 * 1000
                    let after = s[s.index(after: mIdx)...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if after.hasSuffix("s") {
                        let secText = after.dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
                        if let sec = Double(secText) {
                            totalMs += sec * 1000
                        }
                    }
                    return formatDuration(ms: Int(totalMs))
                }
            }
        }

        if let sec = Double(s) {
            return formatDuration(ms: Int(sec * 1000))
        }

        return s
    }

    private func formatDuration(ms: Int) -> String {
        let seconds = Double(ms) / 1000.0
        if seconds < 1.0 {
            return "\(ms)ms"
        } else if seconds < 60.0 {
            return String(format: "%.1fs", seconds)
        } else {
            let minutes = Int(seconds) / 60
            let remainingSeconds = Int(seconds) % 60
            return "\(minutes)m \(remainingSeconds)s"
        }
    }

    private func normalizeStatus(_ raw: String) -> ToolCallStatus {
        let n = normalizeToken(raw)
        switch n {
        case "inprogress", "in progress", "running", "pending", "started":
            return .inProgress
        case "completed", "complete", "success", "ok", "done":
            return .completed
        case "failed", "failure", "error", "denied", "cancelled", "aborted":
            return .failed
        default:
            return .unknown
        }
    }

    private func inferredStatus(kind: ToolCallKind, raw: String?) -> ToolCallStatus {
        let s = normalizeStatus(raw ?? "")
        if s != .unknown {
            return s
        }
        if kind == .webSearch {
            return .completed
        }
        return .unknown
    }

    private func parseSingleBlock(_ text: String) -> ToolCallCardModel? {
        guard let (title, body) = parseSystemEnvelope(text) else { return nil }
        guard let kind = ToolCallKind.from(title: title) else { return nil }

        let parsed = parseBody(body: body, kind: kind)
        if parsed.metadata.isEmpty && parsed.primarySections.isEmpty && parsed.auxSections.isEmpty {
            return nil
        }

        let status = inferredStatus(kind: kind, raw: parsed.metadataValue(forKey: "status"))
        let duration = parsed.metadataValue(forKey: "duration").flatMap(parseDuration)
        let summary = summaryFor(kind: kind, title: title, body: parsed)

        var allSections: [ToolCallSection] = []
        if !parsed.metadata.isEmpty {
            allSections.append(.kv(label: "Metadata", entries: parsed.metadata))
        }
        allSections.append(contentsOf: parsed.primarySections)
        allSections.append(contentsOf: parsed.auxSections)

        let normalizedSections = normalizedSections(kind: kind, sections: allSections)
        let commandContext = synthesizedCommandContext(kind: kind, sections: allSections)

        return ToolCallCardModel(
            kind: kind,
            title: title,
            summary: summary,
            status: status,
            duration: duration,
            sections: normalizedSections,
            commandContext: commandContext
        )
    }

    private func normalizedSections(kind: ToolCallKind, sections: [ToolCallSection]) -> [ToolCallSection] {
        var normalized = sections

        if kind == .fileChange || kind == .fileDiff {
            let diffIndices = normalized.enumerated().compactMap { index, section -> Int? in
                if case .diff = section { return index }
                return nil
            }

            if !diffIndices.isEmpty {
                normalized.removeAll { section in
                    if case .list(let label, _) = section {
                        return normalizeToken(label) == "files"
                    }
                    return false
                }
            }

            if kind == .fileChange,
               diffIndices.count == 1,
               let diffIndex = normalized.enumerated().first(where: { _, section in
                   if case .diff = section { return true }
                   return false
               })?.offset,
               case .diff(_, let content) = normalized[diffIndex] {
                normalized[diffIndex] = .diff(label: "", content: content)
            }
        }

        guard kind.isCommandLike else { return normalized }
        return normalized.filter { section in
            let label = normalizedLabel(for: section)
            return label != "command" && label != "directory" && label != "cwd" && label != "working directory"
        }
    }

    private func synthesizedCommandContext(
        kind: ToolCallKind,
        sections: [ToolCallSection]
    ) -> ToolCallCommandContext? {
        guard kind.isCommandLike else { return nil }

        let command = (
            sectionText(named: ["command"], in: sections)
            ?? ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = sectionText(named: ["directory", "cwd", "working directory"], in: sections)

        guard !command.isEmpty else {
            return nil
        }
        return ToolCallCommandContext(
            command: command,
            directory: directory?.isEmpty == true ? nil : directory
        )
    }

    private func sectionText(named names: Set<String>, in sections: [ToolCallSection]) -> String? {
        for section in sections {
            switch section {
            case .kv(_, let entries):
                for entry in entries {
                    guard names.contains(normalizeToken(entry.key)) else { continue }
                    let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            case .text(_, let content):
                guard names.contains(normalizedLabel(for: section)) else { continue }
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            case .code(_, _, let content):
                guard names.contains(normalizedLabel(for: section)) else { continue }
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            default:
                break
            }
        }
        return nil
    }

    private func normalizedLabel(for section: ToolCallSection) -> String {
        switch section {
        case .kv(let label, _),
             .code(let label, _, _),
             .json(let label, _),
             .diff(let label, _),
             .text(let label, _),
             .list(let label, _),
             .progress(let label, _):
            return normalizeToken(label)
        }
    }

}
private func makeRegex(pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
    do {
        return try NSRegularExpression(pattern: pattern, options: options)
    } catch {
        preconditionFailure("Invalid regex pattern `\(pattern)`: \(error)")
    }
}
