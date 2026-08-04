import Foundation
import UserNotifications

enum CodexNotificationAuthorizationStatus: String, Equatable, Sendable {
    case unavailable
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case unknown

    var label: String {
        switch self {
        case .unavailable:
            "Unavailable for this launch"
        case .notDetermined:
            "Not requested"
        case .denied:
            "Denied in System Settings"
        case .authorized:
            "Allowed"
        case .provisional:
            "Allowed provisionally"
        case .ephemeral:
            "Allowed temporarily"
        case .unknown:
            "Unknown"
        }
    }
}

enum CodexNotificationAction: Equatable, Sendable {
    case open(threadID: String?)
    case approve(promptID: String)
    case deny(promptID: String)
}

/// Keeps UserNotifications behind a bundle boundary. The framework raises an
/// Objective-C exception when `current()` is called by an unbundled executable,
/// which is how `swift run codex-core-app` launches the reference app.
@MainActor
final class CodexAutomationNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let approvalCategoryIdentifier = "codex.approval-required"
    static let inputCategoryIdentifier = "codex.input-required"
    static let turnCompletionCategoryIdentifier = "codex.turn-complete"
    static let automationCategoryIdentifier = "codex.automation-complete"
    static let approveActionIdentifier = "codex.approve"
    static let denyActionIdentifier = "codex.deny"
    static let openActionIdentifier = "codex.open"

    nonisolated private static let notificationKindKey = "codex.notification.kind"
    nonisolated private static let threadIDKey = "codex.notification.threadID"
    nonisolated private static let promptIDKey = "codex.notification.promptID"

    private let center: UNUserNotificationCenter?

    private(set) var authorizationStatus: CodexNotificationAuthorizationStatus
    private(set) var authorizationError: String?
    var onAction: (@MainActor (CodexNotificationAction) -> Void)?
    var onAuthorizationStatusChange: (@MainActor (
        CodexNotificationAuthorizationStatus,
        String?
    ) -> Void)?

    var isAvailable: Bool { center != nil }

    init(bundle: Bundle = .main) {
        guard Self.supportsNotifications(
            bundleURL: bundle.bundleURL,
            bundleIdentifier: bundle.bundleIdentifier
        ) else {
            center = nil
            authorizationStatus = .unavailable
            super.init()
            return
        }

        let center = UNUserNotificationCenter.current()
        self.center = center
        authorizationStatus = .notDetermined
        super.init()
        center.delegate = self
        registerCategories()
        refreshAuthorizationStatus()
    }

    static func supportsNotifications(
        bundleURL: URL,
        bundleIdentifier: String?
    ) -> Bool {
        bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
            && !(bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func requestAuthorization() {
        guard let center else {
            authorizationStatus = .unavailable
            onAuthorizationStatusChange?(authorizationStatus, authorizationError)
            return
        }

        authorizationError = nil
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    authorizationError = error.localizedDescription
                } else if !granted {
                    authorizationError = "Notifications are disabled in System Settings."
                }
                refreshAuthorizationStatus()
            }
        }
    }

    func refreshAuthorizationStatus() {
        guard let center else {
            authorizationStatus = .unavailable
            onAuthorizationStatusChange?(authorizationStatus, authorizationError)
            return
        }

        center.getNotificationSettings { [weak self] settings in
            let status = Self.authorizationStatus(for: settings.authorizationStatus)
            Task { @MainActor [weak self] in
                guard let self else { return }
                authorizationStatus = status
                if status == .denied {
                    authorizationError = "Notifications are disabled in System Settings."
                }
                onAuthorizationStatusChange?(authorizationStatus, authorizationError)
            }
        }
    }

    func removePendingRequests(forAutomationID id: String) {
        center?.removePendingNotificationRequests(withIdentifiers: ["automation.\(id)"])
    }

    func postCompletion(name: String, failure: String?) {
        let content = UNMutableNotificationContent()
        content.title = failure == nil ? "Automation finished" : "Automation needs attention"
        content.body = failure ?? name
        content.sound = .default
        content.categoryIdentifier = Self.automationCategoryIdentifier
        content.userInfo = [Self.notificationKindKey: "automation"]
        add(content: content, identifier: "automation.run.\(UUID().uuidString)")
    }

    func postTurnCompletion(threadID: String?, title: String, failure: String?) {
        let content = UNMutableNotificationContent()
        content.title = failure == nil ? "Turn finished" : "Turn needs attention"
        content.body = failure ?? title
        content.sound = .default
        content.categoryIdentifier = Self.turnCompletionCategoryIdentifier
        content.userInfo = notificationUserInfo(
            kind: "turn",
            threadID: threadID
        )
        add(content: content, identifier: "turn.complete.\(UUID().uuidString)")
    }

    func postApprovalRequired(
        promptID: String,
        title: String,
        detail: String,
        threadID: String?
    ) {
        let content = blockingPromptContent(
            title: title,
            body: detail,
            categoryIdentifier: Self.approvalCategoryIdentifier,
            kind: "approval",
            promptID: promptID,
            threadID: threadID
        )
        add(content: content, identifier: "approval.required.\(promptID)")
    }

    func postInputRequired(
        promptID: String,
        title: String,
        detail: String,
        threadID: String?
    ) {
        let content = blockingPromptContent(
            title: title,
            body: detail,
            categoryIdentifier: Self.inputCategoryIdentifier,
            kind: "input",
            promptID: promptID,
            threadID: threadID
        )
        add(content: content, identifier: "input.required.\(promptID)")
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Blocking prompts use alert presentation so they stay visible until
        // the user explicitly dismisses or acts on them.
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let kind = userInfo[Self.notificationKindKey] as? String
        let promptID = userInfo[Self.promptIDKey] as? String
        let threadID = userInfo[Self.threadIDKey] as? String

        let notificationAction: CodexNotificationAction?
        switch action {
        case Self.approveActionIdentifier where kind == "approval":
            notificationAction = promptID.map { .approve(promptID: $0) }
        case Self.denyActionIdentifier where kind == "approval":
            notificationAction = promptID.map { .deny(promptID: $0) }
        case UNNotificationDefaultActionIdentifier where kind == "turn"
            || kind == "input"
            || kind == "approval"
            || kind == "automation":
            notificationAction = .open(threadID: threadID)
        case Self.openActionIdentifier where kind == "turn"
            || kind == "input"
            || kind == "approval"
            || kind == "automation":
            notificationAction = .open(threadID: threadID)
        default:
            notificationAction = nil
        }

        if let notificationAction {
            Task { @MainActor [weak self] in
                self?.onAction?(notificationAction)
            }
        }
        completionHandler()
    }

    private func registerCategories() {
        guard let center else { return }
        let approvalActions = [
            UNNotificationAction(
                identifier: Self.approveActionIdentifier,
                title: "Approve",
                options: [.foreground]
            ),
            UNNotificationAction(
                identifier: Self.denyActionIdentifier,
                title: "Deny",
                options: [.foreground]
            ),
        ]
        let openAction = UNNotificationAction(
            identifier: Self.openActionIdentifier,
            title: "Open",
            options: [.foreground]
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.approvalCategoryIdentifier,
                actions: approvalActions,
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: Self.inputCategoryIdentifier,
                actions: [openAction],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: Self.turnCompletionCategoryIdentifier,
                actions: [openAction],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: Self.automationCategoryIdentifier,
                actions: [openAction],
                intentIdentifiers: [],
                options: []
            ),
        ])
    }

    private func blockingPromptContent(
        title: String,
        body: String,
        categoryIdentifier: String,
        kind: String,
        promptID: String,
        threadID: String? = nil
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = 1
        content.userInfo = notificationUserInfo(
            kind: kind,
            threadID: threadID,
            promptID: promptID
        )
        return content
    }

    private func notificationUserInfo(
        kind: String,
        threadID: String? = nil,
        promptID: String? = nil
    ) -> [AnyHashable: Any] {
        var values: [AnyHashable: Any] = [Self.notificationKindKey: kind]
        if let threadID { values[Self.threadIDKey] = threadID }
        if let promptID { values[Self.promptIDKey] = promptID }
        return values
    }

    private func add(content: UNMutableNotificationContent, identifier: String) {
        guard let center else { return }
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                authorizationError = error.localizedDescription
                onAuthorizationStatusChange?(authorizationStatus, authorizationError)
            }
        }
    }

    nonisolated private static func authorizationStatus(
        for status: UNAuthorizationStatus
    ) -> CodexNotificationAuthorizationStatus {
        switch status {
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .authorized:
            .authorized
        case .provisional:
            .provisional
        case .ephemeral:
            .ephemeral
        @unknown default:
            .unknown
        }
    }
}
