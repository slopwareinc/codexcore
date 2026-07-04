import Foundation
import CodexCore

public struct CodexAccountMenuSummary: Equatable, Sendable {
    public var displayName: String
    public var detail: String
    public var initials: String

    public init(displayName: String, detail: String, initials: String? = nil) {
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = normalizedName.isEmpty ? "Codex" : normalizedName
        self.detail = normalizedDetail.isEmpty ? "Available" : normalizedDetail
        self.initials = initials?.nilIfBlank ?? Self.initials(for: self.displayName)
    }

    public init(account: Account?, serverName: String? = nil) {
        if let account {
            let displayName = Self.displayName(fromEmail: account.email)
                ?? Self.titleLabel(account.type)
                ?? serverName?.nilIfBlank
                ?? "Codex"
            let detail = Self.titleLabel(account.planType)
                ?? Self.titleLabel(account.type)
                ?? "Signed in"
            self.init(displayName: displayName, detail: detail)
        } else {
            self.init(displayName: serverName?.nilIfBlank ?? "Codex", detail: "Available")
        }
    }

    private static func displayName(fromEmail email: String?) -> String? {
        guard let localPart = email?.split(separator: "@", maxSplits: 1).first else { return nil }
        let pieces = localPart
            .split { character in
                character == "." || character == "_" || character == "-" || character == "+"
            }
            .map(String.init)
            .compactMap(titleLabel)
        guard !pieces.isEmpty else { return nil }
        return pieces.joined(separator: " ")
    }

    private static func titleLabel(_ value: String?) -> String? {
        guard let value = value?.nilIfBlank else { return nil }
        let lowercased = value.lowercased()
        if lowercased == "chatgpt" { return "ChatGPT" }
        if lowercased == "openai" { return "OpenAI" }
        return value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
            .nilIfBlank
    }

    private static func initials(for displayName: String) -> String {
        let words = displayName
            .split { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" }
            .map(String.init)
        let letters: String
        if words.count >= 2 {
            letters = words.prefix(2).compactMap(\.first).map(String.init).joined()
        } else if let word = words.first {
            letters = String(word.prefix(2))
        } else {
            letters = "C"
        }
        return letters.uppercased()
    }
}
