# Official Codex activity presentation oracle

> **Historical engineering evidence:** This document records behavior observed
> in Codex desktop 26.721.41059 (build 5848). Production CodexCore source and
> tests remain authoritative.

This audit answers two separate questions:

1. Which user-facing strings arrive from app-server?
2. Which strings and groupings are derived by the desktop renderer?

The renderer bundle audited here has SHA-256
`09909b1444003ea23a48d5fa973bedf48b638c6d6ef3059fb48a9f262e73513e`.
Controlled cases were executed by
`Tools/OfficialActivityOracle/run.mjs`.

## Responsibility split

| Presentation | Author | Renderer responsibility |
| --- | --- | --- |
| Assistant commentary | Model, transported by app-server | Render as ordinary transcript prose |
| Reasoning headline such as `Evaluating uncommitted partial modifications` | Model, transported through reasoning summary items and deltas | Select the current reasoning summary and render its Markdown |
| `Read App.swift` | Desktop renderer | Format a typed `commandAction.read` |
| `Searching for liveTail in Sources` | Desktop renderer | Format a typed `commandAction.search` |
| `Read files, ran commands` | Desktop renderer | Aggregate typed activity categories in a fixed order |
| Raw command detail | app-server payload | Reveal only in command detail/fallback presentation |

The desktop renderer does not invent reasoning headlines by examining commands.
It also does not receive completed activity summaries such as `Read files, ran
commands` from app-server.

## Renderer pipeline

The shipped symbols are minified, but their inputs, outputs, message IDs, and
call graph are observable.

| Shipped function | Input | Output or responsibility |
| --- | --- | --- |
| `_T` | Canonical turn and requests | Ordered renderer items |
| `Pqn` | Reasoning `summary: [String]` | One Markdown reasoning string; multiple summary parts are separated by blank lines and the first becomes a heading |
| `cDt` | One app-server `commandAction` | `read`, `list_files`, `search`, or `unknown` parsed command |
| `hDt` | Parsed command and completion state | Adds `isFinished` |
| command-execution branch in `_T` | One `commandExecution` | One renderer `exec` per action, or one unknown fallback |
| `VGc` | One renderer `exec` | Whether it is exploration: read, search, or list |
| `uKc` | Ordered renderer items | Contiguous exploration slices |
| `XUc` | One exploration slice | Read paths, skill paths, search/list counts, and running subsets |
| `GUc` | One renderer item | Tool activity classification |
| `mKc` | Classified activity | Deduplicated activity totals |
| `WGc` | Activity totals | Completed summary parts in fixed category order |
| `wKc` | One summary part | Localized visible phrase |
| `MKc` | Ordered groupable/standalone activities | Disclosure units |
| `NKc` | Unit plus live/closed state | `active`, `thinking`, or collapsed `summary` |
| `Z5c` | Search parsed command | Search row label |
| `i7c` | List parsed command | List row label |
| `l7c` | Read parsed command | Read row label, including skill handling |
| `h7c` | Unknown/classified command | Running, completed, interrupted, background, and duration labels |

## Command adaptation

For a command execution with `N` nonempty actions, the official adapter emits
`N` renderer rows:

```text
one action:   callId = itemID
many actions: callId = itemID:0, itemID:1, …
              commandExecutionItemId = itemID
```

Every emitted row receives the parent execution status, output, exit code,
duration, working directory, and process identity. An execution with no actions
becomes one `unknown` row using the full `command` field.

This is why one shell invocation can expand to several `Read …` rows.

## Verified row-label matrix

These outputs were produced by executing the extracted shipped formatter
functions. English localization and React rendering were replaced with
transparent deterministic stubs.

| Input action and state | Visible label |
| --- | --- |
| Completed read with `name=App.swift` | `Read App.swift` |
| Active ordinary read | No individual row label |
| Active `SKILL.md` read in `STEPS_PROSE` mode | `Reading github skill` |
| Completed `SKILL.md` read | `Read github skill` |
| Active list with path | `Listing files in Sources` |
| Completed list with path | `Listed files in Sources` |
| Active list without path | `Listing files` |
| Completed list without path | `Listed files` |
| Active search with query and path | `Searching for liveTail in Sources` |
| Completed search with query and path | `Searched for liveTail in Sources` |
| Search with query only | `Searching/Searched for liveTail` |
| Search with neither query nor path | `Searching/Searched for files` |
| Active unknown command | `Running command` |
| Completed unknown command, collapsed with raw command available | `Ran swift test` |
| Interrupted unknown command, collapsed with raw command available | `Stopped swift test` |
| No `commandActions` | Same unknown-command fallback |

The official UI intentionally does not show the raw command in the generic
active label.

## Exploration slicing

`read`, `search`, and `list_files` are exploration. The rules are:

| Sequence | Result |
| --- | --- |
| read → search → list | One exploration slice |
| read → reasoning → search | One exploration slice; reasoning stays inside it |
| read → assistant commentary → search | Two exploration slices |
| read → unknown command → search | Exploration, command, exploration |
| active ordinary read | Active exploration, but no ordinary read row label |
| active skill read | May have a visible `Reading … skill` label |

Reasoning participates in exploration continuity but is not counted as tool
activity.

## Active versus collapsed presentation

`NKc` chooses the current presentation:

| State | Presentation |
| --- | --- |
| Latest unit, turn active, slice open, active exploration command | That active command |
| Latest unit, turn active, slice open, another active tool | Latest active tool |
| Latest unit, turn active, slice open, no active tool | `Thinking` |
| Slice closed | Completed collapsed summary |
| Unit is not the latest visible unit | Completed collapsed summary |
| Turn completed | Completed collapsed summary |

Thus the live row is not an accumulating transcript. One stable disclosure unit
switches between its latest active item and its completed aggregate.

## Completed-summary ordering

`WGc` uses this order regardless of event arrival order:

1. named MCP sources/integrations;
2. loaded skills/tools;
3. unnamed MCP calls;
4. file changes;
5. stopped file creation;
6. exploration;
7. visualization;
8. commands;
9. web search;
10. dynamic tool calls.

Exploration always formats as `Read files`, even when the slice contained only
searches or directory listings.

Verified examples:

| Aggregate | Visible English summary |
| --- | --- |
| reads only | `Read files` |
| searches only | `Read files` |
| listings only | `Read files` |
| two edits, exploration, one command | `Edited files, read files, ran a command` |
| one loaded skill, exploration, two commands | `Loaded a tool, read files, ran commands` |
| one command recognized as web search | `Searched the web` |
| one ordinary command plus native web search | `Ran a command, searched the web` |

Counts choose singular or plural but are generally not displayed:
`Ran a command` versus `Ran commands`, not `Ran 3 commands`.

## Event lifecycle

The relevant app-server order is:

```text
item/started(commandExecution)
item/commandExecution/outputDelta*
item/completed(commandExecution)
```

The row identity derives from item ID plus action index, so the completed
projection replaces the active projection. Output deltas do not create activity
rows.

Reasoning uses:

```text
item/started(reasoning)
item/reasoning/summaryPartAdded*
item/reasoning/summaryTextDelta*
item/reasoning/textDelta*
item/completed(reasoning)
```

Only the summary drives the quiet live headline. Reasoning content does not
become normal transcript prose.

## Explicit uncertainty boundary

The following behavior is not fully determined by the pure-function oracle and
must remain covered by captures or integration tests:

- localized output outside English;
- mounted-workspace display labels and clickable path rendering;
- exact skill-path recognition across every installation root;
- named MCP source resolution, logos, and MCP-app standalone behavior;
- visualization-script recognition;
- background-terminal lifecycle after a turn finishes;
- accessibility text and animation timing.

These do not block correcting CodexCore’s central projection: preserve every
command action, use stable action identities, keep model-authored reasoning
summaries verbatim, group exploration correctly, and use the verified summary
order.
