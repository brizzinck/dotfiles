#!/usr/bin/env python3
"""Invented capability policy metadata only; no root, users, broker or backend changes."""
import importlib.util
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest

_isolation_spec = importlib.util.spec_from_file_location('write_test_isolation', Path(__file__).with_name('write_isolation.py'))
_isolation = importlib.util.module_from_spec(_isolation_spec); _isolation_spec.loader.exec_module(_isolation)

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('write_policy', REPO / '.config/hypr/scripts/vault-share-write.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Policy(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='fake-env-write-policy-')
        self.root = Path(self.tmp.name)
        self.path = self.root / 'etc' / 'env-write.tsv'
        self.path.parent.mkdir(mode=0o755)
        self.path.write_text(module.POLICY_HEADER + '\ntd\t1101\n')
        self.path.chmod(0o640)
        self.policy = module.WritePolicy(self.path, test_root=self.root)

    def tearDown(self): self.tmp.cleanup()

    def test_td_exact_uid_only_and_revocation_is_fresh(self):
        self.assertTrue(self.policy.allows(1101, 'td'))
        for uid, name in ((1102, 'td'), (1101, 'yc'), (0, 'td'), (1000, 'owner'), (1101, 'service')):
            self.assertFalse(self.policy.allows(uid, name))
        self.path.write_text(module.POLICY_HEADER + '\n')
        self.assertFalse(self.policy.allows(1101, 'td'))

    def test_malformed_duplicate_foreign_and_large_policies_refuse(self):
        for rows in ('td\t1101\ntd\t1101\n', 'yc\t1101\n', 'td\t0\n', 'td\t01101\n',
                     'td\t1101\textra\n', 'td\t1101\x1b\n', 'td\t1101\n' + 'x' * 4096):
            self.path.write_text(module.POLICY_HEADER + '\n' + rows)
            self.assertFalse(self.policy.allows(1101, 'td'))
        self.path.write_text('# unsupported-v2\ntd\t1101\n')
        self.assertFalse(self.policy.allows(1101, 'td'))

    def test_no_follow_and_write_permission_boundaries(self):
        self.path.chmod(0o660); self.assertFalse(self.policy.allows(1101, 'td'))
        self.path.chmod(0o640)
        self.path.parent.chmod(0o777); self.assertFalse(self.policy.allows(1101, 'td'))
        self.path.parent.chmod(0o755)
        other = self.root / 'other'; self.path.rename(other)
        self.path.symlink_to(other); self.assertFalse(self.policy.allows(1101, 'td'))
        self.path.unlink(); os.mkfifo(self.path, 0o600)
        self.assertFalse(self.policy.allows(1101, 'td'))
        self.path.unlink(); other.rename(self.path)
        self.path.parent.rename(self.root / 'moved')
        self.path.parent.symlink_to(self.root / 'moved', target_is_directory=True)
        self.assertFalse(self.policy.allows(1101, 'td'))

    def render(self, flags='interactive,env-write', user='td'):
        registry = self.root / 'managed.tsv'
        registry.write_text(f'{user}\tcli\t{flags}\torange\tInvented\n')
        tools = self.root / 'bin'; tools.mkdir(exist_ok=True)
        for tool in ('bw', 'rbw', 'fzf-menu', 'ghostty', 'notify-send', 'hyprctl', 'wl-copy'):
            path = tools / tool; path.write_text('#!/bin/sh\nexit 97\n'); path.chmod(0o700)
        path = tools / 'id'; path.write_text('#!/bin/sh\nprintf "1101\\n"\n'); path.chmod(0o700)
        text = (REPO / 'apply-system.sh').read_text()
        functions = text[text.index('users_render_vs_env_write() {'):text.index('users_vault_share() {')]
        program = f'source {shlex.quote(str(REPO / "infrastructure/users/lib.sh"))}\n'
        program += f'INFRA={shlex.quote(str(REPO / "infrastructure"))}\n' + functions + '\nmanaged_validate owner\nusers_render_vs_env_write\n'
        env = {'PATH': str(tools) + ':/usr/bin:/bin', 'HOME': str(self.root), 'USR_MANAGED_TSV': str(registry),
               **{key: str(self.root / key) for key in ('XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME', 'XDG_RUNTIME_DIR')}}
        return subprocess.run(['/bin/bash', '-c', program], env=env, check=True, capture_output=True, text=True).stdout

    def test_root_renderer_and_capability_registry_are_td_only(self):
        output = self.render()
        self.assertTrue(output.startswith(module.POLICY_HEADER + '\n'))
        self.assertIn('td\t1101\n', output)
        self.assertNotIn('td\t1101\n', self.render(flags='interactive'))
        for flags, user in (('interactive,env-write', 'yc'), ('service,env-write', 'td')):
            output = self.render(flags, user)
            self.assertIn('env-write is restricted', output)
            self.assertNotIn('td\t1101\n', output)


if __name__ == '__main__': unittest.main()
