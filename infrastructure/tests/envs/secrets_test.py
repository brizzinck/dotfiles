#!/usr/bin/env python3
"""SECRETS regressions with invented documents and inert backends only."""
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("envs_secrets_tests", REPO / ".config/envs/secrets.py")
s = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = s
spec.loader.exec_module(s)


class References(unittest.TestCase):
    def test_accepted_example_and_exact_folder(self):
        ref = s.parse_bw_ref("bw://Env/my-project/dev#DATABASE_URL")
        self.assertEqual(("Env/my-project", "dev", "field", "DATABASE_URL"), (ref.folder, ref.item, ref.kind, ref.field))
        self.assertEqual("bw://Env/my-project/dev#DATABASE_URL", ref.canonical)

    def test_canonical_roundtrip(self):
        cases = [("MixedCase/Sub folder", "Item+#?%", "custom field", "field"),
                 ("Shared/Env/demo", "dev", "password", "field"),
                 ("Env/demo", "dev", "password", "builtin"), ("", "Unfiled", "notes", "builtin"),
                 ("@root", "Literal folder", "FIELD", "field"), ("Env/Café", "De\u0301v", "API_KEY", "field"),
                 ("Work/*", "Exact * item", "NAME", "field")]
        for folder, item, field, kind in cases:
            with self.subTest(folder=folder, kind=kind):
                uri = s.format_bw_ref(folder, item, field, kind)
                ref = s.parse_bw_ref(uri)
                self.assertEqual(uri, ref.canonical)
                self.assertEqual(folder, ref.folder)
        self.assertEqual("bw://Env/demo/dev#FIELD", s.parse_bw_ref("bw://%45nv/demo/dev#field:%46IELD").canonical)
        self.assertNotEqual(s.parse_bw_ref("bw://@root/item#@notes").folder,
                            s.parse_bw_ref("bw://%40root/item#@notes").folder)

    def test_invalid_references(self):
        invalid = ["bw://item#KEY", "bw://Env//item#KEY", "bw://Env/../item#KEY", "bw://Env/%2e%2e/item#KEY",
                   "bw://Env/a%2Fb/item#KEY", "bw://Env/item%2Fpart#KEY", "bw://Env/item#KEY#OTHER",
                   "bw://Env/item?query#KEY", "bw://user@host/item#KEY", "bw://Env:123/item#KEY",
                   "bw://Env/item#", "bw://Env/item#@totp", "bw://Env/item#@history", "bw://Env/item#@private_key",
                   "bw://Env/plus+item#KEY", "bw://Env/item#field:%ZZ", "bw://Env/item#field:%FF",
                   "bw://Env/item#field:%00", "bw://Env/item#field:%C2%85", "bw://Env/item#field:%1F", "bw://Env/item#field:%E2%80%AE",
                   "bw://Env/it\\em#KEY", "bw://@root/sub/item#KEY", "bw://Env/%#KEY", "bw://Env/%0#KEY"]
        for uri in invalid:
            with self.subTest(uri=uri), self.assertRaises(s.Problem):
                s.parse_bw_ref(uri)
        self.assertEqual("%2e%2e", s.parse_bw_ref("bw://Env/%252e%252e#KEY").item)


class Documents(unittest.TestCase):
    def test_plain_bytes_preserved_and_duplicate_secret_spans_removed(self):
        text = '# fixture\r\nAPP_PORT = 8080 # plain\r\nexport API_KEY="invented\\nsecret"\r\n# between\r\nAPI_KEY=another-invented\r\nTAIL=unchanged'
        doc = s.DotenvDocument(text)
        uri = "bw://Env/demo/dev#API_KEY"
        out = doc.rewrite({"API_KEY": uri})
        self.assertEqual('# fixture\r\nAPP_PORT = 8080 # plain\r\nAPI_KEY=' + uri + '\r\n# between\r\nTAIL=unchanged', out)
        self.assertNotIn("invented", out)

    def test_final_duplicate_preserves_terminal_newline(self):
        for newline in ("\n", "\r\n"):
            doc = s.DotenvDocument("KEY=first" + newline + "KEY=last")
            self.assertEqual("KEY=bw://Env/item#KEY", doc.rewrite({"KEY": "bw://Env/item#KEY"}))

    def test_quoted_refs_and_multiline_literals(self):
        doc = s.DotenvDocument('DATABASE_URL="bw://Env/demo/dev#DATABASE_URL"\nAPP_PORT=8080\nSINGLE=\'a\nb\'\nDOUBLE="c\\nd"\n')
        self.assertEqual(["DATABASE_URL"], list(doc.references()))
        self.assertEqual("a\nb", doc.values()["SINGLE"])
        self.assertEqual("c\nd", doc.values()["DOUBLE"])

    def test_duplicate_reference_names(self):
        for text in ("KEY=bw://Env/demo/dev#KEY\nKEY=literal\n", "KEY=literal\nKEY=bw://Env/demo/dev#KEY\n",
                     "KEY=bw://Env/demo/dev#KEY\nKEY=bw://Env/demo/dev#KEY\n"):
            with self.subTest(text=text), self.assertRaises(s.Problem):
                s.DotenvDocument(text).references()

    def test_shell_source_dialect(self):
        for text in ("A=one B=two", "A=one echo x", "A=(one two)", "A=~", 'A="one"#suffix', "A =one", "A= one", "A=one\r\n"):
            with self.subTest(text=text), self.assertRaises(s.Problem):
                s.DotenvDocument(text, shell=True)
        self.assertEqual(r"one\ntwo", s.DotenvDocument('A="one\\ntwo"', shell=True).values()["A"])
        self.assertEqual("one\ntwo", s.DotenvDocument('A="one\\ntwo"').values()["A"])

    def test_no_shell_execution_or_partial_parse(self):
        cases = ['KEY=$(touch /must-never-exist)', 'KEY=`touch /must-never-exist`', 'KEY="${OTHER}"',
                 'KEY=literal;echo unsafe', 'KEY=literal|echo unsafe', 'KEY="unterminated', 'func() { echo unsafe; }',
                 'KEY="literal" trailing', 'KEY=\x00literal']
        for text in cases:
            with self.subTest(text=text), self.assertRaises(s.Problem) as caught:
                s.DotenvDocument("APP_PORT=8080\n" + text)
            self.assertNotIn("/must-never-exist", str(caught.exception))
            self.assertNotIn("touch", str(caught.exception))


class SafePaths(unittest.TestCase):
    def setUp(self):
        self.recovery = tempfile.TemporaryDirectory(prefix="envs-recovery-test.")
        os.chmod(self.recovery.name, 0o700)

    def tearDown(self):
        self.recovery.cleanup()

    def test_no_follow_hardlink_fifo_and_snapshot_race(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); source = root / ".env"
            source.write_text("KEY=example\n")
            snap = s.read_document(source, root)
            source.write_text("KEY=changed\n")
            with self.assertRaises(s.Problem):
                snap.replace("KEY=ref\n", recovery_dir=self.recovery.name)
            alias = root / "alias"; alias.symlink_to(source)
            with self.assertRaises(s.Problem):
                s.read_document(alias, root)
            parent = root / "parent"; parent.symlink_to(root, target_is_directory=True)
            with self.assertRaises(s.Problem):
                s.read_document(parent / ".env", root)
            link = root / "hard"; os.link(source, link)
            with self.assertRaises(s.Problem):
                s.read_document(source, root)
            fifo = root / "fifo"; os.mkfifo(fifo)
            with self.assertRaises(s.Problem):
                s.read_document(fifo, root)

    def test_exchange_preserves_concurrent_file_and_parent_edits(self):
        for mode in ("file-before", "parent-before", "file-after"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temp:
                root = Path(temp); parent = root / "project"; parent.mkdir()
                source = parent / ".env"; source.write_text("KEY=original\n")
                snap = s.read_document(source, parent)
                original = s._exchange; calls = 0
                def exchange(fd, a, b):
                    nonlocal calls
                    calls += 1
                    if calls == 1 and mode == "file-before":
                        source.write_text("KEY=concurrent-owner-edit\n")
                    if calls == 1 and mode == "parent-before":
                        parent.rename(root / "moved")
                        parent.mkdir()
                        source.write_text("KEY=concurrent-owner-edit\n")
                    original(fd, a, b)
                    if calls == 1 and mode == "file-after":
                        source.write_text("KEY=concurrent-owner-edit\n")
                s._exchange = exchange
                try:
                    with self.assertRaises(s.Problem):
                        snap.replace("KEY=rendered\n", recovery_dir=self.recovery.name)
                finally:
                    s._exchange = original
                self.assertEqual("KEY=concurrent-owner-edit\n", source.read_text())
                if mode == "parent-before":
                    self.assertEqual("KEY=original\n", (root / "moved/.env").read_text())
                if mode == "file-after":
                    retained = list(Path(self.recovery.name).glob(".envs-recovery-*/displaced.env"))
                    self.assertEqual(1, len(retained))
                    self.assertEqual("KEY=original\n", retained[0].read_text())
                    self.assertEqual(0o600, retained[0].stat().st_mode & 0o777)
                    self.assertEqual(0o700, retained[0].parent.stat().st_mode & 0o777)

    def test_cross_filesystem_recovery_and_required_destination(self):
        if not os.access("/dev/shm", os.W_OK):
            self.skipTest("tmpfs unavailable")
        with tempfile.TemporaryDirectory() as temp, tempfile.TemporaryDirectory(dir="/dev/shm") as recovery:
            root = Path(temp); source = root / ".env"; source.write_text("KEY=original\n"); source.chmod(0o644)
            snap = s.read_document(source, root)
            with self.assertRaises(s.Problem):
                snap.replace("KEY=rendered\n")
            self.assertEqual("KEY=original\n", source.read_text())
            original = s._exchange; count = 0
            def exchange(fd, a, b):
                nonlocal count
                original(fd, a, b)
                count += 1
                if count == 1:
                    source.write_text("KEY=concurrent-owner-edit\n")
            s._exchange = exchange
            try:
                with self.assertRaises(s.Problem):
                    snap.replace("KEY=rendered\n", recovery_dir=recovery)
            finally:
                s._exchange = original
            self.assertEqual("KEY=concurrent-owner-edit\n", source.read_text())
            files = list(Path(recovery).glob(".envs-recovery-*/displaced.env"))
            self.assertEqual(1, len(files))
            self.assertEqual("KEY=original\n", files[0].read_text())
            self.assertEqual(0o600, files[0].stat().st_mode & 0o777)
            self.assertFalse(list(root.glob(".envs-*")))

    def test_private_mode_and_containment(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); source = root / ".env"; source.write_text("KEY=example\n"); source.chmod(0o644)
            with self.assertRaises(s.Problem):
                s.read_document(source, root, private=True)
            source.chmod(0o600)
            s.read_document(source, root, private=True).replace("KEY=bw://Env/demo/dev#KEY\n", recovery_dir=self.recovery.name)
            self.assertEqual(0o600, source.stat().st_mode & 0o777)
            with self.assertRaises(s.Problem):
                s.read_document(source, root / "different")


if __name__ == "__main__":
    unittest.main()
