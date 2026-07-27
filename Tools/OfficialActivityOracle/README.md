# Official activity oracle

This research-only lab executes selected pure functions extracted from the
installed Codex desktop renderer against controlled command and transcript
fixtures. It exists to establish presentation behavior before reproducing that
behavior in CodexCoreUI.

The lab deliberately does not import or commit the shipped renderer. It reads
four locally extracted, prettified slices and extracts the named function
bodies at runtime:

- canonical command-action adaptation;
- exploration grouping;
- active-versus-collapsed selection;
- completed activity aggregation and ordering;
- English command-row formatting.

React, localization, filesystem-link, and application-state dependencies are
replaced with small deterministic stubs. Results involving those dependencies
must be marked separately from results produced entirely by the extracted
functions.

Run:

```sh
node Tools/OfficialActivityOracle/run.mjs > /tmp/official-activity-oracle.json
```

The default source paths are:

```text
/tmp/codex-command-adapter-pretty.js
/tmp/codex-command-summary-pretty.js
/tmp/codex-activity-projection-pretty.js
/tmp/codex-activity-summary-pretty.js
```

Override them with `CODEX_COMMAND_ADAPTER_JS`,
`CODEX_COMMAND_SUMMARY_JS`, `CODEX_ACTIVITY_PROJECTION_JS`, and
`CODEX_ACTIVITY_SUMMARY_JS`.

This lab is evidence for tests, not production code. CodexCoreUI must implement
the resulting behavior using its own typed models.
