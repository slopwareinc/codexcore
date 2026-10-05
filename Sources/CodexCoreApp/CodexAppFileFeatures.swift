import Foundation
import Observation
import CodexCore

protocol CodexAppFileRuntimeProviding: CodexAppRuntimeProviding {
    func changes(watchID: String) async throws -> AsyncThrowingStream<CodexSchemaFSChangedNotification, Error>
    func searches(sessionID: String) async throws -> AsyncThrowingStream<CodexFuzzyFileSearchEvent, Error>
}

extension CodexAppRuntimeProvider: CodexAppFileRuntimeProviding {
    func changes(watchID: String) async throws -> AsyncThrowingStream<CodexSchemaFSChangedNotification, Error> {
        try await codex.session.observeFSChanges(watchID: watchID)
    }
    func searches(sessionID: String) async throws -> AsyncThrowingStream<CodexFuzzyFileSearchEvent, Error> {
        try await codex.observeFuzzyFileSearch(sessionID: sessionID)
    }
}

@MainActor @Observable
final class CodexAppFileFeatures {
    private(set) var entries: [CodexSchemaFSReadDirectoryEntry] = []
    private(set) var metadata: CodexSchemaFSGetMetadataResponse?
    private(set) var directory = ""
    private(set) var openedPath: String?
    var text = ""
    private(set) var searchResults: [CodexSchemaFuzzyFileSearchResult] = []
    private(set) var isLoading = false
    private(set) var watchingPath: String?
    private(set) var error: String?
    private(set) var message: String?
    @ObservationIgnored private var provider: (any CodexAppFileRuntimeProviding)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var watch: (id: String, provider: any CodexAppFileRuntimeProviding)?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var search: (id: String, provider: any CodexAppFileRuntimeProviding)?
    @ObservationIgnored private var watchGeneration = 0
    @ObservationIgnored private var searchGeneration = 0
    var contextVersion: Int { generation }
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    private static let maximumTextBytes = 2 * 1_024 * 1_024

    func bind(_ provider: (any CodexAppFileRuntimeProviding)?) async {
        // Detach old operations before suspending. A second bind can install a
        // new connection while cleanup of the old server is still in flight.
        generation &+= 1
        let oldWatch = detachWatch()
        let oldSearch = detachSearch()
        self.provider = provider
        entries = []; metadata = nil; directory = ""; openedPath = nil; text = ""
        searchResults = []; isLoading = false; error = nil; message = nil
        await cleanupWatch(oldWatch)
        await cleanupSearch(oldSearch)
    }

    func browse(_ path: String) async { await browse(path, resetFeedback: true) }

    private func browse(_ path: String, resetFeedback: Bool) async {
        _ = await run(resetFeedback: resetFeedback) { provider in
            let path = try Self.absolutePath(path)
            let response = try await provider.perform(CodexRequest.fsReadDirectory(.init(path: .init(.string(path)))))
            return { self.directory = path; self.entries = response.entries.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending } }
        }
    }

    func open(_ path: String) async {
        await run { provider in
            let path = try Self.absolutePath(path)
            let rawPath = CodexSchemaAbsolutePathBuf(.string(path))
            let metadata = try await provider.perform(CodexRequest.fsGetMetadata(.init(path: rawPath)))
            guard metadata.isFile else { throw CodexAppFeatureError.invalidInput("Choose a file to edit.") }
            let response = try await provider.perform(CodexRequest.fsReadFile(.init(path: rawPath)))
            guard response.dataBase64.utf8.count <= ((Self.maximumTextBytes + 2) / 3) * 4,
                  let data = Data(base64Encoded: response.dataBase64), data.count <= Self.maximumTextBytes else {
                throw CodexAppFeatureError.invalidInput("The file exceeds the 2 MiB text editor limit.")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw CodexAppFeatureError.invalidInput("This is a binary file. Open it with a suitable viewer.")
            }
            return { self.openedPath = path; self.text = text; self.metadata = metadata }
        }
    }

    func save(path: String, contents: String? = nil) async {
        let data = Data((contents ?? text).utf8)
        guard data.count <= Self.maximumTextBytes else { error = "Text exceeds the 2 MiB editor limit."; return }
        await run { provider in
            let path = try Self.absolutePath(path)
            _ = try await provider.perform(CodexRequest.fsWriteFile(.init(dataBase64: data.base64EncodedString(), path: .init(.string(path)))))
            return { self.openedPath = path; self.message = "File saved." }
        }
    }

    func createDirectory(_ path: String) async {
        let scope = generation, refreshPath = directory
        let succeeded = await run { provider in
            _ = try await provider.perform(CodexRequest.fsCreateDirectory(.init(path: .init(.string(try Self.absolutePath(path))), recursive: true)))
            return { self.message = "Folder created." }
        }
        if succeeded, generation == scope, !refreshPath.isEmpty { await browse(refreshPath, resetFeedback: false) }
    }

    func copy(from source: String, to destination: String, recursive: Bool) async {
        let scope = generation, refreshPath = directory
        let succeeded = await run { provider in
            _ = try await provider.perform(CodexRequest.fsCopy(.init(
                destinationPath: .init(.string(try Self.absolutePath(destination))), recursive: recursive,
                sourcePath: .init(.string(try Self.absolutePath(source)))
            )))
            return { self.message = "Copy completed." }
        }
        if succeeded, generation == scope, !refreshPath.isEmpty { await browse(refreshPath, resetFeedback: false) }
    }

    func remove(_ path: String, recursive: Bool) async {
        let scope = generation, refreshPath = directory
        let succeeded = await run { provider in
            let path = try Self.absolutePath(path)
            guard path != "/" else { throw CodexAppFeatureError.invalidInput("The filesystem root cannot be removed here.") }
            _ = try await provider.perform(CodexRequest.fsRemove(.init(force: false, path: .init(.string(path)), recursive: recursive)))
            return {
                if self.openedPath == path { self.openedPath = nil; self.text = ""; self.metadata = nil }
                self.message = "Removed."
            }
        }
        if succeeded, generation == scope, !refreshPath.isEmpty { await browse(refreshPath, resetFeedback: false) }
    }

    func startWatching(_ path: String) async {
        let previous = detachWatch()
        let operation = watchGeneration, connection = generation
        let provider = provider
        await cleanupWatch(previous)
        guard watchGeneration == operation, generation == connection, let provider else { return }
        let id = "codexcore-watch-" + UUID().uuidString
        do {
            let path = try Self.absolutePath(path)
            let events = try await provider.changes(watchID: id)
            guard watchGeneration == operation, generation == connection else { return }
            watch = (id, provider)
            watchTask = Task { [weak self] in
                do {
                    for try await _ in events {
                        guard !Task.isCancelled, let self, self.generation == connection,
                              self.watchGeneration == operation, self.watch?.id == id else { return }
                        await self.browse(path, resetFeedback: false)
                    }
                } catch is CancellationError {
                } catch {
                    if let self, self.generation == connection, self.watchGeneration == operation {
                        self.error = error.localizedDescription
                    }
                }
            }
            _ = try await provider.perform(CodexRequest.fsWatch(.init(path: .init(.string(path)), watchID: id)))
            guard generation == connection, watchGeneration == operation else {
                // stop/bind may have unregistered before fs/watch completed.
                // Reconcile this exact old watch after its start acknowledges.
                await cleanupWatch((id, provider))
                return
            }
            watchingPath = path
        } catch {
            guard generation == connection, watchGeneration == operation else {
                await cleanupWatch((id, provider)); return
            }
            self.error = error.localizedDescription
            await cleanupWatch(detachWatch())
        }
    }

    func stopWatching() async { await cleanupWatch(detachWatch()) }

    func search(query: String, roots: [String]) async {
        let previous = detachSearch()
        let operation = searchGeneration, connection = generation
        let provider = provider
        searchResults = []
        await cleanupSearch(previous)
        guard searchGeneration == operation, generation == connection, let provider else { return }
        let id = "codexcore-search-" + UUID().uuidString
        do {
            let roots = try roots.map(Self.absolutePath)
            guard !roots.isEmpty else { throw CodexAppFeatureError.invalidInput("Choose a folder to search.") }
            let events = try await provider.searches(sessionID: id)
            guard searchGeneration == operation, generation == connection else { return }
            search = (id, provider)
            searchTask = Task { [weak self] in
                do {
                    for try await event in events {
                        guard !Task.isCancelled, let self, self.generation == connection,
                              self.searchGeneration == operation, self.search?.id == id else { return }
                        if case .updated(let value) = event { self.searchResults = Array(value.files.prefix(200)) }
                    }
                } catch is CancellationError {
                } catch {
                    if let self, self.generation == connection, self.searchGeneration == operation {
                        self.error = error.localizedDescription
                    }
                }
            }
            _ = try await provider.perform(CodexRequest.fuzzyFileSearchSessionStart(.init(roots: roots, sessionID: id)))
            guard generation == connection, searchGeneration == operation else {
                await cleanupSearch((id, provider)); return
            }
            _ = try await provider.perform(CodexRequest.fuzzyFileSearchSessionUpdate(.init(query: query, sessionID: id)))
            guard generation == connection, searchGeneration == operation else {
                await cleanupSearch((id, provider)); return
            }
        } catch {
            guard generation == connection, searchGeneration == operation else {
                await cleanupSearch((id, provider)); return
            }
            self.error = error.localizedDescription
            await cleanupSearch(detachSearch())
        }
    }

    func stopSearch() async { await cleanupSearch(detachSearch()) }

    private func detachWatch() -> (id: String, provider: any CodexAppFileRuntimeProviding)? {
        watchGeneration &+= 1
        let previous = watch
        watch = nil; watchingPath = nil
        watchTask?.cancel(); watchTask = nil
        return previous
    }

    private func detachSearch() -> (id: String, provider: any CodexAppFileRuntimeProviding)? {
        searchGeneration &+= 1
        let previous = search
        search = nil
        searchTask?.cancel(); searchTask = nil
        return previous
    }

    private func cleanupWatch(_ value: (id: String, provider: any CodexAppFileRuntimeProviding)?) async {
        if let value { _ = try? await value.provider.perform(CodexRequest.fsUnwatch(.init(watchID: value.id))) }
    }

    private func cleanupSearch(_ value: (id: String, provider: any CodexAppFileRuntimeProviding)?) async {
        if let value { _ = try? await value.provider.perform(CodexRequest.fuzzyFileSearchSessionStop(.init(sessionID: value.id))) }
    }

    static func absolutePath(_ input: String) throws -> String {
        let path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), !path.contains("\0") else { throw CodexAppFeatureError.invalidInput("Enter an absolute path.") }
        return URL(fileURLWithPath: path).standardized.path
    }

    @discardableResult
    private func run(resetFeedback: Bool = true, _ action: (any CodexAppFileRuntimeProviding) async throws -> (@MainActor () -> Void)) async -> Bool {
        guard !isLoading else { return false }
        guard let provider else { error = CodexAppFeatureError.disconnected.localizedDescription; return false }
        let generation = generation
        isLoading = true
        if resetFeedback { error = nil; message = nil }
        defer { if self.generation == generation { isLoading = false } }
        do {
            let apply = try await action(provider)
            guard self.generation == generation else { return false }
            try Task.checkCancellation(); apply()
            return true
        } catch is CancellationError {
        } catch { if self.generation == generation { self.error = error.localizedDescription } }
        return false
    }
}
