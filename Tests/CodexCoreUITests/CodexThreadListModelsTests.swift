@testable import CodexCoreUI
import Testing

struct CodexThreadListModelsTests {
    @Test func sourceFoldersKeepPrimaryFirstAndDeduplicateInOrder() {
        let project = CodexProjectSummary(
            workspacePath: "/tmp/Alpha",
            sourceFolders: [
                "/tmp/Beta",
                " /tmp/Alpha ",
                "/tmp/Beta",
                " ",
                "/tmp/Gamma",
            ]
        )

        #expect(project.sourceFolders == ["/tmp/Alpha", "/tmp/Beta", "/tmp/Gamma"])
    }
}
