#!/usr/bin/python3 -IB
"""Send acceptance through real envs + invented vault/clipboard/process fixtures."""
import base64
import contextlib
from datetime import datetime, timezone
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[3]
TOOLS = str(REPO / 'infrastructure/tests/envs/bin') + ':' + str(REPO / 'infrastructure/tests/vault-browse/bin')
BOOT = '''import os,sys,ctypes
p=sys.argv.pop(1); ns={'__name__':'send_fixture','__file__':p};exec(compile(open(p).read(),p,'exec'),ns)
ns['HOME']=ns['Path'](os.environ['HOME'])
ns['tty']=lambda:os.environ.get('FAKE_NO_TTY')!='1'
if os.environ.get('FAKE_AGENT_COMM'): ctypes.CDLL(None).prctl(15,os.environ['FAKE_AGENT_COMM'].encode(),0,0,0)
raise SystemExit(ns['main'](sys.argv[1:]))
'''
SECRET = 'invented-database-value'
LINK = 'https://send.example/#accessid/invented-bearer-key'


class SendTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='envs-send.')
        self.root = Path(self.temp.name)
        self.project = self.root / 'demo'; self.project.mkdir()
        self.fake = self.root / 'fake'; self.fake.mkdir(mode=0o700)
        for name in ('run', 'state', 'cache', 'global', 'home', 'config'):
            (self.root / name).mkdir(mode=0o700)
        self.source = self.project / '.env'
        self.source.write_text('DATABASE_URL=bw://Env/my-project/dev#DATABASE_URL\nAPP_PORT=8080\n')
        self.vault = {'folders': [{'id': 'env-folder', 'name': 'Env/my-project'}], 'items': [
            {'id': 'ref-item', 'name': 'dev', 'type': 2, 'folderId': 'env-folder', 'deletedDate': None,
             'fields': [{'name': 'DATABASE_URL', 'value': SECRET, 'type': 1}],
             'notes': None, 'secureNote': {'type': 0}, 'passwordHistory': [], 'attachments': []}]}
        self.save_vault()
        (self.fake / 'rbw.json').write_text('{"email":"fixture@example.test"}')
        (self.fake / 'rbw-unlocked').touch()
        (self.fake / 'bw-unlocked').touch()
        session = self.root / 'run/vault'; session.mkdir(mode=0o700)
        (session / 'bw-session').write_text('SESSION-KEY-abc')
        (session / 'bw-session').chmod(0o600)
        self.env = dict(os.environ, PATH=TOOLS + ':/usr/bin:/bin', ENVS_TOOL_PATH=TOOLS,
                        ENVS_TEST_ROOT_PID=str(os.getpid()), ENVS_TEST_YES='1', ENVS_TEST_SEND_TRANSPORT='1',
                        XDG_RUNTIME_DIR=str(self.root / 'run'), XDG_STATE_HOME=str(self.root / 'state'),
                        XDG_CACHE_HOME=str(self.root / 'cache'), ENVS_GLOBAL_DIR=str(self.root / 'global'),
                        HOME=str(self.root / 'home'), XDG_CONFIG_HOME=str(self.root / 'config'), FAKE_DIR=str(self.fake), VAULT_RBW_CONF=str(self.fake / 'rbw.json'),
                        VAULT_BW_SERVE='0', VAULT_BW_NODUMP='0', FAKE_ENV_SEND='1', RBW_BIN='rbw', BW_BIN='bw')
        for name in ('DISPLAY', 'WAYLAND_DISPLAY', 'CLAUDECODE', '__MISE_DIFF', '__MISE_SESSION'):
            self.env.pop(name, None)
        bind = self.run_envs('bind', '--yes')
        self.assertEqual(bind.returncode, 0, bind.stderr)
        self.clear_log()

    def tearDown(self):
        pid = self.fake / 'copy.pid'
        if pid.exists():
            try:
                os.kill(int(pid.read_text()), signal.SIGTERM)
            except ProcessLookupError:
                pass
        self.temp.cleanup()

    def run_envs(self, *args, **changes):
        env = dict(self.env, **changes)
        return subprocess.run([sys.executable, '-I', '-B', '-c', BOOT, str(REPO / '.local/bin/envs'), *args],
                              cwd=self.project, env=env, capture_output=True, text=True, timeout=20)

    def save_vault(self):
        (self.fake / 'vault.json').write_text(json.dumps(self.vault))
        (self.fake / 'rbw-view.json').unlink(missing_ok=True)

    def clear_log(self):
        (self.fake / 'argv.log').write_text('')

    def log(self):
        return (self.fake / 'argv.log').read_text()

    def records(self):
        return [json.loads(p.read_text()) for p in (self.root / 'state/envs/send').glob('*.json')]

    def creates(self):
        path = self.fake / 'send-events'
        return path.read_text().splitlines().count('create') if path.exists() else 0

    def assert_private(self, result):
        visible = result.stdout + result.stderr + self.log()
        for needle in (SECRET, LINK, 'invented-bearer-key', 'invented-poison', base64.b64encode(SECRET.encode()).decode()):
            self.assertNotIn(needle, visible)
        for path in (self.root / 'state').rglob('*'):
            if path.is_file():
                raw = path.read_bytes()
                self.assertNotIn(SECRET.encode(), raw)
                self.assertNotIn(LINK.encode(), raw)

    def test_text_fixed_policy_and_unchanged_source(self):
        before, stamp = self.source.read_bytes(), self.source.stat().st_mtime_ns
        result = self.run_envs('send')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('1 access, deletes in 1 day', result.stdout)
        payload = json.loads((self.fake / 'send-payload.json').read_text())
        self.assertEqual(payload['type'], 0)
        self.assertEqual(payload['maxAccessCount'], 1)
        self.assertTrue(payload['text']['hidden'])
        self.assertIsNone(payload['file'])
        self.assertEqual(payload['text']['text'], f'DATABASE_URL="{SECRET}"\nAPP_PORT=8080\n')
        self.assertEqual(before, self.source.read_bytes())
        self.assertEqual(stamp, self.source.stat().st_mtime_ns)
        self.assertEqual(self.creates(), 1)
        self.assertEqual(self.records()[0]['status'], 'delivered')
        self.assertIn('--sensitive --foreground', (self.fake / 'clip.args').read_text())
        self.assertNotIn('--paste-once', self.log())
        self.assertNotIn('send receive', self.log())
        self.assert_private(result)

    def test_agents_no_tty_managed_refused_before_source(self):
        self.source.unlink()
        os.mkfifo(self.source)
        for changes in ({'CLAUDECODE': '1'}, {'FAKE_AGENT_COMM': 'codex'}, {'FAKE_NO_TTY': '1'},
                        {'ENVS_TEST_MANAGED_USER': 'td'}):
            for args in (('send',), ('send', '--file-send'), ('send', '--recover')):
                with self.subTest(changes=changes, args=args):
                    result = self.run_envs(*args, **changes)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(self.log(), '')
                    self.assertEqual(self.creates(), 0)
                    self.assertFalse((self.root / 'state/envs/send').exists())

    def test_decline_has_no_value_fetch(self):
        # Test-only confirmation remains false in a noninteractive stdin when
        # ENVS_TEST_YES is zero; tty guard itself is controlled by the bootstrap.
        result = self.run_envs('send', ENVS_TEST_YES='0')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Cancelled', result.stdout)
        self.assertNotIn('rbw get', self.log())
        self.assertNotIn('bw send create', self.log())
        self.assertEqual(self.creates(), 0)
        self.assert_private(result)

    def test_missing_transport_creates_nothing(self):
        result = self.run_envs('send', ENVS_TEST_SEND_TRANSPORT='0')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.log(), '')
        self.assertEqual(self.creates(), 0)

    def test_utf8_boundaries_and_no_automatic_file_fallback(self):
        for text, allowed in (('#' + 'x' * 510 + '\n', True), ('#' + 'x' * 511 + '\n', False),
                              ('#' + 'я' * 255 + '\n', True), ('#' + 'я' * 256 + '\n', False)):
            with self.subTest(allowed=allowed, utf8=len(text.encode())):
                self.source.write_text(text)
                self.assertEqual(self.run_envs('bind', '--yes').returncode, 0)
                before = self.creates()
                result = self.run_envs('send')
                self.assertEqual(result.returncode == 0, allowed, result.stderr)
                self.assertEqual(self.creates() - before, int(allowed))
                if not allowed:
                    self.assertIn('too large for text Send', result.stderr)
                self.assert_private(result)

    def test_only_omits_unselected_reference(self):
        self.source.write_text(self.source.read_text() + 'OTHER=bw://Env/my-project/dev#OTHER\n')
        self.vault['items'][0]['fields'].append({'name': 'OTHER', 'value': 'other-invented-value', 'type': 1})
        self.save_vault()
        self.assertEqual(self.run_envs('bind', '--yes').returncode, 0)
        self.clear_log()
        result = self.run_envs('send', '--only', 'DATABASE_URL')
        self.assertEqual(result.returncode, 0, result.stderr)
        text = json.loads((self.fake / 'send-payload.json').read_text())['text']['text']
        self.assertNotIn('OTHER=', text)
        self.assertNotIn('bw://', text)
        self.assertNotIn('other-invented-value', result.stdout + result.stderr)
        self.assert_private(result)

    def test_envs_transfer_dialect_roundtrips_dollar_slashes_quotes_and_controls(self):
        parser = CoreTests.load('.config/envs/secrets.py', 'send_literal_parser')
        value = 'invented-$TOKEN-${OTHER}-$(touch fake)-`cmd`-\\path-"double"-\'single\'\nline\r\ttail'
        self.vault['items'][0]['fields'][0]['value'] = value
        self.save_vault()
        result = self.run_envs('send')
        self.assertEqual(result.returncode, 0, result.stderr)
        text = json.loads((self.fake / 'send-payload.json').read_text())['text']['text']
        self.assertEqual(value, parser.DotenvDocument(text).values()['DATABASE_URL'])
        self.assertNotIn(value, result.stdout + result.stderr + self.log())
        self.assertFalse((self.project / 'fake').exists())
        self.assert_private(result)

    def test_nul_or_invalid_unicode_refuses_before_create(self):
        for value in ('invented\x00value', 'invented\ud800value'):
            with self.subTest(value=repr(value)):
                self.vault['items'][0]['fields'][0]['value'] = value
                self.save_vault()
                result = self.run_envs('send')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(0, self.creates())
                self.assert_private(result)

    def test_backend_output_bound_is_enforced_and_unknown_never_retries(self):
        for scenario in ('oversized-stdout', 'oversized-stderr'):
            with self.subTest(scenario=scenario):
                self.reset_transactions()
                before = self.creates()
                result = self.run_envs('send', FAKE_SEND_SCENARIO=scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(before + 1, self.creates())
                self.assertEqual('pending', self.records()[0]['status'])
                repeated = self.run_envs('send')
                self.assertNotEqual(repeated.returncode, 0)
                self.assertEqual(before + 1, self.creates())
                self.assert_private(result)

    def test_file_explicit_private_tmpfs_and_actual_cli_precedence(self):
        self.source.write_text(self.source.read_text() + '# ' + 'x' * 1024 + '\n')
        self.assertEqual(self.run_envs('bind', '--yes').returncode, 0)
        self.clear_log()
        before = self.source.read_bytes()
        result = self.run_envs('send', '--file-send')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('1 download', result.stdout)
        payload = json.loads((self.fake / 'send-payload.json').read_text())
        self.assertEqual(payload['type'], 1)
        self.assertIsNone(payload['text'])
        path = Path(payload['file']['fileName'])
        self.assertTrue(str(path).startswith('/dev/shm/'))
        self.assertEqual(path.name, 'environment.env')
        self.assertFalse(path.exists())
        self.assertIn(SECRET.encode(), (self.fake / 'send-file-capture').read_bytes())
        self.assertEqual(self.source.read_bytes(), before)
        self.assert_private(result)

    def test_file_limit_exact_boundary_and_larger_source_refusal(self):
        maximum = 4 * 1024 * 1024
        self.source.write_text('#' + 'x' * (maximum - 2) + '\n')
        self.assertEqual(0, self.run_envs('bind', '--yes').returncode)
        result = self.run_envs('send', '--file-send')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(maximum, (self.fake / 'send-file-capture').stat().st_size)
        self.assertEqual(1, self.creates())
        self.source.write_text('#' + 'x' * (maximum - 1) + '\n')
        oversized = self.run_envs('send', '--file-send')
        self.assertNotEqual(0, oversized.returncode)
        self.assertEqual(1, self.creates())
        self.assert_private(oversized)

    def test_legacy_append_once_only_selection_and_plain_conflict(self):
        config = self.project / '.envs.toml'
        config.write_text('project="my-project"\nenvironments=["dev","prod"]\ndefault="dev"\n'
                          '[secrets]\nLEGACY="Invented optional credential"\n')
        self.vault['items'][0]['fields'].append({'name': 'LEGACY', 'value': 'invented-legacy-value', 'type': 1})
        self.save_vault()
        self.assertEqual(0, self.run_envs('bind', '--yes').returncode)
        result = self.run_envs('send')
        self.assertEqual(0, result.returncode, result.stderr)
        text = json.loads((self.fake / 'send-payload.json').read_text())['text']['text']
        self.assertEqual(1, text.count('LEGACY='))
        self.assertIn('LEGACY="invented-legacy-value"', text)
        result = self.run_envs('send', '--only', 'DATABASE_URL')
        self.assertEqual(0, result.returncode, result.stderr)
        text = json.loads((self.fake / 'send-payload.json').read_text())['text']['text']
        self.assertNotIn('LEGACY=', text)
        before = self.creates()
        self.source.write_text(self.source.read_text() + 'LEGACY=ordinary-literal\n')
        self.clear_log()
        result = self.run_envs('send')
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(before, self.creates())
        self.assertNotIn('rbw get', self.log())
        self.assertNotIn('ordinary-literal', result.stdout + result.stderr)
        self.assert_private(result)

    def test_protected_environment_and_unapproved_file_refuse_before_fields(self):
        (self.project / '.envs.toml').write_text('project="my-project"\nenvironments=["dev","prod"]\ndefault="dev"\n')
        (self.project / '.env.prod').write_text(self.source.read_text())
        self.assertEqual(0, self.run_envs('bind', '--yes').returncode)
        for args in (('send', '-e', 'prod'), ('send', '.env.prod')):
            self.clear_log()
            result = self.run_envs(*args)
            self.assertNotEqual(0, result.returncode)
            self.assertEqual(0, self.creates())
            self.assertNotIn('rbw get', self.log())
            self.assert_private(result)

    def test_copy_failure_recovers_same_id_without_secret_refetch(self):
        failed = self.run_envs('send', FAKE_SEND_COPY_FAIL='1')
        self.assertNotEqual(failed.returncode, 0)
        record = self.records()[0]
        self.assertEqual(record['status'], 'copy-failed')
        self.assertIn('--recover ' + record['id'], failed.stderr)
        self.source.unlink()  # recovery must not need even the source file
        self.clear_log()
        result = self.run_envs('send', '--recover', record['id'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.creates(), 1)
        self.assertNotIn('rbw get', self.log())
        self.assertNotIn('send create', self.log())
        self.assertIn('send get ' + record['id'], self.log())
        self.assert_private(result)

    def test_unknown_outcome_blocks_duplicate_and_recovers_exact_name(self):
        for scenario in ('timeout', 'invalid-json', 'missing-id'):
            with self.subTest(scenario=scenario):
                self.reset_transactions()
                result = self.run_envs('send', FAKE_SEND_SCENARIO=scenario)
                self.assertNotEqual(result.returncode, 0)
                before = self.creates()
                repeated = self.run_envs('send')
                self.assertNotEqual(repeated.returncode, 0)
                self.assertEqual(self.creates(), before)
                recovered = self.run_envs('send', '--recover')
                self.assertEqual(recovered.returncode, 0, recovered.stderr)
                self.assertEqual(self.creates(), before)
                self.assert_private(result)
                self.assert_private(recovered)

    def reset_transactions(self):
        directory = self.root / 'state/envs/send'
        if directory.exists():
            for p in directory.iterdir():
                p.unlink()

    def test_policy_mismatch_never_copies_or_recreates(self):
        for scenario in ('count', 'url', 'type', 'deletion', 'id'):
            with self.subTest(scenario=scenario):
                self.reset_transactions()
                (self.fake / 'clip.last').unlink(missing_ok=True)
                result = self.run_envs('send', FAKE_SEND_SCENARIO=scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.fake / 'clip.last').exists())
                before = self.creates()
                repeated = self.run_envs('send')
                self.assertNotEqual(repeated.returncode, 0)
                self.assertEqual(self.creates(), before)
                self.assert_private(result)

    def test_missing_echo_gets_exact_id_metadata(self):
        result = self.run_envs('send', FAKE_SEND_SCENARIO='missing-echo')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.creates(), 1)
        self.assertIn('bw send get ' + self.records()[0]['id'], self.log())
        self.assert_private(result)

    def test_recover_explicit_id_when_create_response_lost_id(self):
        result = self.run_envs('send', FAKE_SEND_SCENARIO='missing-id')
        self.assertNotEqual(result.returncode, 0)
        ident = json.loads((self.fake / 'sends.json').read_text())[0]['id']
        self.source.unlink()
        self.clear_log()
        recovered = self.run_envs('send', '--recover', ident)
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertEqual(self.creates(), 1)
        self.assertNotIn('rbw get', self.log())
        self.assert_private(recovered)

    def test_ambiguous_recovery_never_creates_or_copies(self):
        self.assertNotEqual(self.run_envs('send', FAKE_SEND_SCENARIO='invalid-json').returncode, 0)
        rows = json.loads((self.fake / 'sends.json').read_text())
        rows.append(dict(rows[0], id='99999999-2222-4333-8444-000000000001'))
        (self.fake / 'sends.json').write_text(json.dumps(rows))
        result = self.run_envs('send', '--recover')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unresolved', result.stderr)
        self.assertEqual(self.creates(), 1)
        self.assertFalse((self.fake / 'clip.last').exists())
        self.assert_private(result)

    def test_lost_or_unsafe_state_never_authorizes_arbitrary_recovery(self):
        ident = '11111111-2222-4333-8444-000000000001'
        result = self.run_envs('send', '--recover', ident)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.log(), '')
        self.assertEqual(self.creates(), 0)
        # A planted state-directory symlink is refused before any field fetch.
        directory = self.root / 'state/envs/send'
        directory.rmdir()
        outside = self.root / 'outside'; outside.mkdir(mode=0o700)
        directory.symlink_to(outside)
        result = self.run_envs('send')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('rbw get', self.log())
        self.assertEqual(self.creates(), 0)

    def test_file_create_failure_cleans_private_artifact(self):
        result = self.run_envs('send', '--file-send', FAKE_SEND_SCENARIO='timeout')
        self.assertNotEqual(result.returncode, 0)
        payload = json.loads((self.fake / 'send-payload.json').read_text())
        self.assertFalse(Path(payload['file']['fileName']).exists())
        self.assertEqual(self.creates(), 1)
        self.assertEqual(self.records()[0]['status'], 'pending')
        self.assert_private(result)

    def test_signal_during_file_create_cleans_artifact_and_reaps_backend(self):
        env = dict(self.env, FAKE_SEND_SCENARIO='hang')
        proc = subprocess.Popen([sys.executable, '-I', '-B', '-c', BOOT, str(REPO / '.local/bin/envs'),
                                 'send', '--file-send'], cwd=self.project, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 5
            marker = self.fake / 'send.pid'
            while not marker.exists() and proc.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(marker.exists(), 'fake create did not start')
            backend_pid = int(marker.read_text())
            proc.send_signal(signal.SIGTERM)
            stdout, stderr = proc.communicate(timeout=5)
            self.assertNotEqual(proc.returncode, 0)
            self.assertEqual(1, self.creates())
            self.assertEqual('pending', self.records()[0]['status'])
            payload = json.loads((self.fake / 'send-payload.json').read_text())
            self.assertFalse(Path(payload['file']['fileName']).exists())
            with self.assertRaises(ProcessLookupError): os.kill(backend_pid, 0)
            self.assert_private(subprocess.CompletedProcess([], proc.returncode, stdout, stderr))
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)

    def test_source_and_approval_races_after_marker_abort_before_dispatch(self):
        global BOOT
        original = BOOT
        hook = '''import importlib.util
spec=importlib.util.spec_from_file_location('_envs_commands',str(ns['REPO']/'.config/envs/commands.py'))
c=importlib.util.module_from_spec(spec);sys.modules[spec.name]=c;spec.loader.exec_module(c);ns['_EXTRA']=c
write=c.write_state
def changed(name,data):
 write(name,data)
 if name.startswith('send/') and data.get('status')=='pending':
  from pathlib import Path
  if os.environ['FAKE_SEND_RACE']=='source': Path('.env').write_text('# changed after marker\\n')
  else: (Path(os.environ['XDG_STATE_HOME'])/'envs/ref-policies.json').write_text('{}')
c.write_state=changed
'''
        try:
            BOOT = BOOT.replace("raise SystemExit(ns['main'](sys.argv[1:]))", hook + "raise SystemExit(ns['main'](sys.argv[1:]))")
            for race in ('approval', 'source'):
                with self.subTest(race=race):
                    self.assertEqual(0, self.run_envs('bind', '--yes').returncode)
                    result = self.run_envs('send', FAKE_SEND_RACE=race)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(0, self.creates())
                    self.assertTrue(all(not record for record in self.records()))
                    self.assert_private(result)
        finally:
            BOOT = original

    def test_size_limit_includes_comments_and_all_policy_fields(self):
        result = self.run_envs('send')
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads((self.fake / 'send-payload.json').read_text())
        deletion = datetime.fromisoformat(payload['deletionDate'].replace('Z', '+00:00'))
        created = datetime.fromisoformat(self.records()[0]['created'].replace('Z', '+00:00'))
        self.assertEqual((deletion - created).total_seconds(), 86400)
        self.assertIsNone(payload['notes'])
        self.assertIsNone(payload['password'])
        self.assertIsNone(payload['emails'])
        self.assertIsNone(payload['expirationDate'])
        self.assertFalse(payload['disabled'])

    def test_original_copier_expiry_preserves_replacement(self):
        result = self.run_envs('send')
        self.assertEqual(result.returncode, 0, result.stderr)
        (self.fake / 'clip.txt').write_text('new unrelated clipboard item')
        time.sleep(0.5)
        self.assertEqual((self.fake / 'clip.txt').read_text(), 'new unrelated clipboard item')
        self.assertNotIn('wl-copy --clear', self.log())

    def test_invalid_source_refuses_before_fields(self):
        self.source.unlink()
        target = self.project / 'real.env'
        target.write_text('DATABASE_URL=bw://Env/my-project/dev#DATABASE_URL\n')
        self.source.symlink_to(target)
        result = self.run_envs('send')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('rbw get', self.log())
        self.assertEqual(self.creates(), 0)
        self.assert_private(result)


class CoreTests(unittest.TestCase):
    @staticmethod
    def load(path, name):
        spec = importlib.util.spec_from_file_location(name, REPO / path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_runtime_acl_accepts_sanctioned_traversal_not_writers(self):
        m = self.load('.config/envs/send.py', 'send_acl_fixture')
        basic = ['user::rwx', 'group::---', 'other::---']
        self.assertTrue(m.runtime_acl_safe(basic, 1000))
        self.assertTrue(m.runtime_acl_safe(basic + ['user:2000:--x', 'mask::--x'], 1000))
        self.assertTrue(m.runtime_acl_safe(basic + ['user:2000:---', 'mask::---'], 1000))
        self.assertFalse(m.runtime_acl_safe(basic + ['user:2000:rwx', 'mask::rwx'], 1000))
        self.assertFalse(m.runtime_acl_safe(basic + ['group:2000:--x', 'mask::--x'], 1000))
        self.assertFalse(m.runtime_acl_safe(['user::rwx', 'group::--x', 'other::---'], 1000))

    def test_alternate_runtime_refused_before_source_backend_or_spawn(self):
        m = self.load('.config/envs/send.py', 'send_runtime_identity_fixture')
        class Refused(Exception): pass
        def fail(message, code): raise Refused(message)
        host = types.SimpleNamespace(managed_user=lambda: False, agent_context=lambda: None, tty=lambda: True,
                                     tool=lambda name: '/fake/' + name, test_mode=lambda: False,
                                     fail=fail, vbw=unittest.mock.Mock())
        commands = types.SimpleNamespace(E=host, D=types.SimpleNamespace(Problem=RuntimeError),
                                         prepare_export=unittest.mock.Mock())
        with patch.dict(os.environ, {'XDG_RUNTIME_DIR': '/tmp/invented-alternate-runtime',
                                     'WAYLAND_DISPLAY': 'wayland-1'}), \
             patch.object(m, 'protect_process'), \
             patch.object(m.subprocess, 'Popen') as spawn, \
             patch.object(m.subprocess, 'run') as invoke:
            with self.assertRaises(Refused) as caught:
                m.run(types.SimpleNamespace(recover=False), commands, None)
            self.assertIn('usable Wayland clipboard', str(caught.exception))
            commands.prepare_export.assert_not_called()
            host.vbw.assert_not_called()
            spawn.assert_not_called()
            invoke.assert_not_called()

    def test_multibyte_link_bound_precedes_clipboard_spawn(self):
        send = self.load('.config/envs/send.py', 'send_link_limit_fixture')
        backend = self.load('.config/hypr/scripts/vault-bw.py', 'send_copy_limit_fixture')
        link = 'https://send.example/#' + 'я' * 2100
        self.assertLess(len(link), 4096)
        self.assertGreater(len(link.encode()), 4096)
        with self.assertRaises(send.SendProblem): send.origin(link, True)
        with patch.object(backend.subprocess, 'Popen') as spawn:
            with self.assertRaises(backend.SendError):
                backend.copy_sensitive_send_link(link, '/fake/wl-copy', '/fake/wl-paste')
            spawn.assert_not_called()

    def test_signal_during_clipboard_setup_retires_unarmed_copier(self):
        m = self.load('.config/hypr/scripts/vault-bw.py', 'send_signal_fixture')
        class Interrupt(BaseException):
            pass
        class Copier:
            pid = 12345
            stdin = io.BytesIO()
            stopped = False
            reaped = False
            def poll(self):
                return 0 if self.stopped else None
            def terminate(self):
                self.stopped = True
            def wait(self, timeout):
                self.reaped = True
                return 0
        copier = Copier()
        with patch.object(m.os, 'access', return_value=True), patch.object(m, 'with_nodump', side_effect=lambda env: env), \
             patch.object(m.subprocess, 'Popen', return_value=copier), patch.object(m, '_send_copy_start', return_value='1'), \
             patch.object(m, '_bounded_cli', side_effect=Interrupt):
            with self.assertRaises(Interrupt):
                m.copy_sensitive_send_link(LINK, '/fake/wl-copy', '/fake/wl-paste')
        self.assertTrue(copier.stopped)
        self.assertTrue(copier.reaped)

    def test_nondumpable_child_identity_and_expiry_use_actual_uid(self):
        m = self.load('.config/hypr/scripts/vault-bw.py', 'send_nondump_identity_fixture')
        script = ('import ctypes,time;'
                  'assert ctypes.CDLL(None).prctl(4,0,0,0,0)==0;'
                  'print("ready",flush=True);time.sleep(30)')
        proc = subprocess.Popen([sys.executable, '-I', '-B', '-c', script],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        try:
            self.assertEqual('ready', proc.stdout.readline().strip())
            if os.getuid() != 0:
                self.assertNotEqual(os.getuid(), Path(f'/proc/{proc.pid}/stat').stat().st_uid)
            started = m._send_copy_start(proc.pid)
            self.assertIsNotNone(started)
            m._expire_send_copy(proc.pid, 'incorrect-start-time', delay=0.01)
            self.assertIsNone(proc.poll())
            m._expire_send_copy(proc.pid, started, delay=0.01)
            self.assertEqual(-signal.SIGTERM, proc.wait(timeout=2))
        finally:
            if proc.poll() is None:
                proc.kill(); proc.wait(timeout=2)
            proc.stdout.close()

    def test_noisy_or_stalled_clipboard_verification_retires_unarmed_copier(self):
        m = self.load('.config/hypr/scripts/vault-bw.py', 'send_paste_bound_fixture')
        real_popen = subprocess.Popen
        class Copier:
            pid = 12345
            def __init__(self):
                self.stdin = io.BytesIO()
                self.stopped = self.reaped = False
            def poll(self): return 0 if self.stopped else None
            def terminate(self): self.stopped = True
            def wait(self, timeout): self.reaped = True; return 0
        with tempfile.TemporaryDirectory(prefix='send-paste.') as root:
            paste = Path(root) / 'paste'
            for scenario in ('stdout', 'stderr', 'timeout'):
                copier = Copier()
                script = ('#!' + sys.executable + '\nimport os,sys,time\n'
                          'assert os.environ.get("FAKE_NODUMP")=="1"\n')
                if scenario == 'stderr': script += 'os.write(2,b"invented-poison"*2000)\n'
                elif scenario == 'timeout': script += 'time.sleep(10)\n'
                else: script += 'print("x-kde-passwordManagerHint" if "--list-types" in sys.argv else "x"*5000)\n'
                paste.write_text(script); paste.chmod(0o700)
                def popen(argv, *args, **kwargs):
                    if argv[0] == '/fake/wl-copy': return copier
                    self.assertNotIn('_send-wait-clear', argv)
                    return real_popen(argv, *args, **kwargs)
                with self.subTest(scenario=scenario), \
                     patch.object(m.os, 'access', return_value=True), \
                     patch.object(m, 'with_nodump', side_effect=lambda env: dict(env, FAKE_NODUMP='1')), \
                     patch.object(m.subprocess, 'Popen', side_effect=popen), \
                     patch.object(m, '_send_copy_start', return_value='1'):
                    with self.assertRaises(m.SendError) as caught:
                        m.copy_sensitive_send_link(LINK, '/fake/wl-copy', str(paste))
                    self.assertNotIn('invented-poison', str(caught.exception))
                    self.assertTrue(copier.stopped)
                    self.assertTrue(copier.reaped)

    def test_generic_adapter_preserves_plain_copy_without_url_notification(self):
        m = self.load('.config/hypr/scripts/vault-bw.py', 'send_adapter_fixture')
        with patch.object(m, 'create_send_result', return_value={'accessUrl': LINK}) as create, \
             patch.object(m, 'copy') as copy, patch.object(m, 'finish') as finish:
            m.create_send({'password': None}, '--file', 'relative.env')
            self.assertTrue(Path(create.call_args.args[2]).is_absolute())
            copy.assert_called_once_with(LINK, sensitive=False)
            finish.assert_called_once_with('Send link copied')

    def test_backend_errors_and_timeouts_have_fixed_messages_and_one_attempt(self):
        m = self.load('.config/hypr/scripts/vault-bw.py', 'send_error_fixture')
        for failure in (subprocess.TimeoutExpired(['bw'], 90, output='invented-poison'),
                        ValueError('invented-poison')):
            with patch.object(m, 'bw_cli', side_effect=failure) as call:
                with self.assertRaises(m.SendError) as result:
                    m.create_send_result({'text': {'text': SECRET}})
                self.assertNotIn('invented-poison', str(result.exception))
                self.assertEqual(call.call_count, 1)

    def test_management_get_requires_exact_uuid_and_exact_response_identity(self):
        m = self.load('.config/hypr/scripts/vault-bw.py', 'send_exact_fixture')
        ident = '11111111-2222-4333-8444-000000000001'
        other = '99999999-2222-4333-8444-000000000001'
        with patch.object(m, '_send_json') as query:
            with self.assertRaises(m.SendError): m.get_send_result('fuzzy-request-name')
            query.assert_not_called()
        with patch.object(m, '_send_json', return_value={'id': other}) as query:
            with self.assertRaises(m.SendError): m.get_send_result(ident)
            query.assert_called_once_with('send', 'get', ident)

    def test_recovery_revalidates_original_selection_after_lock(self):
        m = self.load('.config/envs/send.py', 'send_recovery_race_fixture')
        old_id = '11111111-2222-4333-8444-000000000001'
        new_id = '99999999-2222-4333-8444-000000000001'
        with tempfile.TemporaryDirectory(prefix='send-recovery-race.') as root:
            path = Path(root)
            (path / ('a' * 64 + '.json')).write_text('{}')
            commands = types.SimpleNamespace(private_dir=lambda p: p, state_path=lambda name: path, E=None)
            for requested, old, new in (
                (old_id, {'id': old_id, 'request': 'old-request', 'status': 'delivered'},
                 {'id': new_id, 'request': 'new-request', 'status': 'delivered'}),
                (True, {'id': old_id, 'request': 'old-request', 'status': 'pending'},
                 {'id': new_id, 'request': 'new-request', 'status': 'pending'}),
                (True, {'id': old_id, 'request': 'old-request', 'status': 'pending'},
                 {'id': old_id, 'request': 'old-request', 'status': 'delivered'}),
            ):
                backend = unittest.mock.Mock()
                with self.subTest(requested=requested, new=new), \
                     patch.object(m, 'read_transaction', side_effect=[old, new]), \
                     patch.object(m, 'transaction_lock', return_value=contextlib.nullcontext()), \
                     patch.object(m, 'authorize_backend') as authorize, \
                     patch.object(m, 'copy_result') as copy:
                    with self.assertRaises(m.SendProblem) as caught:
                        m.recover(types.SimpleNamespace(recover=requested), commands, backend, {})
                    self.assertIn('changed', str(caught.exception))
                    authorize.assert_not_called()
                    backend.assert_not_called()
                    self.assertEqual([], backend.method_calls)
                    copy.assert_not_called()

    def test_bounded_transport_drains_stderr_while_feeding_stdin(self):
        m = self.load('.config/hypr/scripts/vault-bw.py', 'send_pipe_fixture')
        script = 'import os,sys;os.write(2,b"e"*262144);data=sys.stdin.buffer.read();print(len(data))'
        result = m._bounded_cli([sys.executable, '-I', '-B', '-c', script], 'x' * 1048576,
                                dict(os.environ), (), 5, 300000)
        self.assertEqual(0, result.returncode)
        self.assertEqual('1048576', result.stdout.strip())
        self.assertEqual(262144, len(result.stderr))

    def test_bounded_transport_timeout_reaps_child(self):
        m = self.load('.config/hypr/scripts/vault-bw.py', 'send_timeout_fixture')
        with tempfile.TemporaryDirectory(prefix='send-bounded.') as root:
            marker = Path(root) / 'pid'
            script = 'import os,sys,time;open(sys.argv[1],"w").write(str(os.getpid()));time.sleep(30)'
            with self.assertRaises(subprocess.TimeoutExpired):
                m._bounded_cli([sys.executable, '-I', '-B', '-c', script, str(marker)], None,
                               dict(os.environ), (), 0.2, 4096)
            pid = int(marker.read_text())
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)


if __name__ == '__main__':
    unittest.main()
