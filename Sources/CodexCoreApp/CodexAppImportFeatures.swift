import Foundation
import Observation
import CodexCore

protocol CodexAppImportRuntimeProviding: CodexAppRuntimeProviding {
    func observeImports() async throws -> AsyncThrowingStream<CodexExternalAgentConfigImportEvent, Error>
}

extension CodexAppRuntimeProvider: CodexAppImportRuntimeProviding {
    func observeImports() async throws -> AsyncThrowingStream<CodexExternalAgentConfigImportEvent, Error> {
        try await codex.observeExternalAgentConfigImport()
    }
}

@MainActor @Observable
final class CodexAppImportFeatures {
    private(set) var items: [CodexSchemaExternalAgentConfigMigrationItem] = []
    private(set) var histories: [CodexSchemaExternalAgentConfigImportHistory] = []
    private(set) var connectors: [CodexSchemaExternalAgentDetectedConnectorCandidate] = []
    private(set) var completion: CodexSchemaExternalAgentConfigImportCompletedNotification?
    private(set) var progress: CodexSchemaExternalAgentConfigImportProgressNotification?
    private(set) var isLoading = false
    private(set) var isImporting = false
    private(set) var error: String?
    @ObservationIgnored private var provider: (any CodexAppImportRuntimeProviding)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var observerTask: Task<Void, Never>?
    @ObservationIgnored private var importID: String?
    @ObservationIgnored private var importGeneration = 0
    @ObservationIgnored private var importStreamEnded = false
    @ObservationIgnored private var earlyCompletions: [String: CodexSchemaExternalAgentConfigImportCompletedNotification] = [:]

    func bind(_ provider: (any CodexAppImportRuntimeProviding)?) {
        observerTask?.cancel()
        observerTask = nil
        generation += 1
        importGeneration &+= 1
        importStreamEnded = false
        self.provider = provider
        items = []; histories = []; connectors = []
        completion = nil; progress = nil; error = nil; importID = nil
        earlyCompletions = [:]; isLoading = false; isImporting = false
    }

    func detect(source: String?, folders: [String], includeHome: Bool) async {
        guard !isLoading, !isImporting, let provider else { return }
        let generation = generation
        isLoading = true; error = nil
        defer { if self.generation == generation { isLoading = false } }
        do {
            let result = try await provider.perform(CodexRequest.externalAgentConfigDetect(.init(
                cwds: folders, includeHome: includeHome, maxSessions: 100, source: source?.nilIfEmpty
            )))
            guard self.generation == generation else { return }
            items = result.items
            connectors = result.connectors ?? []
        } catch { if self.generation == generation { self.error = error.localizedDescription } }
    }

    func readHistory() async {
        guard let provider else { return }
        let generation = generation
        do {
            let result = try await provider.perform(CodexRequest.externalAgentConfigImportReadHistories())
            guard self.generation == generation else { return }
            histories = result.data.sorted { $0.completedAtMs > $1.completedAtMs }
        } catch { if self.generation == generation { self.error = error.localizedDescription } }
    }

    func startImport(indices: Set<Int>, source: String?) async {
        guard !isLoading, !isImporting, let provider else { return }
        let selected = indices.sorted().compactMap { items.indices.contains($0) ? items[$0] : nil }
        guard !selected.isEmpty else { error = "Choose at least one item to import."; return }
        let generation = generation
        importGeneration &+= 1
        let operation = importGeneration
        isImporting = true; error = nil; completion = nil; progress = nil
        earlyCompletions = [:]; importID = nil; importStreamEnded = false
        do {
            // The server assigns the import ID. Observe the connection first,
            // then match that ID, so completion before the RPC response is safe.
            let events = try await provider.observeImports()
            guard self.generation == generation, importGeneration == operation else { return }
            try Task.checkCancellation()
            observerTask = Task { [weak self] in
                do {
                    for try await event in events {
                        guard !Task.isCancelled, let self, self.generation == generation,
                              self.importGeneration == operation else { return }
                        switch event {
                        case .progress(let value):
                            if value.importID == self.importID { self.progress = value }
                        case .completed(let value):
                            if self.importID == value.importID {
                                self.finish(value)
                                await self.readHistory()
                                return
                            } else if self.importID == nil {
                                if self.earlyCompletions.count >= 16 {
                                    throw CodexAppFeatureError.invalidInput("Too many concurrent imports. Refresh import history to reconcile the result.")
                                }
                                self.earlyCompletions[value.importID] = value
                            }
                        }
                    }
                    guard !Task.isCancelled, let self, self.generation == generation,
                          self.importGeneration == operation, self.isImporting else { return }
                    self.importStreamEnded = true
                    self.isImporting = false
                    self.error = "Import updates ended before completion. Refresh import history to reconcile the result."
                    await self.readHistory()
                } catch is CancellationError {
                } catch {
                    guard let self, self.generation == generation, self.importGeneration == operation else { return }
                    self.importStreamEnded = true
                    self.error = error.localizedDescription
                    self.isImporting = false
                }
            }
            let result = try await provider.perform(CodexRequest.externalAgentConfigImport(.init(
                migrationItems: selected, source: source?.nilIfEmpty
            )))
            guard self.generation == generation, importGeneration == operation else { return }
            importID = result.importID
            if let value = earlyCompletions[result.importID] {
                finish(value)
                await readHistory()
            }
            earlyCompletions = [:]
            if importStreamEnded, completion == nil { await readHistory() }
        } catch {
            guard self.generation == generation, importGeneration == operation else { return }
            observerTask?.cancel(); observerTask = nil
            isImporting = false
            self.error = error.localizedDescription
        }
    }

    func recordReceipt(providerID: String) async {
        guard let provider, let completion, let providerID = providerID.nilIfEmpty else { return }
        let generation = generation
        do {
            _ = try await provider.perform(CodexRequest.externalAgentConfigImportRecordHistory(.init(
                itemTypeResults: completion.itemTypeResults.map { result in
                    .init(failures: result.failures, itemType: result.itemType, successes: result.successes.map {
                        .init(cwd: $0.cwd, itemType: $0.itemType, source: $0.source, target: $0.target, title: $0.title)
                    })
                }, providerID: providerID
            )))
            guard self.generation == generation else { return }
            await readHistory()
        } catch { if self.generation == generation { self.error = error.localizedDescription } }
    }

    private func finish(_ value: CodexSchemaExternalAgentConfigImportCompletedNotification) {
        completion = value; isImporting = false
        observerTask?.cancel(); observerTask = nil
        let failures = value.itemTypeResults.flatMap(\.failures)
        error = failures.isEmpty ? nil : failures.map(\.message).joined(separator: "\n")
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
