#!/usr/bin/env python3
"""Private inherited-listener lifecycle; inert handler, no vault/auth/runtime state or live broker."""
import importlib.util
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest

SOURCE = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).resolve().parents[3] / '.config/hypr/scripts/vault-share.py'


def child(kind, address):
    import asyncio
    if kind == '--inherited-child':
        os.dup2(int(address), 3)
        os.environ.update(LISTEN_PID=str(os.getpid()), LISTEN_FDS='1')
    else:
        os.environ.pop('LISTEN_PID', None)
        os.environ.pop('LISTEN_FDS', None)
    spec = importlib.util.spec_from_file_location('socket_idle_broker', SOURCE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.TEST = kind == '--standalone-child'
    module.sock_path = lambda: Path(address)
    module.scopes_path = lambda: Path('invented-scopes')
    module.log = lambda *args: None
    broker = module.Broker.__new__(module.Broker)  # bypass real rate/auth/backend initialization
    broker.idle, broker.total, broker.last_conn = 0.05, 0, time.monotonic()
    async def handle(reader, writer):
        broker.total += 1
        try:
            await reader.readline()
            writer.write(b'inert-response\n')
            await writer.drain()
        finally:
            broker.last_conn = time.monotonic()
            broker.total -= 1
            writer.close()
            await writer.wait_closed()
    broker.handle = handle
    asyncio.run(broker.serve())


class SocketIdle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='fake-socket-idle-')
        self.root = Path(self.tmp.name)
        self.path = self.root / 'broker.sock'
        tools = self.root / 'fake-tools'; tools.mkdir(mode=0o700)
        for name in ('bw', 'rbw', 'fzf-menu', 'ghostty', 'notify-send', 'hyprctl', 'wl-copy'):
            stub = tools / name
            stub.write_text('#!/bin/sh\nprintf "blocked\\n" >> "$FAKE_TOOL_LOG"\nexit 97\n')
            stub.chmod(0o700)
        for name in ('config', 'data', 'cache', 'state', 'runtime'):
            (self.root / name).mkdir(mode=0o700)
        self.env = {'PATH': str(tools) + ':/usr/bin:/bin', 'HOME': str(self.root), 'XDG_CONFIG_HOME': str(self.root / 'config'),
                    'XDG_DATA_HOME': str(self.root / 'data'), 'XDG_CACHE_HOME': str(self.root / 'cache'),
                    'XDG_STATE_HOME': str(self.root / 'state'), 'XDG_RUNTIME_DIR': str(self.root / 'runtime'),
                    'FAKE_TOOL_LOG': str(self.root / 'blocked-tools'), 'LANG': 'C.UTF-8'}

    def tearDown(self):
        self.tmp.cleanup()

    def activate(self, kind, listener=None):
        address = str(listener.fileno()) if listener is not None else str(self.path)
        proc = subprocess.Popen(['/usr/bin/python3', '-I', '-B', __file__, str(SOURCE), kind, address],
                                pass_fds=(listener.fileno(),) if listener is not None else (), env=self.env,
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 3
            while not self.path.exists() and proc.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(3)
                client.connect(str(self.path))
                client.sendall(b'inert-request\n')
                self.assertEqual(b'inert-response\n', client.recv(128))
            stdout, stderr = proc.communicate(timeout=3)
            self.assertEqual(0, proc.returncode, stderr.decode(errors='replace'))
            self.assertEqual(b'', stdout)
            self.assertFalse((self.root / 'blocked-tools').exists(), 'inert lifecycle called a vault/desktop tool')
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.communicate(timeout=3)

    def test_inherited_idle_keeps_parent_path_and_allows_next_activation(self):
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(str(self.path))
            listener.listen(8)
            inode = self.path.stat().st_ino
            for _ in range(2):
                self.activate('--inherited-child', listener)
                self.assertTrue(self.path.exists(), 'idle close unlinked the parent-owned activation socket')
                self.assertTrue(stat.S_ISSOCK(self.path.stat().st_mode))
                self.assertEqual(inode, self.path.stat().st_ino)
                self.assertEqual(str(self.path), listener.getsockname())

    def test_standalone_owned_socket_still_cleans_up_on_idle(self):
        self.activate('--standalone-child')
        self.assertFalse(self.path.exists())


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] in ('--inherited-child', '--standalone-child'):
        child(sys.argv[1], sys.argv[2])
    else:
        unittest.main()
