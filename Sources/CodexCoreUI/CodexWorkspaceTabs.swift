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
    var other: Self { self == .right ? .bottom : .right }
}

public enum CodexWorkspaceTabOpener: String, Codable, Sendable {
    case summary
    case transcript
    case commandMenu
    case restoration
}

public enum CodexWorkspaceTabLifetime: String, Codable, Sendable {
    case preview
    case pinned
}

/// Controls whether an adapter keeps its view host alive when another tab is
/// selected. Lightweight document previews opt into `.activeOnly` so hidden
/// editors never lay out or parse; retained process-backed adapters keep the
/// default `.retained` policy.
public enum CodexWorkspaceTabRetentionPolicy: String, Codable, Sendable {
    case retained
    case activeOnly
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
    /// Adapter-owned stable resource identity used for re-opening an existing
    /// tab. It is presentation metadata, not canonical protocol state.
    public fileprivate(set) var resourceKey: String
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

/// The narrow content seam between the tab reducer and a feature adapter. The
/// reducer supplies both durable tab state and the interaction hook so preview
/// pinning remains a workspace-tab rule instead of leaking into callers.
public struct CodexWorkspaceTabContentContext {
    public let state: Binding<CodexWorkspaceTabState>
    public let interact: @MainActor () -> Void

    init(
        state: Binding<CodexWorkspaceTabState>,
        interact: @escaping @MainActor () -> Void
    ) {
        self.state = state
        self.interact = interact
    }
}

public struct CodexWorkspaceTabRegistration {
    let resourceKey: String
    let title: String
    let systemImage: String
    let lifetime: CodexWorkspaceTabLifetime
    let retentionPolicy: CodexWorkspaceTabRetentionPolicy
    let pinsOnInteraction: Bool
    let durableRoute: CodexWorkspaceTabRoute?
    let initialState: CodexWorkspaceTabState
    let reopenState: CodexWorkspaceTabState?
    let onClose: @MainActor () -> Void
    let makeContent: @MainActor (CodexWorkspaceTabContentContext) -> AnyView

    public init(
        resourceKey: String,
        title: String,
        systemImage: String,
        lifetime: CodexWorkspaceTabLifetime = .pinned,
        retentionPolicy: CodexWorkspaceTabRetentionPolicy = .retained,
        pinsOnInteraction: Bool = false,
        durableRoute: CodexWorkspaceTabRoute? = nil,
        initialState: CodexWorkspaceTabState = .init(),
        reopenState: CodexWorkspaceTabState? = nil,
        onClose: @escaping @MainActor () -> Void = {},
        makeContent: @escaping @MainActor (CodexWorkspaceTabContentContext) -> AnyView
    ) {
        self.resourceKey = resourceKey
        self.title = title
        self.systemImage = systemImage
        self.lifetime = lifetime
        self.retentionPolicy = retentionPolicy
        self.pinsOnInteraction = pinsOnInteraction
        self.durableRoute = durableRoute
        self.initialState = initialState
        self.reopenState = reopenState
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

    public var hasOpenWorkspaceTabs: Bool {
        !snapshot.topology.right.orderedTabs.isEmpty
            || !snapshot.topology.bottom.orderedTabs.isEmpty
    }

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
        let registration = adapter.workspaceTabRegistration
        if let index = snapshot.instances.firstIndex(where: { $0.resourceKey == registration.resourceKey }) {
            return reopen(index, registration: registration, opener: opener)
        }
        if registration.lifetime == .preview,
           let index = snapshot.instances.firstIndex(where: { !$0.isPinned }) {
            return replacePreview(index, registration: registration, opener: opener)
        }
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
                insertionIndex: snapshot.topology.right.orderedTabs.count,
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
        activate(.workspace(id), in: .right, inserting: true)
        return id
    }

    private func reopen(
        _ index: Int,
        registration: CodexWorkspaceTabRegistration,
        opener: CodexWorkspaceTabOpener
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
        activate(.workspace(tab.id), in: placement)
        return tab.id
    }

    private func replacePreview(
        _ index: Int,
        registration: CodexWorkspaceTabRegistration,
        opener: CodexWorkspaceTabOpener
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
        activate(.workspace(tab.id), in: placement)
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
        activate(.workspace(id), in: placement)
    }

    public func move(_ id: CodexWorkspaceTabID, to destination: CodexWorkspaceTabPlacement) {
        guard let source = placement(of: .workspace(id)) else { return }
        guard source != destination else { activate(id); return }
        remove(.workspace(id), from: source)
        activate(.workspace(id), in: destination, inserting: true)
    }

    public func updateState(_ state: CodexWorkspaceTabState, for id: CodexWorkspaceTabID) {
        guard let index = index(of: id), snapshot.instances[index].state != state else { return }
        snapshot.instances[index].state = state
    }

    public func content(for id: CodexWorkspaceTabID) -> AnyView? {
        guard let index = index(of: id), snapshot.instances[index].isMaterialized,
              let registration = registrations[id] else { return nil }
        let state = Binding(
            get: { [weak self] in self?.snapshot.instance(id: id)?.state ?? .init() },
            set: { [weak self] in self?.updateState($0, for: id) }
        )
        return registration.makeContent(.init(
            state: state,
            interact: { [weak self] in self?.interact(id) }
        ))
    }

    func isAvailable(_ id: CodexWorkspaceTabID) -> Bool { registrations[id] != nil }

    /// Reports user interaction with a tab's content. Preview tabs pin on first
    /// interaction; adapters can opt the same rule into another lifetime when
    /// needed. Callers never duplicate preview lifecycle rules.
    public func interact(_ id: CodexWorkspaceTabID) {
        guard let registration = registrations[id],
              registration.lifetime == .preview || registration.pinsOnInteraction else { return }
        pin(id)
    }

    /// Whether the adapter explicitly retains its host while hidden.
    func retainsContentWhenHidden(_ id: CodexWorkspaceTabID) -> Bool {
        registrations[id]?.retentionPolicy == .retained
    }

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
        registration?.onClose()
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

    func setOpen(_ isOpen: Bool, placement: CodexWorkspaceTabPlacement = .right) {
        var panel = snapshot.topology[placement]
        panel.isOpen = isOpen && !panel.orderedTabs.isEmpty
        if panel.isOpen, panel.activeTab == nil { panel.activeTab = panel.orderedTabs.first }
        snapshot.topology[placement] = panel
        if panel.isOpen { snapshot.topology.focusedPlacement = placement }
    }

    func removeAll() {
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
        inserting: Bool = false
    ) {
        var panel = snapshot.topology[placement]
        if inserting, !panel.orderedTabs.contains(handle) { panel.orderedTabs.append(handle) }
        guard panel.orderedTabs.contains(handle) else { return }
        panel.activeTab = handle
        panel.isOpen = true
        snapshot.topology[placement] = panel
        snapshot.topology.focusedPlacement = placement
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
        ) { context in
            AnyView(CodexGitReviewWorkbenchHost(
                workspaceURL: workspaceURL,
                lastTurnSession: session,
                selectedFilePath: Self.selectedFilePath(in: context.state.wrappedValue),
                onSelectedFilePathChange: { context.state.wrappedValue = Self.state($0) },
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
