#!/usr/bin/env python3
"""Invented owner-backend documents; never contacts a real vault or desktop."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
import uuid
import threading

_isolation_spec = importlib.util.spec_from_file_location('write_test_isolation', Path(__file__).with_name('write_isolation.py'))
_isolation = importlib.util.module_from_spec(_isolation_spec); _isolation_spec.loader.exec_module(_isolation)

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('write_engine', REPO / '.config/hypr/scripts/vault-share-write.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)


class Backend:
    def __init__(self):
        self.folder_rows = []
        self.records = {}
        self.calls = []
        self.fail_after_create = False
    def prepare(self): self.calls.append('prepare')
    def sync(self): self.calls.append('sync')
    def folders(self): return copy.deepcopy(self.folder_rows)
    def items(self, folder): return [copy.deepcopy(row) for row in self.records.values() if row['folderId'] == folder]
    def get(self, ident): return copy.deepcopy(self.records[ident])
    def create_folder(self, name):
        self.calls.append('folder')
        row = {'id': str(uuid.uuid4()), 'name': name, 'object': 'folder'}
        self.folder_rows.append(row)
        return copy.deepcopy(row)
    def create(self, document):
        self.calls.append('create')
        row = dict(copy.deepcopy(document), id=str(uuid.uuid4()))
        self.records[row['id']] = row
        if self.fail_after_create: raise m.WriteError()
        return copy.deepcopy(row)
    def edit(self, ident, document):
        self.calls.append('edit')
        self.records[ident] = copy.deepcopy(document)
        return self.get(ident)


class Engine(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fake-native-write-')
        self.root = Path(self.temp.name)
        self.backend = Backend()
        self.allowed = True
        self.visible = True
        self.engine = m.Writer(self.root / 'journal', lambda uid, name: self.allowed and uid == 1101 and name == 'td',
                               backend_factory=lambda deadline: self.backend, verify=self.verify)
        self.msg = {'v': 1, 'op': 'env-put', 'project': 'example', 'env': 'dev', 'values': {'TOKEN': 'invented-token'},
                    'overwrite': False, 'request_id': str(uuid.uuid4())}
    def tearDown(self): self.temp.cleanup()
    def verify(self, *args):
        if not self.visible: raise m.WriteError('pending')
    def run_write(self, msg=None): return self.engine.run(msg or self.msg, 1101, 'td')
    def next(self, **changes): return dict(self.msg, request_id=str(uuid.uuid4()), **changes)
    def test_create_full_hidden_batch_and_metadata_receipt(self):
        self.msg['values']['SECOND'] = 'invented-other'
        result = self.run_write()
        self.assertEqual(set(result), {'id', 'project', 'env', 'names', 'verified'})
        self.assertEqual(self.backend.calls.count('create'), 1)
        row = self.backend.get(result['id'])
        self.assertEqual(row['organizationId'], None)
        self.assertTrue(all(field['type'] == 1 for field in row['fields']))
        for file in (self.root / 'journal').glob('*'):
            self.assertNotIn(b'invented-token', file.read_bytes())
            self.assertEqual(file.stat().st_mode & 0o777, 0o600)
    def test_edit_preserves_unrelated_and_identical_is_noop(self):
        result = self.run_write()
        row = self.backend.records[result['id']]
        row['fields'].append({'name': 'UNRELATED', 'value': 'invented-preserved', 'type': 1})
        self.run_write(self.next())
        self.assertNotIn('edit', self.backend.calls)
        self.run_write(self.next(values={'TOKEN': 'invented-changed'}, overwrite=True))
        self.assertEqual(self.backend.calls.count('edit'), 1)
        self.assertEqual(self.backend.records[result['id']]['fields'][1]['value'], 'invented-preserved')
    def test_conflict_zero_mutation_and_same_uuid_explicit_retry(self):
        self.run_write()
        change = self.next(values={'TOKEN': 'invented-changed', 'NEW': 'invented-new'})
        with self.assertRaises(m.WriteError) as caught: self.run_write(change)
        self.assertEqual(caught.exception.code, 'conflict')
        self.assertNotIn('edit', self.backend.calls)
        self.run_write(dict(change, overwrite=True))
        self.assertEqual(self.backend.calls.count('edit'), 1)
    def test_lost_reply_same_uuid_reconcile_without_replay(self):
        self.backend.fail_after_create = True
        with self.assertRaises(m.WriteError): self.run_write()
        self.backend.fail_after_create = False
        result = self.run_write()
        self.assertTrue(result['verified'])
        self.assertEqual(self.backend.calls.count('create'), 1)
    def test_pending_changed_payload_and_new_uuid_never_mutate(self):
        self.backend.fail_after_create = True
        with self.assertRaises(m.WriteError): self.run_write()
        for change in (dict(self.msg, values={'TOKEN': 'invented-different'}, overwrite=True), self.next()):
            with self.assertRaises(m.WriteError) as caught: self.run_write(change)
            self.assertEqual(caught.exception.code, 'pending')
        self.assertEqual(self.backend.calls.count('create'), 1)
    def test_complete_old_uuid_never_replays_after_later_edit(self):
        self.run_write()
        self.run_write(self.next(values={'TOKEN': 'invented-later'}, overwrite=True))
        with self.assertRaises(m.WriteError): self.run_write()
        self.assertEqual(self.backend.calls.count('edit'), 1)
    def test_stale_visibility_pending_then_reconcile(self):
        self.visible = False
        with self.assertRaises(m.WriteError): self.run_write()
        self.visible = True
        self.run_write()
        self.assertEqual(self.backend.calls.count('create'), 1)
    def test_policy_denials_and_revocation_after_backend_wait(self):
        for uid, name in ((1102, 'yc'), (0, 'td'), (1101, 'yc'), (1000, 'owner')):
            with self.assertRaises(m.WriteError): self.engine.run(self.msg, uid, name)
        self.assertEqual(self.backend.calls, [])
        def revoke(): self.allowed = False
        self.backend.sync = revoke
        with self.assertRaises(m.WriteError): self.run_write()
        self.assertEqual(self.backend.records, {})
    def test_schema_boundaries_and_no_raw_selectors(self):
        changes = [{'folder': 'Shared/Env'}, {'project': '../td'}, {'project': 'x/y'}, {'env': 'a\n'},
                   {'request_id': 'not-uuid'}, {'overwrite': 1}, {'values': {'PATH': 'invented'}},
                   {'values': {'LD_PRELOAD': 'invented'}}, {'values': {'A': '\0'}},
                   {'values': {'A': 'x' * 5001}}, {'values': {'A' * 101: 'invented'}},
                   {'values': {'K' + str(index): 'invented' for index in range(65)}}]
        for change in changes:
            with self.subTest(change=list(change)):
                with self.assertRaises(m.WriteError): self.run_write(dict(self.msg, **change))
        self.assertEqual(self.backend.calls, [])
        m.request_data(dict(self.msg, values={'K' + str(i): 'invented' for i in range(64)}))
    def test_unmarked_protected_org_trash_and_wrong_type_refuse(self):
        result = self.run_write()
        original = copy.deepcopy(self.backend.records[result['id']])
        for delta in ({'notes': 'owner-created'}, {'reprompt': 1}, {'organizationId': 'org-invented'},
                      {'deletedDate': 'invented-date'}, {'type': 1}, {'attachments': [{'id': 'invented'}]},
                      {'secureNote': {'type': 1}}):
            self.backend.records[result['id']] = dict(copy.deepcopy(original), **delta)
            with self.assertRaises(m.WriteError): self.run_write(self.next(overwrite=True))
        self.assertNotIn('edit', self.backend.calls)
    def test_duplicate_targets_and_folders_refuse(self):
        result = self.run_write()
        duplicate = dict(self.backend.records[result['id']], id=str(uuid.uuid4()))
        self.backend.records[duplicate['id']] = duplicate
        with self.assertRaises(m.WriteError): self.run_write(self.next())
        self.backend.records.pop(duplicate['id'])
        self.backend.folder_rows.append(dict(self.backend.folder_rows[0], id=str(uuid.uuid4())))
        with self.assertRaises(m.WriteError): self.run_write(self.next())
    def test_global_self_namespace_and_unresolved_folder_creation(self):
        result = self.run_write(dict(self.msg, project='global', env='default'))
        folder = next(row for row in self.backend.folder_rows if row['name'] == 'Users/td/Env/global')
        self.assertEqual(self.backend.records[result['id']]['folderId'], folder['id'])
        self.assertFalse(any('Shared' in row['name'] for row in self.backend.folder_rows))

    def test_private_journal_rejects_symlink_and_writable_parents(self):
        elsewhere = self.root / 'elsewhere'; elsewhere.mkdir(mode=0o700)
        self.engine.directory.symlink_to(elsewhere, target_is_directory=True)
        with self.assertRaises((m.WriteError, OSError)): self.run_write()
        self.assertEqual(list(elsewhere.iterdir()), [])
        self.engine.directory.unlink()
        self.root.chmod(0o777)
        with self.assertRaises(m.WriteError): self.run_write()
        self.root.chmod(0o700)
        self.assertEqual(self.backend.calls, [])

    def test_same_target_concurrent_creates_serialize(self):
        results, errors = [], []
        def run(msg):
            try: results.append(self.run_write(msg))
            except BaseException as error: errors.append(error)
        threads = [threading.Thread(target=run, args=(dict(self.msg, request_id=str(uuid.uuid4())),)) for _ in range(2)]
        for thread in threads: thread.start()
        for thread in threads: thread.join(2)
        self.assertFalse(any(thread.is_alive() for thread in threads))
        self.assertEqual(errors, [])
        self.assertEqual(len(results), 2)
        self.assertEqual(self.backend.calls.count('create'), 1)

    def test_bad_receipt_and_final_readback_never_complete(self):
        create = self.backend.create
        def wrong(document):
            result = create(document); result['organizationId'] = 'invented-org'; return result
        self.backend.create = wrong
        with self.assertRaises(m.WriteError): self.run_write()
        pending = [json.loads(p.read_text()) for p in self.engine.directory.glob('*.json')]
        self.assertEqual(pending[0]['state'], 'pending')
        self.assertFalse(any(p.name.startswith('done-') for p in self.engine.directory.iterdir()))

    def test_pending_existing_edit_binds_original_values_and_overwrite(self):
        result = self.run_write()
        change = self.next(values={'TOKEN': 'invented-changed'}, overwrite=True)
        def ambiguous(ident, document): raise m.WriteError()
        self.backend.edit = ambiguous
        with self.assertRaises(m.WriteError): self.run_write(change)
        for altered in (dict(change, values=self.msg['values']), dict(change, overwrite=False)):
            with self.assertRaises(m.WriteError) as caught: self.run_write(altered)
            self.assertEqual(caught.exception.code, 'pending')
        self.assertEqual(self.backend.records[result['id']]['fields'][0]['value'], self.msg['values']['TOKEN'])

    def test_tombstone_precedes_complete_and_failure_cannot_replay_uuid(self):
        save = self.engine.save
        def fail_target_complete(target, row):
            if not target.startswith('done-') and row['state'] == 'complete': raise OSError('invented failure')
            save(target, row)
        self.engine.save = fail_target_complete
        with self.assertRaises(m.WriteError): self.run_write()
        self.assertTrue((self.engine.directory / ('done-' + self.msg['request_id'] + '.json')).exists())
        pending = [json.loads(p.read_text()) for p in self.engine.directory.glob('*.json') if not p.name.startswith('done-')]
        self.assertEqual(pending[0]['state'], 'pending')
        with self.assertRaises(m.WriteError): self.run_write(self.next(overwrite=True))
        self.engine.save = save
        self.run_write()
        self.run_write(self.next(values={'TOKEN': 'invented-later'}, overwrite=True))
        with self.assertRaises(m.WriteError): self.run_write()
        self.assertEqual(self.backend.calls.count('create'), 1)

    def test_fixed_capacity_refuses_new_work_without_evicting_recovery(self):
        self.engine.MAX_COMPLETED = 1
        self.run_write()
        before = {path.name: path.read_bytes() for path in self.engine.directory.iterdir()}
        with self.assertRaises(m.WriteError) as caught: self.run_write(self.next(overwrite=True))
        self.assertEqual(caught.exception.code, 'pending')
        self.assertEqual(before, {path.name: path.read_bytes() for path in self.engine.directory.iterdir()})
        self.run_write()  # the retained exact request remains reconcilable at capacity

    def test_merged_field_cap_preflight_allows_replacement_not_growth(self):
        result = self.run_write()
        row = self.backend.records[result['id']]
        row['fields'] += [{'name': 'EXISTING_' + str(i), 'value': 'invented-existing', 'type': 1} for i in range(511)]
        before = {p.name: p.read_bytes() for p in self.engine.directory.iterdir()}
        with self.assertRaises(m.WriteError): self.run_write(self.next(values={'NEW': 'invented-new'}, overwrite=True))
        self.assertNotIn('edit', self.backend.calls)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.engine.directory.iterdir()})
        self.run_write(self.next(values={'TOKEN': 'invented-replaced'}, overwrite=True))
        self.assertEqual(len(self.backend.records[result['id']]['fields']), 512)
        self.assertEqual(self.backend.calls.count('edit'), 1)


if __name__ == '__main__': unittest.main()
