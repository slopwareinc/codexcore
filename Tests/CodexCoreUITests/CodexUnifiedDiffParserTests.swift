@testable import CodexCoreUI
import Testing

struct CodexUnifiedDiffParserTests {
    @Test func parsesMultipleFilesHunksAndCounts() {
        let diff = """
        diff --git a/Sources/A.swift b/Sources/A.swift
        --- a/Sources/A.swift
        +++ b/Sources/A.swift
        @@ -1,2 +1,3 @@
         context
        -old
        +new
        +extra
        diff --git a/Tests/B.swift b/Tests/B.swift
        new file mode 100644
        --- /dev/null
        +++ b/Tests/B.swift
        @@ -0,0 +1 @@
        +test
        """
        let files = CodexUnifiedDiffParser.parse(diff)
        #expect(files.count == 2)
        #expect(files[0].path == "Sources/A.swift")
        #expect(files[0].added == 2)
        #expect(files[0].removed == 1)
        #expect(files[1].kind == "added")
        #expect(files[1].added == 1)
    }

    @Test func preservesUnstructuredInputAsFallback() {
        let files = CodexUnifiedDiffParser.parse("+line\n-line")
        #expect(files.count == 1)
        #expect(files[0].path == "patch")
        #expect(files[0].hunks[0].lines.map(\.text) == ["+line", "-line"])
    }

    @Test func hunkSourceThatResemblesFileHeadersStillCountsAsSource() throws {
        let diff = """
        diff --git a/Sources/Counter.swift b/Sources/Counter.swift
        --- a/Sources/Counter.swift
        +++ b/Sources/Counter.swift
        @@ -1 +1 @@
        ---value
        +++counter
        """

        let file = try #require(CodexUnifiedDiffParser.parse(diff).first)

        #expect(file.added == 1)
        #expect(file.removed == 1)
        #expect(file.hunks.last?.lines.map(\.text) == ["---value", "+++counter"])
        #expect(file.hunks.last?.lines.map(\.kind) == [.remove, .add])
    }
}
