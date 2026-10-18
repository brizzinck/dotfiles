#!/usr/bin/env python3
"""Private UNIX HTTP fixture only: bounded owner-server adapter, no real backend or credentials."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import tempfile
import threading
import time
import types
import unittest
from unittest import mock

_isolation_spec = importlib.util.spec_from_file_location('write_test_isolation', Path(__file__).with_name('write_isolation.py'))
_isolation = importlib.util.module_from_spec(_isolation_spec); _isolation_spec.loader.exec_module(_isolation)

REPO = Path(__file__).resolve().parents[3]
def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, REPO / '.config/hypr/scripts' / filename)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module
w = load('write_backend_under_test', 'vault-share-write.py')
m = load('write_backend_transport', 'vault-bw.py')


class Backend(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='fake-owner-server-')
        self.root = Path(self.tmp.name); self.root.chmod(0o700)
        self.old = {key: getattr(m, key) for key in ('RUN', 'SOCK', 'SESSION', 'SERVE_LOCK', 'SERVE_USED')}
        m.RUN = self.root; m.SOCK = self.root / 'bw.sock'; m.SESSION = self.root / 'session'
        m.SERVE_LOCK = self.root / 'start.lock'; m.SERVE_USED = self.root / 'used'
        self.server = None; self.thread = None; self.seen = []

    def tearDown(self):
        if self.server: self.server.close()
        if self.thread: self.thread.join(2)
        for key, value in self.old.items(): setattr(m, key, value)
        self.tmp.cleanup()

    def fixture(self, body, status=200, delay=0):
        self.server = socket.socket(socket.AF_UNIX); self.server.bind(str(m.SOCK)); self.server.listen(1)
        m.SOCK.chmod(0o600)
        def serve():
            try:
                conn, _ = self.server.accept()
                with conn:
                    conn.settimeout(1)
                    request = bytearray()
                    while b'\r\n\r\n' not in request:
                        request.extend(conn.recv(4096))
                    self.seen.append(bytes(request))
                    time.sleep(delay)
                    conn.sendall(f'HTTP/1.1 {status} Fixture\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n'.encode() + body)
            except (OSError, TimeoutError): pass
        self.thread = threading.Thread(target=serve, daemon=True); self.thread.start()

    def test_bounded_real_unix_transport_and_connection_close_response(self):
        self.fixture(json.dumps({'success': True, 'data': {'template': {'status': 'unlocked'}}}).encode())
        w.OwnerServer(time.monotonic() + 2, m).prepare()
        self.assertTrue(self.seen[0].startswith(b'GET /status '))

    def test_over_cap_response_and_backend_error_are_fixed(self):
        for status, body, category in ((200, b'x' * 129, 'unavailable'),
                                      (403, b'invented-password-sentinel\x1b[31m', 'locked')):
            self.fixture(body, status=status)
            backend = w.OwnerServer(time.monotonic() + 2, m); backend.LIMIT = 128
            with self.subTest(status=status), self.assertRaises(w.WriteError) as caught: backend.ready()
            self.assertEqual(category, caught.exception.code)
            self.assertNotIn('invented-password', str(caught.exception))
            self.thread.join(2); self.server.close(); self.server = None; m.SOCK.unlink()

    def test_overall_deadline_and_missing_server_never_cli_fallback(self):
        self.fixture(b'{}', delay=0.3)
        backend = w.OwnerServer(time.monotonic() + 0.05, m)
        start = time.monotonic()
        with self.assertRaises(w.WriteError): backend.ready()
        self.assertLess(time.monotonic() - start, 0.2)
        self.thread.join(2); self.server.close(); self.server = None; m.SOCK.unlink()
        with mock.patch.object(m, 'bw', side_effect=AssertionError('CLI fallback')), \
             mock.patch.object(m, 'bw_cli', side_effect=AssertionError('CLI')), \
             mock.patch.object(m, 'start_serve', side_effect=AssertionError('popen-capable startup')), \
             mock.patch.object(w.subprocess, 'run', side_effect=AssertionError('no manager without session')):
            with self.assertRaises(w.WriteError): w.OwnerServer(time.monotonic() + 1, m).prepare()

    def test_slow_headers_cannot_renew_overall_deadline(self):
        self.server = socket.socket(socket.AF_UNIX); self.server.bind(str(m.SOCK)); self.server.listen(1)
        m.SOCK.chmod(0o600)
        def slow():
            try:
                conn, _ = self.server.accept()
                with conn:
                    conn.recv(4096)
                    conn.sendall(b'HTTP/1.1 200 Fixture\r\n')
                    for index in range(20):
                        time.sleep(0.03)
                        conn.sendall(b'X-Fixture: bounded\r\n')
                    conn.sendall(b'Content-Length: 2\r\n\r\n{}')
            except OSError: pass
        self.thread = threading.Thread(target=slow, daemon=True); self.thread.start()
        start = time.monotonic()
        with self.assertRaises(w.WriteError): w.OwnerServer(start + 0.05, m).ready()
        self.assertLess(time.monotonic() - start, 0.15)

    def test_manager_start_is_absolute_metadata_only_and_failure_has_no_fallback(self):
        m.SESSION.write_text('invented-test-session'); m.SESSION.chmod(0o600)
        calls = []
        def manager(args, **kwargs): calls.append((args, kwargs)); return types.SimpleNamespace(returncode=1)
        with mock.patch.object(w.subprocess, 'run', side_effect=manager), \
             mock.patch.object(m, 'start_serve', side_effect=AssertionError('fallback startup')):
            with self.assertRaises(w.WriteError): w.OwnerServer(time.monotonic() + 1, m).prepare()
        self.assertEqual(1, len(calls))
        args, opts = calls[0]
        self.assertEqual('/usr/bin/systemd-run', args[0])
        self.assertIn('--unit=vault-bw-serve', args)
        self.assertNotIn('invented-test-session', repr(calls))
        self.assertNotIn('BW_SESSION', repr(calls))
        self.assertIn('-B', args)


if __name__ == '__main__': unittest.main()
