import Foundation

/// A bounded prepared row in the T3 changed-file tree. Review paths preserve
/// the original source spelling even when Windows separators are normalized.
struct CodexChangedFilesTreeRowV2: Sendable, Equatable, Identifiable {
    var id: String
    var path: String
    var name: String
    var depth: Int
    var isDirectory: Bool
    var isExpanded: Bool
    var added: Int
    var removed: Int
}

/// Adapted from T3 Code's `lib/turnDiffTree.ts`. Preparation happens once in
/// the dirty turn projection, never while a SwiftUI row draws or scrolls.
enum CodexChangedFilesTreeV2 {
    private final class Directory {
        var name: String
        var path: String
        var directories: [String: Directory] = [:]
        var files: [CodexPreparedFileChangeSummaryV2] = []
        var added = 0
        var removed = 0
        init(name: String, path: String) { self.name = name; self.path = path }
    }

    static func rows(
        files: [CodexPreparedFileChangeSummaryV2],
        rowID: String,
        allExpanded: Bool,
        toggledDirectoryIDs: Set<String>
    ) -> [CodexChangedFilesTreeRowV2] {
        let root = Directory(name: "", path: "")
        for file in files {
            let parts = file.path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            var directory = root
            root.added += file.added
            root.removed += file.removed
            for part in parts.dropLast() {
                let child = directory.directories[part] ?? Directory(
                    name: part, path: directory.path.isEmpty ? part : directory.path + "/" + part
                )
                directory.directories[part] = child
                child.added += file.added
                child.removed += file.removed
                directory = child
            }
            directory.files.append(file)
        }
        var result: [CodexChangedFilesTreeRowV2] = []
        func append(_ parent: Directory, depth: Int) {
            for child in parent.directories.values.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                var directory = child
                var name = child.name
                // A chain with no sibling files reads as one directory row.
                while directory.files.isEmpty, directory.directories.count == 1,
                      let only = directory.directories.values.first {
                    name += "/" + only.name
                    directory = only
                }
                let id = rowID + ":directory:" + directory.path
                let expanded = allExpanded != toggledDirectoryIDs.contains(id)
                result.append(.init(id: id, path: directory.path, name: name, depth: depth,
                                    isDirectory: true, isExpanded: expanded, added: directory.added, removed: directory.removed))
                if expanded { append(directory, depth: depth + 1) }
            }
            for file in parent.files.sorted(by: { ($0.path as NSString).lastPathComponent.localizedStandardCompare(($1.path as NSString).lastPathComponent) == .orderedAscending }) {
                result.append(.init(id: rowID + ":file:" + file.path, path: file.path,
                                    name: (file.path.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent,
                                    depth: depth, isDirectory: false, isExpanded: false, added: file.added, removed: file.removed))
            }
        }
        append(root, depth: 0)
        return result
    }

    static func compactCount(_ value: Int) -> String {
        guard value >= 1_000 else { return String(value) }
        let divisor: Double
        let suffix: String
        if value >= 1_000_000_000 { divisor = 1_000_000_000; suffix = "b" }
        else if value >= 1_000_000 { divisor = 1_000_000; suffix = "m" }
        else { divisor = 1_000; suffix = "k" }
        let scaled = Double(value) / divisor
        let number = scaled < 10
            ? String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), (scaled * 10).rounded() / 10)
            : String(Int(scaled.rounded()))
        return number.replacingOccurrences(of: #"\.0$"#, with: "", options: .regularExpression) + suffix
    }
}
