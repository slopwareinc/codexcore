import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "validate_transcript_widget_oracle",
    ROOT / "Tools/validate_transcript_widget_oracle.py",
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class TranscriptWidgetOracleTests(unittest.TestCase):
    def test_inventory_schema_recipes_redaction_and_docs_route(self) -> None:
        records, recipes = MODULE.validate()
        self.assertGreaterEqual(records, 15)
        self.assertGreaterEqual(recipes, 15)


if __name__ == "__main__":
    unittest.main()
