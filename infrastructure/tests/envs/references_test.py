#!/usr/bin/env python3
"""Inline-reference integration through the real envs command and invented rbw fixtures."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
SOURCE = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else REPO / ".local/bin/envs"
TOOLS = str(REPO / "infrastructure/tests/envs/bin") + ":" + str(REPO / "infrastructure/tests/vault-browse/bin")
BOOT = "import sys,os,pathlib; p=sys.argv.pop(1); ns={'__name__':'fixture_envs','__file__':sys.argv.pop(1)}; exec(compile(open(p).read(),p,'exec'),ns); ns['HOME']=pathlib.Path(os.environ['HOME']); sys.exit(ns['main'](sys.argv[1:]))"


class References(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="envs-refs.")
        self.root = Path(self.temp.name)
        self.project = self.root / "demo"; self.project.mkdir()
        self.fake = self.root / "fake"; self.fake.mkdir()
        for name in ("run", "state", "cache", "global", "home", "config"):
            (self.root / name).mkdir(mode=0o700)
        (self.fake / "rbw.json").write_text('{"email":"example@example.test"}')
        self.vault = {"folders": [{"id": "env-folder", "name": "Env/my-project"}], "items": [
            {"id": "ref-item", "name": "dev", "type": 2, "folderId": "env-folder", "deletedDate": None,
             "notes": "invented-note-value", "fields": [{"name": "DATABASE_URL", "value": "invented-database-value", "type": 1}],
             "secureNote": {"type": 0}, "passwordHistory": [], "attachments": []}]}
        self.save_vault()
        self.env = dict(os.environ)
        self.env.update(HOME=str(self.root / "home"), XDG_CONFIG_HOME=str(self.root / "config"), PATH=TOOLS + ":/usr/bin:/bin", ENVS_TOOL_PATH=TOOLS, ENVS_TEST_ROOT_PID=str(os.getpid()),
                        XDG_RUNTIME_DIR=str(self.root / "run"), XDG_STATE_HOME=str(self.root / "state"),
                        XDG_CACHE_HOME=str(self.root / "cache"), ENVS_GLOBAL_DIR=str(self.root / "global"),
                        FAKE_DIR=str(self.fake), VAULT_RBW_CONF=str(self.fake / "rbw.json"),
                        ENVS_TEST_YES="1", RBW_BIN="rbw", BW_BIN="bw")
        for name in ("DISPLAY", "WAYLAND_DISPLAY", "CLAUDECODE", "__MISE_DIFF", "__MISE_SESSION"):
            self.env.pop(name, None)

    def tearDown(self):
        self.temp.cleanup()

    def save_vault(self):
        (self.fake / "vault.json").write_text(json.dumps(self.vault))
        (self.fake / "rbw-view.json").unlink(missing_ok=True)

    def run_envs(self, *args, env=None):
        return subprocess.run([sys.executable, "-I", "-B", "-c", BOOT, str(SOURCE), str(REPO / ".local/bin/envs"), *args],
                              cwd=self.project, env=env or self.env, capture_output=True, text=True, timeout=15)

    def ref_file(self, text="DATABASE_URL=bw://Env/my-project/dev#DATABASE_URL\nAPP_PORT=8080\n"):
        (self.project / ".env").write_text(text)

    def log(self):
        path = self.fake / "argv.log"
        return path.read_text() if path.exists() else ""

    def assert_safe(self, result):
        self.assertNotIn("invented-database-value", result.stdout + result.stderr)
        self.assertNotIn("invented-note-value", result.stdout + result.stderr)

    def test_metadata_without_toml_no_vault_calls(self):
        self.ref_file()
        for args in (("status", "--json"), ("check",), ("refs", "list")):
            with self.subTest(args=args):
                result = self.run_envs(*args)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertIn("DATABASE_URL", result.stdout)
                self.assertNotIn("Env/my-project", result.stdout)
                self.assertEqual("", self.log())
                self.assert_safe(result)
        self.assertFalse((self.project / ".envs.toml").exists())

    def test_refs_set_preserves_plain_and_refuses_literal(self):
        self.ref_file("# comment\r\nAPP_PORT = 8080 # unchanged\r\n")
        result = self.run_envs("refs", "set", "--file", ".env", "DATABASE_URL", "bw://Env/my-project/dev#DATABASE_URL")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue((self.project / ".env").read_bytes().startswith(b"# comment\r\nAPP_PORT = 8080 # unchanged\r\n"))
        self.assertEqual("", self.log())
        self.ref_file("DATABASE_URL=invented-database-value\n")
        result = self.run_envs("refs", "set", "DATABASE_URL", "bw://Env/my-project/dev#DATABASE_URL")
        self.assertEqual(4, result.returncode)
        self.assertIn("owner must run envs import", result.stderr)
        self.assert_safe(result)
        self.assertEqual("", self.log())

    def test_duplicate_and_reserved_references_fail_before_vault(self):
        for text in ("DATABASE_URL=bw://Env/my-project/dev#DATABASE_URL\nDATABASE_URL=literal\n",
                     "PATH=bw://Env/my-project/dev#DATABASE_URL\n",
                     "DATABASE_URL=bw://Env/my-project/dev#@totp\n"):
            with self.subTest(text=text):
                self.ref_file(text)
                result = self.run_envs("status", "--json")
                self.assertEqual(4, result.returncode)
                self.assertEqual("", self.log())
                self.assert_safe(result)

    def test_bind_pins_metadata_without_getting_values(self):
        self.ref_file()
        result = self.run_envs("bind", "--yes")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("targets authorized", result.stdout)
        self.assertIn("rbw list --raw", self.log())
        self.assertNotIn("rbw get", self.log())
        path = self.root / "state/envs/ref-policies.json"
        self.assertEqual(0o600, path.stat().st_mode & 0o777)
        self.assertNotIn("invented-database-value", path.read_text())
        self.assert_safe(result)

    def assert_child(self, expected="invented-database-value"):
        script = self.root / "assert-child.py"
        script.write_text("import os,sys\nsys.exit(0 if os.environ.get('DATABASE_URL') == " + repr(expected) + " and os.environ.get('ENVS_SECRETS') == 'DATABASE_URL' else 7)\n")
        return ["/usr/bin/python3", "-I", "-B", str(script)]

    def test_authorized_reference_runs_automatically_and_rotates(self):
        self.ref_file()
        result = self.run_envs("run", "--no-mise", "--", *self.assert_child())
        self.assertEqual(4, result.returncode)
        self.assertEqual("", self.log())
        self.assertEqual(0, self.run_envs("bind", "--yes").returncode)
        self.env["DATABASE_URL"] = "stale-parent-value"
        result = self.run_envs("run", "--no-mise", "--", *self.assert_child())
        self.assertEqual(0, result.returncode, result.stderr)
        self.assert_safe(result)
        self.vault["items"][0]["fields"][0]["value"] = "invented-rotated-value"
        self.save_vault()
        result = self.run_envs("run", "--no-mise", "--", *self.assert_child("invented-rotated-value"))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertNotIn("invented-rotated-value", result.stdout + result.stderr)
        self.assertNotIn("invented-rotated-value", self.log())

    def test_mapping_or_item_identity_change_requires_reapproval(self):
        self.ref_file()
        self.assertEqual(0, self.run_envs("bind", "--yes").returncode)
        mark = len(self.log())
        self.ref_file("DATABASE_URL=bw://Env/my-project/dev#@notes\n")
        result = self.run_envs("run", "--no-mise", "--", *self.assert_child())
        self.assertEqual(4, result.returncode)
        self.assertIn("policy changed", result.stderr)
        self.assertEqual("", self.log()[mark:])
        self.ref_file()
        # Restoring spelling still changes the approved source snapshot; explicitly
        # reapprove it before isolating the same-name replacement UUID regression.
        self.assertEqual(0, self.run_envs("bind", "--yes").returncode)
        self.vault["items"][0]["id"] = "replacement-item"
        self.save_vault()
        mark = len(self.log())
        result = self.run_envs("run", "--no-mise", "--", *self.assert_child())
        self.assertEqual(4, result.returncode)
        self.assertIn("identity changed", result.stderr)
        self.assertNotIn("rbw get", self.log()[mark:])
        self.assert_safe(result)

    def test_protected_source_cannot_be_bound_as_dev(self):
        self.ref_file()
        (self.project / ".env.prod").write_text("DATABASE_URL=bw://Env/my-project/dev#DATABASE_URL\n")
        result = self.run_envs("bind", "--yes", "--ref-file", ".env.prod")
        self.assertEqual(4, result.returncode)
        self.assertIn("protected source", result.stderr)
        self.assertNotIn("rbw get", self.log())
        self.assertFalse((self.root / "state/envs/ref-sources.json").exists())

    def test_unsafe_source_paths_are_rejected(self):
        self.ref_file()
        target = self.project / ".env"; linked = self.project / "linked"; linked.symlink_to(target)
        result = self.run_envs("refs", "set", "--file", "linked", "DATABASE_URL", "bw://Env/my-project/dev#DATABASE_URL")
        self.assertEqual(4, result.returncode)
        self.assertEqual("", self.log())
    def test_builtin_and_custom_same_spelling_project_only_selected_values(self):
        self.vault["folders"].append({"id": "fixture-folder", "name": "Fixture Vault"})
        self.vault["items"].append({"id": "fixture-login", "name": "entry", "type": 1, "folderId": "fixture-folder",
                                   "login": {"username": "fixture-user", "password": "fixture-login-password", "uris": []},
                                   "fields": [{"name": "password", "value": "fixture-custom-password", "type": 1}],
                                   "deletedDate": None, "attachments": [], "passwordHistory": []})
        self.save_vault()
        self.ref_file("CUSTOM=bw://Fixture%20Vault/entry#field:password\nBUILTIN=bw://Fixture%20Vault/entry#@password\n")
        self.assertEqual(0, self.run_envs("bind", "--yes").returncode)
        script = self.project / "assert-projection.py"
        script.write_text("import os\nassert os.environ['CUSTOM']=='fixture-custom-password'\nassert 'BUILTIN' not in os.environ\nassert os.environ['ENVS_SECRETS']=='CUSTOM'\n")
        mark = len(self.log())
        result = self.run_envs("run", "--no-mise", "--only", "CUSTOM", "--", "/usr/bin/python3", str(script))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(1, self.log()[mark:].count("rbw get --raw fixture-login"))
        for value in ("fixture-login-password", "fixture-custom-password"):
            self.assertNotIn(value, result.stdout + result.stderr + self.log()[mark:])

    def test_source_identity_change_fails_before_any_backend_call(self):
        self.ref_file(); self.assertEqual(0, self.run_envs("bind", "--yes").returncode)
        self.ref_file("DATABASE_URL=bw://Env/my-project/dev#DATABASE_URL\nAPP_PORT=9090\n")
        mark = len(self.log())
        result = self.run_envs("run", "--no-mise", "--", "/usr/bin/true")
        self.assertEqual(4, result.returncode)
        self.assertIn("policy changed", result.stderr)
        self.assertEqual("", self.log()[mark:])

    def test_credential_locations_fifo_and_hardlinks_fail_without_backend(self):
        self.ref_file()
        for directory in (".git", ".config/rbw"):
            path = self.project / directory; path.mkdir(parents=True, exist_ok=True)
            target = path / "fake.env"; target.write_text("DATABASE_URL=bw://Env/my-project/dev#DATABASE_URL\n")
            result = self.run_envs("refs", "set", "--file", str(target.relative_to(self.project)), "DATABASE_URL", "bw://Env/my-project/dev#DATABASE_URL")
            self.assertEqual(4, result.returncode)
            self.assertIn("credential location", result.stderr)
        fifo = self.project / "fifo.env"; os.mkfifo(fifo)
        hard = self.project / "hard.env"; os.link(self.project / ".env", hard)
        for target in (fifo, hard):
            result = self.run_envs("refs", "set", "--file", target.name, "DATABASE_URL", "bw://Env/my-project/dev#DATABASE_URL")
            self.assertEqual(4, result.returncode)
        self.assertEqual("", self.log())

    def test_no_partial_launch_on_missing_second_selected_field(self):
        self.ref_file("DATABASE_URL=bw://Env/my-project/dev#DATABASE_URL\nMISSING=bw://Env/my-project/dev#MISSING\n")
        self.assertEqual(0, self.run_envs("bind", "--yes").returncode)
        marker = self.project / "launched"
        result = self.run_envs("run", "--no-mise", "--", "/usr/bin/touch", str(marker))
        self.assertEqual(4, result.returncode)
        self.assertFalse(marker.exists())
        self.assert_safe(result)

    def test_agent_vault_opt_in_is_refused_before_sources_or_backend(self):
        self.ref_file("BROKEN=$(fixture-danger)\n")
        env = dict(self.env, CLAUDECODE="1")
        for args in (("status", "--vault", "--json"), ("check", "--vault"), ("check", "--vault", "--all")):
            result = self.run_envs(*args, env=env)
            self.assertEqual(4, result.returncode)
            self.assertIn("refused inside an agent", result.stderr)
            self.assertNotIn("unsupported shell", result.stderr)
            self.assertEqual("", self.log())

    def test_source_controls_refused_without_raw_terminal_output(self):
        self.ref_file()
        for name in ("fixture\x85.env", "fixture\u202e.env", "fixture\u2028.env", "fixture\u2029.env"):
            result = self.run_envs("refs", "set", "--file", name, "DATABASE_URL", "bw://Env/my-project/dev#DATABASE_URL")
            self.assertEqual(4, result.returncode)
            self.assertNotIn(name, result.stdout + result.stderr)
        self.assertEqual("", self.log())



if __name__ == "__main__":
    unittest.main()
