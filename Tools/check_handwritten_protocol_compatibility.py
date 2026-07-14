#!/usr/bin/env python3
"""Fail when handwritten/generated protocol overlap changes without review."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HANDWRITTEN = ROOT / "Sources/CodexCore/Protocol/V2Types.swift"
GENERATED = ROOT / "Sources/CodexCore/Generated/AppServerSchemaTypes.swift"
INVENTORY = ROOT / "Tools/handwritten_protocol_compatibility.json"
CATEGORIES = {"explicitAdapters", "reviewedExactWire", "legacyCompatibility"}
DECLARATION = re.compile(r"^public (?:struct|enum|typealias) ([A-Za-z0-9_]+)", re.MULTILINE)


def declarations(path: Path) -> set[str]:
    return set(DECLARATION.findall(path.read_text()))


def main() -> int:
    inventory = json.loads(INVENTORY.read_text())
    if set(inventory) != CATEGORIES:
        print(f"Compatibility inventory categories must be {sorted(CATEGORIES)}", file=sys.stderr)
        return 1

    listed = [name for category in CATEGORIES for name in inventory[category]]
    duplicates = sorted({name for name in listed if listed.count(name) > 1})
    if duplicates:
        print(f"Duplicate compatibility inventory entries: {', '.join(duplicates)}", file=sys.stderr)
        return 1

    handwritten = declarations(HANDWRITTEN)
    generated = {
        name.removeprefix("CodexSchema")
        for name in declarations(GENERATED)
        if name.startswith("CodexSchema")
    }
    overlap = handwritten & generated
    listed_set = set(listed)
    missing = sorted(overlap - listed_set)
    stale = sorted(listed_set - overlap)
    if missing or stale:
        if missing:
            print(f"Unreviewed handwritten/generated overlaps: {', '.join(missing)}", file=sys.stderr)
        if stale:
            print(f"Stale compatibility inventory entries: {', '.join(stale)}", file=sys.stderr)
        return 1

    print(
        "Handwritten protocol compatibility inventory matches "
        f"{len(overlap)} generated overlaps."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
