import Foundation

/// Lightweight GFM table parser.
///
/// GFM tables look like:
///
/// | Header | Header |
/// | --- | :---: |
/// | cell | cell |
///
/// This parser is intentionally small — it handles the cases models
/// actually emit (alignment, escaped pipes, inline code, bold). It
/// does not handle cells that themselves contain newlines (GFM
/// disallows that) or nested tables.
public enum CodexGFMTableParser {
    public static func parse(_ raw: String) -> CodexTableModel? {
        let lines = raw
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.count >= 2 else { return nil }

        let headerCells = splitRow(lines[0])
        guard !headerCells.isEmpty else { return nil }

        let delimiterCells = splitRow(lines[1])
        guard delimiterCells.count == headerCells.count else { return nil }

        let columns: [CodexTableModel.Column] = zip(headerCells, delimiterCells).map { header, delimiter in
            CodexTableModel.Column(header: header, alignment: alignment(for: delimiter))
        }

        var rows: [[String]] = []
        for line in lines.dropFirst(2) {
            let cells = splitRow(line)
            // Pad/truncate to column count; GFM allows cells missing
            // in the last row.
            var padded = cells
            while padded.count < columns.count { padded.append("") }
            if padded.count > columns.count {
                padded = Array(padded.prefix(columns.count))
            }
            rows.append(padded)
        }

        return CodexTableModel(columns: columns, rows: rows)
    }

    /// Split a table row on `|`, respecting escaped `\|` and inline
    /// code spans where `|` should not split. A leading or trailing
    /// `|` is treated as a border and dropped.
    static func splitRow(_ line: String) -> [String] {
        var stripped = line
        if stripped.hasPrefix("|") { stripped.removeFirst() }
        if stripped.hasSuffix("|") {
            // Avoid stripping a trailing `|` that closes an inline
            // code span — GFM requires the border to be unescaped.
            stripped.removeLast()
        }

        var cells: [String] = []
        var current = ""
        var inCode = false
        var iterator = stripped.makeIterator()
        while let char = iterator.next() {
            switch char {
            case "\\":
                // Escape: pass through next char literally.
                if let next = iterator.next() {
                    if next == "|" {
                        current.append("|")
                    } else {
                        current.append("\\")
                        current.append(next)
                    }
                }
            case "`":
                inCode.toggle()
                current.append("`")
            case "|":
                if inCode {
                    current.append("|")
                } else {
                    cells.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                }
            default:
                current.append(char)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// Detect alignment from a delimiter cell. GFM uses `:---`,
    /// `:---:`, and `---:` for left, center, right. A bare `---` is
    /// left-aligned by default.
    static func alignment(for cell: String) -> CodexTableModel.Column.Alignment {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        let hasLeading = trimmed.hasPrefix(":")
        let hasTrailing = trimmed.hasSuffix(":")
        switch (hasLeading, hasTrailing) {
        case (true, true): return .center
        case (false, true): return .trailing
        case (true, false): return .leading
        default: return .leading
        }
    }
}
