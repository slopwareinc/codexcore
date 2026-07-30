import Foundation

/// The portion of a response annotation that is sent to Codex.
public struct CodexResponseAnnotationContent: Codable, Equatable, Sendable {
    public var text: String
    public var annotation: String?

    public init(text: String, annotation: String? = nil) {
        self.text = text
        let trimmed = annotation?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.annotation = trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// A local source location used to restore a draft annotation in the transcript.
public struct CodexResponseTextAnchor: Equatable, Sendable {
    public var renderItemID: String
    public var startOffset: Int
    public var endOffset: Int

    public init(renderItemID: String, startOffset: Int, endOffset: Int) {
        self.renderItemID = renderItemID
        self.startOffset = startOffset
        self.endOffset = endOffset
    }

    public var range: NSRange {
        NSRange(location: startOffset, length: max(0, endOffset - startOffset))
    }
}

/// A response selection owned by one composer draft.
public struct CodexResponseTextAnnotation: Identifiable, Equatable, Sendable {
    public var id: String
    public var content: CodexResponseAnnotationContent
    public var anchor: CodexResponseTextAnchor

    public init(
        id: String = UUID().uuidString,
        text: String,
        annotation: String? = nil,
        anchor: CodexResponseTextAnchor
    ) {
        self.id = id
        self.content = CodexResponseAnnotationContent(text: text, annotation: annotation)
        self.anchor = anchor
    }

    public var text: String { content.text }

    public var annotation: String? {
        get { content.annotation }
        set { content = CodexResponseAnnotationContent(text: content.text, annotation: newValue) }
    }
}

/// Encodes composer-only context while preserving a clean user-visible request.
enum CodexComposerPromptCodec {
    struct Decoded: Equatable, Sendable {
        var request: String
        var files: [CodexReferencedFile]
        var responseAnnotations: [CodexResponseAnnotationContent]
    }

    private static let responseHeader = "# Response annotations:"
    private static let responseInstructions = "Each item contains text selected from an earlier Codex response and may include a user comment. Treat items as Annotation 1, Annotation 2, and so on in array order. Use every selection as context and address every comment. When addressing multiple comments, label each answer with its annotation number (for example, `Annotation 1`) so the user can match it to the numbered annotation."
    private static let responseOpenTag = "<response-annotations>"
    private static let responseCloseTag = "</response-annotations>"
    private static let requestHeader = "## My request for Codex:"

    static func encode(
        files: [CodexReferencedFile],
        responseAnnotations: [CodexResponseTextAnnotation],
        request: String
    ) -> String {
        let filePrompt = CodexFileReferencePromptCodec.encode(files: files, request: request)
        guard !responseAnnotations.isEmpty else { return filePrompt }

        let json = responseAnnotations
            .map(\.content)
            .map(jsonObject)
            .joined(separator: ",")
        let requestContext = files.isEmpty
            ? "\n\(requestHeader)\n\(request)\n"
            : filePrompt
        return """

        \(responseHeader)
        \(responseInstructions)
        \(responseOpenTag)
        [\(json)]
        \(responseCloseTag)
        \(requestContext)
        """
    }

    /// Decodes known composer context. Malformed envelopes remain ordinary text.
    static func decode(_ rawText: String) -> Decoded? {
        let responsePrefix = "\n\(responseHeader)\n\(responseInstructions)\n\(responseOpenTag)\n"
        guard rawText.hasPrefix(responsePrefix) else {
            guard let files = CodexFileReferencePromptCodec.decode(rawText) else { return nil }
            return Decoded(request: files.request, files: files.files, responseAnnotations: [])
        }

        let jsonStart = rawText.index(rawText.startIndex, offsetBy: responsePrefix.count)
        let closeMarker = "\n\(responseCloseTag)\n"
        guard let closeRange = rawText.range(of: closeMarker, range: jsonStart..<rawText.endIndex),
              let data = String(rawText[jsonStart..<closeRange.lowerBound]).data(using: .utf8),
              let annotations = try? JSONDecoder().decode([CodexResponseAnnotationContent].self, from: data),
              !annotations.isEmpty,
              annotations.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return nil }

        let remainder = String(rawText[closeRange.upperBound...])
        if let files = CodexFileReferencePromptCodec.decode(remainder) {
            return Decoded(
                request: files.request,
                files: files.files,
                responseAnnotations: annotations
            )
        }

        let requestMarker = "\n\(requestHeader)\n"
        guard let requestRange = remainder.range(of: requestMarker),
              remainder[..<requestRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        else { return nil }
        return Decoded(
            request: remainder[requestRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines),
            files: [],
            responseAnnotations: annotations
        )
    }

    private static func jsonObject(_ content: CodexResponseAnnotationContent) -> String {
        var object = "{\"text\":\(jsonString(content.text))"
        if let annotation = content.annotation {
            object += ",\"annotation\":\(jsonString(annotation))"
        }
        return object + "}"
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return encoded
    }
}
