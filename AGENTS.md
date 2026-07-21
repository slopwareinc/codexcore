# Agent Instructions

- Keep replies to the user short and concise by default.
- Prefer direct answers over long explanations unless the user asks for detail.
- When reporting work, summarize the outcome, key files touched, and verification only.
- When making code or durable project changes, periodically stop and judge whether the current work forms a logical commit. Commit coherent, verified chunks instead of letting unrelated changes pile up.
- For major durable changes, create or confirm a GitHub issue first, implement on a dedicated branch, and open a linked PR. Include the issue link in the PR body with `Fixes #<issue-number>` or equivalent closing syntax.
