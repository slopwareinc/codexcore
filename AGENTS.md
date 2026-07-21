# Agent Instructions

- Keep replies to the user short and concise by default.
- Prefer direct answers over long explanations unless the user asks for detail.
- When reporting work, summarize the outcome, key files touched, and verification only.
- When making code or durable project changes, periodically stop and judge whether the current work forms a logical commit. Commit coherent, verified chunks instead of letting unrelated changes pile up.
- For major durable changes, create or confirm a GitHub issue first, implement on a dedicated branch, and open a linked PR. Include the issue link in the PR body with `Fixes #<issue-number>` or equivalent closing syntax.

## Documentation routing

- Start at `docs/index.md`; load only the guides relevant to the task.
- Treat `Package.swift`, `Tools/UPSTREAM_VERSION`, `justfile`, production source, and tests as authoritative for volatile facts.
- Treat transcript experiments, performance findings, phase plans, and visual audits as historical engineering evidence unless production code confirms them.
- When public API changes, update the relevant guide and a compiling test/example in the same change.
- Keep README concise. Put workflows in task guides and symbol detail in source documentation.
- Never edit generated protocol files or request factories by hand; follow `docs/contributing/protocol-upgrades.md`.
