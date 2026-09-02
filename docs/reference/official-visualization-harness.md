# Official visualization harness audit

This is point-in-time engineering evidence from the installed ChatGPT/Codex
bundle, not a public API contract. The audit used `com.openai.codex`
26.825.32147 (build 7303), whose ASAR SHA-256 is
`0462b03e878f0e78b223b849ee14cbba0de043f2c16acebee163cb95daa622ef`.

## Content creation and directive

The bundled visualization skill directs the model to create a lowercase,
hyphenated HTML fragment in a host-supplied writable root, preferably the
thread-scoped visualization directory. It then emits:

```text
visualize{"path":"/absolute/thread/root/render-probe.html"}
```

The renderer converts that reference to its internal `codex-inline-vis`
directive. It accepts optional title and wide-mode metadata, rejects traversal,
quotes/newlines, unsafe basenames, and non-HTML names, and resolves the source
through the host's file map. The fragment cap is 5,000,000 bytes. A source
thread ID may differ from the visible thread, which enables cross-thread frames
without discarding provenance.

Relevant bundle evidence:

- `webview/assets/app-initial-DJrCTPoN.js`, SHA-256
  `27618295c2da9ccf6959e93427e34b75a6d1b4ccd7d4a9f6a18a3974b61803e5`:
  directive parsing, validation, source mapping, fragment cap, inline/live
  variants, download bridge, and external-link confirmation.
- `webview/assets/visualization-directive-renderer-BBxukGCZ.js`, SHA-256
  `3321fbfb9cd9eb63d6f7088b4b956bfccd3f09c8459113bb8426f4e46c48e872`:
  dedicated lazy renderer boundary.
- `webview/assets/visualization-thread-frames-Dhe3c_Qv.js`, SHA-256
  `8a2aa606952643937810a166951854037d622395ecd7f8eddd875410a898e40d`:
  stable frame anchors, active-thread routing, retry boundary, cross-thread
  resume, and retained sandbox ownership.

## Frame lifecycle

The official renderer gives a visualization a stable sandbox/frame identity and
mounts that frame into a lightweight transcript anchor. Inline frames can be
reattached when their anchor changes. Live fragments include a content hash in
their render identity. A frame is active only when its thread/surface is active
and it has a mounted anchor. Detached frames are removed from the retained frame
store; their associated sandbox state is cleaned asynchronously. The initial
inline height is 240 points and subsequent intrinsic height is cached.

Downloads are not granted directly to untrusted content. The sandbox bridge
accepts a single user-activated `blob:` or `data:` download and forwards it to a
host capability. External links require a host confirmation dialog.

## Live control run

The control fragment for this audit was written to the writable root supplied
to this task:

`~/.codex/visualizations/2026/08/28/01a049ce-1f35-7632-9b35-b2bb2fbe9de1/codex-home-visualization-path-test.html`

The official wrapper produced an iframe with an accessible slider and
progressbar. Updating the slider from 50 to 83 changed the progress value and
the polite live status to `Interactive update rendered at 83%.` No network or
file access was required.

CodexCore's reference runtime defaults to `~/.codexcore`, while this official
desktop control run supplied a `~/.codex/visualizations/...` root. The output
location is therefore a host-owned writable capability rather than something a
renderer should infer from a global default. CodexCore's reference app chooses
`<codexHome>/visualizations` explicitly and embedders may provide other roots
explicitly; a directive alone never grants path access.
