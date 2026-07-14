import CodexCore
import Foundation

public struct CodexTranscriptV2: Sendable, Equatable {
    public var turns: [CodexTurnV2]
    public init(turns: [CodexTurnV2] = []) { self.turns = turns }
}

public struct CodexTurnV2: Identifiable, Sendable, Equatable {
    public var id: String
    public var userMessage: CodexUserMessageV2?
    public var narrative: [CodexNarrativeEntry]
    public var finalAnswer: CodexAssistantTextV2?
    public var liveTail: String?
    public var status: CodexTurnStatusV2
    public var wireStatus: CodexSchemaTurnStatus?
    public var error: CodexSchemaTurnError?
    public var startedAt: Int?
    public var completedAt: Int?
    public var durationMs: Int?
    public var itemsView: CodexSchemaTurnItemsView?

    public init(
        id: String,
        userMessage: CodexUserMessageV2? = nil,
        narrative: [CodexNarrativeEntry] = [],
        finalAnswer: CodexAssistantTextV2? = nil,
        liveTail: String? = nil,
        status: CodexTurnStatusV2,
        wireStatus: CodexSchemaTurnStatus? = nil,
        error: CodexSchemaTurnError? = nil,
        startedAt: Int? = nil,
        completedAt: Int? = nil,
        durationMs: Int? = nil,
        itemsView: CodexSchemaTurnItemsView? = nil
    ) {
        self.id = id; self.userMessage = userMessage; self.narrative = narrative
        self.finalAnswer = finalAnswer; self.liveTail = liveTail; self.status = status
        self.wireStatus = wireStatus; self.error = error; self.startedAt = startedAt
        self.completedAt = completedAt; self.durationMs = durationMs; self.itemsView = itemsView
    }
}

public struct CodexUserMessageV2: Identifiable, Sendable, Equatable {
    public var id: String
    public var clientID: String?
    public var text: String
    public var isOptimistic: Bool
    public init(id: String, clientID: String? = nil, text: String, isOptimistic: Bool = false) {
        self.id = id; self.clientID = clientID; self.text = text; self.isOptimistic = isOptimistic
    }
}

public struct CodexAssistantTextV2: Identifiable, Sendable, Equatable {
    public var id: String
    public var text: String
    public var isStreaming: Bool
    public init(id: String, text: String = "", isStreaming: Bool = true) {
        self.id = id; self.text = text; self.isStreaming = isStreaming
    }
}

public enum CodexTurnStatusV2: Sendable, Equatable {
    case working(since: Int64?)
    case done(durationMs: Int?)
    case failed(message: String)
}

public enum CodexNarrativeEntry: Identifiable, Sendable, Equatable {
    case prose(CodexAssistantTextV2)
    case workGroup(CodexWorkGroupV2)
    case productToolCall(CodexProductToolCallV2)
    case notice(CodexTurnNoticeV2)

    public var id: String {
        switch self {
        case .prose(let value): value.id
        case .workGroup(let value): value.id
        case .productToolCall(let value): value.id
        case .notice(let value): value.id
        }
    }
}

public struct CodexWorkGroupV2: Identifiable, Sendable, Equatable {
    public var id: String
    public var header: String
    public var rows: [CodexWorkRowV2]
    public var isLive: Bool
    public init(id: String, header: String = "", rows: [CodexWorkRowV2] = [], isLive: Bool = true) {
        self.id = id; self.header = header; self.rows = rows; self.isLive = isLive
    }
}

public enum CodexWorkItemStatusV2: Sendable, Equatable { case inProgress, completed, failed }

public struct CodexCommandRowV2: Identifiable, Sendable, Equatable {
    public var id: String; public var command: String; public var label: String
    public var action: CodexWorkCategoryV2; public var status: CodexWorkItemStatusV2
    public var exitCode: Int?; public var durationMs: Int?; public var output: String?
    public init(id: String, command: String, label: String, action: CodexWorkCategoryV2, status: CodexWorkItemStatusV2, exitCode: Int? = nil, durationMs: Int? = nil, output: String? = nil) {
        self.id = id; self.command = command; self.label = label; self.action = action; self.status = status
        self.exitCode = exitCode; self.durationMs = durationMs; self.output = output
    }
}
public struct CodexFileChangeRowV2: Identifiable, Sendable, Equatable {
    public var id: String; public var files: [String]; public var status: CodexWorkItemStatusV2
    public var durationMs: Int?; public var diff: String?
}
public struct CodexMCPToolCallRowV2: Identifiable, Sendable, Equatable {
    public var id: String; public var appName: String; public var server: String; public var tool: String
    public var status: CodexWorkItemStatusV2; public var durationMs: Int?; public var errorFirstLine: String?
    public var arguments: CodexJSONValue?; public var result: CodexJSONValue?
}
public struct CodexWebSearchRowV2: Identifiable, Sendable, Equatable {
    public var id: String; public var query: String; public var status: CodexWorkItemStatusV2
}
 public enum CodexCollabActionV2: Sendable, Equatable {
    case created, sentInput, waited, closed
    case started, interacted, interrupted
}

extension CodexCollabAgentRowV2 {
    var label: String {
        let names = agentNames.joined(separator: ", ")
        return switch action {
        case .created: "Created \(names)\(instructions.map { " with the instructions: \($0)" } ?? "")"
        case .sentInput: "Sent input to \(names)"
        case .waited: names.isEmpty ? "Waited for agents" : "Waited for \(names)"
        case .closed: names.isEmpty ? "Closed agents" : "Closed \(names)"
        case .started: "Started an agent"
        case .interacted: "Messaged an agent"
        case .interrupted: "Interrupted an agent"
        }
    }
}
 public struct CodexCollabAgentRowV2: Identifiable, Sendable, Equatable {
     public var id: String; public var action: CodexCollabActionV2; public var agentNames: [String]
     public var agentThreadIDs: [String]
     public var instructions: String?; public var agentMessages: [String: String]
    public var status: CodexWorkItemStatusV2

    public init(
        id: String,
         action: CodexCollabActionV2,
         agentNames: [String],
         agentThreadIDs: [String] = [],
        instructions: String?,
        agentMessages: [String: String] = [:],
        status: CodexWorkItemStatusV2
    ) {
         self.id = id; self.action = action; self.agentNames = agentNames; self.agentThreadIDs = agentThreadIDs
         self.instructions = instructions; self.agentMessages = agentMessages; self.status = status
    }
}
public struct CodexOtherWorkRowV2: Identifiable, Sendable, Equatable {
    public var id: String; public var label: String; public var status: CodexWorkItemStatusV2
}

public enum CodexWorkRowV2: Identifiable, Sendable, Equatable {
    case command(CodexCommandRowV2), fileChange(CodexFileChangeRowV2), mcpToolCall(CodexMCPToolCallRowV2)
    case webSearch(CodexWebSearchRowV2), collabAgent(CodexCollabAgentRowV2), other(CodexOtherWorkRowV2)
    public var id: String {
        switch self {
        case .command(let v): v.id; case .fileChange(let v): v.id; case .mcpToolCall(let v): v.id
        case .webSearch(let v): v.id; case .collabAgent(let v): v.id; case .other(let v): v.id
        }
    }
    public var isInProgress: Bool {
        switch self {
        case .command(let v): v.status == .inProgress; case .fileChange(let v): v.status == .inProgress
        case .mcpToolCall(let v): v.status == .inProgress; case .webSearch(let v): v.status == .inProgress
        case .collabAgent(let v): v.status == .inProgress; case .other(let v): v.status == .inProgress
        }
    }
}

public struct CodexProductToolCallV2: Identifiable, Sendable, Equatable {
    public var id: String; public var tool: String; public var namespace: String?
    public var arguments: CodexJSONValue?; public var status: CodexWorkItemStatusV2
    public var contentItems: [CodexJSONValue]; public var success: Bool?
}
public struct CodexTurnNoticeV2: Identifiable, Sendable, Equatable {
    public var id: String; public var message: String
    public init(id: String, message: String) { self.id = id; self.message = message }
}

 public enum CodexWorkCategoryV2: Sendable, Hashable {
    case read, list, search, webSearch, run, edit, mcp(String)
    case collabCreated, collabClosed, collabWait, collabWorked, imageGeneration
 }
