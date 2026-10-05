import Foundation
import Observation
import CodexCore

@MainActor @Observable
final class CodexAppExperimentalFeatures {
    private(set) var features: [CodexSchemaExperimentalFeature] = []
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var compressionResult: String?
    @ObservationIgnored private var provider: (any CodexAppRuntimeProviding)?
    @ObservationIgnored private var generation = 0

    func bind(_ provider: (any CodexAppRuntimeProviding)?) {
        generation += 1; self.provider = provider
        features = []; error = nil; isLoading = false; compressionResult = nil
    }

    func refresh(threadID: String? = nil) async {
        await run { provider in
            var cursor: String?
            var seen: Set<String> = []
            var features: [CodexSchemaExperimentalFeature] = []
            repeat {
                try Task.checkCancellation()
                let result = try await provider.perform(CodexRequest.experimentalFeatureList(.init(
                    cursor: cursor, limit: 100, threadID: threadID
                )))
                features.append(contentsOf: result.data)
                cursor = result.nextCursor
                if let cursor, !seen.insert(cursor).inserted { throw CodexAppFeatureError.repeatedCursor }
            } while cursor != nil
            return { self.features = features }
        }
    }

    func setEnabled(_ enabled: Bool, name: String, threadID: String? = nil) async {
        await run { provider in
            _ = try await provider.perform(CodexRequest.experimentalFeatureEnablementSet(.init(enablement: [name: enabled])))
            return {
                if let index = self.features.firstIndex(where: { $0.name == name }) { self.features[index].enabled = enabled }
            }
        }
    }

    func compressRollouts() async {
        await run { provider in
            _ = try await provider.perform(CodexRequest.rolloutCompress())
            return { self.compressionResult = "Compression scheduled. Codex will process eligible stored rollouts in the background." }
        }
    }

    private func run(_ action: (any CodexAppRuntimeProviding) async throws -> (@MainActor () -> Void)) async {
        guard !isLoading else { return }
        guard let provider else { error = CodexAppFeatureError.disconnected.localizedDescription; return }
        let generation = generation
        isLoading = true; error = nil
        defer { if self.generation == generation { isLoading = false } }
        do {
            let apply = try await action(provider)
            guard self.generation == generation else { return }
            try Task.checkCancellation()
            apply()
        } catch is CancellationError {
        } catch { if self.generation == generation { self.error = error.localizedDescription } }
    }
}
