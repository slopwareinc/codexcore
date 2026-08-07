import Foundation

/// A read-only output surfaced by the canonical transcript projection.
///
/// This model intentionally contains no provider or launcher metadata. The
/// summary can therefore show only outputs that app-server has already
/// materialized in the selected thread; opening or exporting an output remains
/// a transcript action until the host supplies such a route.
public struct CodexOutputSummary: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case generatedImage
        case fileChange
        case commandOutput
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let detail: String
    public let systemImage: String
    public let interactionHint: String

    public init(
        id: String,
        kind: Kind,
        title: String,
        detail: String,
        systemImage: String,
        interactionHint: String = "Output details are available in the transcript"
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.interactionHint = interactionHint
    }
}

public extension CodexCanonicalTranscriptPresentation {
    /// Outputs are projected exclusively from the selected thread's canonical
    /// presentation. No artifact provider is inferred from a tool name and no
    /// output is synthesized when the protocol has not supplied one.
    var outputSummaries: [CodexOutputSummary] {
        var summaries: [CodexOutputSummary] = []

        for turnID in turnOrder {
            guard let turn = turnsByID[turnID] else { continue }

            for narrative in turn.narrative {
                guard case .workGroup(let group) = narrative else { continue }
                for row in group.rows {
                    switch row {
                    case .fileChange(let fileChange):
                        let paths = fileChange.changes.map(\.path).filter { !$0.isEmpty }
                            + fileChange.files.filter { !$0.isEmpty }
                        let uniquePaths = paths.removingDuplicateStrings()
                        let title: String
                        if uniquePaths.count == 1, let path = uniquePaths.first {
                            title = "Edited \(path)"
                        } else if uniquePaths.isEmpty {
                            title = "Edited files"
                        } else {
                            title = "Edited \(uniquePaths.count) files"
                        }
                        summaries.append(.init(
                            id: "\(turnID.rawValue):\(fileChange.id)",
                            kind: .fileChange,
                            title: title,
                            detail: "Canonical file change",
                            systemImage: "doc.badge.ellipsis"
                        ))

                    case .command(let command):
                        guard let output = command.output?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !output.isEmpty
                        else { continue }
                        let label = command.label.trimmingCharacters(in: .whitespacesAndNewlines)
                        summaries.append(.init(
                            id: "\(turnID.rawValue):\(command.id)",
                            kind: .commandOutput,
                            title: label.isEmpty ? "Command output" : label,
                            detail: output.firstLine,
                            systemImage: "terminal"
                        ))

                    default:
                        // MCP, search, and collaboration rows are activity,
                        // not artifacts. Do not claim an output provider for
                        // them without a protocol-backed output value.
                        continue
                    }
                }
            }

            for image in turn.generatedImages {
                summaries.append(.init(
                    id: "\(turnID.rawValue):\(image.id)",
                    kind: .generatedImage,
                    title: generatedImageTitle(source: image.source),
                    detail: "Canonical image output",
                    systemImage: "photo"
                ))
            }
        }

        return summaries
    }
}

private extension String {
    var firstLine: String {
        components(separatedBy: .newlines).first ?? self
    }
}

private extension Array where Element == String {
    func removingDuplicateStrings() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}

private func generatedImageTitle(source: String) -> String {
    let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return "Generated image" }

    if let url = URL(string: value), url.scheme != nil,
       let lastPathComponent = url.pathComponents.last,
       !lastPathComponent.isEmpty, lastPathComponent != "/"
    {
        return "Generated \(lastPathComponent)"
    }

    let pathComponent = URL(fileURLWithPath: value).lastPathComponent
    return pathComponent.isEmpty || pathComponent == "." ? "Generated image" : "Generated \(pathComponent)"
}
