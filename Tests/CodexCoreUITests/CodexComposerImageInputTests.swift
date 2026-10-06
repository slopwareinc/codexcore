import CodexCore
@testable import CodexCoreUI
import Testing

struct CodexComposerImageInputTests {
    @Test func imageReferencesBecomeNativeImageInputWhileKeepingDisplayContext() throws {
        var composer = CodexComposerStateSession(activeThreadID: "thread")
        let image = CodexReferencedFile(path: "/tmp/screenshot.png", kind: .image)
        let document = CodexReferencedFile(path: "/tmp/readme.md", kind: .file)
        composer.draft = "Explain the screenshot"
        composer.referencedFiles = [image, document]
        let consumed = composer.consumeDraftForTurn()
        let submission = try #require(consumed)
        #expect(submission.turnInput == [
            .text(CodexFileReferencePromptCodec.encode(files: [image, document], request: submission.prompt)),
            .localImage(path: image.path),
        ])
        let wire = submission.turnInput.map { CodexSchemaUserInput($0.jsonValue) }
        #expect(wire.last?.rawValue.objectValue?["type"] == .string("localImage"))
        #expect(wire.last?.rawValue.objectValue?["path"] == .string(image.path))
        composer.restore(submission)
        #expect(composer.referencedFiles == [image, document])
        #expect(composer.draft == "Explain the screenshot")
    }

    @Test func queuedImageInputsRoundTripWithoutAddingAnImageTwice() {
        let original = CodexComposerSubmission(prompt: "Look", referencedFiles: [
            .init(path: "/tmp/a.png", kind: .image), .init(path: "/tmp/b.jpg", kind: .image),
        ])
        let queued = CodexSchemaQueuedSubmission(clientUserMessageID: original.clientID, id: "queue", input:
            original.turnInput.map { CodexSchemaUserInput($0.jsonValue) })
        let restored = CodexComposerSubmission(queuedSubmission: queued, threadID: "thread")
        #expect(restored.turnInput == original.turnInput)
        #expect(restored.referencedFiles == original.referencedFiles)
    }

    @Test func modelCatalogPreservesKnownAndUnavailableInputCapability() {
        func model(_ modalities: [CodexSchemaInputModality]?) -> CodexSchemaModel {
            .init(defaultReasoningEffort: .init(.string("medium")), description: "Fixture", displayName: "Fixture", hidden: false,
                  id: "fixture", inputModalities: modalities, isDefault: true, model: "fixture",
                  supportedReasoningEfforts: [], supportsPersonality: false)
        }
        #expect(CodexModelSelection.options(from: .init(data: [model([.text, .image])])).first?.inputModalities == [.text, .image])
        #expect(CodexModelSelection.options(from: .init(data: [model([.text])])).first?.inputModalities == [.text])
        #expect(CodexModelSelection.options(from: .init(data: [model(nil)])).first?.inputModalities == nil)
    }
}
