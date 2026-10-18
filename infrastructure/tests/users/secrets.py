#!/usr/bin/python3 -IB
"""Offline C1-C3 regression fixtures. Never reads the real private checkout."""
import importlib.util
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('private_publish', REPO / 'infrastructure/users/private-publish.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class Secrets(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='private-tests-')
        self.t = Path(self.temp.name)
        (self.t / '.private-test').touch()
        self.root = self.t / 'private'
        self.home = self.t / 'home'
        self.home.mkdir(mode=0o700)
        (self.home / '.private-test').touch()
        self.anchor = self.t / 'anchor'
        self.anchor.write_text(pwd.getpwuid(os.getuid()).pw_name + '\n')
        self.anchor.chmod(0o644)
        self.env = patch.dict(os.environ, {'USR_PRIVATE_TEST': '1', 'USR_PRIVATE_ANCHOR': str(self.anchor),
                                          'USR_PRIVATE_TEST_HOME': str(self.home)})
        self.env.start()
        self.repo = self.t / 'repo'
        self.repo.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'core.hooksPath', '/dev/null')
        self.bin = self.t / 'bin'
        self.bin.mkdir()
        scanner = self.bin / 'gitleaks'
        scanner.write_text('#!/bin/sh\n[ "$1" = version ] && { echo fixture-v1; exit 0; }\nexit "${SCAN_RC:-0}"\n')
        scanner.chmod(0o700)
        self.paths = patch.dict(os.environ, {'PATH': str(self.bin) + ':' + os.environ['PATH']})
        self.paths.start()

    def tearDown(self):
        self.paths.stop()
        self.env.stop()
        self.temp.cleanup()

    def git(self, *args):
        return m.run(['git', '-C', str(self.repo), *args])

    def commit(self, files):
        for name, content in files.items():
            p = self.repo / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(content)
        self.git('add', '--', *files)
        self.git('commit', '-qm', 'fixture')
        return self.git('rev-parse', 'HEAD').decode().strip()

    def setup_root(self):
        self.root.mkdir(mode=0o700)
        m.validate_private_tree(self.root, os.getuid(), repair=True)

    def test_manifest_constraints(self):
        files = ['.claude/agents/reader.md', '.gemini/config/skills/tool.md']
        self.assertEqual(len(m.private_manifest(files)), 2)
        for line in ('.claude\t.claude', '.claude/agents\t../agents', '.claude/agents\t/etc/agents',
                     '.claude/agents\t.claude/skills', '.claude/CLAUDE.md\t.claude/CLAUDE.md',
                     '.claude/agents\t.claude/agents\n.claude/agents/reader.md\t.claude/agents/reader.md'):
            with self.subTest(line=line), self.assertRaises(m.Refused):
                m.private_manifest(files, line)

    def test_deny_names(self):
        for name in ('.claude/.credentials.json', 'x/AUTH.JSON', 'x/.env.test', 'x/secret.secret.txt',
                     'x/sessions/y', 'x/history.json', 'x/cache/y', 'x/transcript42.jsonl', '.git/config'):
            self.assertTrue(m.denied(name), name)
        self.assertIsNone(m.denied('.claude/agents/example.env'))
        for name in ('../escape', '/absolute', 'a//b', 'a/./b', 'a\nname', 'a\x85name', 'a\u202ename', 'a\u2028name', 'a\ud800name'):
            with self.subTest(name=name), self.assertRaises(m.Refused):
                m.safe_rel(name)

    def test_reject_symlink_tree(self):
        (self.repo / 'link').symlink_to('/etc/passwd')
        self.git('add', 'link')
        self.git('commit', '-qm', 'fixture link')
        with self.assertRaises(m.Refused):
            m.committed_tree(self.repo, 'HEAD')

    def test_denied_outside_selected_tree(self):
        rev = self.commit({'.claude/agents/ok.md': 'safe', '.gemini/auth.json': 'invented'})
        with self.assertRaises(m.Refused):
            m.committed_tree(self.repo, rev)

    def test_publication_and_failure_keeps_previous(self):
        self.setup_root()
        rev = self.commit({'.claude/agents/ok.md': 'invented shared skill', '.claude/settings.json': 'personal only'})
        m.publish(self.repo, self.root)
        self.assertEqual((self.root / '.claude/agents/ok.md').read_text(), 'invented shared skill')
        self.assertFalse((self.root / '.claude/settings.json').exists())
        marker = (self.root / '.published').read_bytes()
        self.assertIn(rev.encode(), marker)
        (self.repo / '.claude/agents/ok.md').write_text('dirty worktree must be ignored')
        m.publish(self.repo, self.root)
        self.assertEqual((self.root / '.published').read_bytes(), marker)
        self.commit({'.claude/agents/ok.md': 'new invented revision'})
        with patch.dict(os.environ, {'SCAN_RC': '3'}), self.assertRaises(subprocess.CalledProcessError):
            m.publish(self.repo, self.root)
        self.assertEqual((self.root / '.published').read_bytes(), marker)
        self.assertEqual((self.root / '.claude/agents/ok.md').read_text(), 'invented shared skill')

    def test_scan_index_has_entire_snapshot(self):
        rev = self.commit({'.claude/agents/old.md': 'old unchanged'})
        rev = self.commit({'.claude/skills/new.md': 'new'})
        scanner = self.bin / 'gitleaks'
        scanner.write_text('#!/bin/sh\nfor arg do last=$arg; done\ngit -C "$last" diff --cached --name-only >"$SCAN_NAMES"\n')
        scanner.chmod(0o700)
        with patch.dict(os.environ, {'SCAN_NAMES': str(self.t / 'names')}):
            m.scan_private_commit(self.repo, rev, self.t)
        self.assertEqual(set((self.t / 'names').read_text().splitlines()),
                         {'.claude/agents/old.md', '.claude/skills/new.md'})

    def test_acl_and_anchor_fail_closed(self):
        self.setup_root()
        self.anchor.chmod(0o666)
        with self.assertRaises(m.Refused):
            m.anchor_owner(self.root)
        self.anchor.chmod(0o644)
        p = self.root / 'bad'
        p.write_text('fixture')
        p.chmod(0o644)
        with self.assertRaises(m.Refused):
            m.validate_private_tree(self.root, os.getuid())

    def test_acl_repair_reconciles_members_only_while_root_gated(self):
        self.setup_root()
        p = self.root / 'nested/file'
        p.parent.mkdir()
        p.write_text('invented')
        p.chmod(0o666)
        calls = []
        def reconcile():
            self.assertEqual(self.root.stat().st_mode & 0o777, 0o700)
            self.assertEqual(p.stat().st_mode & 0o777, 0o640)
            self.assertIn('group::---', m.acl(p))
            calls.append('members reconciled before reopen')
        m.validate_private_tree(self.root, os.getuid(), repair=True, before_open=reconcile)
        self.assertEqual(len(calls), 1)
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o750)
        m.validate_private_tree(self.root, os.getuid(), repair=True)
        p.unlink()
        p.symlink_to(self.t / 'elsewhere')
        with self.assertRaises(m.Refused):
            m.validate_private_tree(self.root, os.getuid())

    def test_private_link_retires_parent_without_traversal(self):
        self.setup_root()
        self.commit({'.claude/agents/ok.md': 'shared'})
        m.publish(self.repo, self.root)
        clone = self.home / 'dotfiles/private/.claude'
        clone.mkdir(parents=True)
        (clone / 'auth.json').write_text('invented local credential')
        (self.home / '.claude').symlink_to(clone)
        backup = self.home / '.local/state/usr/backup-test'
        m.link_private(self.root, self.home, backup)
        self.assertFalse((self.home / '.claude').is_symlink())
        self.assertTrue((self.home / '.claude/agents').is_symlink())
        self.assertFalse((self.home / '.claude/auth.json').exists())
        self.assertTrue((backup / '.retired-parents/.claude').is_symlink())
        self.assertEqual(list(clone.iterdir()), [clone / 'auth.json'])
        manifest = (backup / 'MANIFEST').read_text()
        m.link_private(self.root, self.home, backup)
        self.assertEqual((backup / 'MANIFEST').read_text(), manifest)

    def test_foreign_ancestor_refused_before_link(self):
        self.setup_root()
        self.commit({'.claude/agents/ok.md': 'shared', '.gemini/config/skills/ok.md': 'shared'})
        m.publish(self.repo, self.root)
        (self.home / '.gemini').symlink_to(self.t)
        with self.assertRaises(m.Refused):
            m.link_private(self.root, self.home, self.home / '.local/state/usr/backup-test')
        self.assertFalse((self.home / '.claude').exists())

    def legacy(self, mode=0o600):
        p = self.home / 'dotfiles/env.secret.sh'
        p.parent.mkdir()
        p.write_text('export FIXTURE_SECRET=only-invented\n')
        p.chmod(mode)
        return p

    def test_migration_copy_backup_and_idempotence(self):
        old = self.legacy(0o644)
        old_inode = old.stat().st_ino
        m.migrate(dry=True)
        self.assertTrue(old.exists())
        m.migrate()
        canonical = self.home / '.config/secrets/env.sh'
        self.assertFalse(old.exists())
        self.assertEqual(canonical.stat().st_mode & 0o777, 0o600)
        self.assertEqual(len(list((self.home / '.local/state/usr/secrets-backups').glob('*/env.secret.sh'))), 1)
        originals = list((self.home / '.local/state/usr/secrets-backups').glob('*/original-env.secret.sh'))
        self.assertEqual(len(originals), 1)
        self.assertEqual(originals[0].stat().st_ino, old_inode)
        m.migrate()

    def test_both_files_no_merge(self):
        old = self.legacy()
        canonical = self.home / '.config/secrets/env.sh'
        canonical.parent.mkdir(parents=True)
        canonical.write_text('export OTHER=invented\n')
        canonical.chmod(0o600)
        with self.assertRaises(m.Refused):
            m.migrate()
        self.assertTrue(old.exists())

    def test_migration_refuses_symlink_hardlink_acl(self):
        old = self.legacy()
        alias = self.home / 'alias'
        alias.hardlink_to(old)
        with self.assertRaises(m.Refused):
            m.migrate()
        alias.unlink()
        m.run(['setfacl', '-m', 'u:65534:r--', str(old)])
        with self.assertRaises(m.Refused):
            m.migrate()
        old.unlink()
        old.symlink_to(self.t / 'absent')
        with self.assertRaises(m.Refused):
            m.migrate()

    def shell(self):
        env = dict(os.environ, DF_SECRETS_TEST='1', DF_SECRETS_HOME=str(self.home))
        return subprocess.run(['zsh', '-f', '-c', 'source "$1"; print -r -- "${FIXTURE_SOURCE:-none}"',
                               '_', str(REPO / '.config/zsh/secrets.zsh')], env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)

    def test_shell_canonical_only_and_no_unsafe_fallback(self):
        old = self.legacy()
        old.write_text('export FIXTURE_SOURCE=legacy\n')
        self.assertEqual(self.shell().stdout.strip(), b'legacy')
        canonical = self.home / '.config/secrets/env.sh'
        canonical.parent.mkdir(parents=True)
        canonical.write_text('export FIXTURE_SOURCE=canonical\n')
        canonical.chmod(0o600)
        self.assertEqual(self.shell().stdout.strip(), b'canonical')
        canonical.chmod(0o644)
        result = self.shell()
        self.assertEqual(result.stdout.strip(), b'none')
        self.assertIn(b'unsafe', result.stderr)

    def test_migration_no_clobber_concurrent_canonical(self):
        old = self.legacy()
        original_link = os.link
        def racing_link(*args, **kwargs):
            canonical = self.home / '.config/secrets/env.sh'
            canonical.write_text('concurrently-created-invented-value')
            canonical.chmod(0o600)
            return original_link(*args, **kwargs)
        with patch.object(m.os, 'link', side_effect=racing_link), self.assertRaises(FileExistsError):
            m.migrate()
        self.assertTrue(old.exists())
        self.assertEqual((self.home / '.config/secrets/env.sh').read_text(), 'concurrently-created-invented-value')
        self.assertEqual(len(list((self.home / '.local/state/usr/secrets-backups').glob('*/env.secret.sh'))), 1)

    def test_migration_source_swap_retains_both_sources(self):
        old = self.legacy()
        moved = old.with_name('original-invented')
        original_copy = shutil.copyfileobj
        swapped = False
        def racing_copy(*args, **kwargs):
            nonlocal swapped
            if not swapped:
                old.rename(moved)
                old.write_text('replacement-invented')
                old.chmod(0o600)
                swapped = True
            return original_copy(*args, **kwargs)
        with patch.object(m.shutil, 'copyfileobj', side_effect=racing_copy), self.assertRaises(m.Refused):
            m.migrate()
        self.assertEqual(old.read_text(), 'replacement-invented')
        self.assertTrue(moved.exists())
        self.assertFalse((self.home / '.config/secrets/env.sh').exists())

    def test_migration_source_in_place_edit_refused(self):
        old = self.legacy()
        original_copy = shutil.copyfileobj
        changed = False
        def racing_copy(*args, **kwargs):
            nonlocal changed
            result = original_copy(*args, **kwargs)
            if not changed:
                old.write_text('in-place-invented-replacement')
                changed = True
            return result
        with patch.object(m.shutil, 'copyfileobj', side_effect=racing_copy), self.assertRaises(m.Refused):
            m.migrate()
        self.assertEqual(old.read_text(), 'in-place-invented-replacement')
        self.assertFalse((self.home / '.config/secrets/env.sh').exists())

    def test_migration_last_retirement_race_keeps_newest_original(self):
        old = self.legacy()
        original_rename = m.rename_noreplace
        raced = False
        def racing_rename(src, dst, *args):
            nonlocal raced
            if src == 'env.secret.sh' and not raced:
                old.write_text('latest-invented-at-retirement')
                raced = True
            return original_rename(src, dst, *args)
        with patch.object(m, 'rename_noreplace', side_effect=racing_rename), self.assertRaises(m.Refused):
            m.migrate()
        self.assertEqual(old.read_text(), 'latest-invented-at-retirement')
        self.assertFalse((self.home / '.config/secrets/env.sh').exists())

    def test_migration_source_swap_fifo_never_blocks(self):
        old = self.legacy()
        moved = old.with_name('held-original')
        original_open = os.open
        def racing_open(path, flags, *args, **kwargs):
            if path == 'env.secret.sh' and kwargs.get('dir_fd') is not None:
                self.assertTrue(flags & os.O_NONBLOCK)
                old.rename(moved)
                os.mkfifo(old, 0o600)
            return original_open(path, flags, *args, **kwargs)
        with patch.object(m.os, 'open', side_effect=racing_open), self.assertRaises(m.Refused):
            m.migrate()
        self.assertTrue(moved.exists())

    def test_migration_zero_effective_legacy_acl_is_safe_to_tighten(self):
        old = self.legacy()
        m.run(['setfacl', '-m', 'u:65533:rwx,m::---', str(old)])
        self.assertEqual(old.stat().st_mode & 0o777, 0o600)
        m.migrate()
        canonical = self.home / '.config/secrets/env.sh'
        self.assertFalse(any(line.startswith('user:65533:') for line in m.acl(canonical)))
        self.assertEqual(canonical.stat().st_mode & 0o777, 0o600)

    def test_initializer_preserves_existing_home_publisher_acl(self):
        m.run(['setfacl', '-m', 'u:65533:rwx', str(self.home)])
        before = m.acl(self.home)
        with patch.object(m, 'anchor_owner', return_value=65533):
            m.migrate(initialize=True)
        self.assertEqual(m.acl(self.home), before)
        self.assertEqual((self.home / '.config/secrets').stat().st_mode & 0o777, 0o700)

    def test_existing_canonical_masked_acl_is_cleaned_without_reading(self):
        canonical = self.home / '.config/secrets/env.sh'
        canonical.parent.mkdir(parents=True)
        canonical.write_text('export FIXTURE_SOURCE=canonical\n')
        canonical.chmod(0o600)
        m.run(['setfacl', '-m', 'u:65533:r--,m::---', str(canonical)])
        m.migrate(dry=True)
        self.assertTrue(any(line.startswith('user:65533:') for line in m.acl(canonical)))
        m.migrate()
        self.assertFalse(any(line.startswith('user:65533:') for line in m.acl(canonical)))
        self.assertEqual(self.shell().stdout.strip(), b'canonical')

    def test_migration_named_owner_parent_and_unrelated_writer(self):
        self.legacy()
        # The trusted workstation owner on a managed home is represented by an
        # invented numeric uid. It is trusted only via the checked anchor API.
        m.run(['setfacl', '-m', 'u:65533:rwx', str(self.home)])
        with patch.object(m, 'anchor_owner', return_value=65533):
            m.migrate(dry=True)
        with patch.object(m, 'anchor_owner', return_value=65532), self.assertRaises(m.Refused):
            m.migrate(dry=True)

    def test_usr_restore_roundtrip_and_user_edit_preserved(self):
        self.setup_root()
        self.commit({'.claude/agents/ok.md': 'shared', '.gemini/config/skills/ok.md': 'shared'})
        m.publish(self.repo, self.root)
        srv = self.t / 'public'
        srv.mkdir()
        (srv / '.zshrc').write_text('# fixture\n')
        clone = self.home / 'dotfiles/private'
        for parent in ('.claude', '.gemini'):
            (clone / parent).mkdir(parents=True)
            (self.home / parent).symlink_to(clone / parent)
        registry = self.t / 'managed.tsv'
        registry.write_text('fixture\tcli\tinteractive\t-\n')
        env = dict(os.environ, USR_MANAGED_TSV=str(registry), USR_TARGET_USER='fixture',
                   USR_TARGET_HOME=str(self.home), USR_SRV_DOTFILES=str(srv), USR_SRV_PRIVATE=str(self.root),
                   USR_DEVTOOLS_SHARED=str(self.t / 'absent-tools'))
        command = [str(REPO / '.local/bin/usr'), '_link']
        subprocess.run(command, env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        subprocess.run(command + ['--restore'], env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(os.readlink(self.home / '.claude'), str(clone / '.claude'))
        self.assertEqual(os.readlink(self.home / '.gemini'), str(clone / '.gemini'))
        # Link again, then a local edit must survive --restore.
        subprocess.run(command, env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        link = self.home / '.claude/agents'
        link.unlink()
        link.mkdir()
        (link / 'local.md').write_text('local invented edit')
        (self.home / '.gemini/user-empty').mkdir()
        subprocess.run(command + ['--restore'], env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual((link / 'local.md').read_text(), 'local invented edit')
        self.assertTrue((self.home / '.gemini/user-empty').is_dir())
        self.assertFalse((self.home / '.gemini').is_symlink())
        # A changed ancestor must not redirect restore into a foreign tree,
        # even if that foreign leaf has the exact previously recorded target.
        subprocess.run(command, env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        (self.home / '.claude').rename(self.home / 'kept-claude')
        foreign = self.t / 'foreign'
        foreign.mkdir()
        (foreign / 'agents').symlink_to(self.root / '.claude/agents')
        (self.home / '.claude').symlink_to(foreign)
        subprocess.run(command + ['--restore'], env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertTrue((foreign / 'agents').is_symlink())
        self.assertEqual(os.readlink(self.home / '.claude'), str(foreign))

    def test_removed_manifest_prunes_exact_link_and_preserves_replacement(self):
        self.setup_root()
        self.commit({'.claude/agents/ok.md': 'shared', '.claude/skills/ok.md': 'shared'})
        m.publish(self.repo, self.root)
        backup = self.home / '.local/state/usr/backup-test'
        m.link_private(self.root, self.home, backup)
        skills = self.home / '.claude/skills'
        skills.unlink()
        skills.mkdir()
        (skills / 'mine.md').write_text('invented user edit')
        self.commit({'links.txt': '.claude/agents\t.claude/agents\n'})
        m.publish(self.repo, self.root)
        m.link_private(self.root, self.home, backup)
        self.assertEqual((skills / 'mine.md').read_text(), 'invented user edit')
        self.commit({'links.txt': '# no shared destinations\n'})
        m.publish(self.repo, self.root)
        m.link_private(self.root, self.home, backup)
        self.assertFalse((self.home / '.claude/agents').is_symlink())

    def test_planted_state_temp_symlink_never_truncates_target(self):
        self.setup_root()
        self.commit({'.claude/agents/ok.md': 'shared'})
        m.publish(self.repo, self.root)
        state = self.home / '.local/state/usr'
        state.mkdir(parents=True)
        victim = self.t / 'unrelated'
        victim.write_text('must remain unchanged')
        (state / 'private-links.new').symlink_to(victim)
        m.link_private(self.root, self.home, state / 'backup-test')
        self.assertEqual(victim.read_text(), 'must remain unchanged')

    def test_recovery_directory_never_stowed_or_publicly_published(self):
        packages = self.t / 'packages'
        package = packages / 'fixture'
        recovery = package / 'env.secret.backups/one'
        recovery.mkdir(parents=True)
        (recovery / 'original-env.secret.sh').write_text('invented recovery')
        shutil.copyfile(REPO / '.stow-local-ignore', package / '.stow-local-ignore')
        target = self.t / 'target'
        target.mkdir()
        m.run(['stow', '--dir', str(packages), '--target', str(target), 'fixture'])
        self.assertFalse((target / 'env.secret.backups').exists())
        destination = self.t / 'public-destination'
        destination.mkdir()
        m.run(['rsync', '-r', '--exclude-from=' + str(REPO / 'infrastructure/users/publish.exclude'),
               str(package) + '/', str(destination) + '/'])
        self.assertFalse((destination / 'env.secret.backups').exists())

    def test_target_migration_dispatches_published_usr(self):
        registry = self.t / 'managed.tsv'
        registry.write_text('fixture\tcli\tinteractive\t-\n')
        srv = self.t / 'public'
        command = srv / '.local/bin/usr'
        command.parent.mkdir(parents=True)
        command.write_text('#!/bin/sh\nexit 99\n')
        command.chmod(0o700)
        sudo = self.bin / 'sudo'
        sudo.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
        sudo.chmod(0o700)
        getent = self.bin / 'getent'
        getent.write_text('#!/bin/sh\nif [ "$1:$2" = passwd:fixture ]; then\n'
                          '  printf "fixture:x:12345:12345::/fixture:/bin/zsh\\n"\n'
                          'else exec /usr/bin/getent "$@"; fi\n')
        getent.chmod(0o700)
        env = dict(os.environ, USR_MANAGED_TSV=str(registry), USR_SRV_DOTFILES=str(srv))
        result = subprocess.run([str(REPO / '.local/bin/usr'), 'secrets-migrate', 'fixture', '--dry-run'],
                                env=env, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.stdout.decode().splitlines(),
                         ['-n', '-u', 'fixture', '-H', str(command), 'secrets-migrate', '--self', '--dry-run'])
        # Root integration must use the same accessible path after publication.
        apply = (REPO / 'apply-system.sh').read_text()
        self.assertIn('sudo -u "$u" -H "$USERS_SRV_DOTFILES/.local/bin/usr" secrets-migrate --self', apply)
        self.assertNotIn('sudo -u "$u" -H "$usr_cmd" secrets-migrate', apply)

    def test_clone_inventory_is_metadata_only_and_prunes_stores(self):
        clone = self.home / 'dotfiles'
        clone.mkdir()
        (self.home / 'unmatched').symlink_to(clone / 'missing')
        # A directory symlink must never be traversed, even when its target has
        # another clone link; credential/cache paths are pruned entirely.
        outside = self.t / 'outside'
        outside.mkdir()
        (outside / 'nested').symlink_to(clone / 'missing')
        (self.home / 'foreign').symlink_to(outside)
        for name in ('.ssh', '.cache', '.local/state'):
            directory = self.home / name
            directory.mkdir(parents=True)
            (directory / 'secret-link').symlink_to(clone / 'missing')
        self.assertEqual(m.legacy_clone_links(self.home), ['unmatched'])

    def test_initializer_and_shell_unsafe_present_canonical(self):
        m.migrate(initialize=True)
        canonical = self.home / '.config/secrets/env.sh'
        self.assertEqual(canonical.stat().st_mode & 0o777, 0o600)
        canonical.unlink()
        canonical.symlink_to(self.t / 'missing')
        self.legacy().write_text('export FIXTURE_SOURCE=legacy\n')
        self.assertEqual(self.shell().stdout.strip(), b'none')

    def test_shell_ancestor_writer_refused(self):
        self.legacy().write_text('export FIXTURE_SOURCE=legacy\n')
        m.run(['setfacl', '-m', 'u:65534:rwx', str(self.home)])
        result = self.shell()
        self.assertEqual(result.stdout.strip(), b'none')
        self.assertIn(b'ancestor ACL refused', result.stderr)


if __name__ == '__main__':
    # Desktop side effects are blocked even if a future regression invokes one.
    os.environ.pop('DISPLAY', None)
    os.environ.pop('WAYLAND_DISPLAY', None)
    with tempfile.TemporaryDirectory(prefix='secrets-safe-bin-') as safe:
        for name in ('fzf-menu', 'ghostty', 'notify-send', 'hyprctl', 'wl-copy'):
            p = Path(safe) / name
            p.write_text('#!/bin/sh\nexit 99\n')
            p.chmod(0o700)
        os.environ['PATH'] = safe + ':' + os.environ['PATH']
        unittest.main()
