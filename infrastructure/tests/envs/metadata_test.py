#!/usr/bin/env python3
"""Metadata doctor never opens a dotenv source payload, including FIFO/stale paths."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("envs_metadata", REPO / ".config/envs/metadata.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


class Metadata(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="envs-metadata.")
        self.home = Path(self.temp.name)
        (self.home / ".config/envs").mkdir(parents=True, mode=0o700)
        (self.home / ".local/state/envs").mkdir(parents=True, mode=0o700)

    def tearDown(self):
        self.temp.cleanup()

    def test_unconfigured_is_info_and_unsafe_global_map_is_fail(self):
        self.assertFalse(any(row[0] == "FAIL" for row in m.inspect(self.home, REPO)))
        path = self.home / ".config/envs/global.env"; path.write_text("FIXTURE=never-read-value\n"); path.chmod(0o644)
        result = m.inspect(self.home, REPO)
        self.assertTrue(any(row[0] == "FAIL" for row in result))
        self.assertNotIn("never-read-value", str(result))

    def test_source_identity_is_stat_only_and_changed_file_is_stale(self):
        project = self.home / "fixture-project"; project.mkdir()
        source = project / ".env"; source.write_text("TOKEN=never-read-fixture-secret\n")
        identity = list(m.D._identity(source.stat()))
        path = self.home / ".local/state/envs/ref-policies.json"
        path.write_text(json.dumps({"fixture": {"root": str(project), "source_identities": {".env": identity}}})); path.chmod(0o600)
        original = m.D.read_document
        def metadata_only(path, *args, **kwargs):
            self.assertNotEqual(source, Path(path), "doctor opened source content")
            return original(path, *args, **kwargs)
        with mock.patch.object(m.D, "read_document", side_effect=metadata_only):
            result = m.inspect(self.home, REPO)
            self.assertFalse(any(row[0] == "FAIL" for row in result))
            source.write_text("TOKEN=owner-concurrent-fixture\n")
            result = m.inspect(self.home, REPO)
            self.assertTrue(any(row[0] == "FAIL" and "source metadata changed" in row[2] for row in result))
        self.assertNotIn("never-read-fixture-secret", str(result))

    def test_state_and_wrapper_symlinks_refused_without_target_payload(self):
        outside = self.home / "outside"; outside.write_text("fixture-private-data")
        (self.home / ".config/envs/wrap.tsv").symlink_to(outside)
        (self.home / ".local/state/envs/agent-approvals.json").symlink_to(outside)
        result = m.inspect(self.home, REPO)
        self.assertGreaterEqual(sum(row[0] == "FAIL" for row in result), 2)
        self.assertNotIn("fixture-private-data", str(result))


if __name__ == "__main__":
    unittest.main()
