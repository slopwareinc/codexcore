#!/usr/bin/env node

import { mkdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const port = Number(process.argv[2] ?? "9222");
const outputDirectory = resolve(process.argv[3] ?? "/tmp/codex-review-capture");
const action = process.argv[4];
const actionValue = process.argv[5];

const targets = await fetch(`http://127.0.0.1:${port}/json/list`).then((response) => {
  if (!response.ok) {
    throw new Error(`CDP target discovery failed: HTTP ${response.status}`);
  }
  return response.json();
});
const target = targets.find((candidate) =>
  candidate.type === "page"
  && candidate.webSocketDebuggerUrl
  && !candidate.url.includes("avatar-overlay")
);
if (!target) {
  throw new Error("No main renderer page target was found");
}

const socket = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolveOpen, rejectOpen) => {
  socket.addEventListener("open", resolveOpen, { once: true });
  socket.addEventListener("error", rejectOpen, { once: true });
});

let nextID = 1;
const pending = new Map();
socket.addEventListener("message", (event) => {
  const message = JSON.parse(event.data);
  if (message.id == null) {
    return;
  }
  const continuation = pending.get(message.id);
  if (!continuation) {
    return;
  }
  pending.delete(message.id);
  if (message.error) {
    continuation.reject(new Error(JSON.stringify(message.error)));
  } else {
    continuation.resolve(message.result);
  }
});

function call(method, params = undefined) {
  const id = nextID++;
  const response = new Promise((resolveCall, rejectCall) => {
    pending.set(id, { resolve: resolveCall, reject: rejectCall });
  });
  socket.send(JSON.stringify({ id, method, params }));
  return response;
}

if ([
  "click-text",
  "trusted-click-text",
  "click-aria",
  "trusted-click-aria",
  "click-title",
  "trusted-click-title",
].includes(action)) {
  if (!actionValue) {
    throw new Error("click-text requires visible text");
  }
  const clickResult = await call("Runtime.evaluate", {
    expression: String.raw`
((text) => {
  const visible = (element) => {
    const style = getComputedStyle(element);
    const bounds = element.getBoundingClientRect();
    return style.display !== "none"
      && style.visibility !== "hidden"
      && bounds.width > 0
      && bounds.height > 0;
  };
  const candidates = [...document.querySelectorAll(
    "button,a,[role='button'],[role='tab'],[role='menuitem'],[role='option']"
  )].filter(visible);
  const attribute = ${JSON.stringify(
    action.includes("aria") ? "aria-label" : action.includes("title") ? "title" : null
  )};
  const exact = candidates.find((element) => attribute
    ? element.getAttribute(attribute) === text
    : (element.innerText || element.textContent || "").trim() === text
  );
  const element = exact ?? candidates.find((candidate) => attribute
    ? (candidate.getAttribute(attribute) || "").includes(text)
    : (candidate.innerText || candidate.textContent || "").includes(text)
  );
  if (!element) {
    return { clicked: false, available: candidates.map(
      (candidate) => (candidate.innerText || candidate.textContent || "").trim()
    ).filter(Boolean) };
  }
  const bounds = element.getBoundingClientRect();
  if (${JSON.stringify(action)}.startsWith("click-")) {
    element.click();
  }
  return {
    clicked: true,
    text: (element.innerText || element.textContent || "").trim(),
    center: {
      x: bounds.x + bounds.width / 2,
      y: bounds.y + bounds.height / 2,
    },
  };
})(${JSON.stringify(actionValue)})
`,
    returnByValue: true,
  });
  if (!clickResult.result.value.clicked) {
    throw new Error(`No visible element matched ${JSON.stringify(actionValue)}: ${
      JSON.stringify(clickResult.result.value.available)
    }`);
  }
  if (action.startsWith("trusted-click-")) {
    const { x, y } = clickResult.result.value.center;
    await call("Input.dispatchMouseEvent", {
      type: "mouseMoved",
      x,
      y,
    });
    await call("Input.dispatchMouseEvent", {
      type: "mousePressed",
      x,
      y,
      button: "left",
      clickCount: 1,
    });
    await call("Input.dispatchMouseEvent", {
      type: "mouseReleased",
      x,
      y,
      button: "left",
      clickCount: 1,
    });
  }
  await new Promise((resolveDelay) => setTimeout(resolveDelay, 1_000));
} else if (action === "fill-aria") {
  const separatorIndex = actionValue?.indexOf("=") ?? -1;
  if (separatorIndex < 1) {
    throw new Error("fill-aria requires aria-label=value");
  }
  const ariaLabel = actionValue.slice(0, separatorIndex);
  const value = actionValue.slice(separatorIndex + 1);
  const fillResult = await call("Runtime.evaluate", {
    expression: String.raw`
((ariaLabel, value) => {
  const element = document.querySelector(
    "[aria-label=" + CSS.escape(ariaLabel) + "]"
  );
  if (!element) {
    return { filled: false };
  }
  const setter = Object.getOwnPropertyDescriptor(
    HTMLInputElement.prototype,
    "value"
  )?.set ?? Object.getOwnPropertyDescriptor(
    HTMLTextAreaElement.prototype,
    "value"
  )?.set;
  setter.call(element, value);
  element.dispatchEvent(new Event("input", { bubbles: true }));
  element.dispatchEvent(new Event("change", { bubbles: true }));
  return { filled: true };
})(${JSON.stringify(ariaLabel)}, ${JSON.stringify(value)})
`,
    returnByValue: true,
  });
  if (!fillResult.result.value.filled) {
    throw new Error(`No element had aria-label ${JSON.stringify(ariaLabel)}`);
  }
  await new Promise((resolveDelay) => setTimeout(resolveDelay, 300));
} else if (action) {
  throw new Error(`Unsupported action: ${action}`);
}

const expression = String.raw`
(() => {
  const visible = (element) => {
    const style = getComputedStyle(element);
    const bounds = element.getBoundingClientRect();
    return style.display !== "none"
      && style.visibility !== "hidden"
      && Number(style.opacity) !== 0
      && bounds.width > 0
      && bounds.height > 0;
  };
  const describe = (element) => {
    const bounds = element.getBoundingClientRect();
    return {
      tag: element.tagName.toLowerCase(),
      role: element.getAttribute("role"),
      ariaLabel: element.getAttribute("aria-label"),
      title: element.getAttribute("title"),
      text: (element.innerText || element.textContent || "").trim().slice(0, 300),
      disabled: Boolean(element.disabled || element.getAttribute("aria-disabled") === "true"),
      bounds: {
        x: Math.round(bounds.x),
        y: Math.round(bounds.y),
        width: Math.round(bounds.width),
        height: Math.round(bounds.height),
      },
    };
  };
  const interactiveSelector = [
    "button",
    "a",
    "input",
    "textarea",
    "[contenteditable='true']",
    "[role='button']",
    "[role='tab']",
    "[role='menuitem']",
    "[role='option']",
    "[tabindex]",
  ].join(",");
  return {
    capturedAt: new Date().toISOString(),
    title: document.title,
    url: location.href,
    viewport: { width: innerWidth, height: innerHeight, deviceScaleFactor: devicePixelRatio },
    bodyText: (document.body?.innerText || "").slice(0, 100000),
    interactiveElements: [...document.querySelectorAll(interactiveSelector)]
      .filter(visible)
      .slice(0, 1000)
      .map(describe),
  };
})()
`;

await mkdir(outputDirectory, { recursive: true });
await call("Runtime.enable");
await call("Page.enable");
const evaluated = await call("Runtime.evaluate", {
  expression,
  returnByValue: true,
  awaitPromise: true,
});
const snapshot = evaluated.result.value;
const screenshot = await call("Page.captureScreenshot", {
  format: "png",
  captureBeyondViewport: false,
  fromSurface: true,
});

await Promise.all([
  writeFile(
    resolve(outputDirectory, "snapshot.json"),
    `${JSON.stringify(snapshot, null, 2)}\n`,
  ),
  writeFile(
    resolve(outputDirectory, "screenshot.png"),
    Buffer.from(screenshot.data, "base64"),
  ),
]);
socket.close();

console.log(JSON.stringify({
  outputDirectory,
  target: { title: target.title, url: target.url },
  viewport: snapshot.viewport,
  interactiveElementCount: snapshot.interactiveElements.length,
}, null, 2));
