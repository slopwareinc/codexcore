import Foundation

/// Provenance carried by a prompt sent from one independent Codex thread to another.
///
/// The desktop app transports this metadata inside the text input so it survives
/// app-server persistence and thread resume. Consumers should display `input` as
/// the user-facing prompt and use `sourceThreadID` only for attribution/navigation.
public struct CodexThreadDelegationEnvelope: Sendable, Equatable {
    public var sourceThreadID: ThreadID
    public var input: String

    public init(sourceThreadID: ThreadID, input: String) {
        self.sourceThreadID = sourceThreadID
        self.input = input
    }

    public var encodedText: String {
        """
        <codex_delegation>
          <source_thread_id>\(Self.escape(sourceThreadID.rawValue))</source_thread_id>
          <input>\(Self.escape(input))</input>
        </codex_delegation>
        """
    }

    public static func decode(_ text: String) -> Self? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<codex_delegation>"),
              trimmed.hasSuffix("</codex_delegation>"),
              let source = element("source_thread_id", in: trimmed),
              let input = element("input", in: trimmed)
        else { return nil }
        return Self(sourceThreadID: ThreadID(source), input: input)
    }

    private static func element(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(name)>"),
              let end = text.range(of: "</\(name)>", range: start.upperBound..<text.endIndex)
        else { return nil }
        return unescape(String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
