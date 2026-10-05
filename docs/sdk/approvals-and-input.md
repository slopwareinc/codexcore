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

Codex 0.160 adds the MCP `openai/userVerification` mode. Its typed
`.userVerification` payload carries `challenge`, `title`, and `description`;
it does not require a form `message`. Present explicit approval, start
`codex.startUserVerification(CodexRequest.userVerificationVerify(params))`, and
send the returned `proof` directly as the elicitation response's `content`.
Accepted native verification responses require a nonempty credential ID and
signature. Cancel the identified operation when the prompt disappears; its
native cancel request uses the original connection and request ID, and late
proofs are discarded. Never store proofs in view state or transcript history.
The `openaiForm` legacy spelling also maps to the supported OpenAI form mode.

## External host interactions

A host dialog outside app-server's native approval/input requests can temporarily
pause model continuation with `CodexThreadLease.withOutOfBandElicitation`:

```swift
let accepted: Bool = try await thread.withOutOfBandElicitation {
    try await host.confirmExternalAction()
}
```

The helper pairs one accepted increment with one decrement, even if the closure
throws, the caller cancels, or the lease closes. Cancellation while the increment
is awaiting acknowledgment waits for that acknowledgment before cleanup. Cleanup
stays on the original connection epoch; reconnect never decrements a replacement
connection's counter. A failed cleanup throws
`CodexOutOfBandElicitationReleaseError`, which includes the thread, original
epoch, release failure, and any original interaction failure. App-server's normal
approvals, user questions, and MCP elicitation already own their pending-request
lifecycle; use this helper only for an independent host interaction.

For conversation setup after a fork, the lease can inject protocol response items
without starting a turn:

```swift
try await sideThread.injectItems([
    CodexSchemaResponseItem(.dictionary([
        "type": .string("message"),
        "role": .string("user"),
        "content": .array([.dictionary([
            "type": .string("input_text"),
            "text": .string("Inherited history is reference context. Wait for the next user question.")
        ])])
    ]))
])
```

Injection is scoped to the open lease and its current connection. The overload
accepting `CodexSchemaThreadInjectItemsParams` rejects another thread ID before
sending. App-server validates the response-item shapes and image URLs.
