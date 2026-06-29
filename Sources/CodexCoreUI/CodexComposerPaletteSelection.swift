import Foundation

public struct CodexComposerPaletteSelection: Equatable, Sendable {
    public private(set) var selectedID: String?

    public init(selectedID: String? = nil) {
        self.selectedID = selectedID
    }

    public mutating func reconcile(availableIDs: [String]) {
        guard !availableIDs.isEmpty else {
            selectedID = nil
            return
        }
        if let selectedID, availableIDs.contains(selectedID) {
            return
        }
        selectedID = availableIDs.first
    }

    public mutating func moveDown(availableIDs: [String]) {
        move(by: 1, availableIDs: availableIDs)
    }

    public mutating func moveUp(availableIDs: [String]) {
        move(by: -1, availableIDs: availableIDs)
    }

    public mutating func clear() {
        selectedID = nil
    }

    private mutating func move(by offset: Int, availableIDs: [String]) {
        guard !availableIDs.isEmpty else {
            selectedID = nil
            return
        }

        let currentIndex = selectedID.flatMap { availableIDs.firstIndex(of: $0) }
        let startingIndex = currentIndex ?? (offset > 0 ? -1 : 0)
        let nextIndex = (startingIndex + offset + availableIDs.count) % availableIDs.count
        selectedID = availableIDs[nextIndex]
    }
}
