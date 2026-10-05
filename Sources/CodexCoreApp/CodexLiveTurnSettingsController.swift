import Observation
import CodexCore
import CodexCoreUI

/// Serializes live picker changes against one exact active turn. A newer full
/// desired selection replaces queued work; writes already in flight are never
/// replayed against a replacement turn.
@MainActor
@Observable
final class CodexLiveTurnSettingsController {
    private(set) var isUpdating = false
    private(set) var message: String?
    private(set) var errorMessage: String?
    @ObservationIgnored private var provider: (any CodexAppRuntimeProviding)?
    @ObservationIgnored private var target: TurnKey?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pending: CodexSchemaTurnSettingsUpdateParams?
    @ObservationIgnored private var worker: Task<Void, Never>?

    func bind(provider: (any CodexAppRuntimeProviding)?, target: TurnKey?) {
        guard self.target != target || (provider == nil) != (self.provider == nil) else { return }
        generation &+= 1
        worker?.cancel()
        worker = nil
        pending = nil
        self.provider = provider
        self.target = target
        isUpdating = false
        message = nil
        errorMessage = nil
    }

    /// Supply the complete desired model/effort/tier selection so coalescing
    /// cannot lose a previous picker change. `.null` explicitly clears a tier.
    func submit(model: String, effort: CodexSchemaReasoningEffort?, serviceTier: CodexAppServerOptionalField<String>) {
        guard let provider, let target else { return }
        pending = .init(
            effort: effort,
            model: model,
            serviceTier: serviceTier,
            threadID: target.threadID.rawValue,
            turnID: target.turnID.rawValue
        )
        message = nil
        errorMessage = nil
        guard worker == nil else { return }
        let binding = generation
        isUpdating = true
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, generation == binding, let params = pending {
                pending = nil
                do {
                    let response = try await provider.perform(CodexRequest.turnSettingsUpdate(params))
                    guard !Task.isCancelled, generation == binding else { return }
                    switch response.status {
                    case .applied: message = "Active turn settings updated."
                    case .targetUnavailable:
                        pending = nil
                        message = "The active turn ended. Your selection applies to the next turn."
                    case .unrecognized(let value):
                        pending = nil
                        errorMessage = "Codex returned an unknown settings status: \(value)."
                    }
                } catch {
                    guard !Task.isCancelled, generation == binding else { return }
                    pending = nil
                    errorMessage = CodexErrorFormat.localizedDescription(error)
                }
            }
            guard generation == binding else { return }
            worker = nil
            isUpdating = false
        }
    }

    func waitUntilIdle() async { await worker?.value }
}
