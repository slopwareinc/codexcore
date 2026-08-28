# Workspace-panel oracle

This is a read-only measurement lab for issue [#231](https://github.com/slopwareinc/codexcore/issues/231). It captures two kinds of evidence before the workspace-tab architecture changes in [#230](https://github.com/slopwareinc/codexcore/issues/230):

1. `workspace_panel_oracle.py` reads `Info.plist` and the Electron `app.asar` header from the installed official bundle. It never imports or executes official renderer code. The inventory records bundle version, ASAR/runtime hashes, hashed asset paths, module sizes, and the surface family inferred from each filename.
2. `CodexWorkspacePanelPerformanceTests` exercises existing CodexCore interfaces and writes raw samples, p50/p95/mean/max statistics, workload sizes, retained-memory observations, and `os_signpost` names to JSON.

Run the complete oracle from the repository root:

```sh
Tools/WorkspacePanelOracle/run.sh \
  --bundle /Applications/ChatGPT.app \
  --output /tmp/codexcore-workspace-panel-oracle \
  --configuration debug
```

The default output directory is `${TMPDIR}/codexcore-workspace-panel-oracle`. Use `--skip-performance` when only the official bundle inventory is needed. `CODEX_OFFICIAL_BUNDLE`, `CODEX_WORKSPACE_ORACLE_OUTPUT`, `CODEX_PERF_CONFIGURATION`, `CODEX_PANEL_PERF_ITERATIONS`, and `CODEX_ORACLE_CAPTURED_AT` provide equivalent environment overrides.

## Measurements

The performance report contains five scenarios:

- `tab_activation`: state-level selection across terminal, browser, files, and file-preview tabs.
- `panel_open_close`: four open/close mutations of the agent-panel state, isolating the state seam from native surface construction.
- `transcript_streaming_with_heavy_panels`: append-only projection of a 217-turn/1,085-item transcript while terminal, browser, and files sessions remain retained.
- `hidden_surface_layout`: relayout while switching one selected surface in a three-surface deck. The current implementation uses opacity, hit testing, and accessibility hiding; the other two surfaces remain mounted. The report records process RSS before/after mount and the retained hidden-surface count. RSS excludes WebKit helper processes and is directional rather than an allocation guarantee.
- `twenty_chat_lru`: current `CodexWorkspacePanelStore` capacity-20 behavior, including a touched-chat retention check and deferred eviction purge.

Each measured operation is wrapped in an `OSLog` signpost under subsystem `com.slopware.CodexCore` and category `WorkspacePanelOracle`. Attach Instruments to the test process and select those signposts when a timeline or CPU allocation trace is useful. The test deliberately does not add signposts to production Swift.

The committed inventory and baseline are point-in-time evidence. Rerun the command after an official bundle update or before a later workspace-tab slice; compare the machine-readable `surfaceID`, `assetPath`, workload, and statistics fields rather than assuming hashed asset names are stable forever.

## Verification

```sh
python3 -m unittest discover Tools/tests
swift test --filter CodexWorkspacePanelPerformanceTests
```

The test is interface-level: it uses `CodexWorkspacePanelState`, `CodexWorkspacePanelStore`, `CodexMountedWorkspaceToolSessions`, `CodexAgentSidePanel`, and `CodexTranscriptRenderProjector`. No production behavior or generated protocol file is changed by this oracle.
