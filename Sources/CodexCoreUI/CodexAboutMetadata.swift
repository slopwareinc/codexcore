import Foundation
import CodexCore

public struct CodexAboutMetadata: Equatable, Sendable {
    public var appName: String
    public var version: String?
    public var build: String?
    public var releaseDate: String?
    public var copyright: String
    public var serverName: String?

    public init(
        appName: String = "",
        version: String? = nil,
        build: String? = nil,
        releaseDate: String? = nil,
        copyright: String = "",
        serverName: String? = nil
    ) {
        self.appName = appName
        self.version = version?.nilIfBlank
        self.build = build?.nilIfBlank
        self.releaseDate = releaseDate?.nilIfBlank
        self.copyright = copyright
        self.serverName = serverName?.nilIfBlank
    }

    /// Builds about-metadata from a host bundle. Host apps supply their own
    /// branding via `fallbackAppName` / `fallbackCopyright` (or the standard
    /// Info.plist keys); this reusable layer does not hardcode any product name.
    ///
    /// - Parameter releaseDateInfoKey: Optional Info.plist key carrying a
    ///   human-readable release date (there is no standard key for this).
    public init(
        bundle: Bundle,
        serverName: String? = nil,
        fallbackAppName: String = "",
        fallbackCopyright: String = "",
        releaseDateInfoKey: String = "CodexReleaseDate"
    ) {
        let info = bundle.infoDictionary ?? [:]
        self.init(
            appName: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? fallbackAppName,
            version: info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String,
            releaseDate: info[releaseDateInfoKey] as? String,
            copyright: (info["NSHumanReadableCopyright"] as? String) ?? fallbackCopyright,
            serverName: serverName
        )
    }

    public var versionLine: String {
        var parts: [String] = []
        if let version {
            parts.append("Version \(version)")
        } else {
            parts.append("Version unavailable")
        }
        if let build {
            parts.append("Build \(build)")
        }
        if let releaseDate {
            parts.append("Released \(releaseDate)")
        } else {
            parts.append("Release date unavailable")
        }
        return parts.joined(separator: " • ")
    }
}
