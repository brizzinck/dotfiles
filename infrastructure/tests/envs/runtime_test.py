#!/usr/bin/env python3
"""Masking, streaming and tmpfs lifecycle regressions; all values and child programs are invented."""
import importlib.util
import os
import signal
import select
import pty
from unittest import mock
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parents[3] / ".config/envs/runtime.py"
spec = importlib.util.spec_from_file_location("envs_runtime_tests", SOURCE)
r = importlib.util.module_from_spec(spec); spec.loader.exec_module(r)


class Masking(unittest.TestCase):
    def test_every_form_every_split_and_identical_names(self):
        patterns = r.secret_patterns({"B": "fixture +/token", "A": "fixture +/token"})
        for form in patterns:
            for split in range(len(form) + 1):
                with self.subTest(form=form, split=split):
                    masker = r.StreamingMasker(patterns)
                    got = masker.feed(b"before " + form[:split]) + masker.feed(form[split:] + b" after") + masker.feed(b"", final=True)
                    self.assertEqual(b"before [secret A,B] after", got)
                    self.assertLessEqual(len(masker.pending), masker.keep)

    def test_longest_overlap_binary_and_partial_suffix(self):
        patterns = r.secret_patterns({"LONG": "abcdefghi", "SHORT": "abcdef"})
        masker = r.StreamingMasker(patterns)
        self.assertEqual(b"", masker.feed(b"abcdef"))
        self.assertEqual(b"[secret LONG] ", masker.feed(b"ghi abc"))
        self.assertEqual(b"abc", masker.feed(b"", final=True))
        masker = r.StreamingMasker(patterns)
        self.assertEqual(b"\xff[secret SHORT]\x80", masker.feed(b"\xffabcdef\x80", final=True))

    def test_intersecting_patterns_cover_the_union_at_every_split(self):
        patterns = r.secret_patterns({"FIRST": "abcXYZ", "SECOND": "XYZdef"})
        for split in range(10):
            masker = r.StreamingMasker(patterns)
            raw = b"abcXYZdef"
            got = masker.feed(raw[:split]) + masker.feed(raw[split:]) + masker.feed(b"", final=True)
            self.assertEqual(b"[secret FIRST]", got)

    def test_repetitive_overlap_has_bounded_retention(self):
        masker = r.StreamingMasker(r.secret_patterns({"TOKEN": "aaaaaa"}))
        output = b""
        for _ in range(20):
            output += masker.feed(b"a" * 8192)
            self.assertLessEqual(len(masker.pending), masker.keep)
            self.assertLessEqual(len(masker.covered), masker.keep + 1)
        output += masker.feed(b"", final=True)
        self.assertEqual(b"[secret TOKEN]", output)

    def test_serializer_portability_refusal(self):
        for value in ("fixture$dollar", "fixture\rreturn", "fixture\\slash", "fixture'\"quotes"):

            with self.assertRaises(r.RuntimeProblem):
                r.dotenv_literal(value)
        self.assertEqual('"fixture\nline"', r.dotenv_literal("fixture\nline"))

    def test_envs_transfer_dialect_is_lossless_for_nonportable_values(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("literal_core", SOURCE.with_name("secrets.py"))
        core = importlib.util.module_from_spec(spec)
        __import__('sys').modules[spec.name] = core; spec.loader.exec_module(core)
        for value in ("fixture$dollar", "fixture\\backslash", "both'\"quotes", "fixture\r\nline\tend", "fixture`backtick"):
            encoded = r.envs_literal(value)
            self.assertEqual(value, core.DotenvDocument("KEY=" + encoded).values()["KEY"])
        with self.assertRaises(r.RuntimeProblem):
            r.envs_literal("fixture\x00nul")

    def test_progress_does_not_wait_for_max_pattern(self):
        masker = r.StreamingMasker(r.secret_patterns({"TOKEN": "X" * 4000}))
        self.assertEqual(b"progress now\n", masker.feed(b"progress now\n"))

    def test_input_bounds(self):
        for value in ("short", "X" * 100000):
            with self.assertRaises(r.RuntimeProblem):
                r.secret_patterns({"KEY": value})


class RuntimeFiles(unittest.TestCase):
    def test_tmpfs_only_and_cleanup_on_exception(self):
        # The public test snapshot itself may live on tmpfs. Model a non-tmpfs
        # fstatfs result explicitly; the success case below uses real /dev/shm.
        with tempfile.TemporaryDirectory(dir=SOURCE.parent, prefix=".envs-disk-probe.") as disk:
            with mock.patch.object(r, "_tmpfs", return_value=False):
                with self.assertRaises(r.RuntimeProblem):
                    with r.private_envfile("KEY=fixture\n", base=disk):
                        self.fail("persistent file fallback was accepted")
        with tempfile.TemporaryDirectory(dir="/dev/shm", prefix="envs-runtime-test.") as tmpfs:
            path = None
            with self.assertRaisesRegex(ValueError, "inert failure"):
                with r.private_envfile("KEY=fixture\n", base=tmpfs) as path:
                    self.assertEqual(0o600, path.stat().st_mode & 0o777)
                    self.assertEqual(0o700, path.parent.stat().st_mode & 0o777)
                    self.assertEqual("KEY=fixture\n", path.read_text())
                    raise ValueError("inert failure")
            self.assertFalse(path.exists())
            self.assertEqual([], list(Path(tmpfs).iterdir()))

    def test_live_run_not_removed_and_dead_run_is_cleaned(self):
        with tempfile.TemporaryDirectory(dir="/dev/shm", prefix="envs-runtime-test.") as tmpfs:
            with r.private_envfile("KEY=first\n", base=tmpfs) as first:
                with r.private_envfile("KEY=second\n", base=tmpfs):
                    self.assertTrue(first.exists())
    def test_unknown_proc_identity_retains_live_file(self):
        with tempfile.TemporaryDirectory(dir="/dev/shm", prefix="envs-runtime-test.") as tmpfs:
            with r.private_envfile("KEY=first\n", base=tmpfs) as first:
                fd = os.open(tmpfs, os.O_DIRECTORY)
                try:
                    with mock.patch.object(r, "_start_time", return_value=None):
                        r._cleanup_run(fd, first.parent.name)
                    self.assertTrue(first.exists())
                finally:
                    os.close(fd)



class Supervision(unittest.TestCase):
    def run_child(self, body, code=0, agent=True):
        with tempfile.TemporaryDirectory() as temp:
            child = Path(temp) / "child.py"; child.write_text(body)
            boot = ("import importlib.util,os,sys; s=importlib.util.spec_from_file_location('runtime',sys.argv[1]); "
                    "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); "
                    "sys.exit(m.supervise_run(['/usr/bin/python3','-I','-B',sys.argv[2]],dict(os.environ),{'TOKEN':os.environ['FIXTURE_SECRET']},agent=" + repr(agent) + "))")
            env = {"PATH": "/usr/bin:/bin", "FIXTURE_SECRET": "fixture-supervised-value"}
            return subprocess.run([sys.executable, "-I", "-B", "-c", boot, str(SOURCE), str(child)],
                                  env=env, capture_output=True, timeout=15)

    def test_both_pipes_large_output_and_nonzero_status(self):
        result = self.run_child("import os,sys,threading\nv=os.environ['FIXTURE_SECRET'].encode()\n"
                                "def emit(fd):\n for _ in range(160): os.write(fd,b'x'*32768+v+b'\\xff')\n"
                                "t=threading.Thread(target=emit,args=(2,));t.start();emit(1);t.join();sys.exit(7)\n")
        self.assertEqual(7, result.returncode)
        for output in (result.stdout, result.stderr):
            self.assertNotIn(b"fixture-supervised-value", output)
            self.assertEqual(160, output.count(b"[secret TOKEN]"))
            self.assertGreater(len(output), 5 * 1024 * 1024)

    def test_signal_exit_and_descendant_pipe_holder_are_bounded(self):
        result = self.run_child("import os,signal\nos.kill(os.getpid(),signal.SIGTERM)\n")
        self.assertEqual(143, result.returncode)
        started = time.monotonic()
        result = self.run_child("import os,time\np=os.fork()\nif p==0: time.sleep(10)\nelse: os._exit(0)\n")
        self.assertEqual(0, result.returncode)
        self.assertLess(time.monotonic() - started, 3)

    def test_human_descendant_pipe_holder_is_bounded(self):
        started = time.monotonic()
        result = self.run_child("import os,time\np=os.fork()\nif p==0: time.sleep(10)\nelse: os._exit(0)\n", agent=False)
        self.assertEqual(0, result.returncode)
        self.assertLess(time.monotonic() - started, 3)
    def test_slow_reader_preserves_complete_normal_output(self):
        boot = ("import importlib.util,os,sys; s=importlib.util.spec_from_file_location('runtime',sys.argv[1]); "
                "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); "
                "sys.exit(m.supervise_run(['/usr/bin/python3','-I','-B','-c',"
                "'import os; os.write(1,b\"q\"*350000)'],{'PATH':'/usr/bin:/bin'},"
                "{'TOKEN':'fixture-token'},agent=True))")
        proc = subprocess.Popen([sys.executable, "-I", "-B", "-c", boot, str(SOURCE)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={"PATH": "/usr/bin:/bin"})
        try:
            time.sleep(1.6)
            output, error = proc.communicate(timeout=5)
            self.assertEqual(0, proc.returncode, error)
            self.assertEqual(b"q" * 350000, output)
        finally:
            if proc.poll() is None:
                proc.kill(); proc.wait()
            proc.stdout.close(); proc.stderr.close()

    def test_blocked_output_signal_deadline(self):
        boot = ("import importlib.util,os,sys; s=importlib.util.spec_from_file_location('runtime',sys.argv[1]); "
                "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); "
                "sys.exit(m.supervise_run(['/usr/bin/python3','-I','-B','-c',"
                "'import os,signal; signal.signal(signal.SIGTERM,signal.SIG_IGN); os.write(1,b\"q\"*1048576); signal.pause()'],"
                "{'PATH':'/usr/bin:/bin'},{'TOKEN':'fixture-token'},agent=True))")
        proc = subprocess.Popen([sys.executable, "-I", "-B", "-c", boot, str(SOURCE)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={"PATH": "/usr/bin:/bin"})
        try:
            time.sleep(0.25)
            started = time.monotonic(); proc.terminate()
            self.assertEqual(143, proc.wait(timeout=3.5))
            self.assertLess(time.monotonic() - started, 3)
        finally:
            if proc.poll() is None:
                proc.kill(); proc.wait()
            proc.stdout.close(); proc.stderr.close()

    def test_human_foreground_tty_input_and_restoration(self):
        pid, fd = pty.fork()
        if pid == 0:
            signal.alarm(5)
            os.write(1, b"READY\n")
            result = r.supervise_run(['/usr/bin/python3', '-I', '-B', '-c',
                                     'import os,signal; signal.alarm(4); os.write(1,b"INPUT:"+os.read(0,100))'],
                                    {"PATH": "/usr/bin:/bin"}, agent=False)
            os.write(1, ("RESTORED:%s:%s\n" % (result, os.tcgetpgrp(0) == os.getpgrp())).encode())
            os._exit(0)
        output, sent, finished = b"", False, False
        try:
            until = time.monotonic() + 7
            while time.monotonic() < until:
                if select.select([fd], [], [], 0.05)[0]:
                    try:
                        block = os.read(fd, 8192)
                    except OSError:
                        break
                    if not block:
                        break
                    output += block
                    if b"READY" in output and not sent:
                        os.write(fd, b"fixture-input\n"); sent = True
                done, status = os.waitpid(pid, os.WNOHANG)
                if done:
                    finished = True
                    break
            self.assertIn(b"INPUT:fixture-input", output)
            self.assertIn(b"RESTORED:0:True", output)
        finally:
            if not finished:
                with __import__('contextlib').suppress(ProcessLookupError):
                    os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            os.close(fd)


if __name__ == "__main__":
    unittest.main()
