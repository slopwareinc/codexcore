import Foundation

public struct CodexAutomationLoadResult: Equatable, Sendable {
    public let automations: [CodexAutomation]
    public let errors: [CodexAutomationLoadError]

    public init(automations: [CodexAutomation] = [], errors: [CodexAutomationLoadError] = []) {
        self.automations = automations
        self.errors = errors
    }
}

public struct CodexAutomationLoadError: Error, Equatable, Sendable, LocalizedError {
    public enum Kind: String, Equatable, Sendable {
        case directoryRead
        case fileRead
        case parse
    }

    public let url: URL
    public let kind: Kind
    public let message: String

    public init(url: URL, kind: Kind, message: String) {
        self.url = url
        self.kind = kind
        self.message = message
    }

    public var errorDescription: String? {
        "\(url.path): \(message)"
    }
}

public struct CodexAutomationFileStore: Sendable {
    public let directoryURL: URL

    private let cache: Cache

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        self.cache = Cache()
    }

    /// Loads automation files away from the caller's actor.
    ///
    /// A directory or file failure is returned in `errors` while other files
    /// continue to load. The app can therefore report partial failures without
    /// hiding the automations that were readable.
    public func load() async -> CodexAutomationLoadResult {
        let directoryURL = directoryURL
        let cache = cache
        return await Task.detached(priority: .userInitiated) {
            Self.loadSynchronously(directoryURL: directoryURL, cache: cache)
        }.value
    }

    /// Compatibility shim for callers that have not moved their launch path to
    /// the async result yet. New callers should use `await load()` so load
    /// failures remain visible.
    public func load() -> [CodexAutomation] {
        Self.loadSynchronously(directoryURL: directoryURL, cache: cache).automations
    }

    public func save(_ automation: CodexAutomation) throws {
        let automationDirectory = directoryURL.appendingPathComponent(automation.id, isDirectory: true)
        try FileManager.default.createDirectory(at: automationDirectory, withIntermediateDirectories: true)
        let file = automationDirectory.appendingPathComponent("automation.toml")

        let existingDocument = cache.document(for: automation.id) ?? Self.readExistingDocument(at: file)
        let unknownValues = existingDocument?.unknownValues
            ?? [:]
        let rrule = existingDocument.map { document in
            document.automation.schedule == automation.schedule ? document.rrule : automation.schedule.rrule
        } ?? automation.schedule.rrule
        let updatedAt = Self.currentEpochMilliseconds()
        try Self.encode(
            automation,
            rrule: rrule,
            unknownValues: unknownValues,
            updatedAtMilliseconds: updatedAt
        ).write(to: file, atomically: true, encoding: .utf8)
        cache.store(
            Document(
                automation: automation,
                rrule: rrule,
                unknownValues: unknownValues,
                updatedAtMilliseconds: updatedAt
            ),
            for: automation.id
        )
    }

    public func delete(id: String) throws {
        let directory = directoryURL.appendingPathComponent(id, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
        cache.remove(for: id)
    }

    /// Encodes the official Codex automation schema.
    public static func encode(_ automation: CodexAutomation) -> String {
        let document = decodedDocumentCache.document(for: automation.id)
        let unknownValues = document?.unknownValues ?? [:]
        let rrule = document.map { $0.automation.schedule == automation.schedule ? $0.rrule : automation.schedule.rrule }
            ?? automation.schedule.rrule
        let updatedAtMilliseconds = document?.automation == automation
            ? document?.updatedAtMilliseconds ?? currentEpochMilliseconds()
            : currentEpochMilliseconds()
        return encode(
            automation,
            rrule: rrule,
            unknownValues: unknownValues,
            updatedAtMilliseconds: updatedAtMilliseconds
        )
    }

    /// Decodes an automation without throwing for compatibility with the old
    /// optional-returning API. File loading uses the throwing path internally so
    /// malformed files are reported to the caller.
    public static func decode(_ contents: String) -> CodexAutomation? {
        guard let document = try? parse(contents) else { return nil }
        decodedDocumentCache.store(document, for: document.automation.id)
        return document.automation
    }
}

private extension CodexAutomationFileStore {
    static let decodedDocumentCache = Cache()

    static let knownKeys: Set<String> = [
        "version",
        "id",
        "kind",
        "name",
        "prompt",
        "status",
        "rrule",
        "target_thread_id",
        "created_at",
        "updated_at"
    ]

    struct Document: Sendable {
        let automation: CodexAutomation
        let rrule: String
        let unknownValues: [String: TOMLValue]
        let updatedAtMilliseconds: Int64?
    }

    final class Cache: @unchecked Sendable {
        private let maximumDocumentCount = 256
        private let lock = NSLock()
        private var documents: [String: Document] = [:]

        func store(_ document: Document, for id: String) {
            lock.lock()
            if documents[id] == nil, documents.count >= maximumDocumentCount {
                if let evictedID = documents.keys.first {
                    documents.removeValue(forKey: evictedID)
                }
            }
            documents[id] = document
            lock.unlock()
        }

        func document(for id: String) -> Document? {
            lock.lock()
            defer { lock.unlock() }
            return documents[id]
        }

        func remove(for id: String) {
            lock.lock()
            documents.removeValue(forKey: id)
            lock.unlock()
        }
    }

    enum StoreError: Error, CustomStringConvertible {
        case missingRequiredField(String)
        case invalidField(String)

        var description: String {
            switch self {
            case let .missingRequiredField(key): "missing required field '\(key)'"
            case let .invalidField(key): "invalid value for '\(key)'"
            }
        }
    }

    static func loadSynchronously(directoryURL: URL, cache: Cache) -> CodexAutomationLoadResult {
        let fileManager = FileManager.default
        let directories: [URL]
        do {
            directories = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }.sorted { $0.path < $1.path }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return CodexAutomationLoadResult()
        } catch {
            return CodexAutomationLoadResult(errors: [
                CodexAutomationLoadError(
                    url: directoryURL,
                    kind: .directoryRead,
                    message: error.localizedDescription
                )
            ])
        }

        var automations: [CodexAutomation] = []
        var errors: [CodexAutomationLoadError] = []
        for directory in directories {
            let file = directory.appendingPathComponent("automation.toml")
            let contents: String
            do {
                contents = try String(contentsOf: file, encoding: .utf8)
            } catch {
                errors.append(CodexAutomationLoadError(
                    url: file,
                    kind: .fileRead,
                    message: error.localizedDescription
                ))
                continue
            }

            do {
                let document = try parse(contents)
                automations.append(document.automation)
                cache.store(document, for: document.automation.id)
            } catch {
                errors.append(CodexAutomationLoadError(
                    url: file,
                    kind: .parse,
                    message: String(describing: error)
                ))
            }
        }

        return CodexAutomationLoadResult(
            automations: automations.sorted { $0.createdAt < $1.createdAt },
            errors: errors
        )
    }

    static func readExistingDocument(at file: URL) -> Document? {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return try? parse(contents)
    }

    static func parse(_ contents: String) throws -> Document {
        var parser = TOMLParser(contents)
        let values = try parser.parse()
        guard let id = values["id"]?.stringValue else { throw StoreError.missingRequiredField("id") }
        guard let name = values["name"]?.stringValue else { throw StoreError.missingRequiredField("name") }
        guard let prompt = values["prompt"]?.stringValue else { throw StoreError.missingRequiredField("prompt") }

        let versionValue = try integer(values["version"], key: "version")
        let version: Int
        if let versionValue {
            guard let converted = Int(exactly: versionValue) else { throw StoreError.invalidField("version") }
            version = converted
        } else {
            version = 1
        }
        let status = try decodeStatus(values["status"])
        let rrule = try string(values["rrule"], key: "rrule") ?? "FREQ=DAILY;BYHOUR=9;BYMINUTE=0"
        let targetThreadID = try string(values["target_thread_id"], key: "target_thread_id")
        let createdAt = try decodeDate(values["created_at"], key: "created_at") ?? Date()
        let updatedAtMilliseconds = try integer(values["updated_at"], key: "updated_at")

        let automation = CodexAutomation(
            version: version,
            id: id,
            name: name,
            prompt: prompt,
            schedule: CodexAutomationSchedule(rrule: rrule),
            status: status,
            targetThreadID: targetThreadID,
            createdAt: createdAt
        )
        let unknownValues = values.filter { !knownKeys.contains($0.key) }
        return Document(
            automation: automation,
            rrule: rrule,
            unknownValues: unknownValues,
            updatedAtMilliseconds: updatedAtMilliseconds
        )
    }

    static func encode(
        _ automation: CodexAutomation,
        rrule: String,
        unknownValues: [String: TOMLValue],
        updatedAtMilliseconds: Int64
    ) -> String {
        var lines = [
            "version = \(automation.version)",
            "id = \(quoted(automation.id))",
            "kind = \"heartbeat\"",
            "name = \(quoted(automation.name))",
            "prompt = \(quoted(automation.prompt))",
            "status = \(quoted(wireStatus(for: automation.status)))",
            "rrule = \(quoted(rrule))"
        ]
        if let targetThreadID = automation.targetThreadID {
            lines.append("target_thread_id = \(quoted(targetThreadID))")
        }
        lines.append("created_at = \(epochMilliseconds(for: automation.createdAt))")
        lines.append("updated_at = \(updatedAtMilliseconds)")

        for key in unknownValues.keys.sorted() {
            guard !knownKeys.contains(key), let value = unknownValues[key] else { continue }
            lines.append("\(encodedKey(key)) = \(value.encoded)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func string(_ value: TOMLValue?, key: String) throws -> String? {
        guard let value else { return nil }
        guard case let .string(string) = value else { throw StoreError.invalidField(key) }
        return string
    }

    static func integer(_ value: TOMLValue?, key: String) throws -> Int64? {
        guard let value else { return nil }
        guard case let .integer(integer) = value else { throw StoreError.invalidField(key) }
        return integer
    }

    static func decodeDate(_ value: TOMLValue?, key: String) throws -> Date? {
        guard let value else { return nil }
        if case let .integer(milliseconds) = value {
            return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        }
        if case let .string(string) = value {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: string) { return date }
        }
        throw StoreError.invalidField(key)
    }

    static func decodeStatus(_ value: TOMLValue?) throws -> CodexAutomationStatus {
        guard let value else { return .enabled }
        guard case let .string(raw) = value else { throw StoreError.invalidField("status") }
        switch raw.uppercased() {
        case "ACTIVE", "ENABLED": return .enabled
        case "PAUSED", "DISABLED": return .disabled
        case "RUNNING": return .running
        case "FAILED": return .failed
        default: throw StoreError.invalidField("status")
        }
    }

    static func wireStatus(for status: CodexAutomationStatus) -> String {
        switch status {
        case .enabled: "ACTIVE"
        case .disabled: "PAUSED"
        case .running: "RUNNING"
        case .failed: "FAILED"
        }
    }

    static func currentEpochMilliseconds() -> Int64 {
        epochMilliseconds(for: Date())
    }

    static func epochMilliseconds(for date: Date) -> Int64 {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite else { return 0 }
        if milliseconds >= Double(Int64.max) { return Int64.max }
        if milliseconds <= Double(Int64.min) { return Int64.min }
        return Int64(milliseconds.rounded())
    }

    static func quoted(_ string: String) -> String {
        let data = try? JSONEncoder().encode(string)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    static func encodedKey(_ key: String) -> String {
        let isBare = !key.isEmpty && key.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
        }
        return isBare ? key : quoted(key)
    }
}

private enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case float(Double)
    case boolean(Bool)
    case array([TOMLValue])
    case inlineTable([String: TOMLValue])
    case raw(String)

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var encoded: String {
        switch self {
        case let .string(value): return CodexAutomationFileStore.quoted(value)
        case let .integer(value): return String(value)
        case let .float(value): return String(value)
        case let .boolean(value): return value ? "true" : "false"
        case let .array(values): return "[\(values.map(\.encoded).joined(separator: ", "))]"
        case let .inlineTable(values):
            let entries = values.keys.sorted().compactMap { key in
                values[key].map { "\(CodexAutomationFileStore.encodedKey(key)) = \($0.encoded)" }
            }
            return "{ \(entries.joined(separator: ", ")) }"
        case let .raw(value): return value
        }
    }
}

private struct TOMLParser {
    private enum ParserError: Error, CustomStringConvertible {
        case expected(String, line: Int)
        case invalid(String, line: Int)
        case unterminated(String, line: Int)

        var description: String {
            switch self {
            case let .expected(what, line): "line \(line): expected \(what)"
            case let .invalid(what, line): "line \(line): invalid \(what)"
            case let .unterminated(what, line): "line \(line): unterminated \(what)"
            }
        }
    }

    private let characters: [Character]
    private var index = 0
    private var line = 1

    init(_ contents: String) {
        self.characters = Array(contents)
    }

    mutating func parse() throws -> [String: TOMLValue] {
        var values: [String: TOMLValue] = [:]
        while true {
            skipDocumentWhitespaceAndComments()
            guard !isAtEnd else { return values }
            if current == "[" {
                throw ParserError.invalid("tables are not supported in an automation file", line: line)
            }

            let key = try parseKey()
            skipHorizontalWhitespace()
            guard consume("=") else { throw ParserError.expected("=", line: line) }
            skipHorizontalWhitespace()
            guard !isAtEnd else { throw ParserError.expected("a value", line: line) }
            guard values[key] == nil else { throw ParserError.invalid("duplicate key '\(key)'", line: line) }
            values[key] = try parseValue()

            skipHorizontalWhitespace()
            if consume("#") {
                skipToLineEnd()
            }
            if consumeNewline() {
                continue
            }
            guard isAtEnd else { throw ParserError.expected("a newline", line: line) }
        }
    }

    private mutating func parseKey() throws -> String {
        guard !isAtEnd else { throw ParserError.expected("a key", line: line) }
        if current == "\"" {
            return try parseBasicString(multiLine: false)
        }
        if current == "'" {
            return try parseLiteralString(multiLine: false)
        }

        let start = index
        while !isAtEnd, current.isASCII && (current.isLetter || current.isNumber || current == "_" || current == "-" || current == ".") {
            advance()
        }
        guard index > start else { throw ParserError.invalid("key", line: line) }
        return String(characters[start..<index])
    }

    private mutating func parseValue() throws -> TOMLValue {
        if starts(with: "\"\"\"") {
            return .string(try parseBasicString(multiLine: true))
        }
        if current == "\"" {
            return .string(try parseBasicString(multiLine: false))
        }
        if starts(with: "'''") {
            return .string(try parseLiteralString(multiLine: true))
        }
        if current == "'" {
            return .string(try parseLiteralString(multiLine: false))
        }
        if current == "[" {
            return try parseArray()
        }
        if current == "{" {
            return try parseInlineTable()
        }

        let token = parseBareToken()
        guard !token.isEmpty else { throw ParserError.expected("a value", line: line) }
        guard !token.contains("=") else { throw ParserError.invalid("unquoted value", line: line) }
        if token == "true" { return .boolean(true) }
        if token == "false" { return .boolean(false) }
        if let integer = parseInteger(token) { return .integer(integer) }
        if let float = Double(token.replacingOccurrences(of: "_", with: "")) { return .float(float) }
        return .raw(token)
    }

    private mutating func parseArray() throws -> TOMLValue {
        guard consume("[") else { throw ParserError.expected("[", line: line) }
        var values: [TOMLValue] = []
        skipArrayWhitespace()
        if consume("]") { return .array(values) }

        while true {
            values.append(try parseValue())
            skipArrayWhitespace()
            if consume("]") { return .array(values) }
            guard consume(",") else { throw ParserError.expected(", or ]", line: line) }
            skipArrayWhitespace()
            if consume("]") { return .array(values) }
        }
    }

    private mutating func parseInlineTable() throws -> TOMLValue {
        guard consume("{") else { throw ParserError.expected("{", line: line) }
        var values: [String: TOMLValue] = [:]
        skipInlineTableWhitespace()
        if consume("}") { return .inlineTable(values) }

        while true {
            let key = try parseKey()
            skipHorizontalWhitespace()
            guard consume("=") else { throw ParserError.expected("=", line: line) }
            skipHorizontalWhitespace()
            guard values[key] == nil else { throw ParserError.invalid("duplicate key '\(key)'", line: line) }
            values[key] = try parseValue()
            skipInlineTableWhitespace()
            if consume("}") { return .inlineTable(values) }
            guard consume(",") else { throw ParserError.expected(", or }", line: line) }
            skipInlineTableWhitespace()
            if consume("}") { return .inlineTable(values) }
        }
    }

    private mutating func parseBasicString(multiLine: Bool) throws -> String {
        if multiLine {
            guard starts(with: "\"\"\"") else { throw ParserError.expected("\"\"\"", line: line) }
            advance(3)
            if consumeNewline() { }
        } else {
            guard consume("\"") else { throw ParserError.expected("\"", line: line) }
        }

        var result = ""
        while !isAtEnd {
            if multiLine && starts(with: "\"\"\"") {
                advance(3)
                return result
            }
            if !multiLine && current == "\"" {
                advance()
                return result
            }
            if current == "\\" {
                advance()
                if multiLine && (current == "\n" || current == "\r") {
                    _ = consumeNewline()
                    while !isAtEnd && (current == " " || current == "\t" || current == "\n" || current == "\r") {
                        _ = consumeNewline()
                        if !isAtEnd && current != " " && current != "\t" { break }
                        if !isAtEnd { advance() }
                    }
                    continue
                }
                result.append(try parseEscape())
                continue
            }
            if !multiLine && (current == "\n" || current == "\r") {
                throw ParserError.unterminated("basic string", line: line)
            }
            if multiLine && consumeNewline() {
                result.append("\n")
            } else {
                result.append(current)
                advance()
            }
        }
        throw ParserError.unterminated("basic string", line: line)
    }

    private mutating func parseLiteralString(multiLine: Bool) throws -> String {
        if multiLine {
            guard starts(with: "'''") else { throw ParserError.expected("'''", line: line) }
            advance(3)
            if consumeNewline() { }
        } else {
            guard consume("'") else { throw ParserError.expected("'", line: line) }
        }

        var result = ""
        while !isAtEnd {
            if multiLine && starts(with: "'''") {
                advance(3)
                return result
            }
            if !multiLine && current == "'" {
                advance()
                return result
            }
            if multiLine && consumeNewline() {
                result.append("\n")
            } else {
                result.append(current)
                advance()
            }
        }
        throw ParserError.unterminated("literal string", line: line)
    }

    private mutating func parseEscape() throws -> Character {
        guard !isAtEnd else { throw ParserError.unterminated("escape", line: line) }
        let escaped = current
        advance()
        switch escaped {
        case "b": return "\u{0008}"
        case "t": return "\t"
        case "n": return "\n"
        case "f": return "\u{000C}"
        case "r": return "\r"
        case "\"": return "\""
        case "\\": return "\\"
        case "u": return try parseUnicodeEscape(count: 4)
        case "U": return try parseUnicodeEscape(count: 8)
        default: throw ParserError.invalid("escape \\\(escaped)", line: line)
        }
    }

    private mutating func parseUnicodeEscape(count: Int) throws -> Character {
        var value = 0
        for _ in 0..<count {
            guard !isAtEnd, let digit = current.hexDigitValue else {
                throw ParserError.invalid("unicode escape", line: line)
            }
            value = value * 16 + digit
            advance()
        }
        guard let scalar = Unicode.Scalar(value) else {
            throw ParserError.invalid("unicode escape", line: line)
        }
        return Character(scalar)
    }

    private mutating func parseBareToken() -> String {
        let start = index
        while !isAtEnd {
            if current == " " || current == "\t" || current == "\n" || current == "\r" || current == "#" || current == "," || current == "]" || current == "}" {
                break
            }
            advance()
        }
        return String(characters[start..<index])
    }

    private mutating func skipDocumentWhitespaceAndComments() {
        while !isAtEnd {
            if current == " " || current == "\t" || current == "\n" || current == "\r" {
                _ = consumeNewline()
                if current != " " && current != "\t" && current != "\n" && current != "\r" { continue }
                advance()
            } else if consume("#") {
                skipToLineEnd()
            } else {
                break
            }
        }
    }

    private mutating func skipHorizontalWhitespace() {
        while !isAtEnd && (current == " " || current == "\t") { advance() }
    }

    private mutating func skipArrayWhitespace() {
        while !isAtEnd {
            if current == "#" {
                skipToLineEnd()
            } else if current == " " || current == "\t" || current == "\n" || current == "\r" {
                _ = consumeNewline()
                if current != " " && current != "\t" && current != "\n" && current != "\r" { continue }
                advance()
            } else {
                break
            }
        }
    }

    private mutating func skipInlineTableWhitespace() {
        while !isAtEnd && (current == " " || current == "\t") { advance() }
    }

    private mutating func skipToLineEnd() {
        while !isAtEnd && current != "\n" && current != "\r" { advance() }
    }

    private mutating func consumeNewline() -> Bool {
        if current == "\r" {
            advance()
            if !isAtEnd && current == "\n" { advance() }
            line += 1
            return true
        }
        if current == "\n" {
            advance()
            line += 1
            return true
        }
        return false
    }

    private var current: Character {
        guard !isAtEnd else { return "\u{0000}" }
        return characters[index]
    }

    private var isAtEnd: Bool {
        index >= characters.count
    }

    private func starts(with value: String) -> Bool {
        let expected = Array(value)
        guard index + expected.count <= characters.count else { return false }
        return characters[index..<(index + expected.count)].elementsEqual(expected)
    }

    private mutating func consume(_ value: Character) -> Bool {
        guard !isAtEnd, current == value else { return false }
        advance()
        return true
    }

    private mutating func advance(_ count: Int = 1) {
        index += count
    }

    private func parseInteger(_ token: String) -> Int64? {
        let normalized = token.replacingOccurrences(of: "_", with: "")
        if normalized.hasPrefix("0x") || normalized.hasPrefix("0X") {
            return Int64(normalized.dropFirst(2), radix: 16)
        }
        if normalized.hasPrefix("0o") || normalized.hasPrefix("0O") {
            return Int64(normalized.dropFirst(2), radix: 8)
        }
        if normalized.hasPrefix("0b") || normalized.hasPrefix("0B") {
            return Int64(normalized.dropFirst(2), radix: 2)
        }
        return Int64(normalized)
    }
}
