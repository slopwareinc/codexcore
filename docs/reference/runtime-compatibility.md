# Runtime compatibility

| CodexCore release | Codex CLI / app-server | Status |
| --- | --- | --- |
| `0.9.0` | `>= 0.145.0` | Current supported range; types generated from `0.146.0-alpha.9.2` |
| `0.8.0` | `0.145.0` | Historical GA release |
| `0.7.0` | `0.145.0` | Historical GA release |
| `0.6.0` | `0.145.0-alpha.24` | Historical prerelease |
| `0.5.0` | `0.145.0-alpha.20` | Historical prerelease |

The composite release tag records both identities:

```text
v0.145.0+codexcore.0.9.0
```

CodexCore validates exact runtime equality. A GA CLI version does not make every app-server feature stable: the SDK requests experimental capabilities during initialization.

## Upgrade rule

Every runtime change requires:

1. source/schema comparison;
2. generated binding regeneration;
3. handwritten server-request audit;
4. drift, generator, build, and full test verification;
5. compatibility notes and a composite release tag.
