@testable import CodexCore
import Testing

struct AssistantRenderBlockParserTests {
    @Test(arguments: ["🙂", "हिन्दी", "e\u{301}", "中文", "👩🏽‍💻"])
    func mathUsesConsistentUnicodeOffsets(prefix: String) {
        let parser = MessageParser()
        let latex = "α + 🙂 + e\u{301}"
        #expect(parser.extractRenderBlocks(text: "\(prefix) $$\(latex)$$ tail") == [
            .markdown("\(prefix) "), .codeBlock(language: "math", code: latex), .markdown(" tail")
        ])
        #expect(parser.extractRenderBlocks(text: "\(prefix) \\[\(latex)\\] tail") == [
            .markdown("\(prefix) "), .codeBlock(language: "math", code: latex), .markdown(" tail")
        ])
        #expect(parser.extractRenderBlocks(text: "\(prefix) \\(\(latex)\\) tail") == [
            .markdown("\(prefix) $\(latex)$ tail")
        ])
        #expect(parser.extractRenderBlocks(text: "\(prefix) $\(latex)$ tail") == [
            .markdown("\(prefix) $\(latex)$ tail")
        ])
    }

    @Test func unicodeCodeSpansRemainOpaqueToMathAndImages() {
        let inline = "🙂 `$$α$$ data:image/png;base64,AQID` tail"
        #expect(MessageParser().extractRenderBlocks(text: inline) == [.markdown(inline)])
        let fenced = "🙂\n```text\n$$α$$ data:image/png;base64,AQID\n```\n$$β$$"
        #expect(MessageParser().extractRenderBlocks(text: fenced) == [
            .markdown("🙂\n"),
            .codeBlock(language: "text", code: "$$α$$ data:image/png;base64,AQID"),
            .markdown("\n"), .codeBlock(language: "math", code: "β")
        ])
    }

    @Test func escapesWhitespaceAndCurrencyStillRemainLiteral() {
        for text in [#"\$x\$"#, "$ x $", "$x $", "$5 and $10", #"\(x"#, "plain 🙂"] {
            #expect(MessageParser().extractRenderBlocks(text: text) == [.markdown(text)])
        }
        #expect(MessageParser().extractRenderBlocks(text: "$\u{2003}x$") == [.markdown("$\u{2003}x$")])
    }
}
