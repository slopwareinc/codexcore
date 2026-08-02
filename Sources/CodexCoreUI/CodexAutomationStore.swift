import Foundation

public struct CodexAutomationFileStore: Sendable {
    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public func load() -> [CodexAutomation] {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return directories.compactMap { directory in
            let file = directory.appendingPathComponent("automation.toml")
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return Self.decode(contents)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    public func save(_ automation: CodexAutomation) throws {
        let automationDirectory = directoryURL.appendingPathComponent(automation.id, isDirectory: true)
        try FileManager.default.createDirectory(at: automationDirectory, withIntermediateDirectories: true)
        let file = automationDirectory.appendingPathComponent("automation.toml")
        try Self.encode(automation).write(to: file, atomically: true, encoding: .utf8)
    }

    public func delete(id: String) throws {
        let directory = directoryURL.appendingPathComponent(id, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    public static func encode(_ automation: CodexAutomation) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "version = \(automation.version)",
            "id = \(quoted(automation.id))",
            "kind = \"schedule\"",
            "name = \(quoted(automation.name))",
            "prompt = \(quoted(automation.prompt))",
            "status = \(quoted(automation.status.rawValue))",
            "rrule = \(quoted(automation.schedule.rrule))",
            "created_at = \(quoted(formatter.string(from: automation.createdAt)))"
        ]
        if let targetThreadID = automation.targetThreadID { lines.append("target_thread_id = \(quoted(targetThreadID))") }
        if let lastRunAt = automation.lastRunAt { lines.append("last_run_at = \(quoted(formatter.string(from: lastRunAt)))") }
        if let nextRunAt = automation.nextRunAt { lines.append("next_run_at = \(quoted(formatter.string(from: nextRunAt)))") }
        if let lastError = automation.lastError { lines.append("last_error = \(quoted(lastError))") }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func decode(_ contents: String) -> CodexAutomation? {
        let pairs = contents.split(whereSeparator: \.isNewline).reduce(into: [String: String]()) { result, line in
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2 else { return }
            result[pair[0]] = unquoted(pair[1])
        }
        guard let id = pairs["id"], let name = pairs["name"], let prompt = pairs["prompt"] else { return nil }
        let formatter = ISO8601DateFormatter()
        let status: CodexAutomationStatus
        switch pairs["status"]?.lowercased() {
        case "active": status = .enabled
        case "paused": status = .disabled
        case let raw?: status = CodexAutomationStatus(rawValue: raw) ?? .enabled
        case nil: status = .enabled
        }
        return CodexAutomation(
            version: Int(pairs["version"] ?? "1") ?? 1,
            id: id,
            name: name,
            prompt: prompt,
            schedule: CodexAutomationSchedule(rrule: pairs["rrule"] ?? "FREQ=DAILY;BYHOUR=9;BYMINUTE=0"),
            status: status,
            targetThreadID: pairs["target_thread_id"],
            createdAt: pairs["created_at"].flatMap(formatter.date) ?? Date(),
            lastRunAt: pairs["last_run_at"].flatMap(formatter.date),
            nextRunAt: pairs["next_run_at"].flatMap(formatter.date),
            lastError: pairs["last_error"]
        )
    }

    private static func quoted(_ string: String) -> String {
        let data = try? JSONEncoder().encode(string)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private static func unquoted(_ string: String) -> String {
        guard let data = string.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) else { return string }
        return decoded
    }
}
