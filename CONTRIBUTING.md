# Contributing to CodexCore

Keep changes narrow, verified, and aligned with the single-session architecture. Start with the [development guide](docs/contributing/development.md) for prerequisites and commands.

## Before coding

- Read `AGENTS.md` and the relevant focused guide.
- Confirm or create the GitHub issue and intended module boundary for major work.
- Use a dedicated `codex/…` branch for major changes.
- Preserve unrelated working-tree changes.

Use the verification matrix in the [development guide](docs/contributing/development.md). Protocol changes additionally require the [protocol upgrade procedure](docs/contributing/protocol-upgrades.md).

## Generated code

Do not edit these by hand:

- `Sources/CodexCore/Generated/*`
- `Sources/CodexCore/Client/CodexSessionCommands.swift`

Follow `docs/contributing/protocol-upgrades.md`.

## Pull requests

Explain what changed, why, compatibility impact, and verification. Link the issue with `Fixes #…` when the PR completes it. Include screenshots only when a visible surface materially changes.
