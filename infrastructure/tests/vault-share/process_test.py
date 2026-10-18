#!/usr/bin/env python3
"""Broker subprocess cleanup: inert sleep only, no real rbw or credentials."""
import asyncio
import importlib.util
import pathlib
import unittest

source = pathlib.Path(__file__).resolve().parents[3] / ".config/hypr/scripts/vault-share.py"
spec = importlib.util.spec_from_file_location("vault_share_process", source)
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)


class Cleanup(unittest.IsolatedAsyncioTestCase):
    def test_metadata_check_never_sweeps_callers_session(self):
        original_read = v.Path.read_text
        reads = []
        def read(path, *args, **kwargs):
            reads.append(str(path))
            if str(path) == "/proc/self/cgroup":
                return "0::/user.slice/user-1000.slice/session-example.scope\n"
            raise AssertionError("metadata check inspected the caller's cgroup processes")
        v.Path.read_text = read
        try:
            v.Broker.__new__(v.Broker).sweep_cgroup()
        finally:
            v.Path.read_text = original_read
        self.assertEqual(["/proc/self/cgroup"], reads)

    async def test_timeout_drains_and_reaps(self):
        broker = v.Broker.__new__(v.Broker)       # no real runtime/rate state is read
        broker.sweep_cgroup = lambda: None
        original_spawn = asyncio.create_subprocess_exec
        child = None
        drains = 0
        async def spawn(*args, **kwargs):
            nonlocal child
            child = await original_spawn("/usr/bin/sleep", "10", **kwargs)
            original_communicate = child.communicate
            async def communicate():
                nonlocal drains
                drains += 1
                return await original_communicate()
            child.communicate = communicate
            return child
        asyncio.create_subprocess_exec = spawn
        try:
            with self.assertRaises(v.Err) as caught:
                await broker.rbw("inert-test", timeout=0.01)
            self.assertEqual("unavailable", caught.exception.code)
            self.assertEqual(2, drains, "timeout must await communicate after kill")
            self.assertIsNotNone(child.returncode, "return only after child is reaped")
        finally:
            asyncio.create_subprocess_exec = original_spawn
            if child and child.returncode is None:
                child.kill()
                await child.wait()


if __name__ == "__main__":
    unittest.main()
