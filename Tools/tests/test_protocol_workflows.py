import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


TOOLS = Path(__file__).resolve().parents[1]


class ProtocolWorkflowTests(unittest.TestCase):
    def test_failed_regeneration_leaves_all_committed_outputs_and_pin_intact(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tools = root / "Tools"
            tools.mkdir()
            for name in ["regenerate.sh", "app_server_schema_common.sh"]:
                shutil.copyfile(TOOLS / name, tools / name)
            outputs = [
                root / "Sources/CodexCore/Generated/AppServerProtocolMethods.swift",
                root / "Sources/CodexCore/Generated/AppServerSchemaTypes.swift",
                root / "Sources/CodexCore/Generated/PinnedRuntimeVersion.swift",
                root / "Sources/CodexCore/Client/CodexSessionCommands.swift",
                tools / "UPSTREAM_VERSION",
            ]
            for output in outputs:
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_text("previous verified output\n")
            # Reproduce the actual failure mode: the first two generators write
            # successfully, then a new request fails response mapping.
            writer = (
                "import sys\nfrom pathlib import Path\n"
                "Path(sys.argv[sys.argv.index('--out') + 1]).write_text('new output')\n"
            )
            for name in ["generate_app_server_methods.py", "generate_app_server_schema_types.py"]:
                (tools / name).write_text(writer)
            (tools / "generate_app_server_requests.py").write_text("raise SystemExit(1)\n")
            binary = root / "codex"
            binary.write_text("#!/bin/sh\nexit 0\n")
            binary.chmod(0o755)
            result = subprocess.run(
                ["bash", str(tools / "regenerate.sh")],
                env={**os.environ, "CODEX_BINARY": str(binary)},
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            for output in outputs:
                self.assertEqual(output.read_text(), "previous verified output\n")

    def test_drift_override_rejects_a_different_runtime_before_generating(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tools = root / "Tools"
            tools.mkdir()
            for name in ["check_drift.sh", "app_server_schema_common.sh"]:
                shutil.copyfile(TOOLS / name, tools / name)
            (tools / "UPSTREAM_VERSION").write_text("codex-cli 0.160.0\n")
            binary = root / "codex"
            binary.write_text("#!/bin/sh\necho 'codex-cli 0.159.0'\n")
            binary.chmod(0o755)
            result = subprocess.run(
                ["bash", str(tools / "check_drift.sh")],
                env={**os.environ, "CODEX_BINARY": str(binary)},
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("requires codex-cli 0.160.0", result.stderr)
            self.assertFalse((root / ".build/protocol-generation").exists())


if __name__ == "__main__":
    unittest.main()
