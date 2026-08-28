# Workspace tab and panel oracle

Issue [#231](https://github.com/slopwareinc/codexcore/issues/231) captures the installed official bundle and the CodexCore workspace-panel baseline before the #230 tab architecture work. The committed artifacts are:

- [`official-workspace-panel-inventory.json`](official-workspace-panel-inventory.json) — 150 hashed JavaScript/CSS renderer assets grouped into 27 surface families, with bundle/runtime provenance.
- [`workspace-panel-performance-baseline.json`](workspace-panel-performance-baseline.json) — raw samples and summary statistics from the current main-branch interfaces.

## Official bundle provenance

The inventory was captured on 2026-08-28 at `8d3999d659d558e4b444d43a0d42109cab4c6538` from `/Applications/ChatGPT.app`:

- Bundle `com.openai.codex`, version `26.825.32147` (build `7303`)
- `Contents/Resources/app.asar` SHA-256: `0462b03e878f0e78b223b849ee14cbba0de043f2c16acebee163cb95daa622ef`
- bundled `Contents/Resources/codex` SHA-256: `67ea03c98e7726eeebd161bc3bc92d8937f412f1899790a28e4ee9b80803c4d7`

The scanner reads only `Info.plist` and the ASAR header/random-access file bytes. It does not import or execute the official renderer. Surface families are filename evidence, not claims about private route APIs; hashed filenames can change after an official update.

## CodexCore baseline

The performance test ran in Debug on macOS 27.0 (8 logical processors, 16 GiB) with a 30-sample scale. Values are milliseconds; p95 is the nearest-rank sample.

| Scenario | Workload | Mean | p95 | Max |
| --- | ---: | ---: | ---: | ---: |
| Tab activation | 4 tabs | 0.0018 | 0.0061 | 0.0161 |
| Panel open/close | 4 toggles | 0.0028 | 0.0070 | 0.0091 |
| Transcript streaming with heavy panels | 1,085 items; 3 retained surfaces | 37.7818 | 46.0585 | 75.5860 |
| Hidden-surface layout | 3 mounted / 2 hidden surfaces | 3.9801 | 5.5330 | 5.9013 |
| 20-chat LRU | 21 chats; capacity 20 | 0.0063 | 0.0112 | 0.0133 |

The streaming workload appends one final-answer delta per frame while terminal, browser, and files sessions remain retained. The hidden-surface workload relayouts the current `CodexAgentSidePanel` deck while changing selection; opacity, hit testing, and accessibility hiding leave the other two surfaces mounted. Process RSS rose from 108,707,840 to 109,576,192 bytes in this run, while two hidden sessions remained retained. RSS excludes WebKit helper processes and is directional evidence, not an allocation guarantee.

The LRU check touches chat 0, inserts chat 20, and verifies that chat 1 is purged on the next MainActor tick. The result is 20 retained chats, one eviction, and restoration of the touched chat.

## Re-run

```sh
Tools/WorkspacePanelOracle/run.sh \
  --bundle /Applications/ChatGPT.app \
  --output /tmp/codexcore-workspace-panel-oracle \
  --configuration debug
```

Use `--skip-performance` for inventory-only evidence. The test wraps each operation in `OSLog` signposts (`com.slopware.CodexCore` / `WorkspacePanelOracle`) without adding production hooks. Attach Instruments to the test process when a CPU or allocation timeline is needed.

```sh
python3 -m unittest discover Tools/tests
swift test --filter CodexWorkspacePanelPerformanceTests
```
