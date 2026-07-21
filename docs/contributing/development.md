# Development

## Repository map

```text
Sources/CodexCore/       SDK, protocol, session, state
Sources/CodexCoreUI/     reusable SwiftUI/AppKit presentation
Sources/CodexCoreApp/    full reference host
Sources/CodexRun/        trusted development demo
Tests/                   SDK and UI tests
Tools/                   protocol generators and drift checks
docs/                    stable guides plus internal research
```

Prerequisites are macOS 26+, Swift 6.2/Xcode, Git, Python 3, Bash, and the exact runtime. Generator downloads also use `curl` and `tar`; `just` is optional. The first Swift build downloads sizeable UI/parser dependencies. Xcode Instruments and at least 10 GiB free space are required only for tracing.

## Commands

```bash
swift build --target CodexCoreApp
swift test
just run
just run-app
python3 -m unittest discover Tools/tests
git diff --check
```

There is currently no repository CI; contributors must run the relevant validation locally. `Tools/check_drift.sh` without `CODEX_BINARY` downloads the pinned GA runtime and therefore needs network access; set `CODEX_BINARY=/absolute/path/to/codex` for a local binary.

SDK/session/protocol tests belong in `Tests/CodexCoreTests`. Presentation and fixture tests belong in `Tests/CodexCoreUITests`.

## Performance work

Run the app against a representative long transcript before `just trace`. Preserve stable render identities, keep parsing off the scroll path, and verify with the existing performance harness and tests.

## Release

1. Complete the exact-runtime upgrade and local verification matrix.
2. Update `Tools/UPSTREAM_VERSION`, compatibility docs, and the CodexCore version.
3. Merge the issue-linked PR from a dedicated `codex/…` branch.
4. Tag the merge as `v<codex-cli>+codexcore.<version>` and publish release notes covering compatibility and limitations.
