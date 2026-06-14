# Python SDK parity (`openai-codex`)

CodexCore is a **Swift** SDK. Its high-level client API is meant to track the official OpenAI Codex **Python SDK**:

| | |
|---|---|
| **PyPI package** | [`openai-codex`](https://pypi.org/project/openai-codex/) |
| **Import** | `from openai_codex import Codex, AsyncCodex, …` |
| **Docs** | [developers.openai.com/codex/sdk](https://developers.openai.com/codex/sdk) |
| **API reference** | [openai/codex `sdk/python/docs/api-reference.md`](https://github.com/openai/codex/blob/main/sdk/python/docs/api-reference.md) |
| **Source** | [openai/codex `sdk/python/src/openai_codex/`](https://github.com/openai/codex/tree/main/sdk/python/src/openai_codex) |

This is **not** the general [`openai`](https://pypi.org/project/openai/) Chat Completions client. It is also **not** the unofficial third-party `openai-codex-sdk` package on PyPI.

---

## Version pins (check these when comparing)

| Artifact | Current pin (as of doc write) |
|----------|-------------------------------|
| CodexCore runtime | `Tools/UPSTREAM_VERSION` → `codex-cli 0.139.0` |
| Published Python SDK | `openai-codex` **0.1.0b3** (public beta) |
| Python SDK bundled runtime | `openai-codex-cli-bin` **0.137.0a4** |

Swift regenerates wire types from a local `codex` binary; the published Python wheel ships its own pinned CLI. Expect minor skew until versions align.

To inspect the real public surface locally:

```bash
python3 -m venv /tmp/openai-codex-inspect
source /tmp/openai-codex-inspect/bin/activate
pip install openai-codex
python -c "import openai_codex; print(openai_codex.__version__); print(openai_codex.__all__)"
```

---

## What prior reviews checked

Architecture and code-quality reviews in this repo looked at **Swift** structure (store, projection, example app). They did **not** diff CodexCore against the installed `openai_codex` package or its published API reference.

Parity is enforced today by Swift unit tests named `*PythonSDK*` plus hand-maintained wrappers—not by an automated cross-language diff.

---

## Public API map (official Python → Swift)

The **public beta** surface of `openai_codex` is intentionally small. CodexCore mirrors it at the `Codex` / `CodexThread` / `CodexTurnHandle` layer.

### `Codex` ↔ `Codex` (`Sources/CodexCore/Client/Codex.swift`)

| Python (`openai_codex.Codex`) | Swift |
|-------------------------------|-------|
| `with Codex() as codex:` | `let codex = try await Codex(...)` then `await codex.close()` |
| `metadata` | `metadata` (`InitializeResponse`) |
| `close()` | `close()` |
| `login_api_key(api_key)` | `loginAPIKey(_:)` |
| `login_chatgpt()` → `ChatgptLoginHandle` | `loginChatGPT(...)` → `ChatGPTLoginHandle` |
| `login_chatgpt_device_code()` → `DeviceCodeLoginHandle` | `loginChatGPTDeviceCode()` → `DeviceCodeLoginHandle` |
| `account(refresh_token=…)` | `account(refreshToken:)` |
| `logout()` | `logout()` |
| `thread_start(...)` → `Thread` | `threadStart(...)` → `CodexThread` |
| `thread_list(...)` | `threadList(...)` |
| `thread_resume(thread_id, …)` | `threadResume(_:…)` |
| `thread_fork(thread_id, …)` | `threadFork(_:…)` |
| `thread_archive(thread_id)` | `threadArchive(_:)` |
| `thread_unarchive(thread_id)` → `Thread` | `threadUnarchive(_:)` → `CodexThread` |
| `models(include_hidden=…)` | `models(includeHidden:)` |

**`CodexConfig`**

| Python | Swift |
|--------|-------|
| `codex_bin` | `codexBinaryPath` |
| `launch_args_override` | `launchArgumentsOverride` |
| `config_overrides` | `configOverrides` |
| `cwd` | `cwd` |
| `env` | `environment` |
| `client_name` / `client_title` / `client_version` | same |
| `experimental_api` | `experimentalAPI` |

Swift adds `approvalPolicy` (`.autoApprove` / `.ask`) for interactive approval UX—**not** in public Python `CodexConfig`.

### `Thread` ↔ `CodexThread`

| Python | Swift |
|--------|-------|
| `thread.id` | `thread.id` |
| `thread.run(input, …)` → `TurnResult` | `thread.run(_:timeout:…)` → `CodexTurnResult` |
| `thread.turn(input, …)` → `TurnHandle` | `thread.turn(_:…)` / `turn([CodexInput], …)` → `CodexTurnHandle` |
| `thread.read(include_turns=…)` | `thread.read(includeTurns:)` |
| `thread.set_name(name)` | `thread.setName(_:)` |
| `thread.compact()` | `thread.compact()` |

### `TurnHandle` ↔ `CodexTurnHandle`

| Python | Swift |
|--------|-------|
| `turn.id` | `handle.id` |
| `turn.thread_id` | `handle.threadId` |
| `turn.steer(input)` | `handle.steer(_:)` / `steer([CodexInput])` |
| `turn.interrupt()` | `handle.interrupt()` |
| `turn.stream()` → `Iterator[Notification]` | `handle.stream()` → `AsyncStream<CodexNotification>` |
| `turn.run()` → `TurnResult` | `handle.run(timeout:)` → `CodexTurnResult` |

Swift extras on the handle (not in public Python API): `textDeltas()`, `snapshots()`.

### `TurnResult` ↔ `CodexTurnResult`

| Python field | Swift field | Notes |
|--------------|-------------|-------|
| `id` | `id` | |
| `status` | `status` (`CodexTurnStatus`) | |
| `error` | `error` | Python uses `TurnError`; Swift uses `String?` |
| `started_at` | `startedAt` | Python: epoch ms `int`; Swift: `Date` |
| `completed_at` | `completedAt` | same |
| `duration_ms` | `duration` | Swift: `TimeInterval` seconds |
| `final_response` | `finalResponse` | |
| `items` | `items` | Python: `list[ThreadItem]`; Swift: `[CodexTimelineItem]` |
| `usage` | `usage` | |

### Login handles

| Python | Swift |
|--------|-------|
| `ChatgptLoginHandle.wait()` | `ChatGPTLoginHandle.wait()` |
| `ChatgptLoginHandle.cancel()` | `ChatGPTLoginHandle.cancel()` |
| (no public `stream()` in api-reference) | `ChatGPTLoginHandle.stream()` / `loginNotifications(loginId:)` |

Device-code handles mirror the same pattern (`verification_url` / `user_code` ↔ `verificationUrl` / `userCode`).

### Inputs (`openai_codex` root exports)

| Python | Swift (`Generated/V2Types.swift`) |
|--------|-----------------------------------|
| `TextInput(text=…)` | `CodexInput.text(_:)` |
| `ImageInput(url=…)` | wire via `CodexInput` / `CodexWireInputItem.raw` |
| `LocalImageInput(path=…)` | same |
| `SkillInput(name=…, path=…)` | same |
| `MentionInput(name=…, path=…)` | same |
| `RunInput = str \| Input` | `String` or `[CodexInput]` accepted on `turn` / `run` |

Wire-shape tests: `Tests/CodexCoreTests/V2TypeTests.swift` (`test*MatchesPythonSDK`).

### Enums

| Python | Swift |
|--------|-------|
| `ApprovalMode` | `ApprovalMode` |
| `Sandbox.read_only` / `.workspace_write` / `.full_access` | `Sandbox.readOnly` / `.workspaceWrite` / `.fullAccess` |

### Retry + errors

| Python | Swift |
|--------|-------|
| `retry_on_overload(...)` | `requestWithRetryOnOverload` in `AppServerRequests.swift` |
| `is_retryable_error(exc)` | overload retry logic in same module |
| `JsonRpcError`, `ServerBusyError`, … | JSON-RPC error mapping test in `CodexClientTerminalTests` |

Public Python types live in `openai_codex.types`; Swift protocol models live in `Generated/AppServerSchemaTypes.swift` and thin wrappers in `Protocol/`.

---

## Swift extensions beyond the public Python SDK

CodexCore exposes more than `openai_codex.__all__` for app-server power users and the example app. These are **not** part of the official Python public beta API reference:

| Swift-only (or extra) | Purpose |
|-----------------------|---------|
| `loginChatGPTAuthTokens(...)` | Token-based ChatGPT login |
| `threadGoalSet` / `goal` / `clearGoal` / `setGoal` / `updateGoal` | Thread goal RPCs |
| `threadSearchRaw`, `threadListRaw` | Loose JSON list/search |
| `skillsListRaw`, `pluginListRaw`, `mcpServerStatusListRaw`, … | Example-app integrations |
| `fuzzyFileSearch` | @-mention file search |
| `execCommand`, `startCommandSession` | Host command/PTY helpers |
| `rawRequest(method:params:)` | Arbitrary client RPC |
| `CodexClient` actor | Low-level typed wire client (Python keeps this internal as `openai_codex.client.CodexClient`) |
| `notifications()` | Global notification stream |
| `respondToApproval` / `respondToUserInput` | Interactive server requests |
| `CodexCoreStore` + reducer | Local timeline state (Python SDK does not ship an equivalent store) |
| `CodexCoreUI` | SwiftUI; N/A for Python |

When adding Swift API, prefer matching a **public** Python name/signature first; mark deliberate extensions in this table.

---

## Wire / generated protocol (both SDKs)

Both SDKs talk JSON-RPC to `codex app-server`. Full method inventory is generated from the CLI schema:

| | Python | Swift |
|---|--------|-------|
| Client methods | internal + generated models in `openai_codex.generated` | `CodexAppServerClientMethod` (114) in `Generated/AppServerProtocolMethods.swift` |
| Regenerate | upstream `openai/codex` Python tooling | `Tools/regenerate.sh` + `Tools/check_drift.sh` |
| Router | `openai_codex._message_router.MessageRouter` | `CodexNotificationRouter` (turn/login replay buffer) |

Swift test `testEveryGeneratedClientMethodCanBeSentByEnumRequest` proves every generated client method is reachable; that is **wire** coverage, not proof that each method has a public Python wrapper.

---

## Parity tests in this repo

```bash
swift test --filter PythonSDK
swift test --filter V2TypeTests
swift test --filter AppServerProtocolMethodTests
```

| Test | Locks |
|------|-------|
| `V2TypeTests.test*MatchesPythonSDK` | Input / ApprovalMode / Sandbox wire JSON |
| `CodexClientTerminalTests.testJSONRPCErrorMappingMatchesPythonSDK` | RPC error codes |
| `CodexClientTerminalTests.testDefaultCodexHomeMatchesPythonSDKHelper` | `defaultCodexHome()` |
| `CodexClientTerminalTests.testTypedClientMethodsUsePythonSDKWireMethods` | `CodexClient` → wire method names |
| `CodexClientTerminalTests.testHighLevelCodexThreadMethodsUseTypedPythonParitySurface` | `Codex` facade + several `*Raw` calls |
| `CodexClientTerminalTests.testHighLevelLoginHandlesMatchPythonSDKSurface` | Login handle behavior |

**Gap:** there is no CI job that imports `openai_codex` and diffs method signatures against Swift. Adding one (or a checked-in manifest generated from both sides) would close the loop the user expects.

---

## Maintenance checklist

1. Install/reference the same generation of [`openai-codex`](https://pypi.org/project/openai-codex/) you intend to match.
2. Read [api-reference.md](https://github.com/openai/codex/blob/main/sdk/python/docs/api-reference.md) for **public** API changes.
3. Update Swift wrappers in `Codex.swift` / `Client.swift` / `V2Types.swift`.
4. Extend `*MatchesPythonSDK` tests.
5. Run `Tools/regenerate.sh` when the pinned `codex` CLI schema changes; run `Tools/check_drift.sh` before landing.

For UI feature parity (example app vs Codex.app), see `CODEX_APP_FEATURE_INVENTORY.md`—that document is unrelated to the Python SDK public surface.
