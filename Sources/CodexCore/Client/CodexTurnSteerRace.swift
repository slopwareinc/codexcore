import Foundation

/// Recoverable active-turn races reported by app-server for `turn/steer`.
public enum CodexTurnSteerRace: Sendable, Equatable {
    /// The expected turn completed before app-server accepted the steer.
    case noActiveTurn
    /// The client cached a stale turn ID; app-server reports the current one.
    case expectedTurnMismatch(actualTurnID: String)
}

/// Classifies the two app-server errors for which an interactive steer client
/// can preserve the user's input without treating it as a generic failure.
///
/// Call this only for a failed `turn/steer` request. A missing active turn can
/// fall through to `turn/start`; a mismatch can be retried once with the
/// server-reported active turn ID.
public func classifyCodexTurnSteerRace(_ error: Error) -> CodexTurnSteerRace? {
    let message: String
    if let error = error as? CodexJSONRPCErrorObject {
        message = error.message
    } else if let error = error as? CodexRPCError {
        message = error.message
    } else {
        return nil
    }

    if message == "no active turn to steer" {
        return .noActiveTurn
    }

    let prefix = "expected active turn id `"
    let separator = "` but found `"
    guard let remainder = message.dropPrefix(prefix),
          let separatorRange = remainder.range(of: separator),
          remainder[separatorRange.upperBound...].last == "`"
    else { return nil }

    let actualWithSuffix = remainder[separatorRange.upperBound...]
    let actual = actualWithSuffix.dropLast()
    guard !actual.isEmpty else { return nil }
    return .expectedTurnMismatch(actualTurnID: String(actual))
}

private extension String {
    func dropPrefix(_ prefix: String) -> Substring? {
        guard hasPrefix(prefix) else { return nil }
        return dropFirst(prefix.count)
    }
}
