#!/usr/bin/python3 -IB
"""Real envs/Client/Broker/Writer socket integration with a private invented backend."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import tempfile
import pty
import select
import unittest

spec=importlib.util.spec_from_file_location('socket_refs',Path(__file__).with_name('references_test.py'))
f=importlib.util.module_from_spec(spec);spec.loader.exec_module(f)
HERE=f.REPO/'infrastructure/tests/vault-share'

class NativeSocket(unittest.TestCase):
    def setUp(self):
        f.References.setUp(self)
        self.broker_temp=tempfile.TemporaryDirectory(prefix='native-broker.')
        self.broker_root=Path(self.broker_temp.name)
        self.logfile=(self.root/'broker.log').open('w+')
        self.broker=subprocess.Popen([sys.executable,'-I','-B',str(HERE/'native_fixture.py'),str(self.broker_root)],
                                     env=self.env,stdout=self.logfile,stderr=subprocess.STDOUT)
        self.env.update(ENVS_TEST_MANAGED_USER='td',VAULT_SHARE_TEST_DIR=str(HERE),VAULT_SHARE_SCRATCH=str(self.broker_root),
                        VAULT_SHARE_SOCK=str(self.broker_root/'run/sock'),VAULT_SHARE_SCOPES=str(self.broker_root/'etc/scopes.tsv'),
                        VAULT_SHARE_RUNTIME=str(self.broker_root/'runtime'),VAULT_SHARE_TEST_AS='td')
        deadline=time.monotonic()+5
        while not (self.broker_root/'run/sock').exists() and self.broker.poll() is None and time.monotonic()<deadline:
            time.sleep(.02)
        if not (self.broker_root/'run/sock').exists():
            self.logfile.seek(0);detail=self.logfile.read();self.broker.terminate();self.broker.wait(timeout=3)
            self.logfile.close();self.broker_temp.cleanup();f.References.tearDown(self);self.fail('fixture broker startup failed: '+detail)

    def tearDown(self):
        self.broker.terminate()
        try:self.broker.wait(timeout=4)
        except subprocess.TimeoutExpired:self.broker.kill();self.broker.wait()
        self.logfile.close()
        self.broker_temp.cleanup()
        f.References.tearDown(self)

    save_vault=f.References.save_vault
    run_envs=f.References.run_envs
    ref_file=f.References.ref_file

    def bind(self):
        result=self.run_envs('bind','--yes');self.assertEqual(0,result.returncode,result.stderr)

    def set_secret(self,value):
        return subprocess.run([sys.executable,'-I','-B','-c',f.BOOT,str(f.SOURCE),str(f.REPO/'.local/bin/envs'),'set','NEW_TOKEN','--stdin'],
                              cwd=self.project,env=self.env,input=value+'\n',capture_output=True,text=True,timeout=15)

    def terminal_import(self, answer):
        master,slave=pty.openpty()
        command=[sys.executable,'-I','-B','-c',f.BOOT,str(f.SOURCE),str(f.REPO/'.local/bin/envs'),
                 'import','--secrets','NEW_TOKEN','--resume-pending','--yes']
        child=subprocess.Popen(command,cwd=self.project,env=self.env,stdin=slave,stdout=slave,stderr=slave)
        os.close(slave);output=bytearray();answered=False;deadline=time.monotonic()+12
        try:
            while time.monotonic()<deadline:
                if select.select([master],[],[],.05)[0]:
                    try:chunk=os.read(master,65536)
                    except OSError:break
                    if not chunk:break
                    output.extend(chunk)
                    if b'Type resume to confirm:' in output and not answered:
                        os.write(master,answer.encode()+b'\n');answered=True
                elif child.poll() is not None:break
            # PTY EOF can arrive just before waitpid observes process exit.
            try:code=child.wait(timeout=max(.01,deadline-time.monotonic()))
            except subprocess.TimeoutExpired:
                child.kill();child.wait();self.fail('inert recovery fixture did not finish')
            return code,output.decode(errors='replace'),answered
        finally:
            if child.poll() is None:child.kill();child.wait()
            os.close(master)

    def legacy_pending(self):
        self.ref_file('NEW_TOKEN=fixture-legacy-recovery\n');self.bind()
        marker=self.broker_root/'lose-folder-reply';marker.touch()
        result=self.run_envs('import','--secrets','NEW_TOKEN');self.assertNotEqual(0,result.returncode)
        marker.unlink()
        directory=self.broker_root/'state/vault-share/env-write'
        pending=[]
        for path in directory.glob('*.json'):
            row=json.loads(path.read_text())
            if row.get('state')=='pending':
                self.assertIsNone(row.get('id'));row.pop('phase',None)
                path.write_text(json.dumps(row));path.chmod(0o600);pending.append(row)
        self.assertEqual(1,len(pending))
        return (self.project/'.env').read_bytes()

    def test_legacy_absent_pending_requires_typed_resume_and_cancel_is_no_write(self):
        before=self.legacy_pending();source=self.project/'.env'
        ordinary=self.run_envs('import','--secrets','NEW_TOKEN')
        self.assertEqual(4,ordinary.returncode,ordinary.stderr)
        self.assertIn('env write pending (stage=recovery)',ordinary.stderr)
        self.assertEqual(before,source.read_bytes())
        calls=json.loads((self.broker_root/'vault.json').read_text())['calls']
        refused,output,prompt=self.terminal_import('no')
        self.assertTrue(prompt);self.assertEqual(4,refused,output)
        self.assertIn('pending import recovery was cancelled; source retained',output)
        self.assertEqual(before,source.read_bytes())
        self.assertEqual(calls,json.loads((self.broker_root/'vault.json').read_text())['calls'])
        resumed,output,prompt=self.terminal_import('resume')
        self.assertTrue(prompt);self.assertEqual(0,resumed,output)
        self.assertIn('NEW_TOKEN=bw://Users/td/Env/demo/dev#NEW_TOKEN',source.read_text())
        vault=json.loads((self.broker_root/'vault.json').read_text())
        self.assertEqual(1,vault['calls'].count('create'))
        self.assertNotIn('fixture-legacy-recovery',output)

    def test_confirmed_resume_cannot_change_original_hmac_bound_values(self):
        self.legacy_pending();source=self.project/'.env'
        source.write_text('NEW_TOKEN=fixture-changed-payload\n');before=source.read_bytes()
        calls=json.loads((self.broker_root/'vault.json').read_text())['calls']
        result,output,prompt=self.terminal_import('resume')
        self.assertTrue(prompt);self.assertEqual(4,result,output)
        self.assertIn('env write pending (stage=recovery)',output)
        self.assertEqual(before,source.read_bytes())
        self.assertEqual(calls,json.loads((self.broker_root/'vault.json').read_text())['calls'])
        self.assertNotIn('fixture-changed-payload',output)

    def test_native_import_bind_run_then_set_without_toml(self):
        self.ref_file('NEW_TOKEN=fixture-socket-secret\nAPP_PORT=8080\n');self.bind()
        imported=self.run_envs('import','--secrets','NEW_TOKEN','--plain','APP_PORT')
        self.assertEqual(0,imported.returncode,imported.stderr)
        self.assertEqual('NEW_TOKEN=bw://Users/td/Env/demo/dev#NEW_TOKEN\nAPP_PORT=8080\n',(self.project/'.env').read_text())
        self.assertFalse((self.project/'.envs.toml').exists());self.bind()
        child=self.project/'verify.py';child.write_text('import os,sys\nsys.exit(0 if os.environ.get("NEW_TOKEN")=="fixture-socket-secret" else 9)\n')
        run=self.run_envs('run','--no-mise','--','/usr/bin/python3','-I','-B',str(child))
        self.assertEqual(0,run.returncode,run.stderr)
        changed=self.set_secret('fixture-socket-updated');self.assertEqual(0,changed.returncode,changed.stderr)
        self.bind()
        child.write_text('import os,sys\nsys.exit(0 if os.environ.get("NEW_TOKEN")=="fixture-socket-updated" else 9)\n')
        run=self.run_envs('run','--no-mise','--','/usr/bin/python3','-I','-B',str(child))
        self.assertEqual(0,run.returncode,run.stderr)
        vault=json.loads((self.broker_root/'vault.json').read_text())
        self.assertEqual(1,vault['calls'].count('create'));self.assertEqual(1,vault['calls'].count('edit'))
        self.assertEqual(1,len(vault['items']))
        self.assertNotIn('fixture-socket-secret',imported.stdout+imported.stderr+changed.stdout+changed.stderr)
        self.assertNotIn('fixture-socket-updated',changed.stdout+changed.stderr)

    def test_lost_reply_reconciles_same_request_without_duplicate_create(self):
        self.ref_file('NEW_TOKEN=fixture-recovery-secret\n');self.bind()
        marker=self.broker_root/'lose-reply';marker.touch();before=(self.project/'.env').read_bytes()
        failed=self.run_envs('import','--secrets','NEW_TOKEN')
        self.assertNotEqual(0,failed.returncode);self.assertEqual(before,(self.project/'.env').read_bytes())
        marker.unlink()
        retried=self.run_envs('import','--secrets','NEW_TOKEN')
        self.assertEqual(0,retried.returncode,retried.stderr)
        vault=json.loads((self.broker_root/'vault.json').read_text());self.assertEqual(1,vault['calls'].count('create'))
        self.assertEqual(1,len(vault['items']))

    def test_locked_stale_and_revoked_policy_keep_source(self):
        self.ref_file('NEW_TOKEN=fixture-failure-secret\n');self.bind();before=(self.project/'.env').read_bytes()
        marker=self.broker_root/'locked';marker.touch()
        locked=self.run_envs('import','--secrets','NEW_TOKEN');self.assertEqual(3,locked.returncode,locked.stderr)
        self.assertEqual(before,(self.project/'.env').read_bytes());marker.unlink()
        stale=self.broker_root/'stale';stale.touch()
        failed=self.run_envs('import','--secrets','NEW_TOKEN');self.assertNotEqual(0,failed.returncode)
        self.assertEqual(before,(self.project/'.env').read_bytes());stale.unlink()
        (self.broker_root/'etc/env-write.tsv').write_text('# vault-share env-write v1\n')
        denied=self.run_envs('import','--secrets','NEW_TOKEN');self.assertEqual(4,denied.returncode,denied.stderr)
        self.assertEqual(before,(self.project/'.env').read_bytes())

if __name__=='__main__':unittest.main()
