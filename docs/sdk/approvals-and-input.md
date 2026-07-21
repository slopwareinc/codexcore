# Approvals and user input

App-server can send requests that require a host decision. CodexCore parses and validates them but does not choose policy for the host.

## Handler strategies

A `CodexSessionServerRequestHandler` may:

- return a validated result immediately;
- return an error;
- return `.pending` so the UI can resolve the request later.

Pending requests are keyed by exact `(connectionEpoch, requestID)` identity. Resolve that key once; disconnect removes old-epoch requests and cancels handler tasks. Do not cache continuations or replay decisions after reconnect.

## Request families

- command execution approval
- file-change approval
- permissions approval
- blocking user questions
- MCP elicitation
- dynamic-tool calls
- token refresh and attestation
- current-time requests
- legacy command and patch approvals

## Example: explicit non-interactive policy

```swift
let codex = try await Codex(
    config: .init(cwd: workspacePath),
    serverRequestHandler: { request in
        switch request.body {
        case .commandApproval, .fileChangeApproval, .permissionsApproval:
            return .error(.init(
                code: -32_000,
                message: "This host does not permit mutations."
            ))
        default:
            return .pending
        }
    }
)
```

Production policy should be explicit about commands, paths, network access, and session-scoped grants. Do not copy `codex-run`'s auto-approval handler into an end-user application.

Handlers return `.result(CodexJSONValue)`, so validated results are encoded at the boundary. GA legacy denials carry a rejection reason:

```swift
let denial = CodexValidatedServerRequestResult.legacyExecCommandApproval(
    .denied(rejection: "Rejected by the user.")
)
return .result(denial.jsonValue)
```

The default `.pending` policy keeps approvals, questions, permissions, MCP elicitation, and legacy approvals in the inbox. It answers current-time requests, fails unhandled dynamic tools with `success: false`, returns configuration errors for token/attestation requests, and rejects unknown methods.
