import Foundation

public enum CodexAuthTokenProfileReader {
    public static func displayName(codexHome: CodexHome = .default) -> String? {
        displayName(authFileURL: codexHome.authFileURL)
    }

    /// Reads the auth profile without making the caller's actor wait on disk I/O.
    /// The parsing helpers are value-only, so the complete read/decode can stay
    /// off the main actor before the display name crosses back to the caller.
    public static func displayNameAsync(codexHome: CodexHome = .default) async -> String? {
        await displayNameAsync(authFileURL: codexHome.authFileURL)
    }

    public static func displayNameAsync(authFileURL: URL) async -> String? {
        return await Task.detached(priority: .utility) {
            displayName(authFileURL: authFileURL)
        }.value
    }

    public static func displayName(authFileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: authFileURL) else { return nil }
        return displayName(authJSONData: data)
    }

    public static func displayName(authJSONData: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: authJSONData) as? [String: Any],
            let tokens = object["tokens"] as? [String: Any],
            let idToken = tokens["id_token"] as? String
        else {
            return nil
        }
        return displayName(idToken: idToken)
    }

    public static func displayName(idToken: String) -> String? {
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        guard let payload = base64URLDecode(String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else {
            return nil
        }
        return string(in: object, key: "name")
            ?? profileString(in: object, key: "name")
            ?? profileString(in: object, key: "given_name")
    }

    private static func profileString(in object: [String: Any], key: String) -> String? {
        guard let profile = object["https://api.openai.com/profile"] as? [String: Any] else { return nil }
        return string(in: profile, key: key)
    }

    private static func string(in object: [String: Any], key: String) -> String? {
        let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}
