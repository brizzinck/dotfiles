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
from unittest import mock

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
        self.cli_folder_sentinel = None
        self.service_folder_sentinel = None
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
            doc = self.folders + ([self.cli_folder_sentinel] if self.cli_folder_sentinel is not None else [])
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
            data = self.folders + ([self.service_folder_sentinel] if self.service_folder_sentinel is not None else [])
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

    def test_official_no_folder_sentinels_normalize_cli_and_service(self):
        expected = {'folder-one': 'Invented folder'}
        for cli_id, service_id in ((None, None), ('', ''), (None, ''), ('', None)):
            with self.subTest(cli_id=cli_id, service_id=service_id):
                b = Backend()
                b.items[0]['folderId'] = None
                b.cli_folder_sentinel = {'object': 'folder', 'id': cli_id, 'name': 'No Folder'}
                b.service_folder_sentinel = {'object': 'folder', 'id': service_id, 'name': 'No Folder'}
                self.assertEqual(expected, v.backup_snapshot(b)['folders'])
                self.assertEqual(expected, v.backup_snapshot(b, cli=False)['folders'])
                self.assertEqual(expected, v.Applier(b, [], None, None).live_folders())
                path = self.backup(b)
                manifest = json.loads((path / 'manifest.json').read_text())
                self.assertEqual(['folder-one'], manifest['folderIds'])
                self.assertIsNone(manifest['items']['personal-one']['folderId'])
                self.assertEqual(['folder-one'], [f['id'] for f in json.loads((path / 'personal.json').read_text())['folders']])

    def test_only_exact_unique_no_folder_sentinel_is_ignored(self):
        invalid = [
            {'object': 'folder', 'name': 'No Folder'},
            {'id': None, 'name': 'No Folder'},
            {'object': 'item', 'id': None, 'name': 'No Folder'},
            {'object': 'folder', 'id': None, 'name': 'Invented missing-ID folder'},
            {'object': 'folder', 'id': '', 'name': 'No folder'},
            {'object': 'folder', 'id': 0, 'name': 'No Folder'},
            {'object': 'folder', 'id': None, 'name': 'No Folder', 'extra': 'invented'},
        ]
        for record in invalid:
            for served in (False, True):
                with self.subTest(record=record, served=served):
                    b = Backend()
                    b.folders.append(record)
                    with self.assertRaises(v.Fail): v.backup_snapshot(b, cli=not served)
                    with self.assertRaises(v.Fail): v.Applier(b, [], None, None).live_folders()
        for duplicate in (
            [{'object': 'folder', 'id': None, 'name': 'No Folder'}] * 2,
            [{'object': 'folder', 'id': None, 'name': 'No Folder'}, {'object': 'folder', 'id': '', 'name': 'No Folder'}],
            [{'id': 'folder-one', 'name': 'Duplicate real folder'}],
        ):
            b = Backend(); b.folders.extend(duplicate)
            with self.assertRaises(v.Fail): v.backup_snapshot(b)
            with self.assertRaises(v.Fail): v.Applier(b, [], None, None).live_folders()

    def test_real_no_folder_name_remains_in_exact_export_coverage(self):
        b = Backend()
        real_id = '11111111-2222-4333-8444-000000000001'
        b.folders.append({'object': 'folder', 'id': real_id, 'name': 'No Folder'})
        b.cli_folder_sentinel = {'object': 'folder', 'id': '', 'name': 'No Folder'}
        b.service_folder_sentinel = {'object': 'folder', 'id': None, 'name': 'No Folder'}
        path = self.backup(b)
        self.assertEqual(sorted(['folder-one', real_id]), json.loads((path / 'manifest.json').read_text())['folderIds'])
        b.edit_export = lambda doc, org: doc.update(folders=doc['folders'][:1]) if org is None else None
        self.assertIn('folder coverage', self.refused(b))

    def test_apply_with_official_cli_and_service_sentinels_completes(self):
        class Journal:
            sha = PLAN
            def seen(self, *args): return False
            def log(self, *args): pass
        class ApplyBackend(Backend):
            def b64(self, obj): return obj
            def bw(self, *args, stdin=None):
                if args[:2] == ('get', 'item'):
                    return types.SimpleNamespace(returncode=0, stdout=json.dumps(next(i for i in self.items if i['id'] == args[2])), stderr='')
                if args[:2] == ('edit', 'item'):
                    self.items = [copy.deepcopy(stdin) if i['id'] == args[2] else i for i in self.items]
                    return types.SimpleNamespace(returncode=0, stdout=json.dumps(stdin), stderr='')
                return super().bw(*args)
        for sentinel_id in (None, ''):
            with self.subTest(sentinel_id=sentinel_id):
                b = ApplyBackend([item('personal-one')])
                b.folders.append({'object': 'folder', 'id': 'folder-two', 'name': 'Destination'})
                b.cli_folder_sentinel = {'object': 'folder', 'id': sentinel_id, 'name': 'No Folder'}
                b.service_folder_sentinel = {'object': 'folder', 'id': '' if sentinel_id is None else None, 'name': 'No Folder'}
                row = v.Row('item', 'personal-one', 'Invented private name', 'Invented folder', 'folder:Destination')
                applier = v.Applier(b, [row], Journal(), None)
                applier.finish = lambda: None
                applier.summary = lambda: 5 if applier.skipped else 0
                with contextlib.redirect_stdout(io.StringIO()): self.assertEqual(0, applier.run())
                self.assertEqual('folder-two', b.items[0]['folderId'])
                self.assertEqual(1, applier.counts['moved'])

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

    def test_each_failed_request_identifies_fixed_stage_and_rc_without_backend_output(self):
        stages = [('cli', ('sync',)), ('cli', ('list', 'folders')), ('cli', ('list', 'items')),
                  ('cli', ('export', 'personal')), ('cli', ('export', 'organization')),
                  ('cli', ('sync',)), ('cli', ('list', 'folders')), ('cli', ('list', 'items')),
                  ('service', ('sync',)), ('service', ('list', 'folders')), ('service', ('list', 'items'))]
        expected = ['initial-sync', 'initial-folders', 'initial-items', 'personal-export', 'organization-export',
                    'verify-sync', 'verify-folders', 'verify-items', 'service-sync', 'service-folders', 'service-items']
        for n, stage in enumerate(expected):
            b = Backend(); requests = []
            cli, service = b.bw_cli, b.bw
            def request(transport, original, args):
                logical = args if args[0] != 'export' else ('export', 'organization' if '--organizationid' in args else 'personal')
                requests.append((transport, logical))
                if len(requests) == n + 1:
                    return types.SimpleNamespace(returncode=23, stdout='invented-password-sentinel\x1b]52;poison\x07',
                                                 stderr='Invented private name\n/org-a/private/path\x1b[31m')
                return original(*args)
            b.bw_cli = lambda *args: request('cli', cli, args)
            b.bw = lambda *args: request('service', service, args)
            with self.subTest(stage=stage):
                message = self.refused(b)
                self.assertEqual(f'backup failed: nothing was changed (stage={stage} rc=23 category=unknown)', message)
                self.assertEqual(stages[:n + 1], requests)
                self.assertFalse(list(v.BACKUPS.glob('vault-*')))

    def test_failure_categories_require_exact_public_messages(self):
        messages = {
            'You are not logged in.': 'not-logged-in', 'Vault is locked.': 'locked',
            'One or more organization policies prevents you from exporting your personal vault.': 'personal-export-policy',
            'No encryption key found for organization': 'organization-key-unavailable',
            'Error: No encryption key found for organization': 'organization-key-unavailable',
        }
        for message, category in messages.items():
            for transport in ('stdout', 'stderr'):
                for suffix in ('', '\n', '\nsecret\x1b[31m', '\r', '\n\n'):
                    p = types.SimpleNamespace(returncode=1, stdout='', stderr='')
                    setattr(p, transport, message + suffix)
                    b = types.SimpleNamespace(bw_cli=lambda *args: p)
                    with self.subTest(message=message, transport=transport, suffix=suffix):
                        with self.assertRaises(v.Fail) as caught: v.backup_cli(b, 'sync', stage='initial-sync')
                        wanted = category if suffix in ('', '\n') else 'unknown'
                        self.assertEqual(f'backup failed: nothing was changed (stage=initial-sync rc=1 category={wanted})', str(caught.exception))
        p = types.SimpleNamespace(returncode=1, stdout='invented-password-sentinel', stderr='Vault is locked.')
        self.assertEqual('unknown', v.backup_error_category(p))

    def test_backend_exception_and_invalid_results_have_safe_numeric_rc(self):
        failures = [(FileNotFoundError('invented-password-sentinel'), 'unavailable'),
                    (v.subprocess.TimeoutExpired('invented-password-sentinel', 1), 'timeout'),
                    (v.Fail('invented-password-sentinel'), 'exception')]
        for error, category in failures:
            def fail(*args): raise error
            with self.subTest(category=category), self.assertRaises(v.Fail) as caught:
                v.backup_cli(types.SimpleNamespace(bw_cli=fail), 'sync', stage='initial-sync')
            self.assertEqual(f'backup failed: nothing was changed (stage=initial-sync rc=-1 category={category})', str(caught.exception))
        for rc, category in ((True, 'invalid-response'), ('secret', 'invalid-response'), (10**100, 'invalid-response'), (-15, 'signal')):
            p = types.SimpleNamespace(returncode=rc, stdout='secret', stderr='secret')
            with self.subTest(rc=rc), self.assertRaises(v.Fail) as caught:
                v.backup_cli(types.SimpleNamespace(bw_cli=lambda *args: p), 'sync', stage='initial-sync')
            self.assertEqual(f'backup failed: nothing was changed (stage=initial-sync rc={-15 if rc == -15 else -1} category={category})', str(caught.exception))

    @contextlib.contextmanager
    def backup_only_fixture(self):
        b = Backend(); b.RUN = self.root / 'runtime'
        b.status = mock.Mock(return_value='unlocked')
        b.ensure = mock.Mock(side_effect=AssertionError('unexpected unlock'))
        plan, journal, rules = (self.root / name for name in ('plan', 'journal', 'rules'))
        for path in (plan, journal, rules): path.write_text('invented existing ' + path.name)
        rows = [v.Row('item', 'personal-one', 'Invented private name', 'Invented folder', 'folder:Destination')]
        forbidden = mock.Mock(side_effect=AssertionError('backup-only reached journal, confirmation or vault mutations'))
        with contextlib.ExitStack() as stack:
            for name, value in {'vbw': lambda: b, 'load_plan': lambda: ({}, rows), 'validate_plan': lambda *args: [],
                                'agent': lambda: None, 'PLAN': plan, 'JOURNAL': journal, 'Journal': forbidden,
                                'Applier': forbidden, 'confirm': forbidden}.items():
                stack.enter_context(mock.patch.object(v, name, value))
            yield b, rows, forbidden
        for path in (plan, journal, rules): self.assertEqual('invented existing ' + path.name, path.read_text())

    def test_backup_only_verifies_bundle_without_confirmation_journal_or_any_mutator(self):
        with self.backup_only_fixture() as (b, rows, forbidden):
            for no_changes in (False, True):
                if no_changes: rows[0].target = 'keep'
                output = io.StringIO()
                with contextlib.redirect_stdout(output): self.assertEqual(0, v.apply_plan(['--backup-only']))
                self.assertIn('backup verified and retained:', output.getvalue())
                self.assertIn('no journal, folders or items were changed', output.getvalue())
            self.assertEqual(2, len(list(v.BACKUPS.glob('vault-*'))))
            self.assertEqual(2, b.status.call_count)
            forbidden.assert_not_called(); b.ensure.assert_not_called()
            self.assertTrue(all(args[0] in ('list', 'sync', 'export') for _, args in b.calls))

    def test_backup_only_failure_and_agent_gate_never_reach_mutators_or_journal(self):
        with self.backup_only_fixture() as (b, rows, forbidden):
            b.fail = 'org-a'
            with self.assertRaises(v.Fail) as caught: v.apply_plan(['--backup-only'])
            self.assertIn('stage=organization-export rc=1 category=unknown', str(caught.exception))
            forbidden.assert_not_called()
            b.calls.clear(); b.status.reset_mock()
            with mock.patch.object(v, 'agent', return_value='invented-agent'):
                with self.assertRaises(v.Fail) as caught: v.apply_plan(['--backup-only'])
            self.assertEqual(4, caught.exception.code)
            b.status.assert_not_called(); forbidden.assert_not_called()
            self.assertEqual([], b.calls)

    def test_backup_only_dry_run_invalid_plan_and_incompatible_flags_do_not_open_backend(self):
        with self.backup_only_fixture() as (b, rows, forbidden):
            for flag in ('--resume', '--new-journal', '--yes'):
                with self.assertRaises(v.Fail) as caught: v.apply_plan(['--backup-only', flag])
                self.assertEqual(2, caught.exception.code)
            with contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(0, v.apply_plan(['--backup-only', '--dry-run']))
            self.assertIn('would verify and retain', output.getvalue())
            with mock.patch.object(v, 'validate_plan', return_value=['invented invalid plan']):
                with self.assertRaises(v.Fail) as caught: v.apply_plan(['--backup-only'])
                self.assertEqual(4, caught.exception.code)
            b.status.assert_not_called(); forbidden.assert_not_called()
            self.assertEqual([], b.calls)
            self.assertFalse(v.BACKUPS.exists())

    def test_invalid_encryption_modes_and_folder_ids_refused(self):
        for change in ('plain', 'validation', 'password', 'folder-missing', 'folder-duplicate', 'synthetic-folder'):
            b = Backend()
            def edit(doc, org):
                if org is None:
                    if change == 'plain': doc['encrypted'] = False
                    elif change == 'validation': doc.pop('encKeyValidation_DO_NOT_EDIT')
                    elif change == 'password': doc['passwordProtected'] = True
                    elif change == 'folder-missing': doc['folders'] = []
                    elif change == 'folder-duplicate': doc['folders'] *= 2
                    else: doc['folders'].append({'object': 'folder', 'id': None, 'name': 'No Folder'})
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
