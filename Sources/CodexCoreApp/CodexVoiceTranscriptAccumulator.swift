import Foundation
import CodexCore

/// Item IDs own utterances when the runtime supplies them. Session-level
/// notifications provide compatibility fallback without duplicating mirrored
/// text or merging distinct utterances that happen to contain the same words.
struct CodexVoiceTranscriptAccumulator {
    private(set) var entries: [CodexVoiceTranscriptEntry] = []
    private var partialByRole: [String: UUID] = [:]
    private var itemByID: [String: Item] = [:]
    private var activeItemByRole: [String: String] = [:]
    private var entryIndexByID: [UUID: Int] = [:]
    private var completedItemAwaitingMirror: [String: String] = [:]

    private struct Item {
        let role: String
        let entryID: UUID
        var streamedText: String
        var hasDelta: Bool
    }

    mutating func reset() { self = .init() }

    mutating func appendLocalText(_ text: String) {
        append(.init(role: "user", text: text, isFinal: true))
    }

    mutating func sessionDelta(role rawRole: String, delta: String) {
        let role = rawRole.lowercased()
        guard !delta.isEmpty else { return }
        if let itemID = activeItemByRole[role], itemByID[itemID]?.hasDelta == true { return }
        let index = partialIndex(role: role)
        entries[index].text += delta
    }

    mutating func sessionDone(role rawRole: String, text: String) {
        let role = rawRole.lowercased()
        // A completed item's legacy mirror must not finalize a newer live
        // item of the same role when utterances overlap.
        if let completed = completedItemAwaitingMirror.removeValue(forKey: role),
           completed.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines) {
            return
        }
        if let id = partialByRole.removeValue(forKey: role), let index = index(id: id) {
            entries[index].text = text
            entries[index].isFinal = true
            return
        }
        // A mirrored session done follows the item completion. Only compare
        // the latest utterance; repeated messages later in a conversation are
        // independent entries.
        if let last = entries.indices.last,
           entries[last].role.lowercased() == role,
           entries[last].text.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines) {
            entries[last].isFinal = true
        } else if !text.isEmpty {
            append(.init(role: role, text: text, isFinal: true))
        }
    }

    mutating func itemStarted(_ raw: CodexSchemaThreadRealtimeItem) {
        guard let fields = raw.rawValue.objectValue,
              fields["type"] == .string("transcriptSegment"),
              case .string(let id)? = fields["id"],
              case .string(let rawRole)? = fields["role"] else { return }
        let role = rawRole.lowercased()
        if itemByID[id] != nil { return }
        if activeItemByRole[role] == nil { completedItemAwaitingMirror.removeValue(forKey: role) }
        let initialText = CodexJSONCoercion.flatString(from: fields["text"]) ?? ""
        let entryIndex: Int
        if activeItemByRole[role] != nil {
            let entry = CodexVoiceTranscriptEntry(role: role, text: "", isFinal: false)
            append(entry)
            partialByRole[role] = entry.id
            entryIndex = entries.count - 1
        } else {
            entryIndex = partialIndex(role: role)
        }
        let entryID = entries[entryIndex].id
        if !initialText.isEmpty { entries[entryIndex].text = initialText }
        itemByID[id] = Item(role: role, entryID: entryID, streamedText: initialText, hasDelta: false)
        activeItemByRole[role] = id
    }

    mutating func itemDelta(id: String, delta: String) {
        guard !delta.isEmpty, var item = itemByID[id], let index = index(id: item.entryID) else { return }
        item.streamedText += delta
        item.hasDelta = true
        entries[index].text = item.streamedText
        itemByID[id] = item
    }

    mutating func itemCompleted(_ raw: CodexSchemaThreadRealtimeItem) {
        guard let fields = raw.rawValue.objectValue,
              fields["type"] == .string("transcriptSegment"),
              case .string(let id)? = fields["id"] else { return }
        if itemByID[id] == nil { itemStarted(raw) }
        guard let item = itemByID.removeValue(forKey: id), let index = index(id: item.entryID) else { return }
        entries[index].text = CodexJSONCoercion.flatString(from: fields["text"]) ?? item.streamedText
        entries[index].isFinal = true
        completedItemAwaitingMirror[item.role] = entries[index].text
        if partialByRole[item.role] == item.entryID { partialByRole.removeValue(forKey: item.role) }
        if activeItemByRole[item.role] == id { activeItemByRole.removeValue(forKey: item.role) }
    }

    private mutating func partialIndex(role: String) -> Int {
        if let id = partialByRole[role], let index = index(id: id), !entries[index].isFinal { return index }
        let entry = CodexVoiceTranscriptEntry(role: role, text: "", isFinal: false)
        partialByRole[role] = entry.id
        append(entry)
        return entries.count - 1
    }

    private mutating func append(_ entry: CodexVoiceTranscriptEntry) {
        entryIndexByID[entry.id] = entries.count
        entries.append(entry)
    }
    private func index(id: UUID) -> Int? { entryIndexByID[id] }
}
