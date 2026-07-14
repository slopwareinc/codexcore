#!/usr/bin/env python3
"""Validate reviewed handwritten/generated protocol overlap and structure."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_HANDWRITTEN = ROOT / "Sources/CodexCore/Protocol/V2Types.swift"
DEFAULT_GENERATED = ROOT / "Sources/CodexCore/Generated/AppServerSchemaTypes.swift"
DEFAULT_INVENTORY = ROOT / "Tools/handwritten_protocol_compatibility.json"
DEFAULT_FINGERPRINTS = ROOT / "Tools/handwritten_protocol_structural_fingerprints.json"
CATEGORIES = {"explicitAdapters", "reviewedExactWire", "legacyCompatibility"}
DECLARATION = re.compile(
    r"^public\s+(struct|enum)\s+([A-Za-z0-9_]+)[^{]*\{|"
    r"^public\s+(typealias)\s+([A-Za-z0-9_]+)\s*=\s*([^\n]+)",
    re.MULTILINE,
)
FIELD = re.compile(r"^\s*public\s+var\s+(`?[A-Za-z0-9_]+`?)\s*:\s*([^=\n]+?)(?:\s*=.*)?$", re.MULTILINE)
CODING_KEYS = re.compile(r"(?:private\s+)?enum\s+CodingKeys\s*:\s*String\s*,\s*CodingKey\s*\{")
CASE_LINE = re.compile(r"^\s*case\s+(.+?)\s*$", re.MULTILINE)
ENUM_CASE = re.compile(r"^(`?[A-Za-z0-9_]+`?)(?:\s*=\s*\"([^\"]*)\")?$")


def normalize_type(value: str) -> str:
    return re.sub(r"\s+", " ", value.strip())


def matching_brace(text: str, opening: int) -> int:
    depth = 0
    in_string = False
    escaped = False
    for index in range(opening, len(text)):
        character = text[index]
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            continue
        if character == '"':
            in_string = True
        elif character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return index
    raise ValueError(f"Unbalanced declaration body beginning at byte {opening}")


def declaration_bodies(text: str) -> dict[str, tuple[str, str]]:
    result: dict[str, tuple[str, str]] = {}
    for match in DECLARATION.finditer(text):
        if match.group(3) == "typealias":
            result[match.group(4)] = ("typealias", normalize_type(match.group(5)))
            continue
        kind = match.group(1)
        name = match.group(2)
        opening = text.find("{", match.start(), match.end())
        closing = matching_brace(text, opening)
        result[name] = (kind, text[opening + 1 : closing])
    return result


def coding_keys(body: str) -> dict[str, str]:
    match = CODING_KEYS.search(body)
    if match is None:
        return {}
    opening = body.find("{", match.start(), match.end())
    closing = matching_brace(body, opening)
    result: dict[str, str] = {}
    for case_match in CASE_LINE.finditer(body[opening + 1 : closing]):
        for entry in case_match.group(1).split(","):
            parsed = ENUM_CASE.fullmatch(entry.strip())
            if parsed is not None:
                name = parsed.group(1).strip("`")
                result[name] = parsed.group(2) or name
    return result


def signature(kind: str, body: str) -> dict[str, Any]:
    if kind == "typealias":
        return {"kind": kind, "target": body}
    if kind == "struct":
        keys = coding_keys(body)
        fields = []
        for match in FIELD.finditer(body):
            name = match.group(1).strip("`")
            fields.append(
                {
                    "name": name,
                    "type": normalize_type(match.group(2)),
                    "codingKey": keys.get(name, name),
                }
            )
        return {"kind": kind, "fields": sorted(fields, key=lambda field: field["name"])}

    cases = []
    for match in CASE_LINE.finditer(body):
        for entry in match.group(1).split(","):
            parsed = ENUM_CASE.fullmatch(entry.strip())
            if parsed is not None:
                name = parsed.group(1).strip("`")
                cases.append({"name": name, "rawValue": parsed.group(2)})
    return {"kind": kind, "cases": sorted(cases, key=lambda case: case["name"])}


def signatures(path: Path) -> dict[str, dict[str, Any]]:
    return {
        name: signature(kind, body)
        for name, (kind, body) in declaration_bodies(path.read_text()).items()
    }


def describe_exact_wire_drift(name: str, handwritten: dict[str, Any], generated: dict[str, Any]) -> str:
    if handwritten.get("kind") != generated.get("kind"):
        return f"Declaration kind drift for {name}"
    if handwritten["kind"] != "struct":
        return f"Structural drift for {name}"

    handwritten_fields = {field["name"]: field for field in handwritten["fields"]}
    generated_fields = {field["name"]: field for field in generated["fields"]}
    if handwritten_fields.keys() != generated_fields.keys():
        return f"Field drift for {name}"
    for field_name in sorted(handwritten_fields):
        if handwritten_fields[field_name]["type"] != generated_fields[field_name]["type"]:
            return f"Field drift for {name}: {field_name} type changed"
        if handwritten_fields[field_name]["codingKey"] != generated_fields[field_name]["codingKey"]:
            return f"CodingKey drift for {name}: {field_name} changed"
    return f"Structural drift for {name}"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--handwritten", type=Path, default=DEFAULT_HANDWRITTEN)
    parser.add_argument("--generated", type=Path, default=DEFAULT_GENERATED)
    parser.add_argument("--inventory", type=Path, default=DEFAULT_INVENTORY)
    parser.add_argument("--fingerprints", type=Path, default=None)
    parser.add_argument("--write-fingerprints", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    inventory = json.loads(args.inventory.read_text())
    if set(inventory) != CATEGORIES:
        print(f"Compatibility inventory categories must be {sorted(CATEGORIES)}", file=sys.stderr)
        return 1

    listed = [name for category in CATEGORIES for name in inventory[category]]
    duplicates = sorted({name for name in listed if listed.count(name) > 1})
    if duplicates:
        print(f"Duplicate compatibility inventory entries: {', '.join(duplicates)}", file=sys.stderr)
        return 1

    handwritten = signatures(args.handwritten)
    generated_prefixed = signatures(args.generated)
    generated = {
        name.removeprefix("CodexSchema"): value
        for name, value in generated_prefixed.items()
        if name.startswith("CodexSchema")
    }
    overlap = set(handwritten) & set(generated)
    listed_set = set(listed)
    missing = sorted(overlap - listed_set)
    stale = sorted(listed_set - overlap)
    if missing or stale:
        if missing:
            print(f"Unreviewed handwritten/generated overlaps: {', '.join(missing)}", file=sys.stderr)
        if stale:
            print(f"Stale compatibility inventory entries: {', '.join(stale)}", file=sys.stderr)
        return 1

    for name in inventory["reviewedExactWire"]:
        if handwritten[name] != generated[name]:
            print(describe_exact_wire_drift(name, handwritten[name], generated[name]), file=sys.stderr)
            return 1

    current_fingerprints = {name: generated[name] for name in sorted(listed_set)}
    if args.write_fingerprints is not None:
        args.write_fingerprints.write_text(
            json.dumps({"version": 1, "generated": current_fingerprints}, indent=2, sort_keys=True) + "\n"
        )
        print(f"Wrote structural fingerprints for {len(current_fingerprints)} generated overlaps.")
        return 0

    fingerprint_path = args.fingerprints
    if fingerprint_path is None and args.handwritten == DEFAULT_HANDWRITTEN and args.generated == DEFAULT_GENERATED:
        fingerprint_path = DEFAULT_FINGERPRINTS
    fingerprint_count = 0
    if fingerprint_path is not None:
        expected_document = json.loads(fingerprint_path.read_text())
        if expected_document.get("version") != 1 or set(expected_document) != {"version", "generated"}:
            print("Structural fingerprint document must have version 1 and generated entries", file=sys.stderr)
            return 1
        expected = expected_document["generated"]
        if expected != current_fingerprints:
            changed = sorted(
                name
                for name in set(expected) | set(current_fingerprints)
                if expected.get(name) != current_fingerprints.get(name)
            )
            print(
                "Generated structural fingerprint drift for: " + ", ".join(changed),
                file=sys.stderr,
            )
            return 1
        fingerprint_count = len(expected)

    print(
        "Handwritten protocol compatibility inventory matches "
        f"{len(overlap)} generated overlaps; reviewed exact-wire structures match "
        f"{len(inventory['reviewedExactWire'])} type(s); generated structural fingerprints match "
        f"{fingerprint_count} type(s)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
