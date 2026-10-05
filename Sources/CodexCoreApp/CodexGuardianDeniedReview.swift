import Foundation
import CodexCore

/// Reconstructs the protocol GuardianAssessmentEvent from the exact completed
/// notification retained by the canonical reducer. This follows Codex 0.160.0's
/// TUI protocol_requests conversion; it never infers an action from a transcript.
struct CodexGuardianDeniedReview: Identifiable, Sendable, Equatable {
    let reviewID: String
    let turnID: String
    let targetItemID: String?
    let completedAtMs: Int
    let rationale: String?
    let summary: String
    let action: CodexJSONValue
    let event: CodexJSONValue?
    let unavailableReason: String?
    var id: String { turnID + ":" + reviewID }

    init?(notification raw: CodexJSONValue, threadID: String, turnID: String) {
        guard let value = try? raw.decode(CodexSchemaItemGuardianApprovalReviewCompletedNotification.self),
              value.threadID == threadID, value.turnID == turnID, value.review.status == .denied,
              !value.reviewID.isEmpty else { return nil }
        reviewID = value.reviewID
        self.turnID = value.turnID
        targetItemID = value.targetItemID
        completedAtMs = value.completedAtMs
        rationale = value.review.rationale
        action = value.action.rawValue
        summary = Self.actionSummary(action)
        do {
            guard value.decisionSource == .agent else { throw Unsupported() }
            if let risk = value.review.riskLevel, !CodexSchemaGuardianRiskLevel.allCases.contains(risk) { throw Unsupported() }
            if let authorization = value.review.userAuthorization,
               !CodexSchemaGuardianUserAuthorization.allCases.contains(authorization) { throw Unsupported() }
            var fields: [String: CodexJSONValue] = [
                "id": .string(value.reviewID), "turn_id": .string(value.turnID),
                "started_at_ms": .int(value.startedAtMs), "completed_at_ms": .int(value.completedAtMs),
                "status": .string("denied"), "decision_source": .string("agent"),
                "action": try Self.protocolAction(action)
            ]
            if let id = value.targetItemID { fields["target_item_id"] = .string(id) }
            if let risk = value.review.riskLevel { fields["risk_level"] = .string(risk.rawValue) }
            if let authorization = value.review.userAuthorization { fields["user_authorization"] = .string(authorization.rawValue) }
            if let rationale = value.review.rationale { fields["rationale"] = .string(rationale) }
            event = .dictionary(fields)
            unavailableReason = nil
        } catch {
            event = nil
            unavailableReason = "This action uses a protocol shape this client cannot faithfully approve."
        }
    }

    private static func actionSummary(_ value: CodexJSONValue) -> String {
        let fields = value.objectValue ?? [:]
        func string(_ key: String) -> String? { CodexJSONCoercion.string(in: fields, keys: [key]) }
        switch string("type") {
        case "command": return string("command") ?? "Command"
        case "execve": return string("program") ?? "Execute program"
        case "writeStdin": return "Send input to process " + (string("processId") ?? "")
        case "applyPatch": return "Apply file changes"
        case "networkAccess": return "Network access to " + (string("target") ?? string("host") ?? "")
        case "mcpToolCall": return "MCP " + (string("toolName") ?? "tool") + " on " + (string("server") ?? "server")
        case "requestPermissions": return string("reason") ?? "Grant requested permissions"
        default: return "Unsupported reviewed action"
        }
    }

    static func protocolAction(_ value: CodexJSONValue) throws -> CodexJSONValue {
        guard var fields = value.objectValue,
              case .string(let type)? = fields["type"] else { throw Unsupported() }
        let wireType: String
        switch type {
        case "command", "execve":
            guard let source = fields["source"], [.string("shell"), .string("unifiedExec")].contains(source) else { throw Unsupported() }
            fields["source"] = source == .string("unifiedExec") ? .string("unified_exec") : source
            wireType = type
        case "writeStdin":
            wireType = "write_stdin"
            rename("approvalId", to: "approval_id", in: &fields)
            rename("processId", to: "process_id", in: &fields)
            fields["cwd"] = try pathURI(fields["cwd"])
        case "applyPatch": wireType = "apply_patch"
        case "networkAccess":
            wireType = "network_access"
            switch fields["protocol"] {
            case .string("http"), .string("https"): break
            case .string("socks5Tcp"): fields["protocol"] = .string("socks5_tcp")
            case .string("socks5Udp"): fields["protocol"] = .string("socks5_udp")
            default: throw Unsupported()
            }
        case "mcpToolCall":
            wireType = "mcp_tool_call"
            for (from, to) in [("toolName", "tool_name"), ("connectorId", "connector_id"),
                               ("connectorName", "connector_name"), ("toolTitle", "tool_title")] {
                rename(from, to: to, in: &fields)
            }
        case "requestPermissions":
            wireType = "request_permissions"
            fields["permissions"] = try protocolPermissions(fields["permissions"])
        default: throw Unsupported()
        }
        fields["type"] = .string(wireType)
        return .dictionary(fields)
    }

    private static func protocolPermissions(_ value: CodexJSONValue?) throws -> CodexJSONValue {
        guard let value, var profile = value.objectValue,
              Set(profile.keys).isSubset(of: ["network", "fileSystem"]) else { throw Unsupported() }
        if case .dictionary(let network)? = profile["network"], !Set(network.keys).isSubset(of: ["enabled"]) { throw Unsupported() }
        if let fs = profile.removeValue(forKey: "fileSystem"), fs != .null {
            guard let fileSystem = fs.objectValue,
                  Set(fileSystem.keys).isSubset(of: ["read", "write", "entries", "globScanMaxDepth"]) else { throw Unsupported() }
            var entries: [CodexJSONValue] = []
            if case .array(let values)? = fileSystem["entries"] {
                for entry in values {
                    guard var object = entry.objectValue, var path = object["path"]?.objectValue else { throw Unsupported() }
                    if path["type"] == .string("path") { path["path"] = try pathURI(path["path"]) }
                    else if ![.string("glob_pattern"), .string("special")].contains(path["type"] ?? .null) { throw Unsupported() }
                    object["path"] = .dictionary(path)
                    entries.append(.dictionary(object))
                }
            } else {
                for access in ["read", "write"] {
                    if case .array(let paths)? = fileSystem[access] {
                        for path in paths {
                            entries.append(.dictionary(["access": .string(access), "path": .dictionary(["type": .string("path"), "path": try pathURI(path)])]))
                        }
                    }
                }
            }
            var core: [String: CodexJSONValue] = ["entries": .array(entries)]
            if let depth = fileSystem["globScanMaxDepth"] { core["glob_scan_max_depth"] = depth }
            profile["file_system"] = .dictionary(core)
        } else { profile["file_system"] = .null }
        return .dictionary(profile)
    }

    private static func pathURI(_ value: CodexJSONValue?) throws -> CodexJSONValue {
        guard case .string(let path)? = value else { throw Unsupported() }
        if path.hasPrefix("file:"), let components = URLComponents(string: path), components.scheme == "file" {
            return .string(path)
        }
        guard path.hasPrefix("/") else { throw Unsupported() }
        return .string(URL(fileURLWithPath: path).absoluteString)
    }

    private static func rename(_ from: String, to: String, in fields: inout [String: CodexJSONValue]) {
        if let value = fields.removeValue(forKey: from) { fields[to] = value }
    }
    private struct Unsupported: Error {}
}
