import Foundation

public struct MarkdownFence {
    public let language: String
    public let content: String

    public static func parseAll(in text: String) -> [MarkdownFence] {
        let lines = text.components(separatedBy: "\n")
        var fences: [MarkdownFence] = []
        var index = 0

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let opening = MarkdownFenceOpening(line: trimmed) else {
                index += 1
                continue
            }

            let language = String(trimmed.dropFirst(opening.length))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var collected: [String] = []
            var cursor = index + 1

            while cursor < lines.count {
                let candidate = lines[cursor].trimmingCharacters(in: .whitespacesAndNewlines)
                if MarkdownFenceTracker.isClosing(candidate, marker: opening.marker, minLength: opening.length) {
                    let content = collected.joined(separator: "\n").trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
                    fences.append(MarkdownFence(language: language, content: content))
                    index = cursor
                    break
                }

                collected.append(lines[cursor])
                cursor += 1
            }

            index += 1
        }

        return fences
    }

    public static func parseSingle(_ text: String) -> MarkdownFence? {
        let lines = text.components(separatedBy: "\n")
        guard let firstLine = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              let opening = MarkdownFenceOpening(line: firstLine) else {
            return nil
        }

        var collected: [String] = []
        var closed = false
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if MarkdownFenceTracker.isClosing(trimmed, marker: opening.marker, minLength: opening.length) {
                closed = true
                break
            }
            collected.append(line)
        }
        guard closed else { return nil }

        let language = String(firstLine.dropFirst(opening.length)).trimmingCharacters(in: .whitespacesAndNewlines)
        let content = collected.joined(separator: "\n").trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        return MarkdownFence(language: language, content: content)
    }
}

public struct MarkdownFenceTracker {
    private var marker: Character?
    private var length = 0
    private var inFence = false

    public init() {}

    public mutating func consume(trimmedLine: String) -> Bool {
        if inFence {
            if let marker, Self.isClosing(trimmedLine, marker: marker, minLength: length) {
                inFence = false
                self.marker = nil
            }
        } else if let opening = MarkdownFenceOpening(line: trimmedLine) {
            marker = opening.marker
            length = opening.length
            inFence = true
        }

        return inFence
    }

    public static func isClosing(_ line: String, marker: Character, minLength: Int) -> Bool {
        guard line.first == marker else { return false }
        let length = line.prefix(while: { $0 == marker }).count
        guard length >= minLength else { return false }
        return line.dropFirst(length).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct MarkdownFenceOpening {
    let marker: Character
    let length: Int

    init?(line: String) {
        guard let first = line.first else { return nil }
        guard first == "`" || first == "~" else { return nil }
        let length = line.prefix(while: { $0 == first }).count
        guard length >= 3 else { return nil }

        self.marker = first
        self.length = length
    }
}
