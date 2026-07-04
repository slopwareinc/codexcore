import Foundation
import SwiftUI

public protocol CodexClipboardService: Sendable {
    func copy(_ text: String)
}

public protocol CodexStringListPreferenceStore: Sendable {
    func loadStrings(forKey key: String) -> [String]
    func saveStrings(_ strings: [String], forKey key: String)
    func hasStrings(forKey key: String) -> Bool
}

public struct CodexNoopClipboardService: CodexClipboardService {
    public init() {}

    public func copy(_ text: String) {}
}

public struct CodexNoopStringListPreferenceStore: CodexStringListPreferenceStore {
    public init() {}

    public func loadStrings(forKey key: String) -> [String] { [] }
    public func saveStrings(_ strings: [String], forKey key: String) {}
    public func hasStrings(forKey key: String) -> Bool { false }
}

private struct CodexClipboardServiceKey: EnvironmentKey {
    static let defaultValue: any CodexClipboardService = CodexNoopClipboardService()
}

public extension EnvironmentValues {
    var codexClipboardService: any CodexClipboardService {
        get { self[CodexClipboardServiceKey.self] }
        set { self[CodexClipboardServiceKey.self] = newValue }
    }
}

public extension View {
    func codexClipboardService(_ service: any CodexClipboardService) -> some View {
        environment(\.codexClipboardService, service)
    }
}
