import Foundation

public struct CodexWebSearchRowV2: Identifiable, Sendable, Equatable {
    public var id: String
    public var query: String
    public var status: CodexWorkItemStatusV2
    public var results: [CodexWebSearchResultV2]

    public init(
        id: String,
        query: String,
        status: CodexWorkItemStatusV2,
        results: [CodexWebSearchResultV2] = []
    ) {
        self.id = id
        self.query = query
        self.status = status
        self.results = results
    }
}

public struct CodexWebSearchResultV2: Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var url: String?
    public var snippet: String?

    public init(id: String, title: String, url: String? = nil, snippet: String? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}
