# Subagents: dual-mode handling + Subagents panel

> **Historical engineering note:** Capture-derived implementation research, not current public product documentation. Verify behavior against production source and tests.

Ground truth: wire + CDP captures of the official app (ChatGPT.app v0.144,
2026-07-11) — fixtures `turn-collab-official.jsonl` (classic) and
`turn-subagents-ultra.jsonl` (ultra) — plus `openai/codex` source
(`multi_agents_v2`). The client contract below is NOT in the official
app-server docs; it was observed on the wire.

## Two orchestration modes

### Classic collab (message-passing, thread-id addressed)

The parent transcript tells the whole story via `collabAgentToolCall` items:

| tool | started | completed |
|---|---|---|
| `spawnAgent` | `prompt` (full instructions), `receiverThreadIds: []` | `receiverThreadIds: [childId]`, `model` (e.g. `gpt-5.6-luna`), `agentsStates{id: {status: pendingInit}}` |
| `sendInput` | `prompt` = the message, target in `receiverThreadIds` | `agentsStates{id: {status, message: <agent reply>}}` |
| `wait` | `receiverThreadIds` = awaited ids | narrows to ids that returned; `agentsStates{id: {status, message: <final reply>}}` |
| `closeAgent` | (from July capture) closes agents | — |

Child threads stream interleaved **on the same connection**; the main
transcript filters them by `threadId` (already implemented).

Official row grammar (PR #117): "Created agent-{shortId} with the
instructions: {prompt}", upgrading to "Created {nickname} ({role}) …" once
known. Summary lines "Created an agent" / "Created N agents". Waits render
under "Working" with "Waited for …" rows; agent replies expandable.

### Ultra (fork-based agent tree, path-addressed)

Model-side: `spawn_agent {task_name, fork_turns, message, [model,
reasoning_effort, service_tier, agent_type]}`. `fork_turns: "all"` forks the
parent's full history (and then model/effort/agent_type overrides are
REJECTED — child inherits the parent's model); `"none"`/turn-count allows
overrides. `agent_type` = predefined role (e.g. `explorer`) with its own
model config, taking precedence.

Wire: the parent transcript gets only a marker —
`subAgentActivity {kind: started|interacted|interrupted, agentThreadId,
agentPath}` — where `agentPath` is hierarchical (`/root/count_docs`,
children of children: `/root/task1/task_3`). `wait` is still a
`collabAgentToolCall`. No prompt appears on the wire (the task message is
encrypted at rest in rollouts).

## Client contract on discovering an agent (both modes)

For each new agent thread id (from `receiverThreadIds` or `agentThreadId`):

1. `thread/read {threadId, includeTurns: false}` → `agentNickname`,
   `agent_role`, spawn source (`parent_thread_id`, `depth`, `agent_path`).
2. `thread/resume {threadId}` → subscribe; the child's full item stream
   (deltas included) then flows on the connection.
3. `thread/list {parentThreadId: threadId}` → discover grandchildren;
   recurse. The tree is arbitrary-depth by design.

## CodexCore implementation plan

### 1. `CodexSubagentStoreV2` (CodexCoreUI/TranscriptV2)

- Map `threadId → CodexTranscriptReducerV2` plus per-agent metadata
  (`agentPath`, `nickname`, `role`, `depth`, `parentThreadId`, live status).
- Fed from the SAME notification stream the main reducer consumes: events
  whose `threadId` is a known agent route to that agent's reducer; the main
  reducer keeps filtering them out of the main transcript.
- Discovery: `collabAgentToolCall.receiverThreadIds` + `subAgentActivity.
  agentThreadId` register agents (dedup). Host runtime performs the
  read/resume/list dance and feeds metadata back into the store.
- Pure value type + reducer, fixture-replayable like the transcript.

### 2. `CodexSubagentsPanelV2` (view)

- Sidebar-style section: header "Subagents" + count of working agents
  ("2 working").
- One card per agent (tree-ordered by `agentPath`, indent children):
  title = nickname if known, else humanized last path segment
  ("count_docs" → "Count docs"), role tag, its own live stopwatch
  ("Working for Ns" → "Worked for Xm Ys"), and the agent's transcript
  rendered with the existing `CodexTranscriptViewV2` (same grammar,
  smaller type scale). Live tail per agent.
- Zero new transcript rendering code — composition only.

### 3. Runtime session

- `CodexChatRuntimeSession` exposes `subagents: CodexSubagentStoreV2`,
  issues `thread/read`/`thread/resume`/`thread/list` on discovery,
  routes notifications by threadId (main reducer OR agent reducer).

### 4. Tests

- Replay `turn-subagents-ultra.jsonl`: main transcript shows the
  subAgentActivity work rows and wait; store ends with 2 agents
  (`/root/count_docs`, `/root/count_binaries`), each agent transcript has
  its own turns (commands/prose) and completes.
- Replay `turn-collab-official.jsonl`: store registers 2 agents from
  receiverThreadIds; main transcript unchanged from PR #117 assertions.

## Model selector (separate work item)

Official composer exposes a model × effort grid for the 5.6 family:
columns = models (GPT 5.6 Sol / Terra / Luna), rows = efforts (Light /
Medium / High / Extra High / Ultra), cell shading = price × effort
token-volume heuristic, one checkmark cell = current selection, footer
"Default (GPT 5.6 Sol · Medium) selected". Drive rows/columns from
`model/list` (models carry supported reasoning efforts); selection writes
thread settings (model + effort) for the next `turn/start`. Component:
`CodexModelSelectorGridV2`, host-embeddable (Walkable composer + workspace).
