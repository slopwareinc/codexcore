/// The host's result after accepting an explicit transcript action.
/// Acceptance may enqueue processing; it does not mean the agent has answered.
public enum CodexTranscriptUserMessageReceipt: Sendable, Equatable {
    case accepted
    /// The host owns the failed submission and exposes it in its retry queue.
    case retainedForRetry(message: String)
    /// The host did not retain the submission. The card can offer another try.
    case rejected(message: String)
}
