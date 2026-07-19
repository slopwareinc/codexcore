/// A client-provided tool advertised to the app-server when a thread starts.
public struct CodexDynamicToolSpec: Codable, Sendable, Equatable {
    public var deferLoading: Bool?
    public var description: String
    public var inputSchema: CodexJSONValue
    public var name: String
    public var namespace: String?

    public init(
        name: String,
        description: String,
        inputSchema: CodexJSONValue,
        namespace: String? = nil,
        deferLoading: Bool? = nil
    ) {
        self.deferLoading = deferLoading
        self.description = description
        self.inputSchema = inputSchema
        self.name = name
        self.namespace = namespace
    }
}
