import Foundation
import GhosttyTerminal
import XCTest
@testable import CodexCoreUI

final class CodexWorkspaceToolsTests: XCTestCase {
    func testLauncherOptionsEnableTerminalAndDisableFutureTools() {
        let options = CodexWorkspaceToolCatalog.launcherOptions

        XCTAssertEqual(options.first?.id, CodexWorkspaceToolCatalog.terminalID)
        XCTAssertEqual(options.first?.title, "Terminal")
        XCTAssertEqual(options.first?.isEnabled, true)
        XCTAssertEqual(options.first { $0.id == CodexWorkspaceToolCatalog.filesID }?.isEnabled, true)
        let futureOptions = options.filter { ![CodexWorkspaceToolCatalog.terminalID, CodexWorkspaceToolCatalog.filesID].contains($0.id) }
        XCTAssertTrue(futureOptions.allSatisfy { !$0.isEnabled })
        XCTAssertTrue(futureOptions.allSatisfy { $0.detail.contains("Not available") })
    }

    @MainActor
    func testTerminalSessionUsesGhosttyExecBackendAndWorkspaceDirectory() {
        let workspace = FileManager.default.temporaryDirectory.path
        let session = CodexTerminalSession(workingDirectory: workspace, fontSize: 12)

        XCTAssertEqual(session.title, "Terminal")
        XCTAssertEqual(session.initialWorkingDirectory, workspace)
        XCTAssertEqual(session.state.configuration.workingDirectory, workspace)
        XCTAssertEqual(session.state.configuration.fontSize, 12)
        if case .exec = session.state.configuration.backend {
            XCTAssertTrue(true)
        } else {
            XCTFail("Terminal sessions should use Ghostty exec backend")
        }
    }

    func testTerminalPathFormatterCompactsHomeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        XCTAssertEqual(CodexTerminalPathFormatter.display(home), "~")
        XCTAssertEqual(CodexTerminalPathFormatter.display(home + "/Projects/CodexCore"), "~/Projects/CodexCore")
        XCTAssertEqual(CodexTerminalPathFormatter.display("/tmp/CodexCore"), "/tmp/CodexCore")
    }

    func testFileTreeLoaderSortsDirectoriesBeforeFilesByLocalizedName() throws {
        let workspace = try makeTemporaryWorkspace()
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("zeta"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Alpha"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: workspace.appendingPathComponent("beta.txt").path, contents: Data())
        FileManager.default.createFile(atPath: workspace.appendingPathComponent("aardvark.txt").path, contents: Data())

        let children = CodexFileTreeLoader().children(of: workspace)

        XCTAssertEqual(children.map(\.name), ["Alpha", "zeta", "aardvark.txt", "beta.txt"])
        XCTAssertEqual(children.map(\.kind), [.directory, .directory, .file, .file])
    }

    func testFileTreeLoaderFiltersNoisyFoldersButKeepsOtherDotfiles() throws {
        let workspace = try makeTemporaryWorkspace()
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".config"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: workspace.appendingPathComponent(".env").path, contents: Data())

        let children = CodexFileTreeLoader().children(of: workspace)

        XCTAssertEqual(children.map(\.name), [".config", ".env"])
    }

    func testFileTreeNodeLoadsChildrenLazilyOneLevelAtATime() throws {
        let workspace = try makeTemporaryWorkspace()
        let childDirectory = workspace.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: childDirectory.appendingPathComponent("grandchild"), withIntermediateDirectories: true)

        let root = CodexFileTreeLoader().rootNode(for: workspace)
        XCTAssertFalse(root.areChildrenLoaded)

        let children = root.loadChildren()

        XCTAssertTrue(root.areChildrenLoaded)
        XCTAssertEqual(children.map(\.name), ["child"])
        XCTAssertFalse(children[0].areChildrenLoaded)
    }

    func testFileTreeLoaderTreatsSymlinkDirectoryAsLeaf() throws {
        let workspace = try makeTemporaryWorkspace()
        let target = workspace.appendingPathComponent("target")
        let link = workspace.appendingPathComponent("linked-target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let linkedNode = CodexFileTreeLoader().children(of: workspace).first { $0.name == "linked-target" }

        XCTAssertEqual(linkedNode?.kind, .symbolicLink)
        XCTAssertEqual(linkedNode?.isExpandable, false)
    }

    func testFilesPathFormatterCompactsHomeDirectoryAndUsesRootName() {
        let home = FileManager.default.homeDirectoryForCurrentUser

        XCTAssertEqual(CodexFilesPathFormatter.display(home), "~")
        XCTAssertEqual(CodexFilesPathFormatter.display(home.appendingPathComponent("Projects/CodexCore")), "~/Projects/CodexCore")
        XCTAssertEqual(CodexFilesPathFormatter.display(URL(fileURLWithPath: "/tmp/CodexCore")), "/tmp/CodexCore")
        XCTAssertEqual(CodexFilesPathFormatter.rootName(for: URL(fileURLWithPath: "/tmp/CodexCore")), "CodexCore")
    }

    @MainActor
    func testFilesSessionRefreshReplacesRootNodeAndKeepsSelection() throws {
        let workspace = try makeTemporaryWorkspace()
        let selected = workspace.appendingPathComponent("Package.swift")
        let session = CodexFilesSession(rootURL: workspace)
        session.selectedURL = selected
        let originalRoot = session.rootNode

        session.refresh()

        XCTAssertFalse(session.rootNode === originalRoot)
        XCTAssertEqual(session.selectedURL, selected)
    }

    private func makeTemporaryWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexWorkspaceToolsTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
