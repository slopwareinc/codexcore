import Foundation
import CodexCore

@MainActor
public final class CodexMentionSearchSession {
    private var searchTask: Task<Void, Never>?

    public init() {}

    public func updateQuery(
        _ query: String?,
        codex: Codex?,
        roots: [String],
        debounceNanoseconds: UInt64 = 120_000_000,
        onResults: @escaping @MainActor ([FuzzyFileSearchResult]) -> Void,
        onClear: @escaping @MainActor () -> Void
    ) {
        updateQuery(
            query,
            debounceNanoseconds: debounceNanoseconds,
            search: { query in
                guard let codex else { return [] }
                return try await codex.perform(CodexRequest.fuzzyFileSearch(.init(
                    query: query,
                    roots: roots
                ))).files
            },
            onResults: onResults,
            onClear: onClear
        )
    }

    public func updateQuery(
        _ query: String?,
        debounceNanoseconds: UInt64 = 120_000_000,
        search: @escaping (String) async throws -> [FuzzyFileSearchResult],
        onResults: @escaping @MainActor ([FuzzyFileSearchResult]) -> Void,
        onClear: @escaping @MainActor () -> Void
    ) {
        searchTask?.cancel()
        guard let query else {
            onClear()
            return
        }

        searchTask = Task {
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            do {
                let results = try await search(query)
                guard !Task.isCancelled else { return }
                await MainActor.run { onResults(results) }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { onClear() }
            }
        }
    }

    public func reset() {
        searchTask?.cancel()
        searchTask = nil
    }
}
