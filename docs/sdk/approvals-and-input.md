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

## Rust interaction layer

`codex-app-server-interaction` parses the actor's exact pending inbox entries
into stable request families for command/file/permission approval, user input,
MCP elicitation, dynamic tools, token refresh, attestation, current time, and
legacy command/patch approval. Unknown methods remain explicit with their full
raw parameters.

Every known parameter and response shape is checked against schema artifacts
generated from `Tools/UPSTREAM_VERSION`. An invalid result is rejected locally
and the request stays pending; only a validated result or explicit JSON-RPC
error is written. Use `ServerRequestReply.into_resolution()` and pass the result
to `AppServerClient::resolve_server_request` with the original epoch-qualified
key.

`default_resolution` intentionally handles only non-consent policy: it answers
current-time reads, fails undeclared dynamic tools, and returns configuration
errors for unavailable token-refresh or attestation providers. Approvals,
questions, permission grants, MCP elicitation, and legacy approvals remain
pending until the host makes an explicit decision.

Approval policies include `untrusted`, `onRequest`, and `never`, plus the
structured `AskForApproval.granular` form for independently controlling MCP
elicitation, rules, sandbox approval, permission requests, and skill approval.
The obsolete `on-failure` wire value is not accepted.

Handlers return `.result(CodexJSONValue)`, so validated results are encoded at the boundary. GA legacy denials carry a rejection reason:

```swift
let denial = CodexValidatedServerRequestResult.legacyExecCommandApproval(
    .denied(rejection: "Rejected by the user.")
)
return .result(denial.jsonValue)
```

The default `.pending` policy keeps approvals, questions, permissions, MCP elicitation, and legacy approvals in the inbox. It answers current-time requests, fails unhandled dynamic tools with `success: false`, returns configuration errors for token/attestation requests, and rejects unknown methods.
