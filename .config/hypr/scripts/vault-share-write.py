#!/usr/bin/env python3
"""Constrained managed Env batch writes. No CLI, prompt or arbitrary item authority."""
import os
from pathlib import Path
import re
import stat
import fcntl
import importlib.util
import json
import subprocess
import time
import urllib.parse
import copy
import hashlib
import tempfile
import uuid
import socket
import threading
import hmac

MAX_FRAME = 256 * 1024
RESERVED = set('PATH HOME USER SHELL PWD TERM LANG IFS PYTHONPATH PYTHONSTARTUP PYTHONHOME NODE_OPTIONS NODE_PATH BW_SESSION SSH_AUTH_SOCK XDG_RUNTIME_DIR XDG_STATE_HOME XDG_CONFIG_HOME WAYLAND_DISPLAY BASH_ENV ENV ZDOTDIR GLIBC_TUNABLES GCONV_PATH PERL5OPT PERL5LIB RUBYOPT RUBYLIB GIT_DIR GIT_WORK_TREE GIT_SSH_COMMAND GIT_EXEC_PATH GIT_ASKPASS BW_BIN RBW_BIN PINENTRY_BIN'.split())
PREFIXES = ('MISE_', 'ENVS_', '__MISE', 'LD_', 'GIT_CONFIG', 'VAULT_BW_')


def identifier(value):
    return isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}', value) is not None


def request_data(msg):
    if (set(msg) != {'v', 'op', 'project', 'env', 'values', 'overwrite', 'request_id'}
            or type(msg['v']) is not int or msg['v'] != 1 or msg['op'] != 'env-put'
            or not isinstance(msg['project'], str) or not re.fullmatch(r'[a-z0-9][a-z0-9._-]{0,62}', msg['project'])
            or not isinstance(msg['env'], str) or not re.fullmatch(r'[a-z][a-z0-9_-]{0,31}', msg['env'])
            or (msg['project'] == 'global' and msg['env'] != 'default') or type(msg['overwrite']) is not bool):
        raise WriteError('bad_request')
    try:
        if str(uuid.UUID(msg['request_id'], version=4)) != msg['request_id']:
            raise ValueError
    except (ValueError, TypeError, AttributeError):
        raise WriteError('bad_request') from None
    values = msg['values']
    if not isinstance(values, dict) or not 1 <= len(values) <= 64:
        raise WriteError('bad_request')
    for name, value in values.items():
        if (not isinstance(name, str) or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]{0,99}', name)
                or name in RESERVED or name.startswith(PREFIXES) or not isinstance(value, str)
                or len(value) > 5000 or '\0' in value):
            raise WriteError('bad_request')
        try:
            if len(value.encode('utf-8')) > 20000:
                raise WriteError('bad_request')
        except UnicodeError:
            raise WriteError('bad_request') from None
    if len(json.dumps(msg, ensure_ascii=False).encode('utf-8')) + 1 > MAX_FRAME:
        raise WriteError('bad_request')
    return values

POLICY_HEADER = '# vault-share env-write v1'


class WritePolicy:
    """Read a fresh fd-pinned root policy for every authorization; never cache a revoked capability."""
    def __init__(self, path, test_root=None):
        self.path = Path(path)
        self.test_root = Path(test_root).absolute() if test_root is not None else None

    def allows(self, uid, name):
        if name != 'td' or type(uid) is not int or not 1000 <= uid <= 59999:
            return False
        fds = []
        try:
            target = self.path.absolute()
            if self.test_root is not None and not target.is_relative_to(self.test_root):
                return False
            fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
            fds.append(fd)
            current = Path('/')
            for component in target.parts[1:-1]:
                fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                fds.append(fd)
                current /= component
                st = os.fstat(fd)
                test_parent = self.test_root is not None and current.is_relative_to(self.test_root)
                owner = os.getuid() if test_parent else 0
                sticky_test_tmp = self.test_root is not None and current == Path('/tmp') and st.st_uid == 0 and st.st_mode & stat.S_ISVTX
                if st.st_uid != owner or (st.st_mode & 0o022 and not sticky_test_tmp):
                    return False
            fd = os.open(target.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
            fds.append(fd)
            before = os.fstat(fd)
            if (not stat.S_ISREG(before.st_mode) or before.st_uid != (os.getuid() if self.test_root is not None else 0)
                    or before.st_mode & 0o022 or before.st_size > 4096):
                return False
            raw = os.read(fd, 4097)
            after = os.fstat(fd)
            if len(raw) > 4096 or (before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
                    after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                return False
            lines = raw.decode('utf-8').splitlines()
            if not lines or lines[0] != POLICY_HEADER:
                return False
            rows = []
            for line in lines[1:]:
                if line.startswith('#'):
                    continue
                match = re.fullmatch(r'td\t([1-9][0-9]{3,4})', line)
                if match is None or not 1000 <= int(match[1]) <= 59999:
                    return False
                rows.append(int(match[1]))
            return rows == [uid]
        except (OSError, UnicodeError, ValueError):
            return False
        finally:
            for fd in reversed(fds):
                os.close(fd)


class WriteError(Exception):
    def __init__(self, code='unavailable'):
        self.code = code
        super().__init__(code)      # fixed category only, never backend output


class OwnerServer:
    """Bounded existing owner UNIX server only. Startup is user-manager-only; never the CLI fallback."""
    LIMIT = 16 * 1024 * 1024

    def __init__(self, deadline, module=None):
        self.deadline = deadline
        if module is None:
            path = Path(__file__).with_name('vault-bw.py')
            spec = importlib.util.spec_from_file_location('vault_share_owner_server', path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
        self.m = module

    def remaining(self):
        left = self.deadline - time.monotonic()
        if left <= 0:
            raise WriteError()
        return left

    def request(self, method, path, body=None, query=None):
        m = self.m
        if not m.run_dir_trusted():
            raise WriteError()
        if query:
            path += '?' + urllib.parse.urlencode(query)
        raw = json.dumps(body, ensure_ascii=False).encode('utf-8') if body is not None else None
        if raw is not None and len(raw) > 2 * 1024 * 1024:
            raise WriteError('bad_request')
        conn = m._UnixConn(str(m.SOCK), min(15, self.remaining()))
        timer = None
        try:
            conn.connect()     # existing adapter checks SO_PEERCRED before sending any body
            wire = conn.sock
            def expire():
                try:
                    wire.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            # HTTP header parsing performs repeated recv calls; a fixed timer bounds their total duration too.
            timer = threading.Timer(self.remaining(), expire)
            timer.daemon = True
            timer.start()
            wire.settimeout(min(15, self.remaining()))
            conn.request(method, path, body=raw, headers={'Accept': 'application/json', 'Content-Type': 'application/json'})
            response = conn.getresponse()
            content = bytearray()
            while True:
                if response.isclosed():
                    break
                wire.settimeout(min(15, self.remaining()))
                chunk = response.read1(min(65536, self.LIMIT + 1 - len(content)))
                if not chunk:
                    break
                content.extend(chunk)
                if len(content) > self.LIMIT:
                    raise WriteError()
            if response.status != 200:
                raise WriteError('locked' if response.status in (401, 403) else 'unavailable')
            document = json.loads(content)
            self.remaining()
            if not isinstance(document, dict) or document.get('success') is not True:
                raise WriteError()
            m.touch_used()
            return document.get('data')
        except WriteError:
            raise
        except Exception:
            raise WriteError() from None
        finally:
            if timer is not None:
                timer.cancel()
            conn.close()

    def ready(self):
        data = self.request('GET', '/status')
        data = data.get('template', data) if isinstance(data, dict) else None
        if not isinstance(data, dict) or data.get('status') != 'unlocked':
            raise WriteError('locked')

    def prepare(self):
        try:
            self.ready()
            return
        except WriteError as error:
            if error.code == 'locked':
                raise
        m = self.m
        if not m.run_dir_trusted():
            raise WriteError()
        lock = None
        try:
            # Validate metadata without loading the session key into this broker.
            session = os.open(m.SESSION, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            try:
                st = os.fstat(session)
                if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077 or not 1 <= st.st_size <= 16384:
                    raise WriteError('locked')
            finally:
                os.close(session)
            lock = os.open(m.SERVE_LOCK, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            st = os.fstat(lock)
            if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
                raise WriteError()
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    self.remaining()
                    time.sleep(0.05)
            try:
                self.ready()
                return
            except WriteError as error:
                if error.code == 'locked':
                    raise
            env = {'HOME': str(Path.home()), 'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8',
                   'XDG_RUNTIME_DIR': str(m.RUN.parent)}
            for name in ('XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME'):
                if os.environ.get(name):
                    env[name] = os.environ[name]
            settings = dict(env, BW_BIN='/usr/bin/bw', RBW_BIN='/usr/bin/rbw')
            args = ['/usr/bin/systemd-run', '--user', '--quiet', '--collect', '--unit=vault-bw-serve',
                    '--description=Bitwarden CLI server (unix socket)', '-p', 'LimitCORE=0']
            args += [f'--setenv={name}={value}' for name, value in settings.items()]
            args += ['--', '/usr/bin/python3', '-I', '-B', str(Path(m.__file__).resolve()), '_serve']
            result = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    env=env, timeout=min(10, self.remaining()), check=False)
            if result.returncode != 0:
                raise WriteError()
            while True:
                try:
                    self.ready()
                    return
                except WriteError as error:
                    if error.code == 'locked':
                        raise
                self.remaining()
                time.sleep(0.05)
        except WriteError:
            raise
        except Exception:
            raise WriteError() from None
        finally:
            if lock is not None:
                os.close(lock)

    def sync(self):
        self.request('POST', '/sync')

    def folders(self):
        data = self.request('GET', '/list/object/folders')
        return data.get('data') if isinstance(data, dict) else None

    def items(self, folder):
        data = self.request('GET', '/list/object/items', query={'folderid': folder})
        return data.get('data') if isinstance(data, dict) else None

    def get(self, ident):
        return self.request('GET', '/object/item/' + urllib.parse.quote(ident, safe=''))

    def create_folder(self, name):
        return self.request('POST', '/object/folder', {'name': name})

    def create(self, document):
        return self.request('POST', '/object/item', document)

    def edit(self, ident, document):
        return self.request('PUT', '/object/item/' + urllib.parse.quote(ident, safe=''), document)


class Writer:
    """Synchronous engine called off-loop under a broker lock. Journal entries contain metadata only."""
    MAX_COMPLETED = 4096
    MAX_RECORDS = 8192
    def __init__(self, directory, authorize, backend_factory=OwnerServer, verify=None):
        self.directory = Path(directory)
        self.authorize = authorize
        self.backend_factory = backend_factory
        self.verify = verify

    def permit(self, uid, name):
        if not self.authorize(uid, name):
            raise WriteError('policy')

    def private_directory(self):
        """Create descendants through held no-follow parents; never traverse a planted link."""
        path = self.directory.absolute()
        fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
        try:
            for part in path.parts[1:]:
                try:
                    child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                except FileNotFoundError:
                    os.mkdir(part, mode=0o700, dir_fd=fd)
                    child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd); fd = child
                st = os.fstat(fd)
                sticky_root = st.st_uid == 0 and st.st_mode & stat.S_ISVTX
                if st.st_uid not in (0, os.getuid()) or (st.st_mode & 0o022 and not sticky_root):
                    raise WriteError()
            st = os.fstat(fd)
            if st.st_uid != os.getuid() or st.st_mode & 0o077:
                raise WriteError()
        except OSError:
            raise WriteError() from None
        finally:
            os.close(fd)

    @staticmethod
    def marker(uid, project, env, request):
        return 'vault-share env v1\n' + json.dumps({'v': 1, 'uid': uid, 'project': project, 'env': env,
                                                   'created_request': request}, sort_keys=True, separators=(',', ':'))

    def inspect(self, rec, uid, project, env, folder, expected_id=None):
        if (not isinstance(rec, dict) or not identifier(rec.get('id')) or (expected_id and rec['id'] != expected_id)
                or rec.get('folderId') != folder or rec.get('name') != env or type(rec.get('type')) is not int
                or rec['type'] != 2 or rec.get('organizationId') is not None or rec.get('deletedDate')
                or type(rec.get('reprompt', 0)) is not int or rec.get('reprompt', 0) != 0 or rec.get('attachments') or rec.get('login')
                or rec.get('card') or rec.get('identity') or rec.get('sshKey')
                or rec.get('secureNote') != {'type': 0} or type(rec['secureNote'].get('type')) is not int):
            raise WriteError('policy')
        try:
            notes = rec['notes']
            prefix, raw = notes.split('\n', 1)
            mark = json.loads(raw)
            created = mark['created_request']
            if prefix != 'vault-share env v1' or str(uuid.UUID(created, version=4)) != created or notes != self.marker(uid, project, env, created):
                raise ValueError
        except (KeyError, ValueError, TypeError, AttributeError):
            raise WriteError('policy') from None
        fields = rec.get('fields')
        if not isinstance(fields, list) or len(fields) > 512:
            raise WriteError('policy')
        seen = set()
        for field in fields:
            if (not isinstance(field, dict) or not isinstance(field.get('name'), str) or field['name'] in seen
                    or not isinstance(field.get('value'), str) or type(field.get('type')) is not int or field.get('type') != 1
                    or field.get('linkedId') is not None):
                raise WriteError('policy')
            seen.add(field['name'])
        return created

    def folders(self, backend):
        records = backend.folders()
        if not isinstance(records, list) or len(records) > 100000:
            raise WriteError()
        found, ids, sentinel = {}, set(), False
        for row in records:
            if isinstance(row, dict) and set(row) == {'id', 'name', 'object'} and row['id'] in (None, '') and row['name'] == 'No Folder' and row['object'] == 'folder':
                if sentinel:
                    raise WriteError('conflict')
                sentinel = True
                continue
            if (not isinstance(row, dict) or not identifier(row.get('id')) or not isinstance(row.get('name'), str)
                    or row['id'] in ids or row['name'] in found):
                raise WriteError('conflict')
            ids.add(row['id'])
            found[row['name']] = row['id']
        return found

    def target(self, backend, folder, env):
        rows = backend.items(folder)
        if not isinstance(rows, list) or len(rows) > 100000:
            raise WriteError()
        matches, ids = [], set()
        for row in rows:
            if not isinstance(row, dict) or not identifier(row.get('id')) or row['id'] in ids or row.get('folderId') != folder:
                raise WriteError('conflict')
            ids.add(row['id'])
            if row.get('name') == env:
                matches.append(row)
        if len(matches) > 1:
            raise WriteError('conflict')
        if not matches:
            return None
        result = backend.get(matches[0]['id'])
        if not isinstance(result, dict) or result.get('id') != matches[0]['id']:
            raise WriteError('conflict')
        return result

    def save(self, target, row):
        fd, temp = tempfile.mkstemp(prefix='.operation-', dir=self.directory)
        try:
            with os.fdopen(fd, 'w') as stream:
                json.dump(row, stream, sort_keys=True)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temp, self.directory / (target + '.json'))
            parent = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.fsync(parent)
            finally:
                os.close(parent)
        finally:
            try:
                os.unlink(temp)
            except FileNotFoundError:
                pass

    def request_mac(self, msg):
        path = self.directory / 'request.key'
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        except FileExistsError:
            pass
        else:
            try:
                os.write(fd, os.urandom(32)); os.fsync(fd)
            finally:
                os.close(fd)
            parent = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try: os.fsync(parent)
            finally: os.close(parent)
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077 or st.st_size != 32 or st.st_nlink != 1:
                raise WriteError()
            key = os.read(fd, 33)
            if len(key) != 32: raise WriteError()
        finally:
            os.close(fd)
        raw = json.dumps(msg, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode('utf-8')
        return hmac.new(key, raw, hashlib.sha256).hexdigest()

    def run(self, msg, uid, name):
        values = request_data(msg)
        self.permit(uid, name)
        self.private_directory()
        try:
            lock = os.open(self.directory / 'writer.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        except OSError:
            raise WriteError() from None
        try:
            st = os.fstat(lock)
            if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
                raise WriteError()
            deadline = time.monotonic() + 60
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise WriteError()
                    time.sleep(0.05)
            self.permit(uid, name)
            result = self.execute(msg, uid, name, values, deadline)
            if self.verify is None:
                raise WriteError()
            self.verify(result['id'], uid, name, msg, deadline)
            self.permit(uid, name)
            self.complete(*result.pop('_journal'))
            return result
        except WriteError:
            raise
        except Exception:
            raise WriteError() from None
        finally:
            os.close(lock)

    def execute(self, msg, uid, name, values, deadline):
        project, env, request = msg['project'], msg['env'], msg['request_id']
        request_mac = self.request_mac(msg)
        folder_name = 'Users/' + name + '/Env/' + project
        target = hashlib.sha256(json.dumps([uid, project, env]).encode()).hexdigest()
        prior = None
        try:
            fd = os.open(self.directory / (target + '.json'), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except FileNotFoundError:
            pass
        else:
            try:
                st = os.fstat(fd)
                if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077 or st.st_size > 4096:
                    raise WriteError()
                prior = json.loads(os.read(fd, 4097))
                if (not isinstance(prior, dict) or prior.get('uid') != uid or prior.get('project') != project
                        or prior.get('env') != env or prior.get('state') not in ('pending', 'complete')):
                    raise WriteError()
            finally:
                os.close(fd)
        if prior and prior['state'] == 'pending' and prior.get('request') != request:
            raise WriteError('pending')
        if prior and prior.get('request') == request and not hmac.compare_digest(prior.get('mac', ''), request_mac):
            raise WriteError('pending' if prior['state'] == 'pending' else 'conflict')
        # A completed UUID is retained separately, so an old request can never be replayed.
        receipt_path = self.directory / ('done-' + request + '.json')
        if receipt_path.exists() and (not prior or prior.get('request') != request):
            raise WriteError('conflict')
        if not prior or prior.get('request') != request:
            # Never evict spent IDs or uncertain work. At capacity new operations fail closed.
            records = list(self.directory.glob('*.json'))
            if sum(path.name.startswith('done-') for path in records) >= self.MAX_COMPLETED or (prior is None and len(records) >= self.MAX_RECORDS):
                raise WriteError('pending')
        backend = self.backend_factory(deadline)
        backend.prepare()
        backend.sync()
        self.permit(uid, name)
        folders = self.folders(backend)
        folder = folders.get(folder_name)
        rec = self.target(backend, folder, env) if folder else None
        created = self.inspect(rec, uid, project, env, folder) if rec else request
        current = {field['name']: field['value'] for field in rec['fields']} if rec else {}
        if len(set(current) | set(values)) > 512:
            raise WriteError('policy')
        exact = rec is not None and all(current.get(key) == value for key, value in values.items())
        if prior and prior.get('request') == request:
            if (not exact or (prior.get('id') and rec['id'] != prior['id'])
                    or (not prior.get('id') and created != request)):
                raise WriteError('pending' if prior['state'] == 'pending' else 'conflict')
            return self.receipt(rec['id'], project, env, values, target, prior)
        if not msg['overwrite'] and any(key in current and current[key] != value for key, value in values.items()):
            raise WriteError('conflict')
        row = {'v': 1, 'uid': uid, 'project': project, 'env': env, 'request': request, 'id': rec['id'] if rec else None,
               'state': 'pending', 'created': int(time.time()), 'mac': request_mac}
        self.save(target, row)
        if not exact:
            # Folder creation is also an uncertain mutation: the pending record already exists.
            pieces = folder_name.split('/')
            for index in range(1, len(pieces) + 1):
                path = '/'.join(pieces[:index])
                if path not in folders:
                    self.permit(uid, name)
                    reply = backend.create_folder(path)
                    if not isinstance(reply, dict) or not identifier(reply.get('id')) or reply.get('name') != path:
                        raise WriteError('pending')
                    refreshed = self.folders(backend)
                    if refreshed.get(path) != reply['id']:
                        raise WriteError('pending')
                    folders = refreshed
            folder = folders[folder_name]
            fresh = self.target(backend, folder, env)
            if rec:
                self.inspect(fresh, uid, project, env, folder, rec['id'])
                if fresh != rec:
                    raise WriteError('pending')
                document = copy.deepcopy(fresh)
                fields = {field['name']: field for field in document['fields']}
                for key, value in values.items():
                    fields[key] = {'name': key, 'value': value, 'type': 1}
                document['fields'] = list(fields.values())
            else:
                if fresh is not None:
                    raise WriteError('pending')
                document = {'type': 2, 'name': env, 'folderId': folder, 'organizationId': None,
                            'notes': self.marker(uid, project, env, request), 'secureNote': {'type': 0},
                            'reprompt': 0, 'fields': [{'name': key, 'value': value, 'type': 1} for key, value in values.items()]}
            self.permit(uid, name)
            reply = backend.edit(rec['id'], document) if rec else backend.create(document)
            reply_created = self.inspect(reply, uid, project, env, folder, rec['id'] if rec else None)
            if reply_created != created:
                raise WriteError('pending')
            ident = reply['id']
            self.inspect(backend.get(ident), uid, project, env, folder, ident)
            rec = self.target(backend, folder, env)
            self.inspect(rec, uid, project, env, folder, ident)
            current = {field['name']: field['value'] for field in rec['fields']}
            if any(current.get(key) != value for key, value in values.items()):
                raise WriteError('pending')
        self.permit(uid, name)
        return self.receipt(rec['id'], project, env, values, target, row)

    def receipt(self, ident, project, env, values, target, row):
        # Completion is committed only after the broker establishes guarded rbw visibility.
        return {'id': ident, 'project': project, 'env': env, 'names': sorted(values), 'verified': True,
                '_journal': (target, row)}

    def complete(self, target, row):
        row = dict(row, state='complete')
        self.save('done-' + row['request'], {'v': 1, 'request': row['request'], 'state': 'complete'})
        self.save(target, row)
