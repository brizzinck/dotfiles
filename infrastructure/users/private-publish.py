#!/usr/bin/python3 -IB
"""Checked private publication, links and metadata-only secret migration.

The publisher reads committed objects only. Diagnostics never include subprocess
output: scanner/git errors can contain private data. No credentials are parsed.
"""
import argparse
import fnmatch
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import pwd
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata

HERE = Path(__file__).resolve().parent
ALLOWED = ('.claude/agents', '.claude/skills', '.gemini/config/skills')
OPTIONAL = ('.claude/CLAUDE.md', '.gemini/GEMINI.md')
DENY = [s for s in (HERE / 'private-deny.txt').read_text().splitlines() if s and not s.startswith('#')]


class Refused(Exception):
    pass


def run(args, **kw):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          timeout=120, **kw).stdout


def safe_rel(name):
    if (not name or name.startswith('/') or any(unicodedata.category(c) in ('Cc', 'Cf', 'Cs', 'Zl', 'Zp') for c in name)
            or any(c in ('', '.', '..') for c in name.split('/'))):
        raise Refused('unsafe relative path')
    return name


def denied(name):
    for part in name.split('/'):
        for rule in DENY:
            if fnmatch.fnmatchcase(part.lower(), rule.lower()):
                return rule
    return None


def checked_path(path, owner=None, private=False, missing=False):
    """lstat each component; never follow an existing symlink."""
    path = Path(path).absolute()
    for p in reversed([path, *path.parents][:-1]):
        try:
            s = p.lstat()
        except FileNotFoundError:
            if missing:
                continue
            raise Refused('unsafe ownership, mode or path')
        if stat.S_ISLNK(s.st_mode):
            raise Refused('unsafe ownership, mode or path')
        if p == path and owner is not None:
            if s.st_uid != owner or (private and (s.st_mode & 0o077)):
                raise Refused('unsafe ownership, mode or path')
        if p != path and not stat.S_ISDIR(s.st_mode):
            raise Refused('unsafe ownership, mode or path')
    return path.lstat() if path.exists() else None


def acl(path):
    return [line.split()[0] for line in run(['getfacl', '-cpn', '--', str(path)]).decode().splitlines() if line]


def secret_safe(path, uid, tighten=False, permit_wide=False):
    s = checked_path(path, uid)
    if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1:
        raise Refused('unsafe ownership, mode or path')
    # Sources are strict. Migration may tighten a fully masked legacy ACL
    # skeleton; it never accepts any effective named grant.
    lines = acl(path)
    mask = next((line.split(':')[-1] for line in lines if line.startswith('mask:')), 'rwx')
    if any(line.startswith('default:') or
           (len(line.split(':')) == 3 and line.split(':')[0] in ('user', 'group')
            and line.split(':')[1] and line.split(':')[2] != '---'
            and not (permit_wide and mask == '---')) for line in lines):
        raise Refused('unsafe ownership, mode or path')
    if tighten:
        os.chmod(path, 0o600)
    elif s.st_mode & 0o077 and not permit_wide:
        raise Refused('unsafe ownership, mode or path')


def mkdir_private(path, uid):
    path = Path(path)
    checked_path(path, missing=True)
    if not path.exists():
        # Harden only requested/new directories, never an existing ancestor
        # such as a managed home carrying the trusted publisher's ACL.
        if not path.parent.exists():
            mkdir_private(path.parent, uid)
        path.mkdir(mode=0o700)
    s = path.lstat()
    if not stat.S_ISDIR(s.st_mode) or s.st_uid != uid:
        raise Refused('unsafe ownership, mode or path')
    # Strip inherited named/default ACLs rather than silently retaining grants.
    run(['setfacl', '-b', '-k', '--', str(path)])
    os.chmod(path, 0o700)


def home_for_self():
    # Isolated fixtures only; no general HOME override in production.
    fixture = os.environ.get('USR_PRIVATE_TEST_HOME', '')
    if os.environ.get('USR_PRIVATE_TEST') == '1' and os.geteuid() != 0 and fixture:
        p = Path(fixture).absolute()
        if any(str(p).startswith(x + '/') for x in ('/tmp', '/var/tmp', '/dev/shm')) and (p / '.private-test').is_file():
            return p
        raise Refused('invalid test home')
    return Path(pwd.getpwuid(os.getuid()).pw_dir)


def open_directory(path, uid):
    """Hold an ancestor chain via openat, rejecting links and foreign writers."""
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in Path(path).absolute().parts[1:]:
            nextfd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = nextfd
            st = os.fstat(fd)
            # The fixture's /tmp ancestor is sticky/root-owned. No real secret
            # paths are accepted through a globally writable ancestor.
            fixture_tmp = os.environ.get('USR_PRIVATE_TEST') == '1' and part in ('tmp', 'shm') and st.st_uid == 0 and st.st_mode & stat.S_ISVTX
            if st.st_uid not in (0, uid) or (st.st_mode & 0o002 and not fixture_tmp):
                raise Refused('unsafe ownership, mode or path')
            if fixture_tmp:
                continue
            lines = acl('/proc/' + str(os.getpid()) + '/fd/' + str(fd))
            mask = next((line.split(':')[-1] for line in lines if line.startswith('mask:')), 'rwx')
            trusted = {uid, 0}
            try:
                fixture_root = home_for_self().parent / 'private' if os.environ.get('USR_PRIVATE_TEST') == '1' else Path('/srv/private')
                trusted.add(anchor_owner(fixture_root))
            except (Refused, OSError, KeyError):
                pass
            for line in lines:
                fields = line.split(':')
                if len(fields) != 3 or fields[0] not in ('user', 'group') or 'w' not in fields[2] or 'w' not in mask:
                    continue
                if fields[0] == 'user' and (not fields[1] or fields[1].isdigit() and int(fields[1]) in trusted):
                    continue
                raise Refused('unsafe ownership, mode or path')
        return fd
    except BaseException:
        os.close(fd)
        raise


def rename_noreplace(src, dst, src_fd, dst_fd):
    # Linux renameat2 gives atomic no-clobber retirement on one filesystem.
    import ctypes
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.renameat2(src_fd, os.fsencode(src), dst_fd, os.fsencode(dst), 1) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def migrate(dry=False, initialize=False):
    home = home_for_self()
    uid = os.getuid()
    legacy = home / 'dotfiles/env.secret.sh'
    canonical = home / '.config/secrets/env.sh'
    checked_path(legacy, missing=True)
    checked_path(canonical, missing=True)
    # Preflight any existing parent before creating/hardening directories.
    for target in (legacy.parent, canonical.parent):
        existing = target
        while not existing.exists():
            existing = existing.parent
        dfd = open_directory(existing, uid)
        os.close(dfd)
    if canonical.exists():
        if legacy.exists():
            raise Refused('both secret files exist; import the legacy file explicitly before retiring it')
        metadata = checked_path(canonical, uid)
        if metadata.st_mode & 0o077:
            raise Refused('unsafe ownership, mode or path')
        secret_safe(canonical, uid, permit_wide=True)
        skeleton = any(line.startswith(('mask:', 'user:', 'group:')) and line.split(':')[1]
                       for line in acl(canonical))
        if skeleton and dry:
            print('usr: canonical secrets need masked ACL cleanup; run usr secrets-migrate --self')
            return
        if not dry:
            dfd = open_directory(canonical.parent, uid)
            fd = os.open(canonical.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
            try:
                held = os.fstat(fd)
                if (held.st_dev, held.st_ino, held.st_mode, held.st_nlink, held.st_uid) != (metadata.st_dev, metadata.st_ino, metadata.st_mode, metadata.st_nlink, metadata.st_uid):
                    raise Refused('unsafe ownership, mode or path')
                # Revalidate the held inode and remove only a fully masked ACL
                # skeleton. Active grants were refused before opening it.
                held_path = '/proc/' + str(os.getpid()) + '/fd/' + str(fd)
                held_acl = acl(held_path)
                if any(line.startswith('mask:') and line != 'mask::---' for line in held_acl):
                    raise Refused('unsafe ownership, mode or path')
                if skeleton:
                    os.removexattr(fd, 'system.posix_acl_access')
                    os.fchmod(fd, 0o600)
                os.fsync(fd)
            finally:
                os.close(fd)
                os.close(dfd)
            mkdir_private(canonical.parent, uid)
        print('usr: secrets already migrated')
        return
    if not legacy.exists():
        if initialize and not dry:
            mkdir_private(canonical.parent, uid)
            dfd = open_directory(canonical.parent, uid)
            try:
                fd = os.open('env.sh', os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600, dir_fd=dfd)
                os.close(fd)
            finally:
                os.close(dfd)
        print('usr: secrets not configured' + ('; canonical file initialized' if initialize and not dry else ''))
        return
    secret_safe(legacy, uid, permit_wide=True)
    source_dir = open_directory(legacy.parent, uid)
    source_fd = os.open(legacy.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=source_dir)
    try:
        original = os.fstat(source_fd)
        current = os.stat(legacy.name, dir_fd=source_dir, follow_symlinks=False)
        if not stat.S_ISREG(original.st_mode) or original.st_nlink != 1 or original.st_uid != uid or (original.st_dev, original.st_ino) != (current.st_dev, current.st_ino):
            raise Refused('unsafe ownership, mode or path')
        # Repeat ACL validation on the held inode, not its replaceable pathname.
        source_acl = acl('/proc/' + str(os.getpid()) + '/fd/' + str(source_fd))
        source_mask = next((line.split(':')[-1] for line in source_acl if line.startswith('mask:')), 'rwx')
        for line in source_acl:
            fields = line.split(':')
            if len(fields) == 3 and fields[0] in ('user', 'group') and fields[1] and fields[2] != '---' and source_mask != '---':
                raise Refused('unsafe ownership, mode or path')
        if dry:
            print('usr: would back up and migrate legacy secrets to ~/.config/secrets/env.sh')
            return
        os.fchmod(source_fd, 0o600)
        original = os.fstat(source_fd)
        def identity(st):
            return st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns, st.st_nlink
        mkdir_private(canonical.parent, uid)
        backups = home / '.local/state/usr/secrets-backups'
        mkdir_private(backups, uid)
        backup = Path(tempfile.mkdtemp(prefix='migration-', dir=backups)) / 'env.secret.sh'
        # Both copies read the same held, no-follow inode. Always copy to the
        # destination filesystem; linkat publishes atomically without overwrite.
        def copy_closed(destination):
            fd = os.open(destination, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'wb') as dst, os.fdopen(os.dup(source_fd), 'rb') as src:
                src.seek(0)
                shutil.copyfileobj(src, dst)
                dst.flush()
                os.fsync(dst.fileno())
        copy_closed(backup)
        destination_dir = open_directory(canonical.parent, uid)
        tmpname = '.env.new-' + str(os.getpid()) + '-' + str(time.time_ns())
        tmp = canonical.parent / tmpname
        # Keep the original inode recoverable, rather than check-then-unlink.
        # On a split filesystem retain it in an ignored private directory next
        # to the legacy source; ordinary layouts keep it beside the first copy.
        retirement = backup.parent
        if retirement.stat().st_dev != original.st_dev:
            local_backups = legacy.parent / 'env.secret.backups'
            mkdir_private(local_backups, uid)
            retirement = Path(tempfile.mkdtemp(prefix='migration-', dir=local_backups))
        retirement_dir = open_directory(retirement, uid)
        retired_name = 'original-env.secret.sh'
        retired = False
        success = False
        try:
            copy_closed(tmp)
            final_source = os.stat(legacy.name, dir_fd=source_dir, follow_symlinks=False)
            if identity(final_source) != identity(original) or identity(os.fstat(source_fd)) != identity(original):
                raise Refused('legacy file changed during migration; backup retained')
            rename_noreplace(legacy.name, retired_name, source_dir, retirement_dir)
            retired = True
            displaced = os.stat(retired_name, dir_fd=retirement_dir, follow_symlinks=False)
            if (displaced.st_dev, displaced.st_ino, displaced.st_size, displaced.st_mtime_ns, displaced.st_nlink) != (original.st_dev, original.st_ino, original.st_size, original.st_mtime_ns, original.st_nlink):
                raise Refused('legacy file changed during migration; original retained')
            # rename itself advances ctime; adopt that expected metadata only
            # after checking inode/size/mtime of the displaced original.
            original = displaced
            os.link(tmpname, canonical.name, src_dir_fd=destination_dir, dst_dir_fd=destination_dir, follow_symlinks=False)
            os.unlink(tmpname, dir_fd=destination_dir)
            os.fsync(destination_dir)
            if identity(os.fstat(source_fd)) != identity(original):
                raise Refused('legacy file changed during migration; original retained')
            os.fsync(retirement_dir)
            os.fsync(source_dir)
            success = True
        finally:
            if retired and not success:
                # Restore the displaced source without overwriting any newer
                # legacy file. On collision both recoverable inodes stay put.
                try:
                    rename_noreplace(retired_name, legacy.name, retirement_dir, source_dir)
                except OSError:
                    pass
            try:
                os.unlink(tmpname, dir_fd=destination_dir)
            except FileNotFoundError:
                pass
            os.close(retirement_dir)
            os.close(destination_dir)
    finally:
        os.close(source_fd)
        os.close(source_dir)
    print('usr: migrated legacy secrets to ~/.config/secrets/env.sh; values were not displayed')


def test_root(root):
    return (os.environ.get('USR_PRIVATE_TEST') == '1' and os.geteuid() != 0
            and any(str(root).startswith(p + '/') for p in ('/tmp', '/var/tmp', '/dev/shm'))
            and (root.parent / '.private-test').is_file())


def anchor_owner(root):
    test = test_root(root)
    anchor = Path(os.environ.get('USR_PRIVATE_ANCHOR', '')) if test else Path('/etc/usr-managed/devtools-owner')
    if not anchor.is_absolute():
        raise Refused('missing publisher anchor')
    checked_path(anchor)
    for p in [anchor, *anchor.parents][:-1]:
        s = p.lstat()
        if s.st_uid != (os.getuid() if test else 0) or (s.st_mode & 0o022 and not (test and p == Path('/tmp'))):
            raise Refused('unsafe publisher anchor')
        if test and p == root.parent:
            break
    s = anchor.lstat()
    if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1:
        raise Refused('unsafe publisher anchor')
    name = anchor.read_text().strip()
    return pwd.getpwnam(name).pw_uid


def group_id(root):
    import grp
    if test_root(root):
        return os.getgid()
    return grp.getgrnam('dotfiles-private').gr_gid


def validate_private_tree(root, uid, repair=False, before_open=None):
    checked_path(root)
    if not stat.S_ISDIR(root.lstat().st_mode):
        raise Refused('private root is not a directory')
    gid = group_id(root)
    for parent in root.parents:
        s = parent.lstat()
        if not test_root(root) and (s.st_uid != 0 or s.st_mode & 0o022):
            raise Refused('unsafe private parent')
    paths = []
    for directory, dirs, files in os.walk(root, followlinks=False):
        paths.extend(Path(directory) / n for n in [*dirs, *files])
    paths = sorted(set(paths), key=lambda p: len(p.parts), reverse=True) + [root]
    # Validate every entry before any ACL repair, then keep the root closed
    # until all descendants are repaired. No member can traverse a half-repair.
    for p in paths:
        st = p.lstat()
        if st.st_uid != uid or not (stat.S_ISDIR(st.st_mode) or stat.S_ISREG(st.st_mode)) or (stat.S_ISREG(st.st_mode) and st.st_nlink != 1):
            raise Refused('unsafe private tree')
    if repair:
        os.chmod(root, 0o700)
    for p in paths:
        s = p.lstat()
        isdir = stat.S_ISDIR(s.st_mode)
        if s.st_uid != uid or not (isdir or stat.S_ISREG(s.st_mode)) or (not isdir and s.st_nlink != 1):
            raise Refused('unsafe private tree')
        mode = 0o750 if isdir or s.st_mode & 0o100 else 0o640
        if repair:
            if p == root and before_open is not None:
                before_open()
            run(['setfacl', '-b', '-k', '--', str(p)])
            run(['setfacl', '-m', f'u::rw{"x" if mode == 0o750 else "-"},g::---,g:{gid}:r-{"x" if mode == 0o750 else "-"},m::r-{"x" if mode == 0o750 else "-"},o::---', '--', str(p)])
            if isdir:
                run(['setfacl', '-m', f'd:u::rwx,d:g::---,d:g:{gid}:r-x,d:m::r-x,d:o::---', '--', str(p)])
            os.chmod(p, mode)
        lines = set(x for x in acl(p) if x)
        execute = 'x' if mode == 0o750 else '-'
        expected = {'user::rw' + execute, 'group::---', f'group:{gid}:r-{execute}', 'mask::r-' + execute, 'other::---'}
        if isdir:
            expected |= {'default:user::rwx', 'default:group::---', f'default:group:{gid}:r-x', 'default:mask::r-x', 'default:other::---'}
        if not isdir and f'group:{gid}:r-x' in lines:
            lines.remove(f'group:{gid}:r-x')
            lines.add(f'group:{gid}:r--')
        if stat.S_IMODE(p.stat().st_mode) != mode or lines != expected:
            raise Refused('unsafe private ACL or mode')
    if root.stat().st_gid != gid:
        raise Refused('unsafe private root group')


def private_manifest(files, contents=None):
    explicit = contents is not None
    text = contents if explicit else (HERE / 'private-links.tsv').read_text()
    entries = []
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        if len(line.split('\t')) != 2:
            raise Refused('invalid private manifest')
        source, dest = line.split('\t')
        safe_rel(source)
        safe_rel(dest)
        if denied(source) or denied(dest):
            raise Refused('forbidden private manifest path')
        if source != dest or not (any(source == a or source.startswith(a + '/') for a in ALLOWED) or source in OPTIONAL):
            raise Refused('unapproved private manifest path')
        if any(dest == d or dest.startswith(d + '/') or d.startswith(dest + '/') for _, d in entries):
            raise Refused('overlapping private manifest destinations')
        exists = source in files or any(f.startswith(source + '/') for f in files)
        if not exists:
            if explicit:
                raise Refused('missing explicit private source')
            continue
        entries.append((source, dest))
    return entries


def committed_tree(repo, rev):
    files = {}
    raw = run(['git', '-C', str(repo), 'ls-tree', '-rz', '--full-tree', rev])
    for item in raw.split(b'\0'):
        if not item:
            continue
        meta, rawname = item.split(b'\t', 1)
        name = rawname.decode('utf-8', 'strict')
        safe_rel(name)
        mode, kind, oid = meta.decode().split()
        if mode not in ('100644', '100755') or kind != 'blob':
            raise Refused('unsupported private tree entry')
        rule = denied(name)
        if rule:
            raise Refused(f'forbidden tracked path {json.dumps(name, ensure_ascii=True)} ({rule})')
        files[name] = (oid, mode)
    return files


def scan_private_commit(repo, rev, scratch):
    # Empty HEAD + pinned index makes every blob a staged addition, including
    # unchanged ancient blobs and merge-only additions. No repo-provided rules.
    scan = scratch / 'scan'
    run(['git', 'init', '-q', str(scan)])
    objects = run(['git', '-C', str(repo), 'rev-parse', '--path-format=absolute', '--git-path', 'objects']).decode().strip()
    (scan / '.git/objects/info/alternates').write_text(objects + '\n')
    run(['git', '-C', str(scan), 'read-tree', rev])
    config = scratch / 'rules.toml'
    config.write_text('[extend]\nuseDefault = true\n')
    run(['gitleaks', 'git', '--staged', '--redact', '--ignore-gitleaks-allow', '--no-banner',
         '--config', str(config), '--exit-code', '3', str(scan)])


def publish(repo, root, dry=False):
    # Check setup BEFORE touching the private checkout (also keeps hooks safe).
    if not root.exists():
        print('usr: /srv/private is not set up; run sudo ./apply-system.sh --only users')
        return
    uid = anchor_owner(root)
    if os.getuid() != uid:
        raise Refused('only the anchored owner may publish private')
    validate_private_tree(root, uid)
    if not (repo / '.git').exists():
        print('usr: private checkout absent; skipped')
        return
    rev = run(['git', '-C', str(repo), 'rev-parse', 'HEAD^{commit}']).decode().strip()
    files = committed_tree(repo, rev)
    manifest = run(['git', '-C', str(repo), 'show', f'{rev}:links.txt']).decode() if 'links.txt' in files else None
    entries = private_manifest(files, manifest)
    mhash = hashlib.sha256(json.dumps(entries).encode()).hexdigest()
    policy = hashlib.sha256(Path(__file__).read_bytes() + (HERE / 'private-deny.txt').read_bytes() + (HERE / 'private-links.tsv').read_bytes()).hexdigest()
    scanner = run(['gitleaks', 'version']).decode().strip()
    if len(scanner) > 100 or any(ord(c) < 32 for c in scanner):
        raise Refused('invalid scanner version')
    marker = root / '.published'
    old = json.loads(marker.read_text()) if marker.exists() else {}
    wanted = dict(rev=rev, manifest=mhash, policy=policy, scanner=scanner)
    if all(old.get(k) == v for k, v in wanted.items()):
        print('usr: private publication current')
        return
    if dry:
        print('usr: would scan and publish committed private revision')
        return
    with tempfile.TemporaryDirectory(prefix='usr-private-') as temp:
        scratch = Path(temp)
        scan_private_commit(repo, rev, scratch)
        stage = scratch / 'payload'
        stage.mkdir(mode=0o700)
        selected = [n for n in files if n == 'links.txt' or any(n == s or n.startswith(s + '/') for s, _ in entries)]
        for name in selected:
            p = stage / name
            p.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            p.write_bytes(run(['git', '-C', str(repo), 'cat-file', 'blob', files[name][0]]))
            p.chmod(0o700 if files[name][1] == '100755' else 0o600)
        # A failed/interrupted copy never leaves a current certification.
        marker.unlink(missing_ok=True)
        run(['rsync', '-rltp', '--delete', '--no-group', '--filter=P /.published',
             '--chmod=Du=rwx,Dg=rx,Do=,Fu=rwX,Fg=rX,Fo=', str(stage) + '/', str(root) + '/'])
        validate_private_tree(root, uid)
        wanted['time'] = int(time.time())
        tmp = root / '.published.new'
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o640)
        with os.fdopen(fd, 'w') as f:
            json.dump(wanted, f)
            f.flush()
            os.fsync(f.fileno())
        # New publication metadata inherits the same read-only ACL.
        os.rename(tmp, marker)
        validate_private_tree(root, uid)
    print('usr: private publication complete')


def legacy_clone_links(home):
    """Inventory link metadata only; never descend into a symlink or a store."""
    prune = {'.ssh', '.gnupg', '.aws', '.cache', 'dotfiles', 'node_modules', '.git',
             'secrets', 'secrets-backups', 'rbw', 'Bitwarden', 'Bitwarden CLI', 'keyrings',
             'google-chrome', 'chromium', 'mozilla', 'zen', '.mcp-auth'}
    result = []
    for directory, dirs, files in os.walk(home, followlinks=False):
        if Path(directory) == home / '.local':
            dirs[:] = [name for name in dirs if name not in ('share', 'state')]
        dirs[:] = [name for name in dirs if name not in prune and not denied(name)]
        for name in [*dirs, *files]:
            p = Path(directory) / name
            if not p.is_symlink():
                continue
            rel = str(p.relative_to(home))
            target = os.path.normpath(os.path.join(str(p.parent), os.readlink(p)))
            if target == str(home / 'dotfiles') or target.startswith(str(home / 'dotfiles') + '/'):
                result.append(rel)
    return result


def link_private(root, home, backup, dry=False, restore=False):
    if not root.exists():
        return
    uid = anchor_owner(root)
    validate_private_tree(root, uid)
    if not (root / '.published').is_file():
        raise Refused('private publication is not certified')
    files = [str(p.relative_to(root)) for d, _, names in os.walk(root) for p in (Path(d) / n for n in names)]
    entries = private_manifest(files, (root / 'links.txt').read_text() if (root / 'links.txt').exists() else None)
    certification = json.loads((root / '.published').read_text())
    if certification.get('manifest') != hashlib.sha256(json.dumps(entries).encode()).hexdigest():
        raise Refused('private manifest does not match certification')
    for src, _ in entries:
        checked_path(root / src)
    state = home / '.local/state/usr'
    checked_path(state, missing=True)
    record = state / 'private-links.tsv'
    checked_path(record, missing=True)
    previous = [line.split('\t') for line in record.read_text().splitlines()] if record.exists() else []
    # Preflight EVERY destination ancestor before any target changes. A known
    # old clone parent link is moved as a link itself, never traversed.
    parents = {}
    for _, dest in entries:
        for rel in reversed(list(PurePosixPath(dest).parents)[:-1]):
            p = home / str(rel)
            if p.is_symlink():
                target = os.path.normpath(os.path.join(str(p.parent), os.readlink(p)))
                if target != str(home / 'dotfiles/private' / str(rel)):
                    raise Refused(f'foreign destination parent: {str(rel)}')
                parents[str(rel)] = p
                break
            if p.exists() and (not p.is_dir() or p.stat().st_uid != os.getuid()):
                raise Refused('unsafe destination ancestor')
    checked_path(home)
    if dry:
        print('usr: private links validated (dry run)')
        return
    mkdir_private(state, os.getuid())
    for rel, p in sorted(parents.items(), key=lambda kv: len(kv[0])):
        mkdir_private(backup / '.retired-parents' / str(PurePosixPath(rel).parent), os.getuid())
        old = os.readlink(p)
        p.rename(backup / '.retired-parents' / rel)
        p.mkdir(mode=0o700)
        created = p.stat()
        with open(backup / 'MANIFEST', 'a') as out:
            out.write(f'{rel}\tlink\t{old}\t{created.st_dev}:{created.st_ino}\tprivate-parent\n')
    desired = {d: str(root / s) for s, d in entries}
    for rel, target in previous:
        safe_rel(rel)
        p = home / rel
        if desired.get(rel) != target and p.is_symlink() and os.readlink(p) == target:
            checked_path(p.parent)
            p.unlink()
        elif desired.get(rel) != target:
            print(f'usr: changed private link retained: {rel}')
    for src, rel in entries:
        target = str(root / src)
        p = home / rel
        checked_path(p.parent, missing=True)
        if p.is_symlink() and os.readlink(p) == target:
            continue
        made = []
        parent = p.parent
        while parent != home and not parent.exists():
            made.append(str(parent.relative_to(home)))
            parent = parent.parent
        mkdir_private(p.parent, os.getuid())
        mkdir_private(backup, os.getuid())
        with open(backup / 'MANIFEST', 'a') as out:
            for directory in reversed(made):
                created = (home / directory).stat()
                out.write(f'{directory}\tnone\t-\t{created.st_dev}:{created.st_ino}\tprivate-dir\n')
        kind, old = 'none', '-'
        if p.exists() or p.is_symlink():
            kind = 'link' if p.is_symlink() else ('dir' if p.is_dir() else 'file')
            old = os.readlink(p) if p.is_symlink() else '-'
            mkdir_private((backup / rel).parent, os.getuid())
            p.rename(backup / rel)
        p.symlink_to(target)
        with open(backup / 'MANIFEST', 'a') as out:
            out.write(f'{rel}\t{kind}\t{old}\t{target}\tprivate\n')
    fd, temporary = tempfile.mkstemp(prefix='.private-links-', dir=state)
    temp = Path(temporary)
    try:
        with os.fdopen(fd, 'w') as output:
            output.write(''.join(f'{d}\t{t}\n' for d, t in desired.items()))
            output.flush()
            os.fsync(output.fileno())
        temp.replace(record)
    finally:
        temp.unlink(missing_ok=True)
    print(f'usr: {len(entries)} approved private links current')
    for rel in legacy_clone_links(home):
        print('usr: unmatched clone link retained: ' + json.dumps(rel, ensure_ascii=True))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('command', choices=('publish', 'link', 'migrate', 'setup', 'validate', 'parent-check'))
    p.add_argument('--root', type=Path, default=Path('/srv/private'))
    p.add_argument('--repo', type=Path)
    p.add_argument('--home', type=Path)
    p.add_argument('--backup', type=Path)
    p.add_argument('--owner')
    p.add_argument('--relative')
    p.add_argument('--members', default='')
    p.add_argument('--dry-run', action='store_true')
    p.add_argument('--initialize', action='store_true')
    a = p.parse_args()
    try:
        if a.command == 'publish':
            publish(a.repo, a.root, a.dry_run)
        elif a.command == 'migrate':
            migrate(a.dry_run, a.initialize)
        elif a.command == 'link':
            link_private(a.root, a.home, a.backup, a.dry_run)
        elif a.command == 'parent-check':
            safe_rel(a.relative)
            checked_path((a.home / a.relative).parent, missing=True)
        elif a.command == 'setup':
            if os.geteuid() != 0:
                raise Refused('private setup requires root')
            uid = pwd.getpwnam(a.owner).pw_uid
            if a.root != Path('/srv/private'):
                raise Refused('unexpected private root')
            checked_path(a.root, missing=True)
            if a.root.exists() and a.root.stat().st_uid not in (0, uid):
                raise Refused('foreign private root')
            for parent in a.root.parents:
                if parent.stat().st_uid != 0 or parent.stat().st_mode & 0o022:
                    raise Refused('unsafe private parent')
            a.root.mkdir(mode=0o700, exist_ok=True)
            if a.root.stat().st_mode & 0o022:
                raise Refused('unexpected private root writers')
            os.chmod(a.root, 0o700)
            os.chown(a.root, uid, group_id(a.root))
            import re
            if a.members and any(not re.fullmatch(r'[a-z_][a-z0-9_-]{0,30}', name) or name in ('root', a.owner) for name in a.members.split(',')):
                raise Refused('unexpected private members')
            validate_private_tree(a.root, uid, repair=True, before_open=lambda: run(['gpasswd', '-M', a.members, 'dotfiles-private']))
        else:
            validate_private_tree(a.root, anchor_owner(a.root))
    except Refused as e:
        print('usr: ' + ('secrets migration refused: ' if a.command == 'migrate' else 'private publish refused: ') + str(e), file=sys.stderr)
        return 2
    except (OSError, ValueError, KeyError, UnicodeError, subprocess.SubprocessError):
        print('usr: ' + ('secrets migration refused: unsafe ownership, mode or path' if a.command == 'migrate' else 'private operation failed; no private values displayed'), file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
