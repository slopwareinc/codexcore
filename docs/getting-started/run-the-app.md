# Run the reference app

The reference app demonstrates the SDK and reusable UI. It is not required by library consumers, and some visible routes are previews rather than wired workflows; see [support status](../reference/support-status.md).

![CodexCore workspace with model and reasoning controls](../assets/screenshots/composer-controls.png)

## Build and launch

```bash
git clone https://github.com/slopwareinc/codexcore.git
cd codexcore
codex --version  # verifies only the PATH candidate
swift build --target CodexCoreApp
swift run codex-core-app
```

With `just` installed:

```bash
just run
```

`just run` stops an existing development instance, rebuilds, and launches the app.

## Build a macOS application bundle

`swift run` launches an unbundled development executable. To produce a registered Finder/Dock app with `Info.plist`, icon, and ad-hoc signature:

```bash
./scripts/package-app.sh --release
open build/CodexCore.app
```

Or run `just run-app` for a debug bundle. Output is `build/CodexCore.app`. Ad-hoc signing is for local use; sharing the app requires Developer ID signing and Apple notarization.

## First session

1. Authenticate with ChatGPT device login or an API key.
2. Open a workspace folder.
3. Start a new chat within that project.
4. Choose the model and permission mode.
5. Submit a small, verifiable task.
6. Review each approval before allowing an operation, then inspect resulting files and any available diff preview.

The app stores its state under `~/.codexcore`. Existing Codex Desktop or CLI authentication under `~/.codex` is intentionally not reused.

## Development commands

```bash
just build       # build the app target
just run-fast    # relaunch without an explicit build step
just kill        # stop development instances
just trace       # record a performance trace for a running app
```

`just trace` requires Xcode Instruments tooling and at least 10 GiB of free disk space. Set `TRACE_DURATION=30s` to override its default duration.

Do not use `swift run codex-run` as a harmless smoke test: that target auto-approves operations and asks Codex to create `todo.html` in the current directory.
