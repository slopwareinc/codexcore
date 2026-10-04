import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from generate_app_server_methods import load_methods, emit_enum


def arm(value):
    return {"properties": {"method": {"enum": value}}}


class MethodInventoryTests(unittest.TestCase):
    def load(self, value):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ClientRequest.json"
            path.write_text(json.dumps(value))
            return load_methods(path)

    def test_preserves_schema_order(self):
        self.assertEqual(self.load({"oneOf": [arm(["turn/settings/update"]), arm(["thread/start"])]}),
                         ["turn/settings/update", "thread/start"])

    def test_rejects_missing_or_empty_inventory(self):
        for value in ({}, {"oneOf": []}, {"oneOf": {}}, []):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "nonempty oneOf"):
                self.load(value)

    def test_rejects_every_malformed_arm_instead_of_silently_omitting_it(self):
        for value in ({}, None, {"properties": []}, arm([]), arm(["a", "b"]), arm([None]), arm([""])):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, r"oneOf\[1\]"):
                self.load({"oneOf": [arm(["thread/start"]), value]})

    def test_rejects_duplicate_methods(self):
        with self.assertRaisesRegex(ValueError, "duplicate method"):
            self.load({"oneOf": [arm(["thread/start"]), arm(["thread/start"])]})

    def test_rejects_swift_case_collisions(self):
        with self.assertRaisesRegex(ValueError, "case collision"):
            emit_enum("Methods", ["thread/start", "thread_start"])
