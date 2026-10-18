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
        self.binary.write_text('#!/usr/bin/python3 -IB\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n')
        self.binary.chmod(0o755)
        self.command = self.home / "command with spaces"
        self.command.write_text("#!/bin/sh\nexit 0\n"); self.command.chmod(0o755)
        self.safe = self.home / 'refusal-bin'; self.safe.mkdir(mode=0o700)
        for name in ('fzf-menu', 'ghostty', 'notify-send', 'hyprctl', 'wl-copy'):
            fake = self.safe / name; fake.write_text('#!/bin/sh\nexit 97\n'); fake.chmod(0o700)
        self.env = {'HOME': str(self.home), 'PATH': str(self.safe) + ':/usr/bin:/bin'}
        for name, directory in (('XDG_CONFIG_HOME', self.home / '.config'),
                                ('XDG_STATE_HOME', self.home / '.state'),
                                ('XDG_CACHE_HOME', self.home / '.cache'),
                                ('XDG_DATA_HOME', self.home / '.data'),
                                ('XDG_RUNTIME_DIR', self.home / '.runtime')):
            directory.mkdir(mode=0o700, exist_ok=True); self.env[name] = str(directory)

    def tearDown(self):
        self.temp.cleanup()

    def load(self, tail="example 'two words'", prefix="", source=SOURCE):
        return subprocess.run(["/usr/bin/zsh", "-dfc", 'typeset -gr _ENVS_BIN=$1; ' + prefix + '; source $2; ' + tail,
                               "test", str(self.binary), str(source)], capture_output=True, text=True,
                              env=self.env)

    def rows(self, text, mode=0o600):
        path = self.config / "wrap.tsv"; path.write_text(text); path.chmod(mode)

    def publisher_source(self):
        # Root ownership/path substitutions apply to this disposable copy only.
        # The ACL principal65534 differs from the actual fixture EUID and root.
        root = self.home / 'fixture-root'
        directory = root / 'usr-managed'; directory.mkdir(parents=True)
        anchor = directory / 'devtools-owner'; anchor.write_text('fixturepublisher\n'); anchor.chmod(0o644)
        identity = root / 'id'; identity.write_text('#!/bin/sh\necho 65534\n'); identity.chmod(0o755)
        text = SOURCE.read_text()
        text = text.replace('anchor=/etc/usr-managed/devtools-owner', 'anchor=' + str(anchor))
        text = text.replace('for anchor_path in /etc /etc/usr-managed $anchor;', 'for anchor_path in ' + str(root) + ' ' + str(directory) + ' $anchor;')
        text = text.replace('anchor_st[uid] != 0', 'anchor_st[uid] != EUID')
        text = text.replace('/usr/bin/id -u', str(identity) + ' -u')
        copied = root / 'envs-wrap.zsh'; copied.write_text(text)
        return copied, anchor

    def acl(self, path, entries):
        subprocess.run(['/usr/bin/setfacl', '-m', entries, str(path)], check=True, capture_output=True)

    def managed_parents(self):
        self.acl(self.home, 'u:65534:rwx,g::r-x,m::rwx,o::---')
        self.acl(self.config.parent, 'u:65534:rwx,g::r-x,m::rwx,o::r-x')
        self.config.chmod(0o700)
        self.rows(f"example\t{self.command}\tAPI_KEY\n")

    def test_managed_publisher_acl_parents_work_without_mode_changes(self):
        self.managed_parents(); source, _ = self.publisher_source()
        before = [subprocess.check_output(['/usr/bin/getfacl', '-cpnE', str(p)]) for p in (self.home, self.config.parent)]
        result = self.load(source=source)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('API_KEY', result.stdout)
        after = [subprocess.check_output(['/usr/bin/getfacl', '-cpnE', str(p)]) for p in (self.home, self.config.parent)]
        self.assertEqual(before, after)

    def test_managed_acl_unauthorized_writers_and_private_leaf_refused(self):
        for path, entries in ((self.home, 'u:65533:rwx'), (self.config.parent, 'g::rwx'),
                              (self.config.parent, 'g:65533:rwx'), (self.home, 'o::rwx'),
                              (self.config, 'u:65534:rwx,m::rwx')):
            with self.subTest(path=path, entries=entries):
                self.managed_parents()
                # Reset only fixture ACLs between cases, then establish intended publishers.
                for parent in (self.home, self.config.parent, self.config):
                    subprocess.run(['/usr/bin/setfacl', '-b', str(parent)], check=True)
                self.managed_parents()
                if not (self.home / 'fixture-root').exists():
                    source, _ = self.publisher_source()
                self.acl(path, entries)
                result = self.load(source=source)
                self.assertNotEqual(0, result.returncode)
                self.assertNotIn('API_KEY', result.stdout)
                self.assertIn('unsafe', result.stderr)

    def test_masked_writer_retained_and_untrusted_anchor_refused(self):
        self.managed_parents(); source, anchor = self.publisher_source()
        self.acl(self.config.parent, 'u:65533:rwx,m::r-x')
        self.assertEqual(0, self.load(source=source).returncode)
        self.acl(self.config.parent, 'm::rwx')
        self.assertNotEqual(0, self.load(source=source).returncode)
        subprocess.run(['/usr/bin/setfacl', '-x', 'u:65533', str(self.config.parent)], check=True)
        anchor.chmod(0o666)
        self.assertNotEqual(0, self.load(source=source).returncode)
        anchor.chmod(0o644); anchor.write_text('invalid name\n')
        self.assertNotEqual(0, self.load(source=source).returncode)
        anchor.write_text('fixturepublisher\n'); anchor.rename(anchor.with_suffix('.kept'))
        anchor.symlink_to(anchor.with_suffix('.kept'))
        self.assertNotEqual(0, self.load(source=source).returncode)

    def test_anchor_missing_hardlink_size_parent_and_identity_fail_closed(self):
        self.managed_parents(); source, anchor = self.publisher_source()
        original = anchor.read_bytes()
        anchor.unlink()
        self.assertNotEqual(0, self.load(source=source).returncode)
        anchor.write_bytes(original); anchor.chmod(0o644)
        link = anchor.with_suffix('.hardlink'); os.link(anchor, link)
        self.assertNotEqual(0, self.load(source=source).returncode)
        link.unlink()
        anchor.write_text('x' * 65)
        self.assertNotEqual(0, self.load(source=source).returncode)
        anchor.write_bytes(original)
        anchor.parent.chmod(0o777)
        self.assertNotEqual(0, self.load(source=source).returncode)
        anchor.parent.chmod(0o755)
        identity = anchor.parent.parent / 'id'
        for value in ('not-a-uid', '4294967295', '65534\n65533'):
            identity.write_text('#!/bin/sh\nprintf %s ' + __import__('shlex').quote(value) + '\n')
            self.assertNotEqual(0, self.load(source=source).returncode)

    def test_malformed_or_unreadable_acl_refused(self):
        self.managed_parents(); source, _ = self.publisher_source()
        fake = self.home / 'fake-getfacl'
        for body in ('echo malformed; exit 0', 'exit 1'):
            fake.write_text('#!/bin/sh\n' + body + '\n'); fake.chmod(0o755)
            copied = source.with_name('broken-acl.zsh')
            copied.write_text(source.read_text().replace('/usr/bin/getfacl', str(fake)))
            result = self.load(source=copied)
            self.assertNotEqual(0, result.returncode)
            self.assertIn('unsafe', result.stderr)

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
