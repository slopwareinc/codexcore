# Runtime compatibility

| CodexCore release | Codex CLI / app-server | Status |
| --- | --- | --- |
| `0.10.0` | `>= 0.147.0` | Current supported range; types generated from stable `0.147.0` |
| `0.9.0` | `>= 0.145.0` | Historical release; types generated from `0.146.0-alpha.9.2` |
| `0.8.0` | `0.145.0` | Historical GA release |
| `0.7.0` | `0.145.0` | Historical GA release |
| `0.6.0` | `0.145.0-alpha.24` | Historical prerelease |
| `0.5.0` | `0.145.0-alpha.20` | Historical prerelease |

The composite release tag records both identities:

```text
v0.147.0+codexcore.0.10.0
```

CodexCore requires the generated major/minor line and accepts newer patch releases with a warning. A stable CLI release does not make every app-server feature stable: the SDK requests experimental capabilities during initialization.

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
