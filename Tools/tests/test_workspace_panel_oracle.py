import hashlib
import json
import plistlib
import struct
import sys
import tempfile
import unittest
from pathlib import Path


TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))

from WorkspacePanelOracle.workspace_panel_oracle import (  # noqa: E402
    AsarArchive,
    build_inventory,
)


def write_asar(path: Path, files: dict[str, bytes]) -> None:
    """Write the small ASAR shape used by the parser tests."""
    manifest: dict[str, object] = {}
    data = bytearray()
    for file_path, content in sorted(files.items()):
        parts = file_path.strip("/").split("/")
        node = manifest
        for directory in parts[:-1]:
            child = node.setdefault(directory, {"files": {}})
            node = child["files"]  # type: ignore[index]
        node[parts[-1]] = {
            "size": len(content),
            "offset": str(len(data)),
        }
        data.extend(content)

    encoded = json.dumps({"files": manifest}, separators=(",", ":")).encode("utf-8")
    inner_payload = struct.pack("<I", len(encoded)) + encoded
    inner_payload += b"\0" * ((-len(inner_payload)) % 4)
    inner = struct.pack("<I", len(inner_payload)) + inner_payload
    path.write_bytes(struct.pack("<II", 4, len(inner)) + inner + data)


class WorkspacePanelOracleTests(unittest.TestCase):
    def test_reads_asar_entries_and_packed_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            archive_path = Path(directory) / "app.asar"
            write_asar(
                archive_path,
                {
                    "/webview/assets/thread-panel-state-abc.js": b"export {};",
                    "/webview/assets/thread-side-panel-tabs-def.js": b"tabs",
                },
            )

            archive = AsarArchive(archive_path)

            self.assertEqual(
                [entry.path for entry in archive.entries],
                [
                    "/webview/assets/thread-panel-state-abc.js",
                    "/webview/assets/thread-side-panel-tabs-def.js",
                ],
            )
            entry = archive.entries[1]
            self.assertEqual(archive.read(entry), b"tabs")
            self.assertEqual(archive.sha256(entry), hashlib.sha256(b"tabs").hexdigest())

    def test_inventory_is_filename_evidence_and_ignores_unrelated_assets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "ChatGPT.app"
            resources = root / "Contents" / "Resources"
            resources.mkdir(parents=True)
            with (root / "Contents" / "Info.plist").open("wb") as info_file:
                plistlib.dump(
                    {
                        "CFBundleIdentifier": "com.openai.codex",
                        "CFBundleDisplayName": "ChatGPT",
                        "CFBundleShortVersionString": "test-version",
                        "CFBundleVersion": "123",
                    },
                    info_file,
                )
            write_asar(
                resources / "app.asar",
                {
                    "/webview/assets/thread-side-panel-tabs-deadbeef.js": b"tabs",
                    "/webview/assets/terminal-panel-cafebabe.js": b"terminal",
                    "/webview/assets/unrelated-card-deadbeef.js": b"ignore",
                    "/webview/assets/panel-bottom-open-deadbeef.css": b".panel {}",
                },
            )

            report = build_inventory(root, source_commit="abc123", captured_at="2026-08-29T00:00:00Z")

            self.assertEqual(report["sourceCommit"], "abc123")
            self.assertEqual(report["bundle"]["shortVersion"], "test-version")
            self.assertEqual(report["summary"]["matchedAssetCount"], 3)
            self.assertEqual(
                {asset["surfaceID"] for asset in report["assets"]},
                {"panel-topology", "terminal", "thread-side-panel-tabs"},
            )
            self.assertEqual(report["assets"][0]["evidence"], "hashed renderer asset filename in app.asar header")
            self.assertEqual(report["capturedAtUTC"], "2026-08-29T00:00:00Z")


if __name__ == "__main__":
    unittest.main()
