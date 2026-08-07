import Foundation
import UserNotifications

/// Keeps UserNotifications behind a bundle boundary. The framework raises an
/// Objective-C exception when `current()` is called by an unbundled executable,
/// which is how `swift run codex-core-app` launches the reference app.
@MainActor
struct CodexAutomationNotificationService {
    private let center: UNUserNotificationCenter?

    var isAvailable: Bool { center != nil }

    init(bundle: Bundle = .main) {
        guard Self.supportsNotifications(
            bundleURL: bundle.bundleURL,
            bundleIdentifier: bundle.bundleIdentifier
        ) else {
            center = nil
            return
        }
        center = UNUserNotificationCenter.current()
    }

    static func supportsNotifications(
        bundleURL: URL,
        bundleIdentifier: String?
    ) -> Bool {
        bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
            && !(bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func removePendingRequests(forAutomationID id: String) {
        center?.removePendingNotificationRequests(withIdentifiers: ["automation.\(id)"])
    }

    func postCompletion(name: String, failure: String?) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = failure == nil ? "Automation finished" : "Automation needs attention"
        content.body = failure ?? name
        content.sound = .default
        center.add(UNNotificationRequest(
            identifier: "automation.run.\(UUID().uuidString)",
            content: content,
            trigger: nil
        ))
    }
}
