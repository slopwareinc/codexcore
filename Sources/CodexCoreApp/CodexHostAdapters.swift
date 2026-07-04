import AppKit
import CodexCoreUI

struct CodexAppKitClipboardService: CodexClipboardService {
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct CodexUserDefaultsStringListPreferenceStore: CodexStringListPreferenceStore {
    func loadStrings(forKey key: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func saveStrings(_ strings: [String], forKey key: String) {
        UserDefaults.standard.set(strings, forKey: key)
    }

    func hasStrings(forKey key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) != nil
    }
}
