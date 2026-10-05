# Runtime compatibility

| CodexCore release | Codex CLI / app-server | Status |
| --- | --- | --- |
| `0.14.0` (development) | `0.148.x`–`0.160.x` | Current accepted range; types generated from stable `0.160.0` |
| `0.13.0` | `0.148.x`–`0.150.x` | Historical baseline; types generated from stable `0.150.1` |
| `0.12.0` | `>= 0.148.0` | Historical release; types generated from stable `0.149.0` |
| `0.11.0` | `>= 0.148.0` | Historical release; types generated from stable `0.148.0` |
| `0.10.0` | `>= 0.147.0` | Historical release; types generated from stable `0.147.0` |
| `0.9.0` | `>= 0.145.0` | Historical release; types generated from `0.146.0-alpha.9.2` |
| `0.8.0` | `0.145.0` | Historical GA release |
| `0.7.0` | `0.145.0` | Historical GA release |
| `0.6.0` | `0.145.0-alpha.24` | Historical prerelease |
| `0.5.0` | `0.145.0-alpha.20` | Historical prerelease |

The composite release tag records both identities:

```text
v0.160.0+codexcore.0.14.0 (planned; not published)
```

CodexCore accepts the configured minimum through the generated minor line, within the same major version. Any accepted version differing from the exact generated pin produces a warning; newer minor lines require a schema audit and regeneration. A stable CLI release does not make every app-server feature stable: the SDK requests experimental capabilities during initialization.

## 0.160.0 migration

Compared with 0.150.1, the protocol adds 15 client methods and removes
`thread/rollback`, for 167 client methods, 83 notifications, and 11 server-request
families. New factories cover user verification, thread attachments, memory
status, rollout compression, plugin reconciliation, live-turn settings, and
gateway OAuth. They expose protocol capability; dedicated UI workflows are not
implied.

Handwritten adapters retain attachment invalidation facts in thread metadata,
gateway OAuth changes in account extensions, and provider auth recovery facts
in turn extensions. Attachment notifications contain identities only; hosts
must fetch `thread/attachment/list` to refresh payloads. History item pages now
preserve producer start/completion timestamps. Item cursors accept an opaque
string or an item anchor through `CodexSchemaThreadItemsListCursor`.

`account/rateLimits/read` now accepts omitted, null, or feature parameters.
`turn/settings/update.serviceTier` preserves three wire states: omission leaves
the tier unchanged, null clears it, and a value replaces it. The live-turn
response can report `targetUnavailable`; callers must inspect that result.
Turn and thread leases expose validated settings updates and durable attachment
operations; see [threads and turns](../sdk/threads-and-turns.md).
Use `thread/revert` for paginated history replacement. It does not revert files;
legacy rollback is no longer advertised by this generated SDK.

The runtime floor remains 0.148.0 for the existing lifecycle. New factories and
notifications require the runtime version that introduced them; 0.160.0 is the
verified target for this migration. No new required fields were introduced in
shared schema definitions compared with 0.150.1. The accepted version range is
not a claim that every new feature exists on older runtimes.

The reference app uses the complete generated feature stack and requires the
`0.160.x` runtime line. An older SDK-compatible runtime gets an explicit upgrade
message before gateway probing or feature initialization. SDK hosts can still
use the older core lifecycle floor and negotiate their own feature availability.

## 0.150.1 migration

The stable 0.150 schema adds thread timeline reads, MCP event-stream start and
stop requests, MCP connection state, item-scoped realtime lifecycle and
transcript notifications, interrupt hooks, command-approval kind metadata,
Bedrock access-key login, additional collaboration controls, and expanded
browser/computer-use configuration requirements. CodexCore routes the new
realtime notifications through `CodexRealtimeEvent` and exposes
connection-scoped MCP event notifications for clients that opt into the new
subscription methods.

The minimum accepted runtime remains 0.148.0 because the core thread lifecycle
does not require the new methods. Applications using timeline reads, MCP event
streams, or the new realtime item events must run against 0.150.1 or newer.

## 0.149.0 migration

The stable 0.149.0 schema adds seven project-management methods, Bedrock
discovery and setup requests, project and thread-project change notifications,
and a strict auto-approval review notification. CodexCore preserves project
membership in canonical thread metadata and records strict-review requirements
on the affected turn.

The minimum accepted runtime remains 0.148.0 because the existing SDK lifecycle
does not require the new project or Bedrock methods. Applications using those
generated request factories must run against 0.149.0 or newer.

## 0.148.0 migration

The stable 0.148.0 schema adds server diagnostics, six durable thread-queue methods, paginated `thread/revert`, queue/revert notifications, scoped account usage, thread cost estimates, section appearance, model multi-agent versioning and retirement time, MCP ownership and OAuth registration selection, asynchronous/MCP hook metadata, and structured image-generation failure detail.

`account/usage/read` now accepts omitted, null, or thread-scoped parameters. Hook metadata is a heterogeneous command-or-MCP union and remains lossless through the generated raw schema wrapper; image-generation failures are generated as a typed, future-compatible union. On successful paginated revert—or a revert notification from another client—CodexCore evicts stale materialized transcript detail and retains the replacement history cursors for rehydration. Legacy `thread/rollback` behavior is unchanged.

## 0.147.0 migration

The stable 0.147.0 schema adds six client methods: paginated plugin search plus thread-section list, create, update, delete, and move. Thread list/read payloads now carry section identity and ordering instead of the removed `isPinned` fields. Plugin summaries add installation time, eligible plans, and an authoritative disabled reason.

CodexCore also preserves the new model specialty, MCP read-only tool-call hint, image transparency flag, account onboarding hint, initialization extension profile, external-agent connector candidates, and import-history detail. The generated MCP surface includes the runtime's 2026-07-28 negotiation and paginated status inventory; existing pagination guards remain in the handwritten integration layer.

At runtime, 0.147.0 supports full reads and forks for paginated threads, so CodexCore removes its old client-side fork rejection and retains a caller-requested initial turns page during resume. Paginated rollback remains unsupported upstream.

## Upgrade rule

Every runtime change requires:

1. source/schema comparison;
2. generated binding regeneration;
3. handwritten server-request audit;
4. drift, generator, build, and full test verification;
5. compatibility notes and a composite release tag.
