# Documentation conventions

Documentation should reduce search cost, not mirror the codebase in prose.

## Rules

- One task or concept per page.
- Put prerequisites before commands.
- Prefer short examples that compile over broad pseudo-code.
- Link to the source of truth for volatile inventories.
- State whether behavior is stable, experimental, or historical.
- Use exact product names: CodexCore, CodexCoreUI, `codex-core-app`, app-server.
- Do not imply that the reference app or UI layer is required by the SDK.
- Do not publish credentials, usernames, private paths, or captured user content.

## README boundary

README is a landing page: positioning, product choice, first run, minimal SDK use, requirements, and navigation. Detailed API behavior belongs in focused guides or generated symbol documentation.

## Agent-friendly writing

- Begin with the decision or invariant.
- Name authoritative files.
- Use tables for exact mappings.
- Avoid duplicate “overview,” “concepts,” and “introduction” pages.
- Do not use historical research as current API authority.

## Screenshot policy

Use deterministic sample data, a fixed window size/theme, neutral paths, and semantic filenames. Record the source commit, scenario, dimensions in points, and exported pixel size in `docs/assets/screenshots/README.md`. Re-capture only when the documented surface changes materially.
