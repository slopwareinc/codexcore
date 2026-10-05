# Runtime features

The reference app targets the pinned Codex `0.160.0` app-server. Open
**Settings → Runtime features** for account, workspace, and host controls.
Availability follows the connected provider and server capabilities. Failed
operations retain their error instead of implying success.

| Page | Workflow |
| --- | --- |
| Account | Gateway OAuth readiness/sign-in/cancel, provider capabilities, Bedrock discovery/setup/login, usage, workspace messages, reset-credit inventory/redemption, credit-owner email, and native user verification. |
| Voice | Read the voice catalog, select voice/model, choose audio or text output, and append spoken text to an active session. |
| Chat | Open resource, memory, goal, history, settings, queued-message, search, and Guardian review controls. |
| Projects | Read paginated projects; create, update folders/metadata, import, reorder, and explicitly delete server projects. |
| Files | Browse/read runtime files, edit bounded UTF-8 text, copy/remove/create folders, watch a folder, and run cancellable file searches. |
| Processes | Spawn an argument-vector process, use a sandboxed command session or the selected chat's shell, inspect bounded output, send stdin, resize a PTY, and stop the operation. |
| Imports | Detect/import supported external agent sessions and inspect receipts/history, including completions received before the import response. |
| Experiments | Browse features, change their resolved configuration, and request rollout compression for the selected chat. |
| Remote control | Explicitly enable ephemeral or persistent access, reveal an expiring pairing code, inspect paginated clients, revoke a client, and disable access. A compatible remote client is required. |
| Environments | Add an executor connection, read status, and explicitly request environment info/recovery. Credentials are not persisted in view state. |
| Feedback | Review category, note, selected files/tags, and log consent before submitting once. |

The chat inspector also opens from **Find occurrences** in global search. It
loads the matching history page and focuses the exact turn/item, expanding its
activity ancestors when needed. Timeline/history reads are paginated. Reverting
a turn replaces conversation history; it does not revert workspace files.

Chat settings edit server model, reasoning, service tier, project, instructions,
plugins, and thread defaults. Composer model/reasoning/tier changes during a
running turn use `turn/settings/update`, serialize concurrent changes, and
report unavailable targets. Delayed updates never target a replacement turn.
Queue controls send the complete authoritative ordering and support explicitly
starting a queued item.

Native MCP verification prompts are explicit user approvals. The app passes
their challenge to a native verification operation and returns its proof to
that exact pending request. Closing the prompt cancels the original operation;
late proofs are discarded. Ordinary MCP forms and URL elicitation retain their
existing input flow.

Device-code sign-in retains its identified login. **Cancel login** cancels that
exact attempt and clears its code after the terminal fact. Failure/expiration
clears obsolete codes and displays the error. Late completions from earlier
attempts cannot finish a replacement sign-in.

Model verification, provider sign-in recovery, safety buffering, moderation,
and runtime diagnostics appear in the conversation's notice area, scoped to
the selected chat/turn. These facts use canonical-state and diagnostic
observation instead of polling.

## MCP apps

Tool results can carry persistent app descriptors. The transcript renders their
inline widgets and supports fullscreen; older history can recover widgets from
the runtime tool catalog. Resource reads and app tool calls retain the original
server, connector, account target, and thread. An explicitly unauthenticated
target remains `linkId: null`.

Each widget uses an isolated WebKit host and the MCP Apps bridge. The bridge
checks declared capabilities and resource policy for tools, external links,
host messages, and model-context updates. App messages require confirmation.
Context is bounded, labeled as untrusted application data, and attached to
subsequent input in its owning chat. Account/connection changes invalidate
widget hosts and clear that context.

## Lifecycle and compatibility

Chat/account/provider/connection changes invalidate pending feature work.
Watch/search/process cleanup targets the provider that accepted the operation,
including late start acknowledgments. Import observers are registered before
import begins and retain early completions.

Side conversations fork ephemerally, defer inherited goal continuation, clear
the child's goal, and inject an instruction boundary before the first new turn.
Parent history remains reference context. Public SDK hosts can use lease-scoped
item injection and balanced external-elicitation helpers; see
[approvals and input](../sdk/approvals-and-input.md).

The accepted older runtime range supports the existing core lifecycle. New
`0.160.0` workflows require a runtime implementing their methods. The
[protocol coverage ledger](../reference/app-server-feature-coverage.md) records
each generated method, notification, and server-request owner, including
platform and external-host extension boundaries.
