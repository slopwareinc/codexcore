#!/usr/bin/env python3
"""Self-tests for structural handwritten/generated protocol compatibility."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "Tools/check_handwritten_protocol_compatibility.py"


def run_checker(
    handwritten: str,
    generated: str,
    inventory: dict[str, list[str]],
    fingerprints: dict[str, object] | None = None,
) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        handwritten_path = tmp_path / "Handwritten.swift"
        generated_path = tmp_path / "Generated.swift"
        inventory_path = tmp_path / "inventory.json"
        handwritten_path.write_text(textwrap.dedent(handwritten))
        generated_path.write_text(textwrap.dedent(generated))
        inventory_path.write_text(json.dumps(inventory))
        arguments = [
            sys.executable,
            str(CHECKER),
            "--handwritten",
            str(handwritten_path),
            "--generated",
            str(generated_path),
            "--inventory",
            str(inventory_path),
        ]
        if fingerprints is not None:
            fingerprints_path = tmp_path / "fingerprints.json"
            fingerprints_path.write_text(json.dumps(fingerprints))
            arguments.extend(["--fingerprints", str(fingerprints_path)])
        return subprocess.run(
            arguments,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )


def assert_passes(result: subprocess.CompletedProcess[str]) -> None:
    if result.returncode != 0:
        raise AssertionError(f"expected pass, got {result.returncode}\nSTDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}")


def assert_fails(result: subprocess.CompletedProcess[str], needle: str) -> None:
    if result.returncode == 0:
        raise AssertionError("expected failure")
    output = result.stdout + result.stderr
    if needle not in output:
        raise AssertionError(f"expected {needle!r} in output:\n{output}")


def test_exact_wire_field_and_coding_key_match_passes() -> None:
    result = run_checker(
        handwritten="""
        public struct Sample: Codable, Sendable, Equatable {
            public var threadID: String
            public var count: Int?

            enum CodingKeys: String, CodingKey {
                case threadID = "threadId"
                case count
            }
        }
        """,
        generated="""
        public struct CodexSchemaSample: Codable, Sendable, Equatable {
            public var threadID: String
            public var count: Int?

            enum CodingKeys: String, CodingKey {
                case threadID = "threadId"
                case count
            }
        }
        """,
        inventory={"explicitAdapters": [], "reviewedExactWire": ["Sample"], "legacyCompatibility": []},
    )
    assert_passes(result)


def test_field_type_drift_fails() -> None:
    result = run_checker(
        handwritten="""
        public struct Sample: Codable, Sendable, Equatable {
            public var threadID: String
        }
        """,
        generated="""
        public struct CodexSchemaSample: Codable, Sendable, Equatable {
            public var threadID: Int
        }
        """,
        inventory={"explicitAdapters": [], "reviewedExactWire": ["Sample"], "legacyCompatibility": []},
    )
    assert_fails(result, "Field drift for Sample")


def test_coding_key_drift_fails() -> None:
    result = run_checker(
        handwritten="""
        public struct Sample: Codable, Sendable, Equatable {
            public var threadID: String

            enum CodingKeys: String, CodingKey {
                case threadID = "threadId"
            }
        }
        """,
        generated="""
        public struct CodexSchemaSample: Codable, Sendable, Equatable {
            public var threadID: String

            enum CodingKeys: String, CodingKey {
                case threadID = "thread_id"
            }
        }
        """,
        inventory={"explicitAdapters": [], "reviewedExactWire": ["Sample"], "legacyCompatibility": []},
    )
    assert_fails(result, "CodingKey drift for Sample")


def test_adapter_generated_field_drift_fails_against_fingerprint() -> None:
    result = run_checker(
        handwritten="""
        public struct Sample: Codable, Sendable, Equatable {
            public var threadID: String
        }
        """,
        generated="""
        public struct CodexSchemaSample: Codable, Sendable, Equatable {
            public var threadID: Int
        }
        """,
        inventory={"explicitAdapters": ["Sample"], "reviewedExactWire": [], "legacyCompatibility": []},
        fingerprints={
            "version": 1,
            "generated": {
                "Sample": {
                    "kind": "struct",
                    "fields": [{"name": "threadID", "type": "String", "codingKey": "threadID"}],
                }
            },
        },
    )
    assert_fails(result, "Generated structural fingerprint drift for: Sample")


def main() -> int:
    tests = [
        test_exact_wire_field_and_coding_key_match_passes,
        test_field_type_drift_fails,
        test_coding_key_drift_fails,
        test_adapter_generated_field_drift_fails_against_fingerprint,
    ]
    for test in tests:
        test()
    print(f"{len(tests)} compatibility self-tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
