import CodexCore
import Foundation

/// The semantic presentation of one app-server `commandAction`.
///
/// Keeping this adapter separate from turn projection makes the protocol-to-UI
/// boundary explicit and prevents command parsing rules from leaking into the
/// transcript state machine.
struct CodexCommandActionPresentation {
    enum Kind {
        case read(target: String, isTool: Bool)
        case list(path: String?)
        case search(query: String?, path: String?)
        case run
    }

    var command: String
    var kind: Kind

    var category: CodexWorkCategoryV2 {
        switch kind {
        case .read(_, let isTool): isTool ? .loadedTool : .read
        case .list: .list
        case .search: .search
        case .run: .run
        }
    }

    func label(inProgress: Bool) -> String {
        switch kind {
        case .read(let target, _):
            return "\(inProgress ? "Reading" : "Read") \(target)"
        case .list(let path):
            guard let path = path?.codexTrimmedNonEmpty else {
                return inProgress ? "Listing files" : "Listed files"
            }
            return "\(inProgress ? "Listing" : "Listed") files in \(path)"
        case .search(let query, let path):
            let query = query?.codexTrimmedNonEmpty
            let path = path?.codexTrimmedNonEmpty
            if let query, let path {
                return "\(inProgress ? "Searching" : "Searched") for \(query) in \(path)"
            }
            if let query {
                return "\(inProgress ? "Searching" : "Searched") for \(query)"
            }
            return inProgress ? "Searching for files" : "Searched for files"
        case .run:
            return inProgress ? "Running command" : "Ran \(shortCommand(command))"
        }
    }

    static func project(
        _ actions: [[String: CodexJSONValue]],
        fallbackCommand: String
    ) -> [Self] {
        guard !actions.isEmpty else {
            return [.init(command: fallbackCommand, kind: .run)]
        }
        return actions.map { action in
            let command = string("command", in: action) ?? fallbackCommand
            switch string("type", in: action)?.lowercased() {
            case "read", "fileread":
                let path = string("path", in: action)
                let name = string("name", in: action)
                    ?? path.map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? "a file"
                if let skill = skillDisplayName(name: name, path: path) {
                    return .init(command: command, kind: .read(target: skill, isTool: true))
                }
                return .init(command: command, kind: .read(target: name, isTool: false))
            case "listfiles", "list":
                return .init(
                    command: command,
                    kind: .list(path: string("path", in: action))
                )
            case "search", "searchfiles":
                return .init(
                    command: command,
                    kind: .search(
                        query: string("query", in: action),
                        path: string("path", in: action)
                    )
                )
            default:
                return .init(command: command, kind: .run)
            }
        }
    }

    private static func string(
        _ key: String,
        in object: [String: CodexJSONValue]
    ) -> String? {
        guard case .string(let value) = object[key] else { return nil }
        return value
    }

    private static func skillDisplayName(name: String, path: String?) -> String? {
        guard name.lowercased() == "skill.md" || path?.lowercased().hasSuffix("/skill.md") == true,
              let path else { return nil }
        let skillName = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
        guard !skillName.isEmpty else { return nil }
        let displayName = skillName.lowercased() == "github" ? "GitHub" : skillName
        return "\(displayName) skill"
    }

    private func shortCommand(_ command: String) -> String {
        guard let range = command.range(of: "-lc ") else { return command }
        return String(command[range.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
    }
}

private extension String {
    var codexTrimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
