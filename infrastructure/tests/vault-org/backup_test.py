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


class PersonalBackend(Backend):
    def __init__(self):
        super().__init__([item('personal-one'), item('org-one', 'org-a'), item('personal-keep')])
        self.fail = 'org-a'    # faithful org export permission denial; personal export still succeeds
        self.writes = []
        self.before_get = lambda: None
        self.receipt = lambda doc: doc

    def b64(self, obj): return obj
    def status(self): return 'unlocked'
    def refresh_rbw(self): pass

    def bw(self, *args, stdin=None):
        if args[:2] == ('get', 'item'):
            self.before_get()
            data = copy.deepcopy(next((i for i in self.items if i['id'] == args[2]), None))
        elif args[:2] == ('edit', 'item'):
            self.writes.append(args)
            data = copy.deepcopy(stdin)
            data['revisionDate'] += '-moved'
            self.items = [data if i['id'] == args[2] else i for i in self.items]
            data = self.receipt(copy.deepcopy(data))
        elif args[:2] == ('create', 'folder'):
            self.writes.append(args)
            data = {'id': 'new-' + str(len(self.folders)), 'name': stdin['name']}
            self.folders.append(data)
        else:
            return super().bw(*args)
        self.calls.append(('service', args))
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


class Personal(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='fake-personal-')
        self.root = Path(self.tmp.name)
        self.b = PersonalBackend(); self.b.RUN = self.root / 'runtime'
        self.rows = [v.Row('item', 'personal-one', 'Old personal name', 'Invented folder', 'folder:Destination'),
                     v.Row('item', 'org-one', 'Old org name', 'Invented folder', 'folder:Org Destination'),
                     v.Row('item', 'personal-keep', 'Old keep name', 'Invented folder', 'keep')]
        self.header = {'version': 1, 'audit': 'FAKE-AUDIT', 'items': 3, 'generated': 'FAKE'}
        self.plan = self.root / 'plan.tsv'; self.plan.write_text(v.format_plan(self.header, self.rows))
        self.full = self.root / 'org-journal.tsv'; self.full.write_text('invented-original-full-journal\n')
        self.meta = self.root / 'plan.meta.json'; self.meta.write_text('invented-original-meta')
        self.rules = self.root / 'rules.tsv'; self.rules.write_text('invented-original-rules')
        (self.b.RUN / 'org').mkdir(parents=True)
        self.audit = self.b.RUN / 'org' / 'audit.json'; self.audit.write_text('{"items":[],"groups":[]}')
        self.preserved = {p: p.read_bytes() for p in (self.plan, self.full, self.meta, self.rules, self.audit)}
        self.stack = contextlib.ExitStack()
        for name, value in {'PLAN': self.plan, 'JOURNAL': self.full, 'STATE': self.root,
                            'BACKUPS': self.root / 'backups', 'vbw': lambda: self.b, 'agent': lambda: None,
                            'scope_rules': lambda: (v.vs().parse_rules('td\tDestination/**\nyc\tOrg Destination/**\n')[0], True),
                            'confirm': lambda lines: self.confirm(lines)}.items():
            self.stack.enter_context(mock.patch.object(v, name, value))
        self.confirmations = []

    def tearDown(self):
        self.stack.close(); self.tmp.cleanup()

    def confirm(self, lines):
        self.confirmations.append(lines)
        return True

    def apply(self, *args):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            rc = v.apply_plan(['--personal-only', *args])
        return rc, output.getvalue()

    def rewrite(self):
        self.plan.write_text(v.format_plan(self.header, self.rows))

    def test_mixed_scoped_apply_preserves_org_and_original_files_with_exact_personal_backup(self):
        org = copy.deepcopy(self.b.items[1])
        rc, output = self.apply()
        self.assertEqual(0, rc)
        self.assertEqual(org, self.b.items[1])
        self.assertEqual([None], self.b.exports)
        self.assertEqual(1, len(self.confirmations))
        self.assertIn('1 personal moves needed, 0 already at target, 1 new destination folders required', output)
        self.assertIn('1 organization move proposals left unchanged', output)
        self.assertIn('yc: 0 -> 0', output)
        self.assertEqual([('create', 'folder'), ('edit', 'item', 'personal-one')], self.b.writes)
        manifest = json.loads(next(v.BACKUPS.glob('vault-*/manifest.json')).read_text())
        self.assertEqual('personal-only-v1', manifest['scope'])
        self.assertEqual({'personal-one', 'personal-keep'}, set(manifest['items']))
        self.assertEqual(['folder-one'], manifest['folderIds'])
        self.assertEqual(1, len(manifest['exports']))
        for p, data in self.preserved.items(): self.assertEqual(data, p.read_bytes())
        for path in v.BACKUPS.glob('vault-*/*'):
            self.assertNotIn('invented-password', path.read_text())
            self.assertNotIn('Invented private name', path.read_text())
        self.assertTrue((self.root / 'org-personal-journal.tsv').read_text().startswith('# scope=personal-only-v1 '))

    def test_unsupported_actions_refuse_before_backend(self):
        for row in (v.Row('folder', 'folder-one', 'Invented folder', None, 'rename:Elsewhere'),
                    v.Row('folder', 'folder-one', 'Invented folder', None, 'delete-if-empty'),
                    v.Row('item', 'personal-one', 'Personal', None, 'trash-duplicate-of:personal-keep')):
            self.rows.append(row); self.rewrite()
            with self.subTest(target=row.target), self.assertRaises(v.Fail): self.apply()
            self.assertEqual([], self.b.calls)
            self.rows.pop()

    def test_invalid_ownership_and_missing_actionable_identity_fail_closed(self):
        for value in ('', [], False, 0, 'bad/id'):
            b = PersonalBackend(); b.RUN = self.b.RUN
            b.items[0]['organizationId'] = value
            with mock.patch.object(v, 'vbw', return_value=b), self.subTest(value=value), self.assertRaises(v.Fail): self.apply()
            self.assertEqual([], b.writes)
        self.b.items = self.b.items[1:]
        with self.assertRaises(v.Fail): self.apply()
        self.assertEqual([], self.b.writes)

    def test_backup_only_dry_run_and_zero_eligible_do_not_construct_journal(self):
        with mock.patch.object(v, 'Journal', side_effect=AssertionError('no journal in backup-only')):
            rc, output = self.apply('--backup-only')
        self.assertEqual(0, rc); self.assertIn('personal backup verified', output)
        self.assertEqual([], self.confirmations); self.assertEqual([], self.b.writes)
        self.b.calls.clear()
        self.assertEqual(0, self.apply('--dry-run')[0]); self.assertEqual([], self.b.calls)
        for r in self.rows: r.target = 'keep'
        self.rewrite()
        self.assertIn('no eligible personal moves', self.apply()[1])
        self.assertEqual([], self.confirmations)

    def test_scope_summary_uses_fresh_exact_names_new_keep_items_and_already_targets(self):
        self.b.folders.append({'id': 'destination', 'name': 'Destination'})
        self.b.items[0]['folderId'] = 'destination'
        self.b.items[0]['name'] = 'Fresh exact name'
        self.b.items.append(dict(item('unplanned'), name='New keep name'))
        with mock.patch.object(v, 'scope_rules', return_value=(v.vs().parse_rules(
                'td\tDestination/Fresh exact name\nyc\tInvented folder/New keep name\n')[0], False)):
            rc, output = self.apply()
        self.assertEqual(0, rc)
        self.assertIn('0 personal moves needed, 1 already at target, 0 new destination folders required', output)
        self.assertIn('td: 1 -> 1', output); self.assertIn('yc: 1 -> 1', output)
        self.assertEqual([], self.b.writes)

    def test_classification_or_source_plan_change_at_confirmation_refuses_before_backup(self):
        for key, value in (('organizationId', 'org-a'), ('id', 'wrong-id'), ('type', 2),
                           ('revisionDate', 'changed'), ('folderId', None), ('name', 'Changed name')):
            self.b = PersonalBackend(); self.b.RUN = self.root / 'runtime'
            def change(lines): self.b.items[0][key] = value; return True
            with mock.patch.object(v, 'confirm', side_effect=change), self.subTest(key=key), self.assertRaises(v.Fail): self.apply()
            self.assertEqual([], self.b.writes); self.assertEqual([], self.b.exports)
        with mock.patch.object(v, 'confirm', side_effect=lambda lines: self.plan.write_text('changed') or True):
            with self.assertRaises(v.Fail): self.apply()
        self.assertEqual([], self.b.writes)

    def test_invalid_export_ownership_and_coverage_fail_before_mutation(self):
        for change in ('ownership', 'missing', 'duplicate', 'plaintext'):
            self.b = PersonalBackend(); self.b.RUN = self.root / 'runtime'
            def edit(doc, org):
                if change == 'ownership': doc['items'][0]['organizationId'] = ''
                elif change == 'missing': doc['items'].pop()
                elif change == 'duplicate': doc['items'].append(copy.deepcopy(doc['items'][0]))
                else: doc['encrypted'] = False
            self.b.edit_export = edit
            with self.subTest(change=change), self.assertRaises(v.Fail): self.apply()
            self.assertEqual([], self.b.writes)

    def test_late_identity_ownership_type_revision_or_source_change_never_edits(self):
        self.b.folders.append({'id': 'destination', 'name': 'Destination'})
        for key, value in (('organizationId', 'org-a'), ('organizationId', ''), ('id', 'wrong-id'),
                           ('type', 2), ('revisionDate', 'changed'), ('folderId', None)):
            for at_target in (False, True):
                self.b.items[0] = item('personal-one')
                if at_target: self.b.items[0]['folderId'] = 'destination'
                def change():
                    if value == 'MISSING': self.b.items[0].pop(key, None)
                    else: self.b.items[0][key] = value
                self.b.before_get = change; self.b.writes.clear()
                with self.subTest(key=key, value=value, at_target=at_target):
                    self.assertEqual(5, self.apply()[0])
                    self.assertEqual([], [x for x in self.b.writes if x[:2] == ('edit', 'item')])

    def test_bad_receipt_and_poisoned_request_are_fixed_non_success(self):
        for key, value in (('organizationId', 'org-a'), ('organizationId', ''), ('id', 'wrong'), ('folderId', 'wrong')):
            self.b = PersonalBackend(); self.b.RUN = self.root / 'runtime'
            def receipt(doc):
                if value == 'MISSING': doc.pop(key)
                else: doc[key] = value
                return doc
            self.b.receipt = receipt
            with self.subTest(key=key, value=value):
                rc, output = self.apply()
                self.assertEqual(5, rc); self.assertIn('applied: 0 moved', output)
        self.b = PersonalBackend(); self.b.RUN = self.root / 'runtime'
        original = self.b.bw
        def poison(*args, **kwargs):
            if args[:2] == ('get', 'item'):
                raise v.Fail('invented-password-sentinel\x1b]52;poison\x07')
            return original(*args, **kwargs)
        self.b.bw = poison
        rc, output = self.apply()
        self.assertEqual(5, rc); self.assertNotIn('invented-password', output); self.assertNotIn('\x1b', output)
        self.assertNotIn('invented-password', (self.root / 'org-personal-journal.tsv').read_text())

    def test_official_omitted_and_null_personal_ownership_are_equivalent(self):
        for omitted in (False, True):
            self.b = PersonalBackend(); self.b.RUN = self.root / 'runtime'
            self.b.items[0]['folderId'] = None
            if omitted:
                for i in self.b.items:
                    if i['organizationId'] is None: i.pop('organizationId')
                self.b.items[0].pop('folderId')
                def omit_export(doc, org):
                    for i in doc['items']: i.pop('organizationId')
                self.b.edit_export = omit_export
            with self.subTest(omitted=omitted):
                self.assertEqual(0, self.apply()[0])
                self.assertIsNone(self.b.items[0].get('organizationId'))

    def test_resume_identity_survives_own_move_but_refuses_population_source_and_scope_changes(self):
        self.assertEqual(0, self.apply()[0])
        exports = len(self.b.exports)
        self.assertEqual(0, self.apply('--resume')[0])
        self.assertEqual(exports + 1, len(self.b.exports))
        self.assertEqual(1, len([w for w in self.b.writes if w[:2] == ('edit', 'item')]))
        personal_journal = self.root / 'org-personal-journal.tsv'
        saved = personal_journal.read_bytes()
        self.b.items[0]['organizationId'] = 'org-a'
        with self.assertRaises(v.Fail): self.apply('--resume')
        self.b.items[0]['organizationId'] = None
        self.plan.write_text(self.plan.read_text() + '# source changed\n')
        with self.assertRaises(v.Fail): self.apply('--resume')
        self.plan.write_bytes(self.preserved[self.plan])
        personal_journal.write_text('# plan-sha256=' + v.sha(self.plan.read_text()) + '\n')
        with self.assertRaises(v.Fail): self.apply('--resume')
        personal_journal.write_bytes(saved)
        self.assertEqual(self.preserved[self.full], self.full.read_bytes())

    def test_personal_sentinels_and_duplicate_identity_validation(self):
        for sentinel in (None, ''):
            self.b = PersonalBackend(); self.b.RUN = self.root / 'runtime'
            self.b.cli_folder_sentinel = {'object': 'folder', 'id': sentinel, 'name': 'No Folder'}
            self.b.service_folder_sentinel = {'object': 'folder', 'id': '' if sentinel is None else None, 'name': 'No Folder'}
            self.b.items[0]['folderId'] = None
            with self.subTest(sentinel=sentinel): self.assertEqual(0, self.apply()[0])
        self.b = PersonalBackend(); self.b.RUN = self.root / 'runtime'
        self.b.items.append(copy.deepcopy(self.b.items[0]))
        with self.assertRaises(v.Fail): self.apply()
        self.assertEqual([], self.b.writes)

    def test_live_protected_source_and_ambiguous_destination_refuse_before_confirmation(self):
        self.b.folders[0]['name'] = 'Env/protected'
        with self.assertRaises(v.Fail): self.apply()
        self.assertEqual([], self.confirmations); self.assertEqual([], self.b.exports)
        self.b.folders[0]['name'] = 'Invented folder'
        self.b.folders += [{'id': 'dest-one', 'name': 'Destination'}, {'id': 'dest-two', 'name': 'Destination'}]
        with self.assertRaises(v.Fail): self.apply()
        self.assertEqual([], self.confirmations); self.assertEqual([], self.b.exports)

    def test_personal_agent_and_production_yes_gates_make_no_backend_request(self):
        with mock.patch.object(v, 'agent', return_value='invented-agent'):
            with self.assertRaises(v.Fail) as caught: self.apply()
            self.assertEqual(4, caught.exception.code)
            self.assertEqual(0, self.apply('--dry-run')[0])
        with mock.patch.object(v, 'envs_lib', return_value=types.SimpleNamespace(test_mode=lambda: False)):
            with self.assertRaises(v.Fail) as caught: self.apply('--yes')
            self.assertEqual(4, caught.exception.code)
        self.assertEqual([], self.b.calls); self.assertEqual([], self.confirmations)

    def test_full_journal_cannot_resume_personal_header_and_interrupted_personal_resume_is_fresh(self):
        self.rows[2].target = 'folder:Destination'; self.rewrite()
        original = self.b.bw
        def interrupt(*args, **kwargs):
            if args[:3] == ('get', 'item', 'personal-keep'): raise KeyboardInterrupt
            return original(*args, **kwargs)
        self.b.bw = interrupt
        with contextlib.redirect_stderr(io.StringIO()) as error:
            self.assertEqual(130, self.apply()[0])
        self.assertIn('vault-audit apply --personal-only --resume continues', error.getvalue())
        first = set(v.BACKUPS.glob('vault-*'))
        self.assertEqual(1, len(first))
        self.b.bw = original
        self.assertEqual(0, self.apply('--resume')[0])
        self.assertEqual(2, len(list(v.BACKUPS.glob('vault-*'))))
        self.assertTrue(all(p.exists() for p in first))
        self.assertEqual(2, len([w for w in self.b.writes if w[:2] == ('edit', 'item')]))
        self.full.write_bytes((self.root / 'org-personal-journal.tsv').read_bytes())
        with self.assertRaises(v.Fail): v.Journal(v.sha(self.plan.read_text()), resume=True)

    def test_personal_post_export_names_and_service_coherence_remain_required(self):
        self.b.edit_export = lambda doc, org: self.b.items[0].update(name='Changed after export')
        with self.assertRaises(v.Fail): self.apply()
        self.assertEqual([], self.b.writes)
        self.b = PersonalBackend(); self.b.RUN = self.root / 'runtime'
        self.b.served = [item('stale-service')]
        with self.assertRaises(v.Fail): self.apply()
        self.assertEqual([], self.b.writes)

    def test_nfc_equivalent_source_target_and_new_folder_counts_match_execution(self):
        for folder, target in (('Cafe\u0301', 'Café'), ('Café', 'Cafe\u0301'), ('Cafe\u0301', 'Cafe\u0301')):
            self.b = PersonalBackend(); self.b.RUN = self.root / 'runtime'
            self.b.folders[0]['name'] = folder
            self.rows[0].target = 'folder:' + target; self.rewrite()
            with self.subTest(folder=folder, target=target):
                rc, output = self.apply()
                self.assertEqual(0, rc)
                self.assertIn('0 personal moves needed, 1 already at target, 0 new destination folders required', output)
                self.assertEqual([], self.b.writes)
        self.b = PersonalBackend(); self.b.RUN = self.root / 'runtime'
        self.b.folders.append({'id': 'destination', 'name': 'Cafe\u0301'})
        self.rows[0].target = 'folder:Cafe\u0301'; self.rewrite()
        rc, output = self.apply()
        self.assertEqual(0, rc)
        self.assertIn('1 personal moves needed, 0 already at target, 0 new destination folders required', output)
        self.assertEqual([('edit', 'item', 'personal-one')], self.b.writes)

    def test_personal_unique_archives_preserve_every_previous_recovery_journal(self):
        old_prev = self.root / 'org-personal-journal.tsv.prev'
        old_prev.write_text('invented-older-recovery-journal')
        for marker in ('a', 'b', 'c'):
            journal = v.Journal('s' * 64, personal=marker * 64)
            journal.log('move', marker, 'ok ' + marker)
        archives = list(self.root.glob('org-personal-journal.tsv.prev-*'))
        self.assertEqual(2, len(archives))
        self.assertEqual({'a', 'b'}, {p.read_text().splitlines()[-1].split('\t')[2] for p in archives})
        self.assertEqual('invented-older-recovery-journal', old_prev.read_text())
        for p in archives: self.assertEqual(0o600, p.stat().st_mode & 0o777)
        self.assertEqual(self.preserved[self.full], self.full.read_bytes())


if __name__ == '__main__':
    unittest.main()
