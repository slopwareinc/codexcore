import pathlib
import tempfile
import unittest

from generate_pinned_runtime_version import render


class GeneratePinnedRuntimeVersionTests(unittest.TestCase):
    def test_renders_compiled_version_from_upstream_descriptor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            version_file = pathlib.Path(temporary_directory) / "UPSTREAM_VERSION"
            version_file.write_text("codex-cli 0.145.0-alpha.20\n", encoding="utf-8")

            generated = render(version_file)

        self.assertIn('public static let version = "0.145.0-alpha.20"', generated)
        self.assertIn('public static let descriptor = "codex-cli 0.145.0-alpha.20"', generated)

    def test_rejects_an_unstructured_descriptor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            version_file = pathlib.Path(temporary_directory) / "UPSTREAM_VERSION"
            version_file.write_text("0.145.0-alpha.20\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "codex-cli <version>"):
                render(version_file)


if __name__ == "__main__":
    unittest.main()
