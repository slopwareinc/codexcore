import sys
import unittest
from pathlib import Path


TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))

from generate_app_server_schema_types import (  # noqa: E402
    CLOSED_STRING_ENUMS,
    emit_enum,
    emit_open_enum,
    is_open_string_enum,
    reachable_definitions,
    tagged_union_arms,
    validate_closed_string_enum_policy,
)


def arm(tag: str, *, required_type: bool = True) -> dict:
    return {
        "type": "object",
        "title": f"{tag.title()}Payload",
        "required": ["type"] if required_type else [],
        "properties": {
            "type": {"type": "string", "enum": [tag]},
        },
    }


class TaggedUnionValidationTests(unittest.TestCase):
    def test_accepts_unique_required_string_discriminators(self) -> None:
        self.assertEqual(
            [tag for tag, _ in tagged_union_arms("Example", {"oneOf": [arm("one"), arm("two")]})],
            ["one", "two"],
        )

    def test_rejects_duplicate_discriminators(self) -> None:
        with self.assertRaisesRegex(ValueError, "duplicate discriminator"):
            tagged_union_arms("Example", {"oneOf": [arm("same"), arm("same")]})

    def test_rejects_normalized_case_collisions(self) -> None:
        with self.assertRaisesRegex(ValueError, "colliding Swift case"):
            tagged_union_arms("Example", {"oneOf": [arm("future-value"), arm("future_value")]})

    def test_rejects_missing_required_discriminator(self) -> None:
        with self.assertRaisesRegex(ValueError, "must require a type property"):
            tagged_union_arms("Example", {"oneOf": [arm("one", required_type=False)]})

    def test_rejects_non_object_arms(self) -> None:
        with self.assertRaisesRegex(ValueError, "must be an inline object"):
            tagged_union_arms("Example", {"oneOf": [{"type": "string", "enum": ["one"]}]})


class StringEnumPolicyTests(unittest.TestCase):
    def test_forward_compatible_protocol_enums_are_open_by_default(self) -> None:
        for name in (
            "ApprovalsReviewer",
            "EnvironmentStatusKind",
            "HookEventName",
            "McpServerStartupState",
            "ModelRerouteReason",
        ):
            with self.subTest(name=name):
                self.assertTrue(is_open_string_enum(name))

    def test_caller_selected_operation_enums_remain_closed(self) -> None:
        self.assertIn("McpServerStatusDetail", CLOSED_STRING_ENUMS)
        self.assertIn("MergeStrategy", CLOSED_STRING_ENUMS)
        self.assertFalse(is_open_string_enum("McpServerStatusDetail"))
        self.assertFalse(is_open_string_enum("MergeStrategy"))

    def test_open_emission_preserves_unknown_wire_values(self) -> None:
        output = emit_open_enum("ExampleStatus", ["ready", "pending"])
        self.assertIn("Hashable", output)
        self.assertIn("case unrecognized(String)", output)
        self.assertIn("default: self = .unrecognized(rawValue)", output)
        self.assertIn("case .unrecognized(let value): value", output)

    def test_closed_emission_rejects_unknown_wire_values(self) -> None:
        output = emit_enum("ExampleOperation", ["replace", "upsert"])
        self.assertNotIn("unrecognized", output)
        self.assertIn("enum ExampleOperation: String", output)

    def test_rejects_duplicate_or_colliding_enum_values(self) -> None:
        with self.assertRaisesRegex(ValueError, "duplicate enum wire values"):
            emit_open_enum("ExampleStatus", ["ready", "ready"])
        with self.assertRaisesRegex(ValueError, "collide as Swift case"):
            emit_open_enum("ExampleStatus", ["future-value", "future_value"])

    def test_rejects_open_enum_member_collisions(self) -> None:
        for value in ("allCases", "rawValue", "unrecognized"):
            with self.subTest(value=value):
                with self.assertRaisesRegex(ValueError, "conflicts with generated member"):
                    emit_open_enum("ExampleStatus", [value])

    def test_rejects_stale_closed_enum_exception(self) -> None:
        with self.assertRaisesRegex(ValueError, "missing closed string enums"):
            validate_closed_string_enum_policy(
                {"KnownEnum"},
                set(),
                frozenset({"RemovedEnum"}),
            )

    def test_rejects_closed_enum_that_becomes_inbound(self) -> None:
        definitions = {
            "Response": {"properties": {"mode": {"$ref": "#/definitions/RequestMode"}}},
            "RequestMode": {"type": "string", "enum": ["one", "two"]},
        }
        inbound = reachable_definitions({"Response"}, definitions)
        with self.assertRaisesRegex(ValueError, "reachable from inbound schemas"):
            validate_closed_string_enum_policy(
                {"RequestMode"},
                inbound,
                frozenset({"RequestMode"}),
            )


if __name__ == "__main__":
    unittest.main()
