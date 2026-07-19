import Foundation
import Darwin

/// A launch was refused because the configured filesystem namespace could not
/// be prepared without risking the normal Codex application's state.
public enum CodexHomePreparationError: Error, Sendable, Equatable, LocalizedError {
    case protectedCodexDirectory(configuredPath: String, resolvedPath: String)
    case symbolicLinkTraversal(configuredPath: String, componentPath: String)
    case notDirectory(configuredPath: String, componentPath: String)
    case fileSystemFailure(
        configuredPath: String,
        operation: String,
        componentPath: String,
        errno: Int32
    )

    public var errorDescription: String? {
        switch self {
        case .protectedCodexDirectory(let configuredPath, let resolvedPath):
            "Refusing CODEX_HOME=\(configuredPath) because it resolves inside the normal Codex home at \(resolvedPath)."
        case .symbolicLinkTraversal(let configuredPath, let componentPath):
            "Refusing CODEX_HOME=\(configuredPath) because path component \(componentPath) is a symbolic link."
        case .notDirectory(let configuredPath, let componentPath):
            "Cannot use CODEX_HOME=\(configuredPath) because \(componentPath) is not a directory."
        case .fileSystemFailure(
            let configuredPath,
            let operation,
            let componentPath,
            let errorNumber
        ):
            "Could not prepare CODEX_HOME=\(configuredPath): \(operation) failed for \(componentPath) with errno \(errorNumber)."
        }
    }
}

/// The isolated filesystem namespace used by a Codex app-server process.
///
/// CodexCore deliberately defaults to `~/.codexcore` so it never shares the
/// normal Codex app's mutable state under `~/.codex`.
public struct CodexHome: Sendable, Hashable, CustomStringConvertible {
    public static let environmentKey = "CODEX_HOME"

    public static var `default`: CodexHome {
        CodexHome(
            path: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codexcore", isDirectory: true)
                .path
        )
    }

    /// A standardized, symlink-resolved absolute path.
    public let path: String

    public var directoryURL: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    public var authFileURL: URL {
        directoryURL.appendingPathComponent("auth.json", isDirectory: false)
    }

    public var configFileURL: URL {
        directoryURL.appendingPathComponent("config.toml", isDirectory: false)
    }

    public var description: String { path }

    public init(path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!trimmed.isEmpty, "CodexHome requires a non-empty path")

        let expanded = (trimmed as NSString).expandingTildeInPath
        let absolutePath: String
        if expanded.hasPrefix("/") {
            absolutePath = expanded
        } else {
            absolutePath = URL(
                fileURLWithPath: expanded,
                relativeTo: URL(
                    fileURLWithPath: FileManager.default.currentDirectoryPath,
                    isDirectory: true
                )
            ).absoluteURL.path
        }

        self.path = URL(fileURLWithPath: absolutePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    /// Creates and opens every path component without following symbolic
    /// links, then verifies the opened directory is outside `~/.codex`.
    ///
    /// This must run immediately before every app-server process launch. The
    /// descriptor-relative traversal prevents a component from being swapped
    /// to a symlink while the directory is being created. A caller that passes
    /// the path to another process still has an unavoidable final path lookup,
    /// so the stdio transport repeats this check synchronously before
    /// `Process.run()`.
    func prepareForLaunch() throws {
        try Self.rejectProtectedCodexDirectory(
            configuredPath: path,
            resolvedPath: directoryURL.resolvingSymlinksInPath().path
        )

        var directoryDescriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw Self.fileSystemFailure(
                configuredPath: path,
                operation: "open",
                componentPath: "/"
            )
        }
        defer { Darwin.close(directoryDescriptor) }

        var traversedPath = ""
        for componentSubstring in path.split(separator: "/") {
            let component = String(componentSubstring)
            traversedPath += "/\(component)"
            let nextDescriptor = try Self.openOrCreateDirectory(
                named: component,
                relativeTo: directoryDescriptor,
                configuredPath: path,
                componentPath: traversedPath
            )
            Darwin.close(directoryDescriptor)
            directoryDescriptor = nextDescriptor
        }

        let openedPath = try Self.openedPath(
            for: directoryDescriptor,
            configuredPath: path
        )
        try Self.rejectProtectedCodexDirectory(
            configuredPath: path,
            resolvedPath: openedPath
        )
    }

    private static func openOrCreateDirectory(
        named component: String,
        relativeTo parentDescriptor: Int32,
        configuredPath: String,
        componentPath: String
    ) throws -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var descriptor = component.withCString {
            Darwin.openat(parentDescriptor, $0, flags)
        }
        if descriptor >= 0 { return descriptor }

        var errorNumber = errno
        if errorNumber == ENOENT {
            let creationResult = component.withCString {
                Darwin.mkdirat(parentDescriptor, $0, mode_t(0o700))
            }
            if creationResult != 0, errno != EEXIST {
                throw Self.fileSystemFailure(
                    configuredPath: configuredPath,
                    operation: "mkdirat",
                    componentPath: componentPath
                )
            }
            descriptor = component.withCString {
                Darwin.openat(parentDescriptor, $0, flags)
            }
            if descriptor >= 0 { return descriptor }
            errorNumber = errno
        }

        if Self.isSymbolicLink(
            named: component,
            relativeTo: parentDescriptor
        ) {
            throw CodexHomePreparationError.symbolicLinkTraversal(
                configuredPath: configuredPath,
                componentPath: componentPath
            )
        }
        if errorNumber == ENOTDIR {
            throw CodexHomePreparationError.notDirectory(
                configuredPath: configuredPath,
                componentPath: componentPath
            )
        }
        throw CodexHomePreparationError.fileSystemFailure(
            configuredPath: configuredPath,
            operation: "openat",
            componentPath: componentPath,
            errno: errorNumber
        )
    }

    private static func isSymbolicLink(
        named component: String,
        relativeTo parentDescriptor: Int32
    ) -> Bool {
        var metadata = stat()
        let result = component.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard result == 0 else { return false }
        return metadata.st_mode & S_IFMT == S_IFLNK
    }

    private static func openedPath(
        for descriptor: Int32,
        configuredPath: String
    ) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard Darwin.fcntl(descriptor, F_GETPATH, &buffer) != -1 else {
            throw fileSystemFailure(
                configuredPath: configuredPath,
                operation: "fcntl(F_GETPATH)",
                componentPath: configuredPath
            )
        }
        return String(cString: buffer)
    }

    private static func rejectProtectedCodexDirectory(
        configuredPath: String,
        resolvedPath: String
    ) throws {
        let normalCodexURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL
        let protectedPaths = Set([
            normalCodexURL.path,
            normalCodexURL.resolvingSymlinksInPath().path,
        ])
        let standardizedResolvedPath = URL(
            fileURLWithPath: resolvedPath,
            isDirectory: true
        ).standardizedFileURL.path
        guard protectedPaths.contains(where: {
            standardizedResolvedPath == $0
                || standardizedResolvedPath.hasPrefix($0 + "/")
        }) else {
            return
        }
        throw CodexHomePreparationError.protectedCodexDirectory(
            configuredPath: configuredPath,
            resolvedPath: standardizedResolvedPath
        )
    }

    private static func fileSystemFailure(
        configuredPath: String,
        operation: String,
        componentPath: String
    ) -> CodexHomePreparationError {
        .fileSystemFailure(
            configuredPath: configuredPath,
            operation: operation,
            componentPath: componentPath,
            errno: errno
        )
    }
}
