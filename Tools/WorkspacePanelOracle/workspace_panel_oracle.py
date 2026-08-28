#!/usr/bin/env python3
"""Inventory the installed official workspace tab/panel bundle.

The official desktop renderer is shipped as an Electron ASAR archive.  This
module intentionally reads only the archive header and the bundle metadata; it
does not execute or import renderer code.  The resulting report is therefore a
read-only oracle that can be rerun after an official bundle update without
making the CodexCore production target depend on that bundle.
"""

from __future__ import annotations

import argparse
import collections
import datetime as _datetime
import hashlib
import json
import os
import pathlib
import plistlib
import struct
from dataclasses import dataclass
from typing import Any, Iterable, Mapping, Sequence


DEFAULT_BUNDLE = "/Applications/ChatGPT.app"


@dataclass(frozen=True)
class AsarEntry:
    """A regular file entry from an ASAR header."""

    path: str
    size: int
    offset: int | None
    unpacked: bool
    integrity: Mapping[str, Any] | None


class AsarArchive:
    """Read ASAR metadata and packed file bytes using random access."""

    def __init__(self, path: pathlib.Path) -> None:
        self.path = path
        self.header, self.header_size = self._read_header()
        self.data_offset = 8 + self.header_size
        self._entries = tuple(self._flatten(self.header.get("files", {})))

    def _read_header(self) -> tuple[Mapping[str, Any], int]:
        with self.path.open("rb") as archive:
            prefix = archive.read(8)
            if len(prefix) != 8:
                raise ValueError(f"ASAR archive is missing its header: {self.path}")
            pickle_payload_size, header_size = struct.unpack("<II", prefix)
            if pickle_payload_size != 4:
                raise ValueError(
                    f"Unsupported ASAR pickle header ({pickle_payload_size}); "
                    "expected a four-byte header-size payload"
                )
            raw_header = archive.read(header_size)
            if len(raw_header) != header_size:
                raise ValueError(f"ASAR header is truncated: {self.path}")

        if len(raw_header) < 8:
            raise ValueError(f"ASAR header is too short: {self.path}")
        payload_size, string_size = struct.unpack("<II", raw_header[:8])
        if payload_size > len(raw_header) - 4:
            raise ValueError(f"ASAR header payload is invalid: {self.path}")
        if string_size > len(raw_header) - 8:
            raise ValueError(f"ASAR header string is invalid: {self.path}")
        try:
            decoded = raw_header[8 : 8 + string_size].decode("utf-8")
            header = json.loads(decoded)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ValueError(f"ASAR header is not JSON: {self.path}") from error
        if not isinstance(header, dict):
            raise ValueError(f"ASAR header root must be an object: {self.path}")
        return header, header_size

    def _flatten(
        self, files: Mapping[str, Any], prefix: str = ""
    ) -> Iterable[AsarEntry]:
        for name in sorted(files):
            value = files[name]
            path = f"{prefix}/{name}" if prefix else f"/{name}"
            if not isinstance(value, dict):
                continue
            children = value.get("files")
            if isinstance(children, dict):
                yield from self._flatten(children, path)
                continue
            if "link" in value:
                continue
            size = value.get("size")
            if not isinstance(size, int) or size < 0:
                continue
            raw_offset = value.get("offset")
            offset: int | None
            if raw_offset is None:
                offset = None
            else:
                try:
                    offset = int(raw_offset)
                except (TypeError, ValueError) as error:
                    raise ValueError(f"Invalid ASAR offset for {path}") from error
            integrity = value.get("integrity")
            if not isinstance(integrity, dict):
                integrity = None
            yield AsarEntry(
                path=path,
                size=size,
                offset=offset,
                unpacked=bool(value.get("unpacked", False)),
                integrity=integrity,
            )

    @property
    def entries(self) -> tuple[AsarEntry, ...]:
        return self._entries

    def read(self, entry: AsarEntry) -> bytes:
        if entry.unpacked or entry.offset is None:
            raise ValueError(f"Cannot read unpacked ASAR entry: {entry.path}")
        with self.path.open("rb") as archive:
            archive.seek(self.data_offset + entry.offset)
            data = archive.read(entry.size)
        if len(data) != entry.size:
            raise ValueError(f"ASAR entry is truncated: {entry.path}")
        return data

    def sha256(self, entry: AsarEntry) -> str | None:
        if entry.unpacked or entry.offset is None:
            return None
        digest = hashlib.sha256()
        with self.path.open("rb") as archive:
            archive.seek(self.data_offset + entry.offset)
            remaining = entry.size
            while remaining:
                chunk = archive.read(min(1024 * 1024, remaining))
                if not chunk:
                    raise ValueError(f"ASAR entry is truncated: {entry.path}")
                digest.update(chunk)
                remaining -= len(chunk)
        return digest.hexdigest()


@dataclass(frozen=True)
class SurfaceRule:
    surface_id: str
    title: str
    kind: str
    prefixes: tuple[str, ...]


# The names are deliberately filename-level evidence rather than guessed UI
# routes.  They are the stable, hashed asset names exposed by the installed
# bundle and are kept broad enough to show both the topological shell and the
# adapters that can be reached from a thread workspace.
SURFACE_RULES: tuple[SurfaceRule, ...] = (
    SurfaceRule("thread-panel-state", "Thread panel state", "state", ("thread-panel-state-",)),
    SurfaceRule("thread-right-panel-state", "Thread right-panel state", "state", ("thread-right-panel-state-",)),
    SurfaceRule("thread-panel-toggle", "Thread panel toggle", "control", ("thread-panel-toggle-button-",)),
    SurfaceRule("thread-side-panel-tabs", "Thread side-panel tabs", "container", ("thread-side-panel-tabs-",)),
    SurfaceRule("thread-side-panel-content", "Thread side-panel content", "container", ("thread-side-panel-tab-content-",)),
    SurfaceRule("thread-side-panel-new-tab", "Thread side-panel new tab", "tab", ("thread-side-panel-new-tab-",)),
    SurfaceRule("thread-goal", "Thread goal", "tab", ("thread-goal-side-panel-content-",)),
    SurfaceRule("side-chat", "Side chat", "tab", ("side-chat-tab-content-",)),
    SurfaceRule("subagents", "Subagents", "tab", ("local-conversation-subagents-panel-tab-", "open-local-conversation-subagents-panel-", "chatgpt-subagents-panel-", "subagent-panel-")),
    SurfaceRule("terminal", "Terminal", "host", ("terminal-tab-", "terminal-panel-", "xterm-output-panel-", "file-terminal-")),
    SurfaceRule("background-terminal", "Background terminal", "tab", ("local-conversation-background-terminal-tab-", "open-local-conversation-background-terminal-tab-")),
    SurfaceRule("browser", "Browser", "host", ("cloud-browser-side-panel-", "cloud-browser-preview-")),
    SurfaceRule("files", "Files and file editor", "host", ("open-text-file-editor-side-panel-tab", "text-file-editor-tab-content", "local-environment-editor-", "file-editor-theme-")),
    SurfaceRule("plan", "Plan", "tab", ("plan-tab-content-", "editable-plan-tab-", "plan-side-panel-", "plan-summary-page-")),
    SurfaceRule("review", "Review", "tab", ("review-file-source-tab-", "review-file-source-tab-content-", "editable-review-file-source-tab-content", "pull-request-revision-tab-", "thread-pull-request-tab-content-", "open-thread-pull-request-side-panel-tab-", "pull-request-code-review-")),
    SurfaceRule("automation", "Automation", "tab", ("automation-side-panel-tab-", "open-automation-side-panel-tab-", "cloud-automation-detail-panel-", "open-pull-request-fix-automation-panel-", "pull-request-fix-automation-")),
    SurfaceRule("artifact", "Artifact", "host", ("artifact-tab-content", "open-artifact-side-panel-tab-", "artifact-preview-", "artifact-source-bootstrap-")),
    SurfaceRule("sources", "Sources", "tab", ("local-conversation-sources-side-panel-tab-", "chatgpt-sources-side-panel-tab-", "chatgpt-sources-message-", "turn-sources-model-")),
    SurfaceRule("mcp-app", "MCP app", "host", ("thread-mcp-app-side-panel-", "mcp-extension-thread-side-panel-tab-", "mcp-extension-view-", "mcp-app-")),
    SurfaceRule("entity", "Entity", "tab", ("chatgpt-entity-side-panel-tab-",)),
    SurfaceRule("generated-image", "Generated image", "host", ("generated-image-preview",)),
    SurfaceRule("document-preview", "Document preview", "host", ("docx-preview-panel-", "pdf-preview-panel-", "notebook-preview-panel-", "notebook-tabs-", "popcornelectrondocumentpanel-", "popcornelectronpresentationpanel-", "popcornelectronworkbookpanel-")),
    SurfaceRule("inspection", "Inspection", "host", ("inspection-panel-",)),
    SurfaceRule("visualization", "Visualization", "host", ("visualization-directive-renderer-",)),
    SurfaceRule("unrestored-thread", "Unrestored thread", "state", ("unrestored-thread-tab-route-",)),
    SurfaceRule("panel-topology", "Panel topology", "topology", ("panel-", "panels-", "layout-panel-")),
    SurfaceRule("tab-system", "Tab system", "topology", ("tab-content-", "tabs-", "tab-", "open-tab-")),
)


def _rule_for_asset(path: str) -> SurfaceRule | None:
    name = pathlib.PurePosixPath(path).name.lower()
    for rule in SURFACE_RULES:
        if any(name.startswith(prefix.lower()) for prefix in rule.prefixes):
            return rule
    return None


def _sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _find_runtime(resources: pathlib.Path) -> pathlib.Path | None:
    candidates = (
        resources / "codex",
        resources / "codex-aarch64-apple-darwin",
        resources / "codex-x86_64-apple-darwin",
    )
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return None


def _iso_now() -> str:
    return _datetime.datetime.now(_datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def build_inventory(
    bundle_path: pathlib.Path,
    *,
    source_commit: str | None = None,
    captured_at: str | None = None,
) -> dict[str, Any]:
    bundle_path = bundle_path.expanduser().resolve()
    contents = bundle_path / "Contents"
    resources = contents / "Resources"
    info_path = contents / "Info.plist"
    asar_path = resources / "app.asar"
    if not info_path.is_file():
        raise FileNotFoundError(f"Official bundle metadata not found: {info_path}")
    if not asar_path.is_file():
        raise FileNotFoundError(f"Official renderer archive not found: {asar_path}")

    with info_path.open("rb") as info_file:
        info = plistlib.load(info_file)
    archive = AsarArchive(asar_path)
    assets: list[dict[str, Any]] = []
    for entry in archive.entries:
        if not entry.path.startswith("/webview/assets/"):
            continue
        suffix = pathlib.PurePosixPath(entry.path).suffix.lower()
        if suffix not in {".js", ".css"}:
            continue
        rule = _rule_for_asset(entry.path)
        if rule is None:
            continue
        assets.append(
            {
                "assetPath": entry.path,
                "assetType": "style" if suffix == ".css" else "module",
                "surfaceID": rule.surface_id,
                "surfaceTitle": rule.title,
                "surfaceKind": rule.kind,
                "sizeBytes": entry.size,
                "sha256": archive.sha256(entry),
                "evidence": "hashed renderer asset filename in app.asar header",
            }
        )
    assets.sort(key=lambda asset: (asset["surfaceID"], asset["assetPath"]))

    runtime = _find_runtime(resources)
    bundle_info = {
        "bundlePath": str(bundle_path),
        "bundleIdentifier": info.get("CFBundleIdentifier"),
        "displayName": info.get("CFBundleDisplayName") or info.get("CFBundleName"),
        "shortVersion": info.get("CFBundleShortVersionString"),
        "buildVersion": info.get("CFBundleVersion"),
        "minimumSystemVersion": info.get("LSMinimumSystemVersion"),
        "asarRelativePath": "Contents/Resources/app.asar",
        "asarSizeBytes": asar_path.stat().st_size,
        "asarSha256": _sha256_file(asar_path),
    }
    if runtime is not None:
        bundle_info["runtime"] = {
            "relativePath": str(runtime.relative_to(bundle_path)),
            "sizeBytes": runtime.stat().st_size,
            "sha256": _sha256_file(runtime),
        }
    else:
        bundle_info["runtime"] = None

    by_kind = collections.Counter(asset["surfaceKind"] for asset in assets)
    by_surface = collections.Counter(asset["surfaceID"] for asset in assets)
    report: dict[str, Any] = {
        "schemaVersion": 1,
        "capturedAtUTC": captured_at or _iso_now(),
        "sourceCommit": source_commit,
        "oracle": {
            "kind": "installed-official-bundle",
            "readOnly": True,
            "archiveFormat": "electron-asar",
            "assetSelection": "webview/assets JavaScript and CSS modules matching workspace tab/panel families",
        },
        "bundle": bundle_info,
        "asar": {
            "headerSizeBytes": archive.header_size,
            "dataOffsetBytes": archive.data_offset,
            "fileCount": len(archive.entries),
        },
        "summary": {
            "matchedAssetCount": len(assets),
            "surfaceCount": len(by_surface),
            "assetCountBySurfaceKind": dict(sorted(by_kind.items())),
            "assetCountBySurface": dict(sorted(by_surface.items())),
        },
        "assets": assets,
    }
    return report


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--bundle",
        type=pathlib.Path,
        default=pathlib.Path(os.environ.get("CODEX_OFFICIAL_BUNDLE", DEFAULT_BUNDLE)),
        help="installed official .app bundle (default: %(default)s)",
    )
    parser.add_argument("--output", type=pathlib.Path, help="write JSON to this path")
    parser.add_argument("--source-commit", help="CodexCore commit used for the oracle run")
    parser.add_argument("--captured-at", help="UTC timestamp for reproducible artifact generation")
    return parser


def main(arguments: Sequence[str] | None = None) -> int:
    args = _argument_parser().parse_args(arguments)
    report = build_inventory(
        args.bundle,
        source_commit=args.source_commit,
        captured_at=args.captured_at,
    )
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output is None:
        print(encoded, end="")
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
