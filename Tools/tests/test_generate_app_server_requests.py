import sys
import unittest
from pathlib import Path


TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))

from generate_app_server_requests import (  # noqa: E402
    SPECIALIZED_METHODS,
    classify_parameters,
    response_type,
)


def request_arm(params: dict, *, required: bool) -> dict:
    required_fields = ["id", "method"]
    if required:
        required_fields.append("params")
    return {
        "required": required_fields,
        "properties": {"params": params},
    }


class RequestParameterShapeTests(unittest.TestCase):
    def test_login_start_requires_epoch_bound_specialized_api(self) -> None:
        self.assertIn("account/login/start", SPECIALIZED_METHODS)
        self.assertIn("account/login/cancel", SPECIALIZED_METHODS)

    def test_required_reference(self) -> None:
        self.assertEqual(
            classify_parameters(request_arm(
                {"$ref": "#/definitions/ThreadListParams"},
                required=True,
            )),
            ("required", "ThreadListParams"),
        )

    def test_omitted_null_only_member(self) -> None:
        self.assertEqual(
            classify_parameters(request_arm({"type": "null"}, required=False)),
            ("omitted", None),
        )

    def test_nullable_reference(self) -> None:
        self.assertEqual(
            classify_parameters(request_arm({
                "anyOf": [
                    {"$ref": "#/definitions/RemoteControlEnableParams"},
                    {"type": "null"},
                ],
            }, required=False)),
            ("nullable", "RemoteControlEnableParams"),
        )

    def test_unknown_optional_shape_fails_closed(self) -> None:
        with self.assertRaisesRegex(ValueError, "optional params"):
            classify_parameters(request_arm({"type": "object"}, required=False))


class ResponseMappingTests(unittest.TestCase):
    def test_default_response_stem(self) -> None:
        definitions = {"ThreadListResponse": {}}
        self.assertEqual(
            response_type(
                "thread/list",
                "ThreadListParams",
                definitions,
                {"ThreadListResponse": "CodexSchemaThreadListResponse"},
            ),
            "CodexSchemaThreadListResponse",
        )

    def test_schema_naming_exception(self) -> None:
        definitions = {"ConfigWriteResponse": {}}
        self.assertEqual(
            response_type(
                "config/value/write",
                "ConfigValueWriteParams",
                definitions,
                {"ConfigWriteResponse": "CodexSchemaConfigWriteResponse"},
            ),
            "CodexSchemaConfigWriteResponse",
        )

    def test_hand_written_response_type(self) -> None:
        self.assertEqual(
            response_type("fuzzyFileSearch", "FuzzyFileSearchParams", {}, {}),
            "FuzzyFileSearchResponse",
        )


if __name__ == "__main__":
    unittest.main()
