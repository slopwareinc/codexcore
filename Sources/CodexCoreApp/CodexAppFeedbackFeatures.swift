import Foundation
import Observation
import CodexCore

enum CodexAppFeedbackCategory: String, CaseIterable, Identifiable {
    case bug, badResult = "bad_result", goodResult = "good_result", safetyCheck = "safety_check", other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bug: "Bug"
        case .badResult: "Poor result"
        case .goodResult: "Good result"
        case .safetyCheck: "Safety check"
        case .other: "Other"
        }
    }
}

@Observable @MainActor
final class CodexAppFeedbackFeatures {
    private(set) var receipt: CodexSchemaFeedbackUploadResponse?
    private(set) var isUploading = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var provider: (any CodexAppRuntimeProviding)?
    @ObservationIgnored private var generation: UInt64 = 0

    func bind(_ provider: (any CodexAppRuntimeProviding)?) {
        generation &+= 1
        self.provider = provider
        receipt = nil
        isUploading = false
        errorMessage = nil
    }

    static func parameters(category: CodexAppFeedbackCategory, reason: String, threadID: String?,
                           includeLogs: Bool, extraFiles: String, tags: String) throws -> CodexSchemaFeedbackUploadParams {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = extraFiles.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard includeLogs || files.isEmpty else {
            throw CodexAppFeatureError.invalidInput("Enable log uploads before attaching additional log files.")
        }
        guard files.allSatisfy({ $0.hasPrefix("/") }) else {
            throw CodexAppFeatureError.invalidInput("Use absolute file paths on the app-server host for additional logs.")
        }
        var parsedTags: [String: String] = [:]
        for line in tags.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw CodexAppFeatureError.invalidInput("Enter one key=value tag per line.") }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, parsedTags[key] == nil else {
                throw CodexAppFeatureError.invalidInput("Feedback tags need unique, nonempty keys.")
            }
            parsedTags[key] = String(parts[1])
        }
        return .init(classification: category.rawValue, extraLogFiles: files.isEmpty ? nil : Array(Set(files)).sorted(),
                     includeLogs: includeLogs, reason: reason.isEmpty ? nil : reason, tags: parsedTags.isEmpty ? nil : parsedTags,
                     threadID: threadID)
    }

    /// The view passes the immutable payload the user reviewed. Uploads never
    /// run on binding, page appearance, or reconnect, and are never retried.
    func upload(_ params: CodexSchemaFeedbackUploadParams) async {
        guard let provider, !isUploading else { return }
        let expected = generation
        isUploading = true
        errorMessage = nil
        receipt = nil
        defer { if expected == generation { isUploading = false } }
        do {
            let value = try await provider.perform(CodexRequest.feedbackUpload(params))
            guard expected == generation, !Task.isCancelled else { return }
            receipt = value
        } catch {
            guard expected == generation, !Task.isCancelled else { return }
            errorMessage = "Feedback upload could not be confirmed. It was not retried automatically."
        }
    }
}
