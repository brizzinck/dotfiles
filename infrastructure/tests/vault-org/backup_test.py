#!/usr/bin/env python3
"""Encrypted backup gate with invented metadata and ciphertext, no real CLI/session/desktop."""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest

SOURCE = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).resolve().parents[3] / '.config/hypr/scripts/vault-org.py'
spec = importlib.util.spec_from_file_location('backup_under_test', SOURCE)
v = importlib.util.module_from_spec(spec)
v.__file__ = str(Path(__file__).resolve().parents[3] / '.config/hypr/scripts/vault-org.py')
exec(compile(SOURCE.read_text(), str(SOURCE), 'exec'), v.__dict__)
PLAN = 'a' * 64


def item(ident, org=None):
    return {'id': ident, 'organizationId': org, 'folderId': 'folder-one', 'type': 1,
            'revisionDate': '2026-10-18T12:00:00Z', 'name': 'Invented private name',
            'login': {'password': 'invented-password-sentinel'}}


class Backend:
    def __init__(self, items=None):
        self.items = items if items is not None else [item('personal-one'), item('org-one', 'org-a')]
        self.folders = [{'id': 'folder-one', 'name': 'Invented folder'}]
        self.calls = []
        self.exports = []
        self.edit_export = lambda doc, org: None
        self.after_exports = lambda: None
        self.served = None
        self.fail = 'never'
        self.syncs = 0

    def bw_cli(self, *args):
        self.calls.append(('cli', args))
        if args == ('sync',):
            self.syncs += 1
            if self.syncs == 2:
                self.after_exports()
            doc = 'Sync complete'
        elif args[:2] == ('list', 'items'):
            doc = self.items
        elif args[:2] == ('list', 'folders'):
            doc = self.folders
        elif args[0] == 'export':
            org = args[args.index('--organizationid') + 1] if '--organizationid' in args else None
            self.exports.append(org)
            if self.fail == org or self.fail == 'all':
                return types.SimpleNamespace(returncode=1, stdout='', stderr='invented-password-sentinel')
            doc = {'encrypted': True, 'encKeyValidation_DO_NOT_EDIT': '2.INVENTED-CIPHERTEXT',
                   'items': [{'id': i['id'], 'organizationId': org, 'name': '2.INVENTED-CIPHERTEXT', 'revisionDate': i['revisionDate'], 'type': i['type']}
                             for i in self.items if i.get('organizationId') == org and not i.get('deletedDate')]}
            if org is None:
                doc['folders'] = [{'id': f['id'], 'name': '2.INVENTED-CIPHERTEXT'} for f in self.folders]
            self.edit_export(doc, org)
            path = Path(args[args.index('--output') + 1])
            path.write_text(json.dumps(doc))
            doc = 'Export complete'
        else:
            raise AssertionError(args)
        return types.SimpleNamespace(returncode=0, stdout=json.dumps(doc), stderr='')

    def bw(self, *args):
        self.calls.append(('service', args))
        if args == ('sync',):
            data = {}
        elif args[:2] == ('list', 'items'):
            data = self.items if self.served is None else self.served
        elif args[:2] == ('list', 'folders'):
            data = self.folders
        else:
            raise AssertionError('mutation before verified backup: ' + repr(args))
        return types.SimpleNamespace(returncode=0, stdout=json.dumps(data), stderr='')


class Backups(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='fake-backup-')
        self.root = Path(self.tmp.name)
        self.old = v.BACKUPS
        v.BACKUPS = self.root / 'data' / 'vault-backups'

    def tearDown(self):
        v.BACKUPS = self.old
        self.tmp.cleanup()

    def backup(self, backend, plan=PLAN):
        return v.backup_export(backend, plan)

    def refused(self, backend):
        with self.assertRaises(v.Fail) as caught:
            self.backup(backend)
        message = str(caught.exception)
        self.assertIn('backup failed: nothing was changed', message)
        self.assertNotIn('invented-password', message)
        self.assertNotIn('Invented private name', message)
        self.assertEqual([], list(v.BACKUPS.glob('.pending-*')))
        return message

    def test_mixed_ownership_complete_bundle_and_original_mapping(self):
        b = Backend()
        path = self.backup(b)
        doc = json.loads((path / 'manifest.json').read_text())
        self.assertEqual([None, 'org-a'], b.exports)
        self.assertEqual(('cli', ('sync',)), b.calls[0])
        self.assertEqual(2, b.syncs)
        self.assertEqual(PLAN, doc['planSha256'])
        self.assertEqual({'personal-one', 'org-one'}, set(doc['items']))
        self.assertEqual('folder-one', doc['items']['org-one']['folderId'])
        self.assertEqual('org-a', doc['items']['org-one']['organizationId'])
        self.assertEqual(['folder-one'], doc['folderIds'])
        self.assertEqual(0o700, path.stat().st_mode & 0o777)
        for f in path.iterdir():
            self.assertEqual(0o600, f.stat().st_mode & 0o777)
            text = f.read_text()
            self.assertNotIn('invented-password', text)
            self.assertNotIn('Invented private name', text)
            self.assertNotIn('Invented folder', text)

    def test_all_personal_and_multiple_orgs(self):
        for items, expected in (([item('personal')], [None]),
                                ([item('org', 'org-a'), item('other', 'org-b')], [None, 'org-a', 'org-b'])):
            b = Backend(items)
            self.backup(b)
            self.assertEqual(expected, b.exports)

    def test_equal_count_wrong_id_missing_and_duplicate_refused(self):
        for change in ('wrong', 'missing', 'duplicate', 'cross-org', 'revision', 'type'):
            with self.subTest(change=change):
                b = Backend()
                def edit(doc, org):
                    if org is None:
                        if change == 'wrong': doc['items'][0]['id'] = 'wrong-id'
                        elif change == 'missing': doc['items'] = []
                        elif change == 'duplicate': doc['items'] *= 2
                        elif change == 'cross-org': doc['items'][0]['organizationId'] = 'org-a'
                        elif change == 'revision': doc['items'][0]['revisionDate'] = 'stale'
                        else: doc['items'][0]['type'] = 2
                b.edit_export = edit
                self.refused(b)

    def test_extra_org_only_allowed_without_missing_or_wrong_ownership(self):
        b = Backend()
        def extra(doc, org):
            if org:
                doc['items'].append({'id': 'extra-hidden-org-item', 'organizationId': org, 'name': '2.INVENTED', 'type': 1, 'revisionDate': '2026-10-18T12:00:00Z'})
        b.edit_export = extra
        path = self.backup(b)
        self.assertEqual(1, json.loads((path / 'manifest.json').read_text())['exports'][1]['extra'])
        for mode in ('missing', 'wrong-org', 'cross-partition-id'):
            b = Backend()
            def edit(doc, org):
                extra(doc, org)
                if org:
                    if mode == 'missing': doc['items'].pop(0)
                    elif mode == 'wrong-org': doc['items'][-1]['organizationId'] = 'other-org'
                    else: doc['items'][-1]['id'] = 'personal-one'
            b.edit_export = edit
            self.refused(b)

    def test_org_permission_failure_is_fixed_and_no_completed_bundle(self):
        b = Backend(); b.fail = 'org-a'
        self.refused(b)
        self.assertEqual([], list(v.BACKUPS.glob('vault-*')))

    def test_invalid_encryption_modes_and_folder_ids_refused(self):
        for change in ('plain', 'validation', 'password', 'folder-missing', 'folder-duplicate'):
            b = Backend()
            def edit(doc, org):
                if org is None:
                    if change == 'plain': doc['encrypted'] = False
                    elif change == 'validation': doc.pop('encKeyValidation_DO_NOT_EDIT')
                    elif change == 'password': doc['passwordProtected'] = True
                    elif change == 'folder-missing': doc['folders'] = []
                    else: doc['folders'] *= 2
            b.edit_export = edit
            with self.subTest(change=change): self.refused(b)

    def test_metadata_races_and_stale_served_inventory_refused(self):
        for key, value in (('id', 'changed'), ('organizationId', 'other-org'), ('revisionDate', 'changed'), ('folderId', None)):
            b = Backend()
            b.after_exports = lambda: b.items[0].update({key: value})
            with self.subTest(key=key): self.refused(b)
        b = Backend(); b.served = [item('stale-id')]
        self.assertIn('inventories differ', self.refused(b))

    def test_invalid_inventory_and_trash_never_count_as_coverage(self):
        for items in ([item('same'), item('same')], [dict(item('trash'), deletedDate='2026-01-01')],
                      [dict(item('bad'), organizationId=[])], [dict(item('bad'), folderId='unknown')]):
            with self.subTest(items=items): self.refused(Backend(items))

    def test_backend_exceptions_never_escape_with_raw_values(self):
        for backend in ('cli', 'service'):
            b = Backend()
            def fail(*args):
                raise v.Fail('invented-password-sentinel')
            setattr(b, 'bw_cli' if backend == 'cli' else 'bw', fail)
            with self.subTest(backend=backend): self.refused(b)

    def test_unsafe_backup_parent_symlink_refused(self):
        other = self.root / 'other'; other.mkdir()
        (self.root / 'data').symlink_to(other, target_is_directory=True)
        self.refused(Backend())
        self.assertEqual([], list(other.iterdir()))

    def test_failed_new_bundle_and_repeated_resume_preserve_every_original(self):
        original = self.backup(Backend())
        b = Backend(); b.fail = 'org-a'; self.refused(b)
        self.assertTrue((original / 'manifest.json').is_file())
        for n in range(7): self.backup(Backend(), 'b' * 64)
        self.backup(Backend())
        complete = list(v.BACKUPS.glob('vault-*'))
        self.assertEqual(9, len(complete))
        self.assertTrue(original.exists())
        for bundle in complete:
            self.assertEqual(3, len(list(bundle.iterdir())))

    def test_unrecognized_or_extra_contents_never_pruned(self):
        foreign = v.BACKUPS / 'vault-foreign'
        foreign.mkdir(parents=True, mode=0o700)
        (foreign / 'manifest.json').write_text(json.dumps({'version': 1, 'complete': True, 'planSha256': 'b' * 64}))
        (foreign / 'unrelated').write_text('invented-user-recovery-data')
        self.backup(Backend())
        self.assertEqual('invented-user-recovery-data', (foreign / 'unrelated').read_text())

    def test_interrupted_export_cleans_pending_without_losing_original(self):
        original = self.backup(Backend())
        b = Backend()
        def interrupt(doc, org):
            raise KeyboardInterrupt
        b.edit_export = interrupt
        with self.assertRaises(KeyboardInterrupt): self.backup(b)
        self.assertEqual([], list(v.BACKUPS.glob('.pending-*')))
        self.assertTrue((original / 'manifest.json').is_file())

    def test_backup_failure_prevents_every_mutation_and_journal_success(self):
        class Journal:
            sha = PLAN
            def log(self, *args): raise AssertionError('backup failure must not journal success')
        b = Backend(); b.fail = 'org-a'
        a = v.Applier(b, [], Journal(), None)
        def mutation(): raise AssertionError('backup failure must prevent every mutation')
        for name in ('renames', 'creates', 'moves', 'trash', 'empty_folders', 'finish'):
            setattr(a, name, mutation)
        with self.assertRaises(v.Fail): a.run()

    def test_resume_bare_backup_row_never_skips_fresh_gate(self):
        class Journal:
            sha = PLAN
            def seen(self, *args): return True
            def log(self, *args): pass
        calls = []
        old = v.backup_export
        v.backup_export = lambda m, plan: calls.append(plan) or Path('invented')
        try:
            a = v.Applier(None, [], Journal(), None)
            for name in ('renames', 'creates', 'moves', 'trash', 'empty_folders', 'finish'):
                setattr(a, name, lambda: None)
            a.summary = lambda: 0
            with contextlib.redirect_stdout(io.StringIO()): self.assertEqual(0, a.run())
            self.assertEqual([PLAN], calls)
        finally:
            v.backup_export = old


if __name__ == '__main__':
    unittest.main()
