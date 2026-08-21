# Runtime compatibility

| CodexCore release | Codex CLI / app-server | Status |
| --- | --- | --- |
| `0.11.0` | `>= 0.148.0` | Current supported range; types generated from stable `0.148.0` |
| `0.10.0` | `>= 0.147.0` | Historical release; types generated from stable `0.147.0` |
| `0.9.0` | `>= 0.145.0` | Historical release; types generated from `0.146.0-alpha.9.2` |
| `0.8.0` | `0.145.0` | Historical GA release |
| `0.7.0` | `0.145.0` | Historical GA release |
| `0.6.0` | `0.145.0-alpha.24` | Historical prerelease |
| `0.5.0` | `0.145.0-alpha.20` | Historical prerelease |

The composite release tag records both identities:

```text
v0.148.0+codexcore.0.11.0
```

CodexCore requires the generated major/minor line and accepts newer patch releases with a warning. A stable CLI release does not make every app-server feature stable: the SDK requests experimental capabilities during initialization.

The Rust ordered client enforces the same compatibility line from the runtime
version carried in the initialize `userAgent`; it fails the handshake before
starting its actor when the runtime is older or on a different major/minor
line.

## 0.148.0 migration

The stable 0.148.0 schema adds server diagnostics, six durable thread-queue methods, paginated `thread/revert`, queue/revert notifications, scoped account usage, thread cost estimates, section appearance, model multi-agent versioning and retirement time, MCP ownership and OAuth registration selection, asynchronous/MCP hook metadata, and structured image-generation failure detail.

`account/usage/read` now accepts omitted, null, or thread-scoped parameters. Hook metadata is now a heterogeneous command-or-MCP union and therefore remains lossless through the generated raw schema wrapper. On successful paginated revert—or a revert notification from another client—CodexCore evicts stale materialized transcript detail and retains the replacement history cursors for rehydration. Legacy `thread/rollback` behavior is unchanged.

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
