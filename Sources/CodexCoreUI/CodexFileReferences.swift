import Foundation
import UniformTypeIdentifiers

/// A filesystem path dropped into the composer. CodexCore keeps the path as metadata; image
/// contents may be sampled by the thumbnail renderer, while model access still happens via tools.
public struct CodexReferencedFile: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case file
        case directory
        case image
    }

    public let id: String
    public let path: String
    public let displayName: String
    public let kind: Kind

    public var isImage: Bool { kind == .image }

    /// Creates a reference from a path already obtained from history or a protocol message.
    /// Historical paths are retained even if the file has since moved or been deleted.
    public init(path: String, displayName: String? = nil, kind: Kind? = nil) {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        self.id = normalizedPath
        self.path = normalizedPath
        let inferredName = URL(fileURLWithPath: normalizedPath).lastPathComponent
        self.displayName = displayName.flatMap { $0.isEmpty ? nil : $0 }
            ?? (inferredName.isEmpty ? normalizedPath : inferredName)
        self.kind = kind ?? Self.kind(for: normalizedPath)
    }

    /// Creates a reference only for an existing Finder drop. This performs metadata validation but
    /// never opens the file or reads its contents.
    public static func fromDroppedURL(_ url: URL) -> Self? {
        guard url.isFileURL else { return nil }
        let normalized = url.standardizedFileURL
        guard !normalized.path.contains("\n"), !normalized.path.contains("\r") else { return nil }
        let values = try? normalized.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        guard values?.isDirectory == true || values?.isRegularFile == true else { return nil }
        return Self(path: normalized.path)
    }

    private static func kind(for path: String) -> Kind {
        let url = URL(fileURLWithPath: path)
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return .directory
        }
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
            return .image
        }
        return .file
    }
}

/// The prompt-context format used by Codex surfaces for files supplied by the user.
public enum CodexFileReferencePromptCodec {
    public static let filesHeader = "# Files mentioned by the user:"
    public static let requestHeader = "## My request for Codex:"

    public static func encode(files: [CodexReferencedFile], request: String) -> String {
        guard !files.isEmpty else { return request }

        let fileLines = files.map { "## \(safeDisplayName($0.displayName)): \($0.path)" }
        return "\n" + ([filesHeader, ""] + fileLines.flatMap { [$0, ""] } + [requestHeader, request])
            .joined(separator: "\n") + "\n"
    }

    /// Returns the user-visible request and any file references encoded in the prompt context.
    /// Unknown or malformed prefixes are left as ordinary text.
    public static func decode(_ rawText: String) -> (request: String, files: [CodexReferencedFile])? {
        let delimiter = "\n\(requestHeader)\n"
        guard let marker = rawText.range(of: delimiter) else { return nil }
        let prefix = rawText[..<marker.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix.hasPrefix(filesHeader) else { return nil }

        let body = prefix.dropFirst(filesHeader.count).trimmingCharacters(in: .whitespacesAndNewlines)
        var files: [CodexReferencedFile] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("## "),
                  let separator = line.range(of: ": /")
            else { return nil }
            let name = String(line[line.index(line.startIndex, offsetBy: 3)..<separator.lowerBound])
            let pathStart = line.index(separator.lowerBound, offsetBy: 2)
            let path = String(line[pathStart...])
            guard !name.isEmpty, !path.isEmpty else { return nil }
            files.append(CodexReferencedFile(path: path, displayName: name))
        }
        guard !files.isEmpty else { return nil }

        return (
            rawText[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines),
            files
        )
    }

    public static func visibleRequest(from rawText: String) -> String {
        decode(rawText)?.request ?? rawText
    }

    private static func safeDisplayName(_ name: String) -> String {
        name.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
