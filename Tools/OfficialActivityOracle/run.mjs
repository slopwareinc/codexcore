#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const projectionPath =
  process.env.CODEX_ACTIVITY_PROJECTION_JS ??
  "/tmp/codex-activity-projection-pretty.js";
const adapterPath =
  process.env.CODEX_COMMAND_ADAPTER_JS ??
  "/tmp/codex-command-adapter-pretty.js";
const summaryPath =
  process.env.CODEX_COMMAND_SUMMARY_JS ??
  "/tmp/codex-command-summary-pretty.js";
const activitySummaryPath =
  process.env.CODEX_ACTIVITY_SUMMARY_JS ??
  "/tmp/codex-activity-summary-pretty.js";

for (const sourcePath of [
  projectionPath,
  adapterPath,
  summaryPath,
  activitySummaryPath,
]) {
  if (!fs.existsSync(sourcePath)) {
    throw new Error(
      `Missing extracted renderer source: ${sourcePath}\n` +
        "Extract and prettify the installed app renderer first, or set the " +
        "CODEX_ACTIVITY_PROJECTION_JS, CODEX_ACTIVITY_SUMMARY_JS, " +
        "CODEX_COMMAND_ADAPTER_JS, and CODEX_COMMAND_SUMMARY_JS " +
        "environment variables."
    );
  }
}

function extractFunction(source, name) {
  const marker = `function ${name}(`;
  const start = source.indexOf(marker);
  if (start < 0) throw new Error(`Could not find ${name}`);
  const parametersStart = source.indexOf("(", start);
  let parametersDepth = 0;
  let parametersEnd = -1;
  for (let index = parametersStart; index < source.length; index += 1) {
    if (source[index] === "(") parametersDepth += 1;
    if (source[index] === ")") {
      parametersDepth -= 1;
      if (parametersDepth === 0) {
        parametersEnd = index;
        break;
      }
    }
  }
  if (parametersEnd < 0) throw new Error(`Unterminated parameters for ${name}`);
  const bodyStart = source.indexOf("{", parametersEnd);
  let depth = 0;
  let quote = null;
  let escaped = false;
  for (let index = bodyStart; index < source.length; index += 1) {
    const character = source[index];
    if (quote != null) {
      if (escaped) {
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === quote) {
        quote = null;
      }
      continue;
    }
    if (character === "'" || character === '"' || character === "`") {
      quote = character;
      continue;
    }
    if (character === "{") depth += 1;
    if (character === "}") {
      depth -= 1;
      if (depth === 0) return source.slice(start, index + 1);
    }
  }
  throw new Error(`Unterminated function ${name}`);
}

const projectionSource = fs.readFileSync(projectionPath, "utf8");
const adapterSource = fs.readFileSync(adapterPath, "utf8");
const commandSummarySource = fs.readFileSync(summaryPath, "utf8");
const activitySummarySource = fs.readFileSync(activitySummaryPath, "utf8");

const exactFunctions = [
  [adapterSource, "cDt"],
  [adapterSource, "hDt"],
  [projectionSource, "VGc"],
  [projectionSource, "cKc"],
  [projectionSource, "dKc"],
  [projectionSource, "uKc"],
  [projectionSource, "YUc"],
  [projectionSource, "XUc"],
  [projectionSource, "mKc"],
  [projectionSource, "hKc"],
  [projectionSource, "gKc"],
  [projectionSource, "_Kc"],
  [projectionSource, "vKc"],
  [projectionSource, "yKc"],
  [projectionSource, "bKc"],
  [projectionSource, "WGc"],
  [projectionSource, "GGc"],
  [activitySummarySource, "MKc"],
  [activitySummarySource, "NKc"],
  [activitySummarySource, "PKc"],
  [activitySummarySource, "FKc"],
  [activitySummarySource, "IKc"],
  [commandSummarySource, "Z5c"],
  [commandSummarySource, "i7c"],
  [commandSummarySource, "l7c"],
  [commandSummarySource, "d7c"],
  [commandSummarySource, "h7c"],
  [commandSummarySource, "y7c"],
  [commandSummarySource, "b7c"],
];

const sentinel = Symbol.for("react.memo_cache_sentinel");

function flatten(value) {
  if (value == null || value === false) return "";
  if (typeof value === "string" || typeof value === "number") return String(value);
  if (Array.isArray(value)) return value.map(flatten).join("");
  if (typeof value === "object" && "children" in value) return flatten(value.children);
  return "";
}

function interpolate(message, values = {}) {
  let result = message.replace(/<\/?verb>/g, "");
  result = result.replace(
    /\{(\w+), plural, one \{([^{}]*)\} other \{([^{}]*)\}\}/g,
    (_, key, one, other) => (Number(values[key]) === 1 ? one : other)
  );
  return result.replace(/\{(\w+)\}/g, (_, key) => flatten(values[key] ?? ""));
}

function jsx(type, props = {}) {
  if (typeof type === "function") return type(props);
  return { type, children: props.children };
}

function formatMessageComponent({ defaultMessage, values }) {
  return interpolate(defaultMessage, values);
}

const context = {
  console,
  URL,
  Symbol,
  Set,
  Map,
  Object,
  Array,
  Math,
  Date,
  RegExp,
  String,
  Number,
  RUc(value) {
    throw new Error(`Unexpected value: ${String(value)}`);
  },
  uDt: { default: (items, predicate) => items.find(predicate) },
  bXe: (left, right) => left === right,
  fKc: { default: (items) => items.at(-1) },
  iKc: () => false,
  ZLc: ({ summary }) =>
    summary?.type === "read" && /(?:^|\/)SKILL\.md$/i.test(summary.path ?? ""),
  QLc: ({ summary }) => {
    const match = (summary.path ?? "").match(/(?:^|\/)skills\/([^/]+)\/SKILL\.md$/i);
    return match
      ? { isSkillDefinitionFile: true, skillName: match[1].replaceAll("-", " ") }
      : null;
  },
  QUc: (value, cwd) => {
    if (value == null) return "";
    if (path.isAbsolute(value) || cwd == null) return path.normalize(value);
    return path.normalize(path.join(cwd, value));
  },
  fE: (value) => path.basename(value ?? ""),
  J3: { c: (count) => Array(count).fill(sentinel) },
  Y3: { jsx, jsxs: jsx, Fragment: Symbol("Fragment") },
  Z: formatMessageComponent,
  J5c: ({ label }) => label,
  U1: ({ children }) => children,
  Pk: ({ children }) => children,
  u5c: ({ displayPath }) => displayPath,
  q3: (value) => value,
  Q5c: (value) => value,
  $5c: (value) => value,
  e7c: (value) => value,
  t7c: (value) => value,
  n7c: (value) => value,
  r7c: (value) => value,
  a7c: (value) => value,
  o7c: (value) => value,
  s7c: (value) => value,
  c7c: (value) => value,
  u7c: (value) => value,
  f7c: (value) => value,
  p7c: (value) => value,
  m7c: (value) => value,
  $: (...values) => values.filter(Boolean).join(" "),
  CLc: () => false,
  SLc: () => null,
  g7c: () => false,
  x7c: () => null,
  _7c: ({ children }) => children,
  v7c: ({ summary }) => `script ${summary.fileName} from ${summary.skillName} skill`,
  E7c: (milliseconds) => `${Math.round(milliseconds / 100) / 10}s`,
  tKc: "server:node_repl",
};

vm.createContext(context);
const evaluatedSource = [
  ...exactFunctions.map(([source, name]) => extractFunction(source, name)),
  "globalThis.oracle = { cDt, hDt, VGc, cKc, dKc, uKc, YUc, XUc, mKc, WGc, MKc, NKc, PKc, FKc, Z5c, i7c, l7c, d7c, h7c };",
].join("\n");
if (process.env.CODEX_ORACLE_DUMP_SOURCE != null) {
  fs.writeFileSync(process.env.CODEX_ORACLE_DUMP_SOURCE, evaluatedSource);
}
vm.runInContext(evaluatedSource, context);

const oracle = context.oracle;

function adaptCommandExecution(item) {
  const actions = item.commandActions.map((action) => oracle.cDt(action, []));
  const parsed = actions.length > 0 ? actions : [{ type: "unknown", cmd: item.command }];
  const isFinished = item.status !== "inProgress";
  const output =
    item.aggregatedOutput != null || item.exitCode != null
      ? {
          aggregatedOutput: item.aggregatedOutput ?? "",
          exitCode: item.exitCode ?? undefined,
        }
      : null;
  return parsed.map((command, index) => ({
    type: "exec",
    callId: parsed.length > 1 ? `${item.id}:${index}` : item.id,
    ...(parsed.length > 1 ? { commandExecutionItemId: item.id } : {}),
    cwd: item.cwd ?? null,
    cmd: command.cmd.trim().length > 0 ? [command.cmd.trim()] : [],
    executionStatus: item.status,
    parsedCmd: oracle.hDt(command, isFinished),
    output,
  }));
}

function visibleCommandLabel(exec, detailLevel = "STEPS_PROSE") {
  const summary = exec.parsedCmd;
  if (summary.type === "search") {
    return flatten(
      oracle.Z5c({
        summary,
        automaticApprovalReviews: null,
        summaryIcon: null,
      })
    );
  }
  if (summary.type === "list_files") {
    return flatten(
      oracle.i7c({
        summary,
        automaticApprovalReviews: null,
        summaryIcon: null,
      })
    );
  }
  if (summary.type === "read") {
    return flatten(
      oracle.l7c({
        summary,
        cwd: exec.cwd,
        hostId: "oracle",
        threadDetailLevel: detailLevel,
        automaticApprovalReviews: null,
        summaryIcon: null,
      })
    );
  }
  return flatten(
    oracle.h7c({
      summary,
      cmd: exec.cmd,
      elapsedLabel: null,
      isInProgress: !summary.isFinished,
      isBackgroundTerminalRunning: false,
      isFinishedBackgroundTerminal: false,
      wasInterrupted: exec.executionStatus === "interrupted",
      isExpanded: false,
      showRawCommand: true,
      summaryStatusClassName: "",
      executionStatus: exec.executionStatus,
    })
  );
}

function commandFixture(overrides) {
  return {
    id: "exec-1",
    command: "fallback-command",
    cwd: "/workspace",
    status: "completed",
    commandActions: [],
    aggregatedOutput: "",
    exitCode: 0,
    ...overrides,
  };
}

function rowCase(name, fixture, detailLevel) {
  const rows = adaptCommandExecution(fixture);
  return {
    name,
    input: fixture,
    projection: rows.map((row) => ({
      callId: row.callId,
      commandExecutionItemId: row.commandExecutionItemId ?? null,
      parsedCmd: row.parsedCmd,
      label: visibleCommandLabel(row, detailLevel),
    })),
  };
}

const rowCases = [
  rowCase(
    "completed read",
    commandFixture({
      commandActions: [
        { type: "read", command: "sed -n 1,80p Sources/App.swift", name: "App.swift", path: "Sources/App.swift" },
      ],
    })
  ),
  rowCase(
    "active ordinary read",
    commandFixture({
      status: "inProgress",
      aggregatedOutput: null,
      exitCode: null,
      commandActions: [
        { type: "read", command: "cat README.md", name: "README.md", path: "README.md" },
      ],
    })
  ),
  rowCase(
    "active skill read in prose detail mode",
    commandFixture({
      status: "inProgress",
      aggregatedOutput: null,
      exitCode: null,
      commandActions: [
        {
          type: "read",
          command: "cat /workspace/skills/github/SKILL.md",
          name: "SKILL.md",
          path: "/workspace/skills/github/SKILL.md",
        },
      ],
    }),
    "STEPS_PROSE"
  ),
  rowCase(
    "completed list with path",
    commandFixture({
      commandActions: [{ type: "listFiles", command: "find Sources -type f", path: "Sources" }],
    })
  ),
  rowCase(
    "active search with query and path",
    commandFixture({
      status: "inProgress",
      aggregatedOutput: null,
      exitCode: null,
      commandActions: [
        { type: "search", command: "rg liveTail Sources", query: "liveTail", path: "Sources" },
      ],
    })
  ),
  rowCase(
    "completed search with query only",
    commandFixture({
      commandActions: [{ type: "search", command: "rg liveTail", query: "liveTail" }],
    })
  ),
  rowCase(
    "completed search without metadata",
    commandFixture({
      commandActions: [{ type: "search", command: "find . -name '*.swift'" }],
    })
  ),
  rowCase(
    "completed unknown",
    commandFixture({
      command: "swift test",
      commandActions: [{ type: "unknown", command: "swift test" }],
    })
  ),
  rowCase(
    "active unknown",
    commandFixture({
      command: "swift test",
      status: "inProgress",
      aggregatedOutput: null,
      exitCode: null,
      commandActions: [{ type: "unknown", command: "swift test" }],
    })
  ),
  rowCase(
    "three semantic actions from one execution",
    commandFixture({
      id: "exec-multi",
      command: "sed App.swift && sed Model.swift && rg liveTail Sources",
      commandActions: [
        { type: "read", command: "sed App.swift", name: "App.swift", path: "App.swift" },
        { type: "read", command: "sed Model.swift", name: "Model.swift", path: "Model.swift" },
        { type: "search", command: "rg liveTail Sources", query: "liveTail", path: "Sources" },
      ],
    })
  ),
  rowCase(
    "empty actions use whole-command fallback",
    commandFixture({ command: "swift test", commandActions: [] })
  ),
];

function exec(action, finished = true) {
  return {
    type: "exec",
    cwd: "/workspace",
    executionStatus: finished ? "completed" : "inProgress",
    parsedCmd: { ...action, isFinished: finished },
  };
}

const groupingCases = [
  {
    name: "reasoning remains inside contiguous exploration",
    items: [
      exec({ type: "read", cmd: "cat A", name: "A", path: "A" }),
      { type: "reasoning", content: "Checking another file", completed: true },
      exec({ type: "search", cmd: "rg x", query: "x", path: "." }),
    ],
  },
  {
    name: "assistant prose closes exploration",
    items: [
      exec({ type: "read", cmd: "cat A", name: "A", path: "A" }),
      { type: "assistant-message", content: "I found the entry point.", completed: true },
      exec({ type: "search", cmd: "rg x", query: "x", path: "." }),
    ],
  },
  {
    name: "unknown command sits outside exploration",
    items: [
      exec({ type: "read", cmd: "cat A", name: "A", path: "A" }),
      exec({ type: "unknown", cmd: "swift test" }),
      exec({ type: "search", cmd: "rg x", query: "x", path: "." }),
    ],
  },
  {
    name: "unfinished exploration is active only at open live tail",
    items: [exec({ type: "read", cmd: "cat A", name: "A", path: "A" }, false)],
    isTurnInProgress: true,
  },
].map((testCase) => ({
  name: testCase.name,
  inputTypes: testCase.items.map((item) =>
    item.type === "exec" ? item.parsedCmd.type : item.type
  ),
  output: oracle.uKc({
    agentItems: testCase.items,
    isTurnInProgress: testCase.isTurnInProgress ?? false,
    isAnyNonAgentItemInProgress: false,
  }),
}));

function activityWrapper(item, grouping = "groupable") {
  return { item, grouping };
}

const activeSelectionCases = [
  {
    name: "open exploration selects latest active exploration command",
    unit: {
      items: [
        activityWrapper(exec({ type: "read", cmd: "cat A", name: "A", path: "A" })),
        activityWrapper(
          exec({ type: "search", cmd: "rg x", query: "x", path: "." }, false)
        ),
      ],
    },
    input: {
      isLatestVisibleUnit: true,
      isTurnInProgress: true,
      isActivitySliceClosed: false,
      isExploring: true,
    },
  },
  {
    name: "open non-exploration selects latest active command",
    unit: {
      items: [
        activityWrapper(
          exec({ type: "unknown", cmd: "swift test" }, false)
        ),
      ],
    },
    input: {
      isLatestVisibleUnit: true,
      isTurnInProgress: true,
      isActivitySliceClosed: false,
      isExploring: false,
    },
  },
  {
    name: "open unit with no active tool shows thinking",
    unit: {
      items: [
        activityWrapper(exec({ type: "unknown", cmd: "swift test" })),
      ],
    },
    input: {
      isLatestVisibleUnit: true,
      isTurnInProgress: true,
      isActivitySliceClosed: false,
      isExploring: false,
    },
  },
  {
    name: "closed slice always shows collapsed summary",
    unit: {
      items: [
        activityWrapper(
          exec({ type: "search", cmd: "rg x", query: "x", path: "." }, false)
        ),
      ],
    },
    input: {
      isLatestVisibleUnit: true,
      isTurnInProgress: true,
      isActivitySliceClosed: true,
      isExploring: true,
    },
  },
  {
    name: "non-latest unit always shows collapsed summary",
    unit: {
      items: [
        activityWrapper(
          exec({ type: "search", cmd: "rg x", query: "x", path: "." }, false)
        ),
      ],
    },
    input: {
      isLatestVisibleUnit: false,
      isTurnInProgress: true,
      isActivitySliceClosed: false,
      isExploring: true,
    },
  },
].map(({ name, unit, input }) => ({
  name,
  input,
  output: oracle.NKc({ unit, ...input }),
}));

function emptyAggregate(overrides = {}) {
  return {
    createdFileCount: 0,
    editedFileCount: 0,
    deletedFileCount: 0,
    stoppedCreatedFileCount: 0,
    exploredFileCount: 0,
    loadedToolCount: 0,
    searchCount: 0,
    listCount: 0,
    visualizationActivity: undefined,
    commandCount: 0,
    completedVisualizationCommandCount: 0,
    runningVisualizationCommandCount: 0,
    completedWebSearchCommandCount: 0,
    runningWebSearchCommandCount: 0,
    webSearchCount: 0,
    mcpToolCallCount: 0,
    mcpToolCallSources: [],
    ...overrides,
  };
}

function englishSummary(parts) {
  return parts
    .map((part, index) => {
      const leading = index === 0;
      switch (part.kind) {
        case "loaded-tools":
          return part.count === 1
            ? leading
              ? "Loaded a tool"
              : "loaded a tool"
            : leading
              ? "Loaded tools"
              : "loaded tools";
        case "file-changes":
          return part.count === 1
            ? leading
              ? "Edited a file"
              : "edited a file"
            : leading
              ? "Edited files"
              : "edited files";
        case "exploration":
          return leading ? "Read files" : "read files";
        case "commands":
          return part.count === 1
            ? leading
              ? "Ran a command"
              : "ran a command"
            : leading
              ? "Ran commands"
              : "ran commands";
        case "web-search":
          return leading ? "Searched the web" : "searched the web";
        default:
          return part.kind;
      }
    })
    .join(", ");
}

const summaryCases = [
  ["read only", emptyAggregate({ exploredFileCount: 2 })],
  ["search only", emptyAggregate({ searchCount: 2 })],
  ["list only", emptyAggregate({ listCount: 1 })],
  [
    "edit, exploration, and command",
    emptyAggregate({ editedFileCount: 2, exploredFileCount: 3, commandCount: 1 }),
  ],
  [
    "loaded tool before exploration and command",
    emptyAggregate({ loadedToolCount: 1, exploredFileCount: 1, commandCount: 2 }),
  ],
  [
    "command-backed web search removed from command count",
    emptyAggregate({
      commandCount: 1,
      completedWebSearchCommandCount: 1,
    }),
  ],
  [
    "native web search follows commands",
    emptyAggregate({ commandCount: 1, webSearchCount: 1 }),
  ],
].map(([name, aggregate]) => {
  const parts = oracle.WGc(aggregate, [], []);
  return { name, aggregate, parts, visible: englishSummary(parts) };
});

const result = {
  rendererSources: {
    projectionPath,
    adapterPath,
    summaryPath,
    activitySummaryPath,
  },
  rowCases,
  groupingCases,
  activeSelectionCases,
  summaryCases,
};

process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
