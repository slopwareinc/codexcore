import SwiftUI
import Testing
@testable import CodexCoreUI

struct CodexWorkspaceBreadcrumbTests {
    @MainActor
    @Test func customProjectNamesTakePrecedenceOverSharedFolderNames() {
        // Compiling embedding example: project display identity comes from
        // the host, while the path still scopes the native workspace actions.
        _ = CodexChatHeader(
            title: "Implement settings", workspacePath: "/work/shared", workspaceTitle: "Client API",
            chatActions: CodexChatActionHandlers(renameChat: {}), onDisconnect: {}
        )
        #expect(CodexWorkspaceBreadcrumbContext.projectTitle(workspacePath: "/work/shared", workspaceTitle: "Client API") == "Client API")
        #expect(CodexWorkspaceBreadcrumbContext.projectTitle(workspacePath: "/work/shared", workspaceTitle: "Release tools") == "Release tools")
    }

    @Test func absentOrBlankNamesFallBackToTheWorkspaceFolder() {
        #expect(CodexWorkspaceBreadcrumbContext.projectTitle(workspacePath: "/work/codexcore/", workspaceTitle: nil) == "codexcore")
        #expect(CodexWorkspaceBreadcrumbContext.projectTitle(workspacePath: "/work/codexcore", workspaceTitle: " \n ") == "codexcore")
        #expect(CodexWorkspaceBreadcrumbContext.projectTitle(workspacePath: "/", workspaceTitle: nil) == "Workspace")
        #expect(CodexWorkspaceBreadcrumbContext.projectTitle(workspacePath: "", workspaceTitle: nil) == "Workspace")
    }
}
