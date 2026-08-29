import Foundation

/// A citation/provenance entry supplied by an assistant response. The source
/// can be a URL, file reference, or a provider label; adapters bound payloads
/// before it reaches this presentation model.
public struct CodexTranscriptSourceCitationV2: Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var location: String
    public var snippet: String?
    public var sourceKind: String

    public init(
        id: String? = nil,
        title: String,
        location: String,
        snippet: String? = nil,
        sourceKind: String = "source"
    ) {
        let safeLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        self.location = String(safeLocation.prefix(4_096))
        self.snippet = snippet?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank.map { String($0.prefix(20_000)) }
        self.sourceKind = String((sourceKind.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "source").prefix(64))
        self.id = id ?? self.sourceKind + ":" + self.location + ":" + self.title
    }
}

/// A generated output/resource reference. Bytes stay behind the host's lazy
/// resource adapter and are never retained in canonical transcript rows.
public struct CodexTranscriptOutputResourceV2: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case file
        case image
        case audio
        case resource
        case unknown
    }

    public var id: String
    public var kind: Kind
    public var name: String
    public var location: String
    public var mimeType: String?
    public var sizeBytes: Int?
    public var isPreviewable: Bool

    public init(
        id: String? = nil,
        kind: Kind,
        name: String,
        location: String,
        mimeType: String? = nil,
        sizeBytes: Int? = nil,
        isPreviewable: Bool = false
    ) {
        let safeLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        self.location = String(safeLocation.prefix(4_096))
        self.mimeType = mimeType?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank.map { String($0.prefix(128)) }
        self.sizeBytes = sizeBytes.map { max(0, $0) }
        self.isPreviewable = isPreviewable
        self.id = id ?? kind.rawValue + ":" + self.location + ":" + self.name
    }
}

/// All provenance arms attached to one assistant item. Keeping this aggregate
/// separate from the event enum lets memory, source, and generated-output
/// annotations coexist without a second pass through canonical JSON.
public struct CodexTranscriptProvenanceV2: Sendable, Equatable {
    public var memoryCitations: [CodexMemoryCitationV2]
    public var sourceCitations: [CodexTranscriptSourceCitationV2]
    public var outputResources: [CodexTranscriptOutputResourceV2]

    public init(
        memoryCitations: [CodexMemoryCitationV2] = [],
        sourceCitations: [CodexTranscriptSourceCitationV2] = [],
        outputResources: [CodexTranscriptOutputResourceV2] = []
    ) {
        self.memoryCitations = memoryCitations
        self.sourceCitations = sourceCitations
        self.outputResources = outputResources
    }

    public var isEmpty: Bool {
        memoryCitations.isEmpty && sourceCitations.isEmpty && outputResources.isEmpty
    }
}
