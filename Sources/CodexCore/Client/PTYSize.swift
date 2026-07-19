/// Initial pseudo-terminal dimensions for an app-server command execution.
public struct PTYSize: Codable, Sendable, Equatable {
    public let rows: Int
    public let cols: Int

    public init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
    }
}
