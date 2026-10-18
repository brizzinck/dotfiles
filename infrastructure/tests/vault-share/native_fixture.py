#!/usr/bin/env python3
"""Real Broker/Client socket and Writer; invented file backend/read view only.

Start with python3 -I -B native_fixture.py PRIVATE_SCRATCH. Socket is SCRATCH/run/sock.
Client hooks: TEST_DIR=this directory, SCRATCH=root, SOCK=root/run/sock,
SCOPES=root/etc/scopes.tsv, RUNTIME=root/runtime, TEST_AS=td. No live tools are used.
"""
import asyncio
import copy
import importlib.util
import json
import os
from pathlib import Path
import pwd
import stat
import sys
import uuid

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]


def main():
    root = Path(sys.argv[1]).absolute()
    st = root.lstat()
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077 or not str(root).startswith('/tmp/'):
        raise SystemExit('private invented fixture directory required')
    dirs = ('run', 'etc', 'runtime', 'home', 'config', 'data', 'cache', 'state', 'bin')
    for directory in dirs: (root / directory).mkdir(mode=0o700, exist_ok=True)
    for command in ('bw', 'rbw', 'fzf-menu', 'ghostty', 'notify-send', 'hyprctl', 'wl-copy'):
        path = root / 'bin' / command; path.write_text('#!/bin/sh\nexit 97\n'); path.chmod(0o700)
    os.environ.clear()
    os.environ.update({'PATH': str(root / 'bin') + ':/usr/bin:/bin', 'HOME': str(root / 'home'), 'LANG': 'C.UTF-8',
        'XDG_CONFIG_HOME': str(root / 'config'), 'XDG_DATA_HOME': str(root / 'data'), 'XDG_CACHE_HOME': str(root / 'cache'),
        'XDG_STATE_HOME': str(root / 'state'), 'XDG_RUNTIME_DIR': str(root / 'runtime'),
        'VAULT_SHARE_TEST_DIR': str(HERE), 'VAULT_SHARE_SCRATCH': str(root), 'VAULT_SHARE_SOCK': str(root / 'run/sock'),
        'VAULT_SHARE_SCOPES': str(root / 'etc/scopes.tsv'), 'VAULT_SHARE_RUNTIME': str(root / 'runtime'),
        'VAULT_SHARE_WRITE_POLICY': str(root / 'etc/env-write.tsv'), 'VAULT_SHARE_TEST_PEER_FILE': str(root / 'peer')})
    (root / 'peer').write_text('td')
    (root / 'etc/scopes.tsv').write_text('td\tUsers/td/**\nyc\tUsers/yc/**\n')
    try: uid = pwd.getpwnam('td').pw_uid
    except KeyError: uid = 59999
    (root / 'etc/env-write.tsv').write_text('# vault-share env-write v1\ntd\t' + str(uid) + '\n')
    spec = importlib.util.spec_from_file_location('native_fixture_broker', REPO / '.config/hypr/scripts/vault-share.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    if not module.TEST: raise SystemExit('verified test mode required')
    broker = module.Broker()
    vault = root / 'vault.json'
    if not vault.exists(): vault.write_text(json.dumps({'folders': [], 'items': [], 'calls': []}))
    class FakeBackend:
        def __init__(self, deadline): pass
        def read(self): return json.loads(vault.read_text())
        def save(self, doc):
            tmp = vault.with_suffix('.new'); tmp.write_text(json.dumps(doc)); tmp.replace(vault)
        def prepare(self):
            if (root / 'locked').exists(): raise broker.write_module.WriteError('locked')
        def sync(self): pass
        def folders(self): return self.read()['folders']
        def items(self, folder): return [r for r in self.read()['items'] if r['folderId'] == folder]
        def get(self, ident): return next(r for r in self.read()['items'] if r['id'] == ident)
        def create_folder(self, name):
            data = self.read(); row = {'id': str(uuid.uuid4()), 'name': name, 'object': 'folder'}
            data['folders'].append(row); data['calls'].append('folder'); self.save(data)
            if (root / 'lose-folder-reply').exists(): raise broker.write_module.WriteError()
            return row
        def create(self, doc):
            data = self.read(); row = dict(copy.deepcopy(doc), id=str(uuid.uuid4()))
            data['items'].append(row); data['calls'].append('create'); self.save(data)
            if (root / 'lose-reply').exists(): raise broker.write_module.WriteError()
            return row
        def edit(self, ident, doc):
            data = self.read(); data['items'] = [doc if r['id'] == ident else r for r in data['items']]
            data['calls'].append('edit'); self.save(data); return copy.deepcopy(doc)
    original = broker.write_module.Writer
    broker.write_module.Writer = lambda *args, **kwargs: original(*args, backend_factory=FakeBackend, **kwargs)
    async def rbw(*args, timeout=10):
        if args == ('config', 'show'): return 0, json.dumps({'pinentry': str(REPO / '.local/bin/pinentry-themed')}).encode()
        if args in (('unlocked',), ('sync',)):
            return (1 if (root / 'locked').exists() or (args == ('sync',) and (root / 'stale').exists()) else 0), b''
        data = json.loads(vault.read_text())
        folders = {r['id']: r['name'] for r in data['folders']}
        records = [dict(r, folder=folders[r['folderId']], type='note', data={}) for r in data['items']]
        if args[:2] == ('list', '--raw'): return 0, json.dumps(records).encode()
        if args[:2] == ('get', '--raw'):
            found = next((r for r in records if r['id'] == args[2]), None)
            return (0, json.dumps(found).encode()) if found else (1, b'')
        raise AssertionError('unexpected fake rbw operation')
    broker.rbw = rbw
    asyncio.run(broker.serve())


if __name__ == '__main__': main()
