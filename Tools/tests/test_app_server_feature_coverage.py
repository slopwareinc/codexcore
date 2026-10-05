"""Check workflow ownership against the committed pinned protocol inventory.

This is a drift and evidence check, not a substitute for the linked behavioral
tests or live host validation. A generated factory alone cannot establish an app
workflow; upstream internal mock and Windows capability boundaries are explicit.
"""

from collections import Counter
import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
LEDGER = ROOT / "docs/reference/app-server-feature-coverage.json"
METHODS = ROOT / "Sources/CodexCore/Generated/AppServerProtocolMethods.swift"
ENUMS = {
    "clientMethods": "CodexAppServerClientMethod",
    "notifications": "CodexAppServerNotificationMethod",
    "serverRequests": "CodexAppServerServerRequestMethod",
}


def generated_inventory(source, name):
    match = re.search(r"public enum " + re.escape(name) + r":.*?\n\}", source, re.S)
    if match is None:
        raise AssertionError("Generated inventory enum is missing: " + name)
    return re.findall(r'case\s+\w+\s*=\s*"([^"]+)"', match.group())


class AppServerFeatureCoverageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ledger = json.loads(LEDGER.read_text())
        cls.workflows = cls.ledger["workflows"]

    def test_exact_pinned_method_event_and_request_inventory(self):
        self.assertEqual(self.ledger["schemaVersion"], 1)
        self.assertEqual(self.ledger["upstreamVersion"], (ROOT / "Tools/UPSTREAM_VERSION").read_text().strip())
        source = METHODS.read_text()
        for key, enum in ENUMS.items():
            with self.subTest(inventory=key):
                expected = generated_inventory(source, enum)
                owned = [method for workflow in self.workflows for method in workflow[key]]
                self.assertEqual(len(expected), len(set(expected)), "Duplicate generated method")
                self.assertEqual(len(expected), self.ledger["inventory"][key])
                self.assertEqual(set(owned), set(expected), "Missing or obsolete workflow inventory")
                self.assertFalse([value for value, count in Counter(owned).items() if count != 1],
                                 "Each protocol entry needs one primary workflow owner")

    def test_every_owner_and_test_has_existing_source_evidence(self):
        ids = [workflow["id"] for workflow in self.workflows]
        self.assertEqual(len(ids), len(set(ids)))
        allowed = {"app-workflow", "sdk-workflow", "host-extension", "platform-capability", "internal-only"}
        for workflow in self.workflows:
            with self.subTest(workflow=workflow["id"]):
                self.assertIn(workflow["coverage"], allowed)
                self.assertTrue(workflow["title"].strip())
                self.assertTrue(workflow["evidence"])
                self.assertTrue(workflow["tests"])
                for owner in workflow["evidence"]:
                    path = self.source_path(owner["path"], "Sources/")
                    self.assertIn(owner["role"], {"owner", "entrypoint", "protocol"})
                    self.assertTrue(owner["symbols"])
                    source = path.read_text()
                    for symbol in owner["symbols"]:
                        self.assertGreater(len(symbol), 3)
                        self.assertIn(symbol, source, f"Owner symbol disappeared: {owner['path']}: {symbol}")
                for test in workflow["tests"]:
                    self.source_path(test, "Tests/")

    def test_generated_factories_do_not_count_as_app_workflows(self):
        for workflow in self.workflows:
            with self.subTest(workflow=workflow["id"]):
                owners = workflow["evidence"]
                production = [owner for owner in owners if "/Generated/" not in owner["path"]
                              and not owner["path"].endswith("/CodexSessionCommands.swift")
                              and owner["role"] != "protocol"]
                if workflow["coverage"] == "app-workflow":
                    self.assertTrue(any(owner["path"].startswith(("Sources/CodexCoreApp/", "Sources/CodexCoreUI/"))
                                        for owner in production), "App claim needs a real host/UI owner")
                elif workflow["coverage"] != "internal-only":
                    self.assertTrue(production, "Generated methods alone do not provide a workflow")
                else:
                    self.assertEqual(workflow["clientMethods"], ["mock/experimentalMethod"])
                    self.assertEqual(workflow["notifications"], [])
                    self.assertEqual(workflow["serverRequests"], [])

    def test_platform_and_external_host_boundaries_are_explicit(self):
        groups = {workflow["id"]: workflow for workflow in self.workflows}
        windows = groups["windows-sandbox"]
        self.assertEqual(windows["coverage"], "platform-capability")
        self.assertEqual(set(windows["clientMethods"]), {"windowsSandbox/setupStart", "windowsSandbox/readiness"})
        self.assertEqual(set(windows["notifications"]), {"windows/worldWritableWarning", "windowsSandbox/setupCompleted"})
        self.assertEqual(groups["realtime-pcm"]["coverage"], "sdk-workflow")
        self.assertEqual(groups["external-token-refresh"]["coverage"], "host-extension")
        self.assertIn("reference app", groups["external-token-refresh"]["notes"])
        self.assertEqual(groups["out-of-band-elicitation"]["coverage"], "sdk-workflow")

    def source_path(self, value, prefix):
        path = Path(value)
        self.assertFalse(path.is_absolute())
        self.assertNotIn("..", path.parts)
        self.assertTrue(value.startswith(prefix))
        absolute = ROOT / path
        self.assertTrue(absolute.is_file(), f"Missing source evidence: {value}")
        return absolute


if __name__ == "__main__":
    unittest.main()
