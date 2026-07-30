import Foundation

public struct CodexComposerDictationState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case starting
        case recording
        case transcribing
        case retry
    }

    public var phase: Phase
    public var duration: TimeInterval
    public var waveformLevels: [Double]
    public var errorMessage: String?

    public init(
        phase: Phase = .idle,
        duration: TimeInterval = 0,
        waveformLevels: [Double] = [],
        errorMessage: String? = nil
    ) {
        self.phase = phase
        self.duration = duration
        self.waveformLevels = waveformLevels
        self.errorMessage = errorMessage
    }

    public var isRecording: Bool {
        phase == .starting || phase == .recording || phase == .transcribing
    }
}

public struct CodexComposerDictationActions {
    public var start: @MainActor () -> Void
    public var stopAndInsert: @MainActor () -> Void
    public var stopAndSend: @MainActor () -> Void
    public var retry: @MainActor () -> Void
    public var abort: @MainActor () -> Void
    public var dismissError: @MainActor () -> Void

    public init(
        start: @escaping @MainActor () -> Void,
        stopAndInsert: @escaping @MainActor () -> Void,
        stopAndSend: @escaping @MainActor () -> Void,
        retry: @escaping @MainActor () -> Void,
        abort: @escaping @MainActor () -> Void,
        dismissError: @escaping @MainActor () -> Void
    ) {
        self.start = start
        self.stopAndInsert = stopAndInsert
        self.stopAndSend = stopAndSend
        self.retry = retry
        self.abort = abort
        self.dismissError = dismissError
    }
}
