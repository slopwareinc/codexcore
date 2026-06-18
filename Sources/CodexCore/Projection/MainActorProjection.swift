import Foundation

public enum CodexMainActorProjection {
    public static func run(_ operation: @MainActor () -> Void) async {
        await MainActor.run(body: operation)
    }

    public static func value<Value: Sendable>(_ operation: @MainActor () -> Value) async -> Value {
        await MainActor.run(body: operation)
    }
}
