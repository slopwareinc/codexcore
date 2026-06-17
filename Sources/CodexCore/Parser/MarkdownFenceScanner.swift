import Foundation

struct MarkdownFence {
    let language: String
    let content: String

    static func parseSingle(_ text: String) -> MarkdownFence? {
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

struct MarkdownFenceTracker {
    private var marker: Character?
    private var length = 0
    private var inFence = false

    mutating func consume(trimmedLine: String) -> Bool {
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

    static func isClosing(_ line: String, marker: Character, minLength: Int) -> Bool {
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
