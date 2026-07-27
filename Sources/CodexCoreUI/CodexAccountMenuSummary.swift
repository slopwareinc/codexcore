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

    public init(
        account: CodexSchemaAccount?,
        displayName preferredDisplayName: String? = nil,
        serverName: String? = nil
    ) {
        if let account {
            let fields = account.rawValue.objectValue ?? [:]
            let email = CodexJSONCoercion.flatString(from: fields["email"])
            let type = CodexJSONCoercion.flatString(from: fields["type"])
            let planType = CodexJSONCoercion.flatString(from: fields["planType"])
            let displayName = preferredDisplayName?.nilIfBlank
                ?? Self.displayName(fromEmail: email)
                ?? Self.titleLabel(type)
                ?? serverName?.nilIfBlank
                ?? "Codex"
            let detail = Self.titleLabel(planType)
                ?? Self.titleLabel(type)
                ?? "Signed in"
            self.init(displayName: displayName, detail: detail)
        } else {
            self.init(displayName: serverName?.nilIfBlank ?? "Codex", detail: "Available")
        }
    }

    public init(
        accountState: CanonicalAccountState,
        displayName preferredDisplayName: String? = nil,
        serverName: String? = nil
    ) {
        let fields = accountState.extensions["account"]?.objectValue
        let email = CodexJSONCoercion.flatString(from: fields?["email"])
        let type = accountState.authMode
            ?? CodexJSONCoercion.flatString(from: fields?["type"])
        let planType = accountState.planType
            ?? CodexJSONCoercion.flatString(from: fields?["planType"])

        if fields != nil || type != nil || planType != nil {
            let displayName = preferredDisplayName?.nilIfBlank
                ?? Self.displayName(fromEmail: email)
                ?? Self.titleLabel(type)
                ?? serverName?.nilIfBlank
                ?? "Codex"
            let detail = Self.titleLabel(planType)
                ?? Self.titleLabel(type)
                ?? "Signed in"
            self.init(displayName: displayName, detail: detail)
        } else {
            let requiresOpenAIAuth = Self.bool(
                from: accountState.extensions["requiresOpenaiAuth"]
                    ?? accountState.extensions["requiresOpenAIAuth"]
            ) ?? false
            self.init(
                displayName: serverName?.nilIfBlank ?? "Codex",
                detail: requiresOpenAIAuth ? "Sign-in required" : "Available"
            )
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

    private static func bool(from value: CodexJSONValue?) -> Bool? {
        guard case .bool(let bool) = value else { return nil }
        return bool
    }
}
