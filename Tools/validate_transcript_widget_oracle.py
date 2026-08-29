#!/usr/bin/env python3
"""Validate the durable official transcript-widget oracle without app access."""

from __future__ import annotations

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
INVENTORY = ROOT / "docs/reference/official-transcript-widget-inventory.v1.json"
RECIPES = ROOT / "docs/reference/official-transcript-fixture-recipes.v1.json"
INDEX = ROOT / "docs/index.md"

REQUIRED = {
    "id", "family", "title", "trigger", "visual", "copyVariants", "states",
    "actions", "accessibility", "performance", "evidence", "parity",
    "acceptanceChecks", "fixtureRecipeIDs",
}
EVIDENCE_KINDS = {"bundle", "live", "public", "repo", "inference"}
CONFIDENCE = {"high", "medium", "low"}
PARITY = {"parity", "partial", "missing", "unknown"}
SHA256 = re.compile(r"^[0-9a-f]{64}$")
FORBIDDEN = ("/Users/", "file://", "01a0", "sk-proj-", "ghp_")


def load(path: pathlib.Path) -> dict:
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise AssertionError(f"{path}: root must be an object")
    return value


def validate() -> tuple[int, int]:
    inventory = load(INVENTORY)
    fixtures = load(RECIPES)
    assert inventory["schemaVersion"] == "1.0.0"
    assert fixtures["schemaVersion"] == "1.0.0"
    assert SHA256.fullmatch(inventory["bundle"]["asarSha256"])
    assert SHA256.fullmatch(inventory["bundle"]["runtimeSha256"])

    recipes = fixtures.get("recipes", [])
    recipe_ids = [recipe["id"] for recipe in recipes]
    assert len(recipe_ids) == len(set(recipe_ids)), "duplicate fixture recipe ID"
    records = inventory.get("records", [])
    record_ids = [record["id"] for record in records]
    assert len(record_ids) == len(set(record_ids)), "duplicate record ID"

    for record in records:
        missing = REQUIRED - record.keys()
        assert not missing, f"{record.get('id')}: missing {sorted(missing)}"
        assert record["parity"]["status"] in PARITY
        assert record["states"], f"{record['id']}: states must not be empty"
        assert record["acceptanceChecks"], f"{record['id']}: acceptance checks required"
        assert record["fixtureRecipeIDs"], f"{record['id']}: fixture recipe required"
        assert set(record["fixtureRecipeIDs"]) <= set(recipe_ids)
        visual = record["visual"]
        for key in ("hierarchy", "iconography", "typography", "colors", "spacing", "radius"):
            assert key in visual, f"{record['id']}: visual.{key} required"
        accessibility = record["accessibility"]
        for key in ("focus", "keyboard", "voiceOver"):
            assert key in accessibility, f"{record['id']}: accessibility.{key} required"
        performance = record["performance"]
        for key in ("lazy", "retention", "risk"):
            assert key in performance, f"{record['id']}: performance.{key} required"
        kinds = set()
        for evidence in record["evidence"]:
            assert {"kind", "location", "claim", "confidence"} <= evidence.keys()
            assert evidence["kind"] in EVIDENCE_KINDS
            assert evidence["confidence"] in CONFIDENCE
            if evidence["kind"] == "bundle":
                assert SHA256.fullmatch(evidence.get("sha256", "")), f"{record['id']}: bundle evidence needs SHA-256"
            kinds.add(evidence["kind"])
        assert "bundle" in kinds or "repo" in kinds, f"{record['id']}: needs primary evidence"

    for recipe in recipes:
        assert recipe["recordIDs"], f"{recipe['id']}: recordIDs required"
        assert set(recipe["recordIDs"]) <= set(record_ids)
        assert recipe["steps"] and recipe["assert"]

    serialized = INVENTORY.read_text() + RECIPES.read_text()
    assert not any(token in serialized for token in FORBIDDEN), "oracle contains a forbidden personal/secret marker"
    assert "reference/official-transcript-widget-oracle.md" in INDEX.read_text(), "docs/index.md route missing"
    return len(records), len(recipes)


if __name__ == "__main__":
    try:
        record_count, recipe_count = validate()
    except (AssertionError, KeyError, json.JSONDecodeError) as error:
        print(f"transcript widget oracle validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
    print(f"validated {record_count} widget/state records and {recipe_count} fixture recipes")
