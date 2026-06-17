import Foundation

// MARK: - PTY Models

public struct PTYDelta: Sendable {
    public enum StreamKind: String, Codable, Sendable {
        case stdout
        case stderr
    }

    public let stream: StreamKind
    public let data: Data
    public let capReached: Bool

    internal init?(streamName: String, base64Data: String, capReached: Bool) {
        guard let data = Data(base64Encoded: base64Data) else { return nil }
        self.stream = StreamKind(rawValue: streamName) ?? .stdout
        self.data = data
        self.capReached = capReached
    }
}
