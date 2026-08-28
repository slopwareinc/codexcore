import CodexCore
import Foundation
import SwiftUI

public struct CodexWorkspaceTabID: Hashable, Codable, Identifiable, Sendable {
    public let rawValue: UUID

    public var id: UUID { rawValue }

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct CodexWorkspaceTabContentID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum CodexWorkspaceTabPlacement: String, Codable, Sendable {
    case right
    case bottom
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

    public init(data: Data = Data()) {
        self.data = data
    }
}

public struct CodexWorkspaceTabOpenMetadata: Codable, Sendable, Equatable {
    public let opener: CodexWorkspaceTabOpener
    public let insertionIndex: Int
    public let replacedResourceKey: String?
    public let replacedRoute: CodexWorkspaceTabRoute?
}

public struct CodexWorkspaceTabInstanceSnapshot: Identifiable, Sendable, Equatable {
    public let id: CodexWorkspaceTabID
    public let contentID: CodexWorkspaceTabContentID
    public let title: String
    public let systemImage: String
    public let isPinned: Bool
    public let durableRoute: CodexWorkspaceTabRoute?
    public let openMetadata: CodexWorkspaceTabOpenMetadata
    public let state: CodexWorkspaceTabState
    public let isMaterialized: Bool
}

public struct CodexWorkspaceTabPanelSnapshot: Codable, Sendable, Equatable {
    public var orderedTabIDs: [CodexWorkspaceTabID]
    public var activeTabID: CodexWorkspaceTabID?
    public var isOpen: Bool

    init(
        orderedTabIDs: [CodexWorkspaceTabID] = [],
        activeTabID: CodexWorkspaceTabID? = nil,
        isOpen: Bool = false
    ) {
        self.orderedTabIDs = orderedTabIDs
        self.activeTabID = activeTabID
        self.isOpen = isOpen
    }
}

public struct CodexWorkspaceTabTopologySnapshot: Codable, Sendable, Equatable {
    public var right = CodexWorkspaceTabPanelSnapshot()
    public var bottom = CodexWorkspaceTabPanelSnapshot()
    public var focusedPlacement: CodexWorkspaceTabPlacement? = nil
}

public struct CodexWorkspaceTabRestorationState: Codable, Sendable, Equatable {
    public struct Tab: Codable, Sendable, Equatable, Identifiable {
        public let id: CodexWorkspaceTabID
        public let contentID: CodexWorkspaceTabContentID
        public let title: String
        public let systemImage: String
        public let route: CodexWorkspaceTabRoute
        public let openMetadata: CodexWorkspaceTabOpenMetadata
        public let state: CodexWorkspaceTabState
    }

    public let tabs: [Tab]
    public let topology: CodexWorkspaceTabTopologySnapshot
}

public struct CodexWorkspaceTabClosedRoute: Sendable, Equatable {
    public let route: CodexWorkspaceTabRoute
    public let placement: CodexWorkspaceTabPlacement
    public let insertionIndex: Int
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
    let makeContent: @MainActor (Binding<CodexWorkspaceTabState>) -> AnyView

    init(
        resourceKey: String,
        title: String,
        systemImage: String,
        lifetime: CodexWorkspaceTabLifetime = .pinned,
        durableRoute: CodexWorkspaceTabRoute? = nil,
        initialState: CodexWorkspaceTabState = CodexWorkspaceTabState(),
        reopenState: CodexWorkspaceTabState? = nil,
        makeContent: @escaping @MainActor (Binding<CodexWorkspaceTabState>) -> AnyView
    ) {
        self.resourceKey = resourceKey
        self.title = title
        self.systemImage = systemImage
        self.lifetime = lifetime
        self.durableRoute = durableRoute
        self.initialState = initialState
        self.reopenState = reopenState
        self.makeContent = makeContent
    }
}

@MainActor
public final class CodexWorkspaceTabs: ObservableObject {
    private struct Instance {
        var id: CodexWorkspaceTabID
        var contentID: CodexWorkspaceTabContentID
        var resourceKey: String
        var title: String
        var systemImage: String
        var registration: CodexWorkspaceTabRegistration?
        var isPinned: Bool
        var durableRoute: CodexWorkspaceTabRoute?
        var openMetadata: CodexWorkspaceTabOpenMetadata
        var state: CodexWorkspaceTabState
        var isMaterialized: Bool
    }

    private struct ClosedInstance {
        var instance: Instance
        var placement: CodexWorkspaceTabPlacement
        var insertionIndex: Int
        var instanceIndex: Int
    }

    @Published public private(set) var snapshot = CodexWorkspaceTabSnapshot(
        instances: [],
        topology: .init()
    )

    private var instances: [Instance] = []
    private var closedInstances: [ClosedInstance] = []

    public init() {}

    public init(restoring restoration: CodexWorkspaceTabRestorationState) {
        instances = restoration.tabs.map { tab in
            Instance(
                id: tab.id,
                contentID: tab.contentID,
                resourceKey: Self.resourceKey(for: tab.route),
                title: tab.title,
                systemImage: tab.systemImage,
                registration: nil,
                isPinned: true,
                durableRoute: tab.route,
                openMetadata: tab.openMetadata,
                state: tab.state,
                isMaterialized: false
            )
        }
        snapshot = CodexWorkspaceTabSnapshot(
            instances: [],
            topology: restoration.topology
        )
        publishInstances()
    }

    public var lastClosedRoute: CodexWorkspaceTabClosedRoute? {
        guard let closed = closedInstances.last,
              let route = closed.instance.durableRoute else { return nil }
        return CodexWorkspaceTabClosedRoute(
            route: route,
            placement: closed.placement,
            insertionIndex: closed.insertionIndex
        )
    }

    public var restorationState: CodexWorkspaceTabRestorationState {
        let durable = instances.compactMap { instance -> CodexWorkspaceTabRestorationState.Tab? in
            guard let route = instance.durableRoute else { return nil }
            return .init(
                id: instance.id,
                contentID: instance.contentID,
                title: instance.title,
                systemImage: instance.systemImage,
                route: route,
                openMetadata: instance.openMetadata,
                state: instance.state
            )
        }
        let durableIDs = Set(durable.map(\.id))
        var topology = snapshot.topology
        topology.right.orderedTabIDs.removeAll { !durableIDs.contains($0) }
        topology.bottom.orderedTabIDs.removeAll { !durableIDs.contains($0) }
        if topology.right.activeTabID.map({ !durableIDs.contains($0) }) == true {
            topology.right.activeTabID = topology.right.orderedTabIDs.last
        }
        if topology.bottom.activeTabID.map({ !durableIDs.contains($0) }) == true {
            topology.bottom.activeTabID = topology.bottom.orderedTabIDs.last
        }
        return CodexWorkspaceTabRestorationState(tabs: durable, topology: topology)
    }

    public func register(_ adapters: [any CodexWorkspaceTabAdapter]) {
        let registrations = adapters.map(\.workspaceTabRegistration)
        var changed = false
        for index in instances.indices where instances[index].registration == nil {
            guard let route = instances[index].durableRoute,
                  let registration = registrations.first(where: {
                      $0.durableRoute == route
                  }) else { continue }
            instances[index].registration = registration
            instances[index].resourceKey = registration.resourceKey
            instances[index].title = registration.title
            instances[index].systemImage = registration.systemImage
            changed = true
        }
        if changed { publishInstances() }
    }

    @discardableResult
    public func open(
        _ adapter: any CodexWorkspaceTabAdapter,
        from opener: CodexWorkspaceTabOpener
    ) -> CodexWorkspaceTabID {
        let registration = adapter.workspaceTabRegistration
        if let index = instances.firstIndex(where: {
            $0.resourceKey == registration.resourceKey
        }) {
            let replacedRoute = instances[index].durableRoute
            instances[index].registration = registration
            instances[index].title = registration.title
            instances[index].systemImage = registration.systemImage
            instances[index].isMaterialized = true
            if let reopenState = registration.reopenState {
                instances[index].state = reopenState
            }
            if instances[index].isPinned {
                instances[index].durableRoute = registration.durableRoute
            }
            instances[index].openMetadata = CodexWorkspaceTabOpenMetadata(
                opener: opener,
                insertionIndex: snapshot.topology.right.orderedTabIDs.firstIndex(
                    of: instances[index].id
                ) ?? index,
                replacedResourceKey: nil,
                replacedRoute: replacedRoute == registration.durableRoute ? nil : replacedRoute
            )
            snapshot.topology.right.activeTabID = instances[index].id
            snapshot.topology.right.isOpen = true
            snapshot.topology.focusedPlacement = .right
            publishInstances()
            return instances[index].id
        }

        if registration.lifetime == .preview,
           let index = instances.firstIndex(where: { !$0.isPinned }),
           let orderIndex = snapshot.topology.right.orderedTabIDs.firstIndex(of: instances[index].id) {
            let replacedResourceKey = instances[index].resourceKey
            let replacedRoute = instances[index].durableRoute
            instances[index].resourceKey = registration.resourceKey
            instances[index].title = registration.title
            instances[index].systemImage = registration.systemImage
            instances[index].registration = registration
            instances[index].durableRoute = nil
            instances[index].state = registration.initialState
            instances[index].isMaterialized = true
            instances[index].openMetadata = CodexWorkspaceTabOpenMetadata(
                opener: opener,
                insertionIndex: orderIndex,
                replacedResourceKey: replacedResourceKey,
                replacedRoute: replacedRoute
            )
            snapshot.topology.right.activeTabID = instances[index].id
            snapshot.topology.right.isOpen = true
            snapshot.topology.focusedPlacement = .right
            publishInstances()
            return instances[index].id
        }

        let insertionIndex = snapshot.topology.right.orderedTabIDs.count
        let instance = Instance(
            id: CodexWorkspaceTabID(),
            contentID: CodexWorkspaceTabContentID(),
            resourceKey: registration.resourceKey,
            title: registration.title,
            systemImage: registration.systemImage,
            registration: registration,
            isPinned: registration.lifetime == .pinned,
            durableRoute: registration.lifetime == .pinned ? registration.durableRoute : nil,
            openMetadata: CodexWorkspaceTabOpenMetadata(
                opener: opener,
                insertionIndex: insertionIndex,
                replacedResourceKey: nil,
                replacedRoute: nil
            ),
            state: registration.initialState,
            isMaterialized: true
        )
        instances.append(instance)
        snapshot.topology.right.orderedTabIDs.append(instance.id)
        snapshot.topology.right.activeTabID = instance.id
        snapshot.topology.right.isOpen = true
        snapshot.topology.focusedPlacement = .right
        publishInstances()
        return instance.id
    }

    public func pin(_ id: CodexWorkspaceTabID) {
        guard let index = instances.firstIndex(where: { $0.id == id }),
              !instances[index].isPinned else { return }
        instances[index].isPinned = true
        instances[index].durableRoute = instances[index].registration?.durableRoute
        publishInstances()
    }

    public func activate(_ id: CodexWorkspaceTabID) {
        guard let index = instances.firstIndex(where: { $0.id == id }),
              let placement = placement(of: id) else { return }
        setActive(id, in: placement)
        snapshot.topology.focusedPlacement = placement
        if instances[index].registration != nil {
            instances[index].isMaterialized = true
        }
        publishInstances()
    }

    public func move(_ id: CodexWorkspaceTabID, to destination: CodexWorkspaceTabPlacement) {
        guard let source = placement(of: id), source != destination else {
            activate(id)
            return
        }
        remove(id, from: source)
        switch destination {
        case .right:
            snapshot.topology.right.orderedTabIDs.append(id)
        case .bottom:
            snapshot.topology.bottom.orderedTabIDs.append(id)
        }
        setActive(id, in: destination)
        snapshot.topology.focusedPlacement = destination
        publishInstances()
    }

    public func updateState(_ state: CodexWorkspaceTabState, for id: CodexWorkspaceTabID) {
        guard let index = instances.firstIndex(where: { $0.id == id }),
              instances[index].state != state else { return }
        instances[index].state = state
        publishInstances()
    }

    public func content(for id: CodexWorkspaceTabID) -> AnyView? {
        guard let index = instances.firstIndex(where: { $0.id == id }),
              instances[index].isMaterialized,
              let registration = instances[index].registration else { return nil }
        let binding = Binding(
            get: { [weak self] in
                self?.instances.first(where: { $0.id == id })?.state ?? CodexWorkspaceTabState()
            },
            set: { [weak self] state in self?.updateState(state, for: id) }
        )
        return registration.makeContent(binding)
    }

    public func close(_ id: CodexWorkspaceTabID) {
        guard let placement = placement(of: id),
              let instanceIndex = instances.firstIndex(where: { $0.id == id }),
              let insertionIndex = panel(for: placement).orderedTabIDs.firstIndex(of: id) else { return }
        closedInstances.append(ClosedInstance(
            instance: instances.remove(at: instanceIndex),
            placement: placement,
            insertionIndex: insertionIndex,
            instanceIndex: instanceIndex
        ))
        remove(id, from: placement)
        if snapshot.topology.focusedPlacement == placement,
           !panel(for: placement).isOpen {
            snapshot.topology.focusedPlacement = panel(for: other(than: placement)).isOpen
                ? other(than: placement)
                : nil
        }
        publishInstances()
    }

    @discardableResult
    public func undoClose() -> CodexWorkspaceTabID? {
        guard let closed = closedInstances.popLast(),
              !instances.contains(where: { $0.id == closed.instance.id }) else { return nil }
        instances.insert(
            closed.instance,
            at: min(closed.instanceIndex, instances.count)
        )
        switch closed.placement {
        case .right:
            snapshot.topology.right.orderedTabIDs.insert(
                closed.instance.id,
                at: min(closed.insertionIndex, snapshot.topology.right.orderedTabIDs.count)
            )
        case .bottom:
            snapshot.topology.bottom.orderedTabIDs.insert(
                closed.instance.id,
                at: min(closed.insertionIndex, snapshot.topology.bottom.orderedTabIDs.count)
            )
        }
        setActive(closed.instance.id, in: closed.placement)
        snapshot.topology.focusedPlacement = closed.placement
        publishInstances()
        return closed.instance.id
    }

    private func publishInstances() {
        snapshot.instances = instances.map {
            CodexWorkspaceTabInstanceSnapshot(
                id: $0.id,
                contentID: $0.contentID,
                title: $0.title,
                systemImage: $0.systemImage,
                isPinned: $0.isPinned,
                durableRoute: $0.durableRoute,
                openMetadata: $0.openMetadata,
                state: $0.state,
                isMaterialized: $0.isMaterialized
            )
        }
    }

    private static func resourceKey(for route: CodexWorkspaceTabRoute) -> String {
        "\(route.adapterID):\(route.resourceID)"
    }

    private func placement(of id: CodexWorkspaceTabID) -> CodexWorkspaceTabPlacement? {
        if snapshot.topology.right.orderedTabIDs.contains(id) { return .right }
        if snapshot.topology.bottom.orderedTabIDs.contains(id) { return .bottom }
        return nil
    }

    private func panel(for placement: CodexWorkspaceTabPlacement) -> CodexWorkspaceTabPanelSnapshot {
        switch placement {
        case .right: snapshot.topology.right
        case .bottom: snapshot.topology.bottom
        }
    }

    private func setActive(_ id: CodexWorkspaceTabID, in placement: CodexWorkspaceTabPlacement) {
        switch placement {
        case .right:
            snapshot.topology.right.activeTabID = id
            snapshot.topology.right.isOpen = true
        case .bottom:
            snapshot.topology.bottom.activeTabID = id
            snapshot.topology.bottom.isOpen = true
        }
    }

    private func remove(_ id: CodexWorkspaceTabID, from placement: CodexWorkspaceTabPlacement) {
        switch placement {
        case .right:
            remove(id, from: &snapshot.topology.right)
        case .bottom:
            remove(id, from: &snapshot.topology.bottom)
        }
    }

    private func remove(_ id: CodexWorkspaceTabID, from panel: inout CodexWorkspaceTabPanelSnapshot) {
        guard let index = panel.orderedTabIDs.firstIndex(of: id) else { return }
        panel.orderedTabIDs.remove(at: index)
        if panel.activeTabID == id {
            panel.activeTabID = panel.orderedTabIDs.indices.contains(index)
                ? panel.orderedTabIDs[index]
                : panel.orderedTabIDs.last
        }
        if panel.orderedTabIDs.isEmpty {
            panel.activeTabID = nil
            panel.isOpen = false
        }
    }

    private func other(than placement: CodexWorkspaceTabPlacement) -> CodexWorkspaceTabPlacement {
        placement == .right ? .bottom : .right
    }
}

@MainActor
public struct CodexPlanWorkspaceTabAdapter: CodexWorkspaceTabAdapter {
    private let plan: CodexPlanSummary

    public init(plan: CodexPlanSummary) {
        self.plan = plan
    }

    public var workspaceTabRegistration: CodexWorkspaceTabRegistration {
        CodexWorkspaceTabRegistration(
            resourceKey: "codex.plan",
            title: "Plan",
            systemImage: "list.bullet.rectangle",
            durableRoute: CodexWorkspaceTabRoute(
                adapterID: "codex.plan",
                version: 1,
                resourceID: "current"
            )
        ) { _ in
            AnyView(CodexPlanSummaryPage(plan: plan))
        }
    }
}

@MainActor
public struct CodexReviewWorkspaceTabAdapter: CodexWorkspaceTabAdapter {
    public enum Source: String, Codable, Sendable {
        case workspace
        case transcript
    }

    private struct RoutePayload: Codable {
        var source: Source
        var canonicalSourceID: String
    }

    private struct StatePayload: Codable {
        var selectedFilePath: String?
    }

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
        let state = Self.state(selectedFilePath: selectedFilePath)
        return CodexWorkspaceTabRegistration(
            resourceKey: "codex.review",
            title: "Review",
            systemImage: "doc.text.magnifyingglass",
            durableRoute: CodexWorkspaceTabRoute(
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
                onStartReview: onStartReview
            ))
        }
    }

    public static func selectedFilePath(in state: CodexWorkspaceTabState) -> String? {
        try? JSONDecoder().decode(StatePayload.self, from: state.data).selectedFilePath
    }

    private static func state(selectedFilePath: String?) -> CodexWorkspaceTabState {
        CodexWorkspaceTabState(
            data: Self.encode(StatePayload(
                selectedFilePath: selectedFilePath
            ))
        )
    }

    private static func encode<Value: Encodable>(_ value: Value) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }
}
