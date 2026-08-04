import Foundation
import CodexCore

public struct CodexPluginMarketplaceSource: Equatable, Sendable {
    public var name: String
    public var path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// Finds plugin marketplaces already materialized by Codex runtimes without
/// coupling catalog loading to another client's mutable configuration.
public enum CodexPluginMarketplaceDiscovery {
    public static func sources(
        codexHome: CodexHome,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        appResources: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default
    ) -> [CodexPluginMarketplaceSource] {
        var candidates = [
            codexHome.directoryURL.appendingPathComponent(".tmp/plugins", isDirectory: true),
            codexHome.directoryURL.appendingPathComponent(
                ".tmp/bundled-marketplaces/openai-bundled",
                isDirectory: true
            ),
            homeDirectory.appendingPathComponent(
                ".cache/codex-runtimes/codex-primary-runtime/plugins/openai-primary-runtime",
                isDirectory: true
            ),
        ]
        if let appResources {
            candidates.append(
                appResources.appendingPathComponent("plugins/openai-bundled", isDirectory: true)
            )
        }
        candidates.append(
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/plugins/openai-bundled", isDirectory: true)
        )

        return sources(in: candidates, fileManager: fileManager)
    }

    public static func sources(
        in candidateRoots: [URL],
        fileManager: FileManager = .default
    ) -> [CodexPluginMarketplaceSource] {
        // These catalogs are supplied by app-server after authentication and
        // deliberately reject marketplace/add. Keep that first-party seam on
        // the server; only reconcile addable local runtime marketplaces here.
        let serverManagedNames: Set<String> = ["openai-curated", "openai-curated-remote"]
        var seenNames = Set<String>()
        return candidateRoots.compactMap { root in
            let manifest = root.appendingPathComponent(
                ".agents/plugins/marketplace.json",
                isDirectory: false
            )
            guard fileManager.fileExists(atPath: manifest.path),
                  let data = try? Data(contentsOf: manifest),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = object["name"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !serverManagedNames.contains(name),
                  seenNames.insert(name).inserted
            else { return nil }
            return CodexPluginMarketplaceSource(name: name, path: root.path)
        }
    }
}

public struct CodexPluginMarketplaceBootstrapResult: Equatable, Sendable {
    public var registeredNames: [String]
    public var failures: [String]

    public init(registeredNames: [String] = [], failures: [String] = []) {
        self.registeredNames = registeredNames
        self.failures = failures
    }
}

/// Protocol-backed bootstrap seam kept separate from plugin listing and MCP
/// management so those control planes can evolve independently.
public enum CodexPluginMarketplaceBootstrap {
    public static func register(
        _ sources: [CodexPluginMarketplaceSource],
        using codex: Codex,
        errorMessage: (Error) -> String
    ) async -> CodexPluginMarketplaceBootstrapResult {
        var result = CodexPluginMarketplaceBootstrapResult()
        for source in sources {
            do {
                let response = try await codex.marketplaceAdd(.init(source: source.path))
                result.registeredNames.append(response.marketplaceName)
            } catch {
                result.failures.append("\(source.name): \(errorMessage(error))")
            }
        }
        return result
    }
}
