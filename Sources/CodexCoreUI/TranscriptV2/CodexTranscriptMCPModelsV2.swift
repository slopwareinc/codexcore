import CodexCore
import Foundation

/// Bounded, typed MCP result content. Unknown object blocks become a typed
/// warning row; malformed non-object values fail closed. Raw JSON remains
/// available only through an explicit debug/copy path on the row.
public enum CodexMCPContentBlockV2: Sendable, Equatable {
    case text(String)
    case image(source: String, mimeType: String?, alt: String?)
    case audio(source: String, mimeType: String?)
    case resource(uri: String, mimeType: String?, text: String?)
    case resourceLink(uri: String, name: String?, mimeType: String?)
    case structured([String: CodexJSONValue])
    case widget(id: String?, uri: String?, payload: [String: CodexJSONValue])
    case unknown(type: String)

    public var kind: String {
        switch self {
        case .text: "text"
        case .image: "image"
        case .audio: "audio"
        case .resource: "resource"
        case .resourceLink: "resourceLink"
        case .structured: "structured"
        case .widget: "widget"
        case .unknown(let type): type.isEmpty ? "unknown" : type
        }
    }

    public var displayText: String? {
        switch self {
        case .text(let value): return value
        case .resource(_, _, let text): return text
        case .resourceLink(_, let name, _): return name
        case .image(_, _, let alt): return alt
        case .audio: return nil
        case .structured, .widget: return nil
        case .unknown: return "Unsupported MCP content"
        }
    }

    public var isInteractive: Bool {
        if case .widget = self { return true }
        return false
    }
}

public typealias CodexMCPContentBlock = CodexMCPContentBlockV2

public struct CodexMCPWidgetV2: Identifiable, Sendable, Equatable {
    public var id: String
    public var uri: String?
    public var payload: [String: CodexJSONValue]

    public enum State: String, Sendable, Equatable {
        case loading
        case ready
        case failed
        case disabled
    }

    public var state: State
    public var isSandboxed: Bool

    public init(
        id: String,
        uri: String? = nil,
        payload: [String: CodexJSONValue] = [:],
        state: State = .ready,
        isSandboxed: Bool = true
    ) {
        self.id = id
        self.uri = uri
        self.payload = payload
        self.state = state
        self.isSandboxed = isSandboxed
    }
}
