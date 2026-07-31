#!/usr/bin/env python3
"""Unit tests for audit_mcp.py's fail-closed evidence parser."""
import importlib.util
import json
import pathlib
import tempfile
import unittest

MODULE = pathlib.Path(__file__).with_name("audit_mcp.py")
SPEC = importlib.util.spec_from_file_location("audit_mcp", MODULE)
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class EvidenceParserTest(unittest.TestCase):
    def test_parses_complete_group(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = pathlib.Path(directory) / "evidence"
            evidence.write_text(
                "MCP_AUDIT|stage|synth\n"
                "MCP_GROUP|paced_dsp|3|2|1|0\n"
                "MCP_OBJECT|paced_dsp|through|u_dec.hb2_stream[0]\n",
                encoding="utf-8")
            parsed = AUDIT.parse_evidence(evidence)
        self.assertEqual("synth", parsed["stage"])
        self.assertEqual(3, parsed["groups"]["paced_dsp"]["setup"])
        self.assertEqual(["u_dec.hb2_stream[0]"], parsed["groups"]["paced_dsp"]["objects"]["through"])

    def test_signature_changes_when_scope_changes(self):
        base = {"stage": "route", "groups": {"g": {"setup": 3, "hold": 2,
                "objects": {"through": ["a"], "endpoint": ["b"]}}}}
        changed = {"stage": "route", "groups": {"g": {"setup": 3, "hold": 2,
                   "objects": {"through": ["a", "c"], "endpoint": ["b"]}}}}
        self.assertNotEqual(AUDIT.signature(base), AUDIT.signature(changed))


if __name__ == "__main__":
    unittest.main()
