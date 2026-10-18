#!/usr/bin/env python3
"""Actual OwnerServer+Writer with official HTTP envelopes and delayed CLI folder views."""
import copy
from http.server import BaseHTTPRequestHandler
import importlib.util
import json
import os
from pathlib import Path
import socketserver
import tempfile
import threading
import time
import unittest
import urllib.parse
import uuid

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('http_write_isolation', HERE / 'write_isolation.py')
isolation = importlib.util.module_from_spec(spec); spec.loader.exec_module(isolation)
REPO = HERE.parents[2]


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, REPO / '.config/hypr/scripts' / file)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module


w = load('http_write_engine', 'vault-share-write.py')
m = load('http_write_owner_transport', 'vault-bw.py')


class HTTP(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='invented-native-http-')
        self.root = Path(self.tmp.name)
        self.old = {key: getattr(m, key) for key in ('RUN', 'SOCK', 'SERVE_USED')}
        m.RUN = self.root; m.SOCK = self.root / 'owner.sock'; m.SERVE_USED = self.root / 'used'
        self.folders = []; self.visible = []; self.items = []; self.calls = []
        self.show_after = 0; self.mode = 'delayed'; self.delay = 0.08
        lab = self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def answer(self, data):
                raw = json.dumps({'success': True, 'data': data}).encode()
                self.send_response(200); self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(raw))); self.end_headers(); self.wfile.write(raw)
            def do_GET(self):
                path = urllib.parse.urlsplit(self.path)
                if path.path == '/status': self.answer({'template': {'status': 'unlocked'}})
                elif path.path == '/list/object/folders':
                    if time.monotonic() >= lab.show_after: lab.visible = copy.deepcopy(lab.folders)
                    self.answer({'object': 'list', 'data': [{'id': '', 'name': 'No Folder', 'object': 'folder'}] + lab.visible})
                elif path.path == '/list/object/items':
                    folder = urllib.parse.parse_qs(path.query)['folderid'][0]
                    self.answer({'object': 'list', 'data': [r for r in lab.items if r['folderId'] == folder]})
                elif path.path.startswith('/object/item/'):
                    ident = path.path.rsplit('/', 1)[1]
                    self.answer(next(row for row in lab.items if row['id'] == ident))
                else: raise AssertionError(path.path)
            def do_POST(self):
                raw = self.rfile.read(int(self.headers.get('Content-Length', 0)))
                if self.path == '/sync': self.answer({})
                elif self.path == '/object/folder':
                    req = json.loads(raw); lab.calls.append('folder')
                    reply = {'id': str(uuid.uuid4()), 'name': req['name'], 'object': 'folder'}
                    stored = dict(reply)
                    if lab.mode == 'conflict': stored['id'] = str(uuid.uuid4())
                    if lab.mode == 'wrong-receipt': reply['name'] = 'Invented wrong receipt'
                    lab.folders.append(stored)
                    if lab.mode == 'duplicate': lab.folders.append(dict(stored, id=str(uuid.uuid4())))
                    lab.show_after = float('inf') if lab.mode == 'never' else time.monotonic() + lab.delay
                    if lab.mode == 'uncertain': return  # successful remote mutation, connection lost before receipt
                    self.answer(reply)
                elif self.path == '/object/item':
                    lab.calls.append('item')
                    rows = [json.loads(p.read_text()) for p in lab.engine.directory.glob('*.json') if not p.name.startswith('done-')]
                    if rows[0]['phase'] != 'item-dispatch': raise AssertionError('phase not durable before item POST')
                    row = dict(json.loads(raw), id=str(uuid.uuid4()), object='item', revisionDate='invented-revision')
                    lab.items.append(row); self.answer(row)
                else: raise AssertionError(self.path)
        self.server = socketserver.UnixStreamServer(str(m.SOCK), Handler); m.SOCK.chmod(0o600)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()
        self.engine = w.Writer(self.root / 'journal', lambda uid, name: True,
            backend_factory=lambda deadline: w.OwnerServer(deadline, m), verify=lambda *args: None)
        self.msg = {'v': 1, 'op': 'env-put', 'project': 'example', 'env': 'dev',
                    'values': {'TOKEN': 'invented-http-secret'}, 'overwrite': False, 'request_id': str(uuid.uuid4())}
    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(2)
        for key, value in self.old.items(): setattr(m, key, value)
        self.tmp.cleanup()
    def test_delayed_folder_visibility_full_item_batch_single_posts(self):
        result = self.engine.run(self.msg, 1101, 'td')
        self.assertEqual(self.calls, ['folder'] * 4 + ['item'])
        self.assertEqual(self.items[0]['fields'], [{'name': 'TOKEN', 'value': 'invented-http-secret', 'type': 1}])
        self.assertEqual(result['id'], self.items[0]['id'])
        self.assertTrue(result['verified'])
    def test_never_visible_fails_bounded_without_second_post(self):
        self.mode = 'never'; self.engine.FOLDER_WAIT = 0.12
        start = time.monotonic()
        with self.assertRaises(w.WriteError) as caught: self.engine.run(self.msg, 1101, 'td')
        self.assertLess(time.monotonic() - start, 0.4)
        self.assertEqual((caught.exception.code, caught.exception.stage), ('pending', 'folder-visible'))
        self.assertEqual(self.calls, ['folder']); self.assertEqual(self.items, [])
    def test_duplicate_conflicting_and_wrong_receipt_stop_after_one_post(self):
        self.mode = 'duplicate'; self.delay = 0
        with self.assertRaises(w.WriteError) as caught: self.engine.run(self.msg, 1101, 'td')
        self.assertEqual(caught.exception.code, 'conflict'); self.assertEqual(self.calls, ['folder'])
    def test_conflicting_id_stops_without_retry(self):
        self.mode = 'conflict'; self.delay = 0
        with self.assertRaises(w.WriteError) as caught: self.engine.run(self.msg, 1101, 'td')
        self.assertEqual(caught.exception.stage, 'folder-visible'); self.assertEqual(self.calls, ['folder'])
    def test_wrong_receipt_name_refuses_before_visibility_wait(self):
        self.mode = 'wrong-receipt'
        with self.assertRaises(w.WriteError) as caught: self.engine.run(self.msg, 1101, 'td')
        self.assertEqual(caught.exception.stage, 'folder-receipt'); self.assertEqual(self.calls, ['folder'])
    def test_uncertain_post_never_automatically_retries(self):
        self.mode = 'uncertain'
        with self.assertRaises(w.WriteError) as caught: self.engine.run(self.msg, 1101, 'td')
        self.assertEqual(caught.exception.stage, 'folder-create'); self.assertEqual(self.calls, ['folder'])
        with self.assertRaises(w.WriteError): self.engine.run(self.msg, 1101, 'td')
        self.assertEqual(self.calls, ['folder']); self.assertEqual(self.items, [])
    def test_shared_deadline_bounds_poll(self):
        self.mode = 'never'
        backend = w.OwnerServer(time.monotonic() + 0.1, m)
        reply = backend.create_folder('Users')
        with self.assertRaises(w.WriteError): self.engine.visible_folder(backend, 'Users', reply['id'], time.monotonic() + 0.06)
        self.assertEqual(self.calls, ['folder'])


if __name__ == '__main__': unittest.main()
