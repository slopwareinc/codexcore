import Testing
@testable import CodexCore

struct CodeReviewPayloadParserTests {
    private let payload = #"{"findings":[{"title":"[P1] Problem","body":"Details 🙂 {quoted}","confidence_score":0.9}]}"#

    @Test func embeddedAndNestedReviewsKeepTheirFindingContent() throws {
        for text in ["Before \(payload) after", "{\"wrapper\":\(payload)}", "🙂\n```json\n\(payload)\n```", "before {\"broken\n\(payload)"] {
            let review = try #require(MessageParser().parseCodeReview(text: text))
            #expect(review.findings.first?.title == "Problem")
            #expect(review.findings.first?.body == "Details 🙂 {quoted}")
            #expect(review.findings.first?.priority == 1)
        }
    }

    @Test func earlierOuterReviewTakesPrecedenceOverLaterNestedCandidates() throws {
        let review = try #require(MessageParser().parseCodeReview(text: "prefix \(payload) \(payload.replacingOccurrences(of: "Problem", with: "Later"))"))
        #expect(review.findings.first?.title == "Problem")
    }

    @Test func unmatchedBracesAndUnterminatedFencesDoNotRescanTheDocument() {
        #expect(MessageParser().parseCodeReview(text: String(repeating: "{", count: 20_000)) == nil)
        #expect(MarkdownFence.parseAll(in: "```open\n~~~json\n{}\n~~~").isEmpty)
        #expect(MarkdownFence.parseAll(in: "````swift\nlet x = 1\n```\n````").first?.content == "let x = 1\n```")
    }
}
