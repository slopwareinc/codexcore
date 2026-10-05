import Foundation
import Observation
import CodexCore

@MainActor @Observable
final class CodexAppProjectFeatures {
    private(set) var projects: [CodexSchemaProject] = []
    private(set) var selectedProject: CodexSchemaProject?
    private(set) var isLoading = false
    private(set) var error: String?
    var onChanged: (() async -> Void)?

    @ObservationIgnored private var provider: (any CodexAppRuntimeProviding)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var creation: (draft: Draft, key: String)?

    private struct Draft: Equatable {
        let name: String
        let roots: [String]
        let threadIDs: [String]
        let isImport: Bool
    }

    func bind(_ provider: (any CodexAppRuntimeProviding)?) {
        generation += 1
        self.provider = provider
        projects = []
        selectedProject = nil
        creation = nil
        error = nil
        isLoading = false
    }

    func clearSelection() { selectedProject = nil }

    func refresh() async {
        await run { provider in
            let projects = try await Self.loadAll(provider)
            return { self.projects = projects }
        }
    }

    func read(_ id: String) async {
        await run { provider in
            let response = try await provider.perform(CodexRequest.projectRead(.init(projectID: id)))
            return { self.selectedProject = response.project }
        }
    }

    func create(name: String, roots: [String], threadIDs: [String] = [], isImport: Bool = false) async {
        guard !isLoading else { return }
        do {
            let draft = Draft(name: try Self.validName(name), roots: try Self.validRoots(roots),
                              threadIDs: threadIDs.filter { !$0.isEmpty }, isImport: isImport)
            // Retain this idempotency key after uncertain failures. Retrying the
            // same draft must not create a second project on the server.
            if creation?.draft != draft { creation = (draft, UUID().uuidString) }
            guard let key = creation?.key else { return }
            await run(notifyChange: true) { provider in
                let roots = draft.roots.map { CodexSchemaProjectRoot(path: .init(.string($0))) }
                let project: CodexSchemaProject
                if draft.isImport {
                    project = try await provider.perform(CodexRequest.projectImport(.init(
                        idempotencyKey: key, name: draft.name, roots: roots, threads: draft.threadIDs
                    ))).project
                } else {
                    project = try await provider.perform(CodexRequest.projectCreate(.init(
                        idempotencyKey: key, name: draft.name, roots: roots
                    ))).project
                }
                return {
                    self.creation = nil
                    self.selectedProject = project
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func update(id: String, name: String, roots: [String]) async {
        do {
            let name = try Self.validName(name)
            let roots = try Self.validRoots(roots).map { CodexSchemaProjectRoot(path: .init(.string($0))) }
            await run(notifyChange: true) { provider in
                let response = try await provider.perform(CodexRequest.projectUpdate(.init(
                    name: name, projectID: id, roots: roots
                )))
                return { self.selectedProject = response.project }
            }
        } catch { self.error = error.localizedDescription }
    }

    func move(id: String, beforeID: String?) async {
        await run(notifyChange: true) { provider in
            _ = try await provider.perform(CodexRequest.projectMove(.init(beforeProjectID: beforeID, projectID: id)))
            return {}
        }
    }

    func delete(id: String) async {
        await run(notifyChange: true) { provider in
            _ = try await provider.perform(CodexRequest.projectDelete(.init(projectID: id)))
            return {
                self.projects.removeAll { $0.id == id }
                if self.selectedProject?.id == id { self.selectedProject = nil }
            }
        }
    }

    private func run(
        notifyChange: Bool = false,
        _ operation: (any CodexAppRuntimeProviding) async throws -> (@MainActor () -> Void)
    ) async {
        guard !isLoading else { return }
        guard let provider else { error = CodexAppFeatureError.disconnected.localizedDescription; return }
        let generation = generation
        isLoading = true
        error = nil
        defer { if self.generation == generation { isLoading = false } }
        do {
            try Task.checkCancellation()
            let apply = try await operation(provider)
            guard self.generation == generation else { return }
            try Task.checkCancellation()
            apply()
            if notifyChange {
                // The mutation is already accepted. Preserve its returned facts
                // even if the subsequent inventory refresh cannot complete.
                do {
                    let projects = try await Self.loadAll(provider)
                    guard self.generation == generation else { return }
                    self.projects = projects
                } catch {
                    guard self.generation == generation else { return }
                    self.error = "Project saved, but the project list could not refresh: " + error.localizedDescription
                }
                guard self.generation == generation else { return }
                await onChanged?()
            }
        } catch is CancellationError {
        } catch { if self.generation == generation { self.error = error.localizedDescription } }
    }

    private static func loadAll(_ provider: any CodexAppRuntimeProviding) async throws -> [CodexSchemaProject] {
        var projects: [CodexSchemaProject] = []
        var seen: Set<String> = []
        var cursor: String?
        repeat {
            try Task.checkCancellation()
            let response = try await provider.perform(CodexRequest.projectList(.init(cursor: cursor, limit: 100)))
            projects.append(contentsOf: response.data)
            cursor = response.nextCursor
            if let cursor, !seen.insert(cursor).inserted { throw CodexAppFeatureError.repeatedCursor }
        } while cursor != nil
        var seenIDs: Set<String> = []
        return projects.filter { seenIDs.insert($0.id).inserted }
    }

    static func validName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CodexAppFeatureError.invalidInput("Enter a project name.") }
        return name
    }

    static func validRoots(_ roots: [String]) throws -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for root in roots {
            let root = root.trimmingCharacters(in: .whitespacesAndNewlines)
            guard root.hasPrefix("/"), !root.contains("\0") else {
                throw CodexAppFeatureError.invalidInput("Project folders must be absolute paths.")
            }
            let path = URL(fileURLWithPath: root).standardized.path
            if seen.insert(path).inserted { result.append(path) }
        }
        guard !result.isEmpty else { throw CodexAppFeatureError.invalidInput("Add at least one project folder.") }
        return result
    }
}
