import CodexCore
import Foundation
import SwiftUI

public struct CodexWorkspaceTabID: Hashable, Codable, Identifiable, Sendable {
    public let rawValue: UUID
    public var id: UUID { rawValue }
    init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct CodexWorkspaceTabContentID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public enum CodexWorkspaceTabHandle: Hashable, Codable, Sendable, Identifiable {
    case workspace(CodexWorkspaceTabID)
    case legacy(String)

    public var id: Self { self }
    public var workspaceTabID: CodexWorkspaceTabID? {
        guard case .workspace(let id) = self else { return nil }
        return id
    }
    public var legacyID: String? {
        guard case .legacy(let id) = self else { return nil }
        return id
    }
}

public enum CodexWorkspaceTabPlacement: String, Codable, Sendable {
    case right
    case bottom
    public var other: Self { self == .right ? .bottom : .right }
}

public enum CodexWorkspaceTabOpener: String, Codable, Sendable {
    case summary
    case transcript
    case commandMenu
    case restoration
    case background
}

public enum CodexWorkspaceTabLifetime: String, Codable, Sendable {
    case preview
    case pinned
}

public struct CodexWorkspaceTabRoute: Hashable, Codable, Sendable {
    public let adapterID: String
    public let version: Int
    public let resourceID: String
    public let payload: Data

    public init(
        adapterID: String,
        version: Int,
        resourceID: String,
        payload: Data = Data()
    ) {
        self.adapterID = adapterID
        self.version = version
        self.resourceID = resourceID
        self.payload = payload
    }
}

public struct CodexWorkspaceTabState: Hashable, Codable, Sendable {
    public var data: Data
    public init(data: Data = Data()) { self.data = data }
}

public struct CodexWorkspaceTabOpenMetadata: Codable, Sendable, Equatable {
    public let opener: CodexWorkspaceTabOpener
    public let insertionIndex: Int
    public let replacedResourceKey: String?
    public let replacedRoute: CodexWorkspaceTabRoute?
}

public struct CodexWorkspaceTabInstanceSnapshot: Identifiable, Codable, Sendable, Equatable {
    public let id: CodexWorkspaceTabID
    public let contentID: CodexWorkspaceTabContentID
    public fileprivate(set) var title: String
    public fileprivate(set) var systemImage: String
    public fileprivate(set) var isPinned: Bool
    public fileprivate(set) var durableRoute: CodexWorkspaceTabRoute?
    public fileprivate(set) var openMetadata: CodexWorkspaceTabOpenMetadata
    public fileprivate(set) var state: CodexWorkspaceTabState
    public fileprivate(set) var isMaterialized: Bool
    fileprivate var resourceKey: String
    fileprivate var restorableRoute: CodexWorkspaceTabRoute?
}

public struct CodexWorkspaceTabPanelSnapshot: Codable, Sendable, Equatable {
    public var orderedTabs: [CodexWorkspaceTabHandle] = []
    public var activeTab: CodexWorkspaceTabHandle?
    public var isOpen = false
    public var orderedTabIDs: [CodexWorkspaceTabID] { orderedTabs.compactMap(\.workspaceTabID) }
    public var activeTabID: CodexWorkspaceTabID? { activeTab?.workspaceTabID }

    mutating func remove(_ handle: CodexWorkspaceTabHandle) {
        guard let index = orderedTabs.firstIndex(of: handle) else { return }
        orderedTabs.remove(at: index)
        if activeTab == handle {
            activeTab = orderedTabs.indices.contains(index) ? orderedTabs[index] : orderedTabs.last
        }
        if orderedTabs.isEmpty { activeTab = nil; isOpen = false }
    }

    mutating func retainWorkspaceTabs(_ ids: Set<CodexWorkspaceTabID>) {
        orderedTabs.removeAll { $0.workspaceTabID.map { !ids.contains($0) } ?? true }
        if let activeTab, !orderedTabs.contains(activeTab) { self.activeTab = orderedTabs.last }
        if orderedTabs.isEmpty { activeTab = nil; isOpen = false }
    }
}

public struct CodexWorkspaceTabTopologySnapshot: Codable, Sendable, Equatable {
    public var right = CodexWorkspaceTabPanelSnapshot()
    public var bottom = CodexWorkspaceTabPanelSnapshot()
    public var focusedPlacement: CodexWorkspaceTabPlacement?

    subscript(_ placement: CodexWorkspaceTabPlacement) -> CodexWorkspaceTabPanelSnapshot {
        get { placement == .right ? right : bottom }
        set { if placement == .right { right = newValue } else { bottom = newValue } }
    }
}

public struct CodexWorkspaceTabRestorationState: Codable, Sendable, Equatable {
    public let tabs: [CodexWorkspaceTabInstanceSnapshot]
    public let topology: CodexWorkspaceTabTopologySnapshot
}

public struct CodexWorkspaceTabSnapshot: Sendable, Equatable {
    public var instances: [CodexWorkspaceTabInstanceSnapshot]
    public var topology: CodexWorkspaceTabTopologySnapshot
    public func instance(id: CodexWorkspaceTabID) -> CodexWorkspaceTabInstanceSnapshot? {
        instances.first { $0.id == id }
    }
}

@MainActor
public protocol CodexWorkspaceTabAdapter {
    var workspaceTabRegistration: CodexWorkspaceTabRegistration { get }
}

public struct CodexWorkspaceTabRegistration {
    let resourceKey: String
    let title: String
    let systemImage: String
    let lifetime: CodexWorkspaceTabLifetime
    let durableRoute: CodexWorkspaceTabRoute?
    let initialState: CodexWorkspaceTabState
    let reopenState: CodexWorkspaceTabState?
    let preferredPlacement: CodexWorkspaceTabPlacement
    let onClose: (@MainActor () -> Void)?
    let makeContent: @MainActor (Binding<CodexWorkspaceTabState>) -> AnyView

    init(
        resourceKey: String,
        title: String,
        systemImage: String,
        lifetime: CodexWorkspaceTabLifetime = .pinned,
        durableRoute: CodexWorkspaceTabRoute? = nil,
        initialState: CodexWorkspaceTabState = .init(),
        reopenState: CodexWorkspaceTabState? = nil,
        preferredPlacement: CodexWorkspaceTabPlacement = .right,
        onClose: (@MainActor () -> Void)? = nil,
        makeContent: @escaping @MainActor (Binding<CodexWorkspaceTabState>) -> AnyView
    ) {
        self.resourceKey = resourceKey
        self.title = title
        self.systemImage = systemImage
        self.lifetime = lifetime
        self.durableRoute = durableRoute
        self.initialState = initialState
        self.reopenState = reopenState
        self.preferredPlacement = preferredPlacement
        self.onClose = onClose
        self.makeContent = makeContent
    }
}

/// Reducer-owned presentation state plus a runtime-only adapter registry.
/// Routes/state encode no canonical Plan or Review payloads; adapters resolve
/// current projected facts lazily when a tab becomes visible.
@MainActor
public final class CodexWorkspaceTabs: ObservableObject {
    private struct Closed {
        var tab: CodexWorkspaceTabInstanceSnapshot
        var registration: CodexWorkspaceTabRegistration?
        var placement: CodexWorkspaceTabPlacement
        var tabIndex: Int
        var instanceIndex: Int
    }

    @Published public private(set) var snapshot = CodexWorkspaceTabSnapshot(
        instances: [],
        topology: .init()
    )
    private var registrations: [CodexWorkspaceTabID: CodexWorkspaceTabRegistration] = [:]
    private var closed: Closed?

    public init() {}

    public init(restoring restoration: CodexWorkspaceTabRestorationState) {
        let tabs = restoration.tabs.map { tab in
            var tab = tab
            tab.isMaterialized = false
            return tab
        }
        snapshot = .init(instances: tabs, topology: restoration.topology)
    }

    public var lastClosedRoute: CodexWorkspaceTabRoute? { closed?.tab.durableRoute }

    public var restorationState: CodexWorkspaceTabRestorationState {
        let tabs = snapshot.instances.compactMap { tab -> CodexWorkspaceTabInstanceSnapshot? in
            guard tab.durableRoute != nil else { return nil }
            var tab = tab
            tab.isMaterialized = false
            return tab
        }
        let ids = Set(tabs.map(\.id))
        var topology = snapshot.topology
        topology.right.retainWorkspaceTabs(ids)
        topology.bottom.retainWorkspaceTabs(ids)
        if let focus = topology.focusedPlacement, !topology[focus].isOpen {
            topology.focusedPlacement = topology[focus.other].isOpen ? focus.other : nil
        }
        return .init(tabs: tabs, topology: topology)
    }

    public func register(_ adapters: [any CodexWorkspaceTabAdapter]) {
        let available = adapters.map(\.workspaceTabRegistration)
        for index in snapshot.instances.indices {
            let id = snapshot.instances[index].id
            let route = snapshot.instances[index].restorableRoute
            let registration = route.flatMap { route in
                available.first { $0.durableRoute == route }
            } ?? available.first {
                route == nil && $0.resourceKey == snapshot.instances[index].resourceKey
            }
            if let registration {
                registrations[id] = registration
                snapshot.instances[index].title = registration.title
                snapshot.instances[index].systemImage = registration.systemImage
            } else {
                registrations.removeValue(forKey: id)
                snapshot.instances[index].isMaterialized = false
            }
        }
    }

    @discardableResult
    public func open(
        _ adapter: any CodexWorkspaceTabAdapter,
        from opener: CodexWorkspaceTabOpener
    ) -> CodexWorkspaceTabID {
        open(adapter, from: opener, placement: nil, focus: true)
    }

    /// Opens a resource in the requested panel. When `focus` is false the tab
    /// is retained and the panel is opened, but the current active tab and
    /// focused panel remain unchanged; this is the background-terminal path.
    @discardableResult
    public func open(
        _ adapter: any CodexWorkspaceTabAdapter,
        from opener: CodexWorkspaceTabOpener,
        placement requestedPlacement: CodexWorkspaceTabPlacement? = nil,
        focus: Bool = true
    ) -> CodexWorkspaceTabID {
        let registration = adapter.workspaceTabRegistration
        if let index = snapshot.instances.firstIndex(where: { $0.resourceKey == registration.resourceKey }) {
            return reopen(
                index,
                registration: registration,
                opener: opener,
                requestedPlacement: requestedPlacement,
                focus: focus
            )
        }
        if registration.lifetime == .preview,
           let index = snapshot.instances.firstIndex(where: { !$0.isPinned }) {
            return replacePreview(
                index,
                registration: registration,
                opener: opener,
                requestedPlacement: requestedPlacement,
                focus: focus
            )
        }
        let placement = requestedPlacement ?? registration.preferredPlacement
        let id = CodexWorkspaceTabID()
        let tab = CodexWorkspaceTabInstanceSnapshot(
            id: id,
            contentID: CodexWorkspaceTabContentID(),
            title: registration.title,
            systemImage: registration.systemImage,
            isPinned: registration.lifetime == .pinned,
            durableRoute: registration.lifetime == .pinned ? registration.durableRoute : nil,
            openMetadata: .init(
                opener: opener,
                insertionIndex: snapshot.topology[placement].orderedTabs.count,
                replacedResourceKey: nil,
                replacedRoute: nil
            ),
            state: registration.initialState,
            isMaterialized: true,
            resourceKey: registration.resourceKey,
            restorableRoute: registration.durableRoute
        )
        snapshot.instances.append(tab)
        registrations[id] = registration
        activate(.workspace(id), in: placement, inserting: true, focus: focus)
        return id
    }

    @discardableResult
    public func openInBackground(
        _ adapter: any CodexWorkspaceTabAdapter,
        from opener: CodexWorkspaceTabOpener = .background,
        placement: CodexWorkspaceTabPlacement? = nil
    ) -> CodexWorkspaceTabID {
        open(adapter, from: opener, placement: placement, focus: false)
    }

    private func reopen(
        _ index: Int,
        registration: CodexWorkspaceTabRegistration,
        opener: CodexWorkspaceTabOpener,
        requestedPlacement: CodexWorkspaceTabPlacement?,
        focus: Bool
    ) -> CodexWorkspaceTabID {
        var tab = snapshot.instances[index]
        let placement = placement(of: .workspace(tab.id)) ?? .right
        let previousRoute = tab.durableRoute
        tab.title = registration.title
        tab.systemImage = registration.systemImage
        tab.isMaterialized = true
        tab.restorableRoute = registration.durableRoute
        if tab.isPinned { tab.durableRoute = registration.durableRoute }
        if let state = registration.reopenState { tab.state = state }
        tab.openMetadata = .init(
            opener: opener,
            insertionIndex: snapshot.topology[placement].orderedTabs.firstIndex(of: .workspace(tab.id)) ?? index,
            replacedResourceKey: nil,
            replacedRoute: previousRoute == registration.durableRoute ? nil : previousRoute
        )
        snapshot.instances[index] = tab
        registrations[tab.id] = registration
        let destination = requestedPlacement ?? placement
        if destination != placement {
            move(tab.id, to: destination, focus: focus)
        } else {
            activate(.workspace(tab.id), in: placement, focus: focus)
        }
        return tab.id
    }

    private func replacePreview(
        _ index: Int,
        registration: CodexWorkspaceTabRegistration,
        opener: CodexWorkspaceTabOpener,
        requestedPlacement: CodexWorkspaceTabPlacement?,
        focus: Bool
    ) -> CodexWorkspaceTabID {
        var tab = snapshot.instances[index]
        let placement = placement(of: .workspace(tab.id)) ?? .right
        let oldKey = tab.resourceKey
        let oldRoute = tab.durableRoute
        tab.title = registration.title
        tab.systemImage = registration.systemImage
        tab.resourceKey = registration.resourceKey
        tab.restorableRoute = registration.durableRoute
        tab.durableRoute = nil
        tab.state = registration.initialState
        tab.isMaterialized = true
        tab.openMetadata = .init(
            opener: opener,
            insertionIndex: snapshot.topology[placement].orderedTabs.firstIndex(of: .workspace(tab.id)) ?? index,
            replacedResourceKey: oldKey,
            replacedRoute: oldRoute
        )
        snapshot.instances[index] = tab
        registrations[tab.id] = registration
        let destination = requestedPlacement ?? placement
        if destination != placement {
            move(tab.id, to: destination, focus: focus)
        } else {
            activate(.workspace(tab.id), in: placement, focus: focus)
        }
        return tab.id
    }

    public func pin(_ id: CodexWorkspaceTabID) {
        guard let index = index(of: id), !snapshot.instances[index].isPinned else { return }
        snapshot.instances[index].isPinned = true
        snapshot.instances[index].durableRoute = snapshot.instances[index].restorableRoute
    }

    public func activate(_ id: CodexWorkspaceTabID) {
        guard let index = index(of: id), let placement = placement(of: .workspace(id)) else { return }
        if registrations[id] != nil { snapshot.instances[index].isMaterialized = true }
        activate(.workspace(id), in: placement, focus: true)
    }

    public func move(_ id: CodexWorkspaceTabID, to destination: CodexWorkspaceTabPlacement) {
        move(id, to: destination, focus: true)
    }

    /// Moves a tab without changing focus. This is used by background openers
    /// and drag/drop-style topology updates where the user is still working in
    /// the original panel.
    public func move(
        _ id: CodexWorkspaceTabID,
        to destination: CodexWorkspaceTabPlacement,
        focus: Bool
    ) {
        guard let source = placement(of: .workspace(id)) else { return }
        guard source != destination else {
            if focus { activate(id) }
            return
        }
        remove(.workspace(id), from: source)
        activate(.workspace(id), in: destination, inserting: true, focus: focus)
    }

    public func orderedTabs(in placement: CodexWorkspaceTabPlacement) -> [CodexWorkspaceTabHandle] {
        snapshot.topology[placement].orderedTabs
    }

    public func activeTab(in placement: CodexWorkspaceTabPlacement) -> CodexWorkspaceTabHandle? {
        snapshot.topology[placement].activeTab
    }

    public func isOpen(in placement: CodexWorkspaceTabPlacement) -> Bool {
        snapshot.topology[placement].isOpen
    }

    public func placement(of id: CodexWorkspaceTabID) -> CodexWorkspaceTabPlacement? {
        placement(of: .workspace(id))
    }

    /// Restores focus to the last focused open panel, falling back to the other
    /// open panel when the saved placement has been closed or emptied.
    public func restoreFocus() {
        if let focusedPlacement = snapshot.topology.focusedPlacement,
           snapshot.topology[focusedPlacement].isOpen {
            return
        }
        if snapshot.topology.right.isOpen {
            snapshot.topology.focusedPlacement = .right
        } else if snapshot.topology.bottom.isOpen {
            snapshot.topology.focusedPlacement = .bottom
        } else {
            snapshot.topology.focusedPlacement = nil
        }
    }

    public func updateState(_ state: CodexWorkspaceTabState, for id: CodexWorkspaceTabID) {
        guard let index = index(of: id), snapshot.instances[index].state != state else { return }
        snapshot.instances[index].state = state
    }

    public func content(for id: CodexWorkspaceTabID) -> AnyView? {
        guard let index = index(of: id), snapshot.instances[index].isMaterialized,
              let registration = registrations[id] else { return nil }
        return registration.makeContent(Binding(
            get: { [weak self] in self?.snapshot.instance(id: id)?.state ?? .init() },
            set: { [weak self] in self?.updateState($0, for: id) }
        ))
    }

    public func isAvailable(_ id: CodexWorkspaceTabID) -> Bool { registrations[id] != nil }

    public func close(_ id: CodexWorkspaceTabID) {
        let handle = CodexWorkspaceTabHandle.workspace(id)
        guard let placement = placement(of: handle), let instanceIndex = index(of: id),
              let tabIndex = snapshot.topology[placement].orderedTabs.firstIndex(of: handle) else { return }
        let registration = registrations.removeValue(forKey: id)
        closed = .init(
            tab: snapshot.instances.remove(at: instanceIndex),
            registration: registration,
            placement: placement,
            tabIndex: tabIndex,
            instanceIndex: instanceIndex
        )
        remove(handle, from: placement)
        registration?.onClose?()
    }

    @discardableResult
    public func undoClose() -> CodexWorkspaceTabID? {
        guard let closed, index(of: closed.tab.id) == nil else { return nil }
        self.closed = nil
        snapshot.instances.insert(closed.tab, at: min(closed.instanceIndex, snapshot.instances.count))
        registrations[closed.tab.id] = closed.registration
        var panel = snapshot.topology[closed.placement]
        panel.orderedTabs.insert(.workspace(closed.tab.id), at: min(closed.tabIndex, panel.orderedTabs.count))
        snapshot.topology[closed.placement] = panel
        activate(.workspace(closed.tab.id), in: closed.placement)
        return closed.tab.id
    }

    func openLegacy(_ id: String) { activate(.legacy(id), in: .right, inserting: true) }
    func activateLegacy(_ id: String) { activate(.legacy(id), in: .right) }
    func closeLegacy(_ id: String) { remove(.legacy(id), from: .right) }

    func reconcileLegacy(_ ids: [String]) {
        let available = Set(ids)
        var panel = snapshot.topology.right
        let previous = panel
        panel.orderedTabs.removeAll { $0.legacyID.map { !available.contains($0) } ?? false }
        var existing = Set(panel.orderedTabs.compactMap(\.legacyID))
        for id in ids where existing.insert(id).inserted { panel.orderedTabs.append(.legacy(id)) }
        if let active = panel.activeTab, !panel.orderedTabs.contains(active) { panel.activeTab = panel.orderedTabs.last }
        if panel.orderedTabs.isEmpty { panel.activeTab = nil; panel.isOpen = false }
        if panel != previous { snapshot.topology.right = panel }
    }

    public func setOpen(_ isOpen: Bool, placement: CodexWorkspaceTabPlacement = .right) {
        var panel = snapshot.topology[placement]
        panel.isOpen = isOpen && !panel.orderedTabs.isEmpty
        if panel.isOpen, panel.activeTab == nil { panel.activeTab = panel.orderedTabs.first }
        snapshot.topology[placement] = panel
        if panel.isOpen { snapshot.topology.focusedPlacement = placement }
        else if snapshot.topology.focusedPlacement == placement {
            snapshot.topology.focusedPlacement = snapshot.topology[placement.other].isOpen
                ? placement.other : nil
        }
    }

    public func removeAll() {
        registrations.removeAll()
        closed = nil
        snapshot = .init(instances: [], topology: .init())
    }

    private func index(of id: CodexWorkspaceTabID) -> Int? {
        snapshot.instances.firstIndex { $0.id == id }
    }

    private func placement(of handle: CodexWorkspaceTabHandle) -> CodexWorkspaceTabPlacement? {
        if snapshot.topology.right.orderedTabs.contains(handle) { return .right }
        if snapshot.topology.bottom.orderedTabs.contains(handle) { return .bottom }
        return nil
    }

    private func activate(
        _ handle: CodexWorkspaceTabHandle,
        in placement: CodexWorkspaceTabPlacement,
        inserting: Bool = false,
        focus: Bool = true
    ) {
        var panel = snapshot.topology[placement]
        if inserting, !panel.orderedTabs.contains(handle) { panel.orderedTabs.append(handle) }
        guard panel.orderedTabs.contains(handle) else { return }
        panel.isOpen = true
        if focus {
            panel.activeTab = handle
        } else if panel.activeTab == nil {
            panel.activeTab = panel.orderedTabs.first
        }
        snapshot.topology[placement] = panel
        if focus { snapshot.topology.focusedPlacement = placement }
    }

    private func remove(_ handle: CodexWorkspaceTabHandle, from placement: CodexWorkspaceTabPlacement) {
        var panel = snapshot.topology[placement]
        panel.remove(handle)
        snapshot.topology[placement] = panel
        if snapshot.topology.focusedPlacement == placement, !panel.isOpen {
            snapshot.topology.focusedPlacement = snapshot.topology[placement.other].isOpen
                ? placement.other : nil
        }
    }
}

@MainActor
public struct CodexPlanWorkspaceTabAdapter: CodexWorkspaceTabAdapter {
    private let plan: CodexPlanSummary
    public init(plan: CodexPlanSummary) { self.plan = plan }

    public var workspaceTabRegistration: CodexWorkspaceTabRegistration {
        CodexWorkspaceTabRegistration(
            resourceKey: "codex.plan",
            title: "Plan",
            systemImage: "list.bullet.rectangle",
            durableRoute: .init(adapterID: "codex.plan", version: 1, resourceID: "current")
        ) { _ in AnyView(CodexPlanSummaryPage(plan: plan)) }
    }
}

@MainActor
public struct CodexReviewWorkspaceTabAdapter: CodexWorkspaceTabAdapter {
    public enum Source: String, Codable, Sendable { case workspace, transcript }
    private struct RoutePayload: Codable { var source: Source; var canonicalSourceID: String }
    private struct StatePayload: Codable { var selectedFilePath: String? }
    private let workspaceURL: URL
    private let session: CodexGitReviewSession
    private let source: Source
    private let selectedFilePath: String?
    private let onStartReview: (CodexReviewTarget) -> Void

    public init(
        workspaceURL: URL,
        session: CodexGitReviewSession,
        source: Source = .workspace,
        selectedFilePath: String? = nil,
        onStartReview: @escaping (CodexReviewTarget) -> Void = { _ in }
    ) {
        self.workspaceURL = workspaceURL
        self.session = session
        self.source = source
        self.selectedFilePath = selectedFilePath
        self.onStartReview = onStartReview
    }

    public var workspaceTabRegistration: CodexWorkspaceTabRegistration {
        let state = Self.state(selectedFilePath)
        return CodexWorkspaceTabRegistration(
            resourceKey: "codex.review",
            title: "Review",
            systemImage: "doc.text.magnifyingglass",
            durableRoute: .init(
                adapterID: "codex.review",
                version: 1,
                resourceID: session.snapshot.revision.sourceID,
                payload: Self.encode(RoutePayload(
                    source: source,
                    canonicalSourceID: session.snapshot.revision.sourceID
                ))
            ),
            initialState: state,
            reopenState: state
        ) { state in
            AnyView(CodexGitReviewWorkbenchHost(
                workspaceURL: workspaceURL,
                lastTurnSession: session,
                selectedFilePath: Self.selectedFilePath(in: state.wrappedValue),
                onSelectedFilePathChange: { state.wrappedValue = Self.state($0) },
                onStartReview: onStartReview
            ).id("\(session.snapshot.revision.sourceID):\(session.snapshot.revision.value)"))
        }
    }

    public static func selectedFilePath(in state: CodexWorkspaceTabState) -> String? {
        try? JSONDecoder().decode(StatePayload.self, from: state.data).selectedFilePath
    }

    private static func state(_ selectedFilePath: String?) -> CodexWorkspaceTabState {
        .init(data: encode(StatePayload(selectedFilePath: selectedFilePath)))
    }

    private static func encode<Value: Encodable>(_ value: Value) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }
}
