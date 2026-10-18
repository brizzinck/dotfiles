#!/usr/bin/env python3
"""Real zsh wrapper loading with inert executable fixtures; no shell startup files or vault."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[3] / ".config/zsh/envs-wrap.zsh"


class Wrappers(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="envs-wrap.")
        self.home = Path(self.temp.name)
        self.config = self.home / ".config/envs"; self.config.mkdir(parents=True)
        self.binary = self.home / ".local/bin/envs"; self.binary.parent.mkdir(parents=True)
        self.binary.write_text('#!/usr/bin/python3 -I\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n')
        self.binary.chmod(0o755)
        self.command = self.home / "command with spaces"
        self.command.write_text("#!/bin/sh\nexit 0\n"); self.command.chmod(0o755)

    def tearDown(self):
        self.temp.cleanup()

    def load(self, tail="example 'two words'", prefix=""):
        return subprocess.run(["/usr/bin/zsh", "-dfc", 'typeset -gr _ENVS_BIN=$1; ' + prefix + '; source $2; ' + tail,
                               "test", str(self.binary), str(SOURCE)], capture_output=True, text=True,
                              env={"PATH": "/usr/bin:/bin"})

    def rows(self, text, mode=0o600):
        path = self.config / "wrap.tsv"; path.write_text(text); path.chmod(mode)

    def test_default_and_local_literal_words(self):
        import json
        self.rows(f"example\t{self.command}\tAPI_KEY,OTHER_KEY\n")
        result = self.load("example 'two words'; glab --help")
        self.assertEqual(0, result.returncode, result.stderr)
        local, default = map(json.loads, result.stdout.splitlines())
        self.assertEqual(["run", "-g", "--only", "API_KEY,OTHER_KEY", "--", str(self.command), "two words"], local)
        self.assertEqual(["run", "-g", "--only", "GITLAB_TOKEN,GITLAB_HOST", "--", "/usr/bin/glab", "--help"], default)

    def test_local_glab_override_removes_alias_without_recursion(self):
        import json
        self.rows(f"glab\t{self.command}\tAPI_KEY\n")
        result = self.load("glab 'two words'", "alias glab='print unsafe-alias'")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(["run", "-g", "--only", "API_KEY", "--", str(self.command), "two words"], json.loads(result.stdout))

    def test_whole_file_preflight_and_hostile_fields(self):
        cases = [f"example\t{self.command}\tAPI_KEY\nenvs\t{self.command}\tAPI_KEY\n",
                 f"example\t{self.command}\tAPI_KEY\nexample\t{self.command}\tOTHER\n",
                 f"example\t{self.command}\tAPI_KEY;touch\n", f"example\t{self.command}\tAPI_KEY\textra\n",
                 f"eval\t{self.command}\tAPI_KEY\n"]
        for rows in cases:
            with self.subTest(rows=rows):
                self.rows(rows)
                result = self.load("(( $+functions[example] )) && example; exit 0")
                self.assertEqual("", result.stdout)
                self.assertIn("refused", result.stderr)

    def test_unsafe_modes_and_parent_symlinks(self):
        self.rows(f"example\t{self.command}\tAPI_KEY\n", 0o644)
        self.assertIn("unsafe", self.load().stderr)
        (self.config / "wrap.tsv").chmod(0o600)
        moved = self.home / "moved"; self.config.rename(moved); self.config.symlink_to(moved)
        self.assertIn("unsafe", self.load().stderr)


if __name__ == "__main__":
    unittest.main()
