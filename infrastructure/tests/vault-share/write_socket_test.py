#!/usr/bin/env python3
"""Actual private Broker socket, policy, batch writer and ordinary scoped reads."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

_isolation_spec = importlib.util.spec_from_file_location('write_test_isolation', Path(__file__).with_name('write_isolation.py'))
_isolation = importlib.util.module_from_spec(_isolation_spec); _isolation_spec.loader.exec_module(_isolation)

HERE = Path(__file__).resolve().parent


class Socket(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='fake-native-socket-')
        self.root = Path(self.tmp.name)
        self.log = (self.root / 'broker.log').open('wb')
        env = {'PATH': os.environ['PATH'], 'HOME': str(self.root),
               **{key: str(self.root / key) for key in ('XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME', 'XDG_RUNTIME_DIR')}}
        self.proc = subprocess.Popen([sys.executable, '-I', '-B', str(HERE / 'native_fixture.py'), str(self.root)],
                                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=self.log, env=env)
        for _ in range(100):
            if (self.root / 'run/sock').exists(): break
            if self.proc.poll() is not None: self.fail((self.root / 'broker.log').read_text())
            time.sleep(0.02)
        self.msg = {'v': 1, 'op': 'env-put', 'project': 'example', 'env': 'dev', 'values': {'TOKEN': 'invented-socket-secret'},
                    'overwrite': False, 'request_id': str(uuid.uuid4())}
    def tearDown(self):
        self.proc.terminate(); self.proc.wait(timeout=3); self.log.close(); self.tmp.cleanup()
    def request(self, msg):
        with socket.socket(socket.AF_UNIX) as conn:
            conn.settimeout(3); conn.connect(str(self.root / 'run/sock'))
            conn.sendall(json.dumps(msg).encode() + b'\n')
            data = b''
            while not data.endswith(b'\n'): data += conn.recv(65536)
        return json.loads(data)
    def test_create_read_edit_and_metadata_only_log(self):
        result = self.request(self.msg)
        self.assertTrue(result['ok'], result)
        read = self.request({'v': 1, 'op': 'get', 'id': result['id'], 'fields': ['field:TOKEN']})
        self.assertEqual(read['values']['field:TOKEN'], self.msg['values']['TOKEN'])
        change = dict(self.msg, request_id=str(uuid.uuid4()), overwrite=True, values={'TOKEN': 'invented-changed'})
        self.assertTrue(self.request(change)['ok'])
        self.assertNotIn('invented-socket-secret', (self.root / 'broker.log').read_text())
    def test_peer_denial_and_large_read_frame_preserved(self):
        (self.root / 'peer').write_text('yc')
        result = self.request(self.msg)
        self.assertFalse(result['ok']); self.assertEqual(result['error'], 'policy')
        self.assertEqual(json.loads((self.root / 'vault.json').read_text())['calls'], [])
        (self.root / 'peer').write_text('td')
        self.assertEqual(self.request({'v': 1, 'op': 'whoami', 'padding': 'x' * 5000})['error'], 'bad_request')
    def test_ambiguous_create_restartless_recovery_no_duplicate(self):
        (self.root / 'lose-reply').touch()
        self.assertFalse(self.request(self.msg)['ok'])
        (self.root / 'lose-reply').unlink()
        self.assertTrue(self.request(self.msg)['ok'])
        self.assertEqual(json.loads((self.root / 'vault.json').read_text())['calls'].count('create'), 1)
    def test_revoked_capability_and_stale_readview_fail_closed(self):
        (self.root / 'stale').touch()
        result = self.request(self.msg)
        self.assertFalse(result['ok']); self.assertEqual(result['error'], 'pending')
        (self.root / 'stale').unlink()
        (self.root / 'etc/env-write.tsv').write_text('# vault-share env-write v1\n')
        self.assertEqual(self.request(self.msg)['error'], 'policy')

    def test_pending_and_key_survive_broker_and_runtime_restart(self):
        (self.root / 'lose-reply').touch()
        self.assertFalse(self.request(self.msg)['ok'])
        self.proc.terminate(); self.proc.wait(timeout=3)
        key = (self.root / 'state/vault-share/env-write/request.key').read_bytes()
        for path in (self.root / 'runtime').iterdir():
            if path.is_file(): path.unlink()
        (self.root / 'lose-reply').unlink()
        self.proc = subprocess.Popen([sys.executable, '-I', '-B', str(HERE / 'native_fixture.py'), str(self.root)],
                                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=self.log,
                                     env={'HOME': str(self.root), 'PATH': os.environ['PATH']})
        for _ in range(100):
            if self.proc.poll() is not None: self.fail((self.root / 'broker.log').read_text())
            try:
                result = self.request(self.msg); break
            except (ConnectionError, FileNotFoundError): time.sleep(0.02)
        else: self.fail('fixture restart timeout')
        self.assertTrue(result['ok'], result)
        self.assertEqual(key, (self.root / 'state/vault-share/env-write/request.key').read_bytes())
        self.assertEqual(json.loads((self.root / 'vault.json').read_text())['calls'].count('create'), 1)


if __name__ == '__main__': unittest.main()
