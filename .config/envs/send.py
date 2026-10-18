"""Human-only rendered environment Sends. No recipient URL is ever opened."""
import contextlib
import ctypes
from datetime import datetime, timedelta, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import secrets
import signal
import stat
import subprocess
import time
import unicodedata
import urllib.parse

TEXT_LIMIT = 512
FILE_LIMIT = 4 * 1024 * 1024
UUID = re.compile(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}')
REQUEST = re.compile(r'envs-[0-9a-f]{32}')
UNKNOWN = 'Send creation outcome is unknown; recover the existing request before trying again'


class SendProblem(Exception):
    pass


class Interrupted(BaseException):
    pass


def label(value):
    return ''.join(c if unicodedata.category(c) not in ('Cc', 'Cf', 'Cs', 'Zl', 'Zp') else
                   f'<U+{ord(c):04X}>' for c in str(value))


def utc(value):
    if not isinstance(value, str) or len(value) > 40:
        raise SendProblem('Send policy could not be verified; no link copied')
    try:
        date = datetime.fromisoformat(value.replace('Z', '+00:00'))
        if date.utcoffset() != timedelta(0):
            raise ValueError
        return date
    except (ValueError, TypeError):
        raise SendProblem('Send policy could not be verified; no link copied') from None


def stamp(date):
    return date.isoformat(timespec='milliseconds').replace('+00:00', 'Z')


def origin(url, require_fragment=False):
    try:
        if not isinstance(url, str) or not url or len(url) > 4096 or len(url.encode('utf-8')) > 4096 or '\\' in url:
            raise ValueError
        if any(c.isspace() or unicodedata.category(c) in ('Cc', 'Cf', 'Cs', 'Zl', 'Zp') for c in url):
            raise ValueError
        parts = urllib.parse.urlsplit(url)
        if parts.scheme != 'https' or not parts.hostname or parts.username or parts.password:
            raise ValueError
        if require_fragment and not parts.fragment:
            raise ValueError
        port = parts.port
        return 'https://' + parts.hostname.lower() + ((':' + str(port)) if port not in (None, 443) else '')
    except (ValueError, TypeError):
        raise SendProblem('Send link could not be verified; no link copied') from None


def protect_process():
    try:
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        if ctypes.CDLL(None, use_errno=True).prctl(4, 0, 0, 0, 0) != 0:
            raise OSError
    except (OSError, ValueError):
        raise SendProblem('safe Send backend is unavailable; no Send created') from None


def runtime_acl_safe(lines, uid):
    """The existing clipboard policy grants named users traverse, never write."""
    access = [line for line in lines if line and not line.startswith(('#', 'default:'))]
    mask = next((line.split(':')[-1] for line in access if line.startswith('mask::')), 'rwx')
    required = {'user::rwx', 'group::---', 'other::---'}
    if not required.issubset(access):
        return False
    for line in access:
        fields = line.split(':')
        if len(fields) != 3:
            return False
        kind, who, permissions = fields
        if len(permissions) != 3 or any(c not in 'rwx-' for c in permissions):
            return False
        if kind == 'mask' and not who:
            continue
        if not who:
            continue
        effective = set(permissions) & set(mask) - {'-'}
        if kind == 'user' and who.isdigit():
            if int(who) not in (0, uid) and effective - {'x'}:
                return False
        elif kind != 'group' or effective:
            return False
    return True


def preflight(E):
    binaries = {name: E.tool(name) for name in ('bw', 'wl-copy', 'wl-paste')}
    if not all(Path(path).is_absolute() for path in binaries.values()):
        raise SendProblem('sensitive clipboard is unavailable; no Send created')
    if E.test_mode():
        # Verified fake directories only, never a real clipboard fallback.
        if any(not any(Path(path).resolve().is_relative_to(Path(root).resolve()) for root in E.TEST_DIRS)
               for path in binaries.values()) or os.environ.get('ENVS_TEST_SEND_TRANSPORT') != '1':
            raise SendProblem('sensitive clipboard is unavailable; no Send created')
    else:
        display = os.environ.get('WAYLAND_DISPLAY', '')
        if not re.fullmatch(r'[A-Za-z0-9_.-]+', display):
            raise SendProblem('a usable Wayland clipboard is required; no Send created')
        path = Path(f'/run/user/{os.getuid()}') / display
        if os.environ.get('XDG_RUNTIME_DIR') != str(path.parent):
            raise SendProblem('a usable Wayland clipboard is required; no Send created')
        try:
            runtime = path.parent.lstat()
            socket = path.lstat()
            for parent in (Path('/run'), Path('/run/user')):
                metadata = parent.lstat()
                if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o022:
                    raise OSError
            if not stat.S_ISDIR(runtime.st_mode) or runtime.st_uid != os.getuid() or runtime.st_mode & 0o700 != 0o700 or runtime.st_mode & 0o007:
                raise OSError
            if not stat.S_ISSOCK(socket.st_mode) or socket.st_uid != os.getuid():
                raise OSError
            permissions = subprocess.run([E.tool('getfacl'), '-cpnE', '--', str(path.parent)],
                                         capture_output=True, text=True, timeout=2)
            if permissions.returncode or not runtime_acl_safe(permissions.stdout.splitlines(), os.getuid()):
                raise OSError
        except (OSError, subprocess.SubprocessError):
            raise SendProblem('a usable Wayland clipboard is required; no Send created') from None
    backend = E.vbw()
    backend.BW = binaries['bw']
    if not E.test_mode() and not backend.nodump_lib():
        raise SendProblem('safe Send backend is unavailable; no Send created')
    return binaries, backend


def authorize_backend(E, backend):
    # Existing pinentry/session authorization, with fixed error presentation.
    original = backend.pin_ask
    def fixed_prompt(desc, *args, **kwargs):
        if args and args[0] or kwargs.get('error'):
            kwargs.pop('error', None)
            return original(desc, error='Vault authorization failed; try again')
        return original(desc)
    backend.pin_ask = fixed_prompt
    try:
        E.bw_open()
    except BaseException:
        raise SendProblem('vault authorization failed; no Send created') from None
    finally:
        backend.pin_ask = original


def key_for(context, C):
    relative, _, _ = context['source']
    return hashlib.sha256(json.dumps([C.E.binding_key(context['cfg'].root), context['env'], relative]).encode()).hexdigest()


@contextlib.contextmanager
def transaction_lock(C, key):
    directory = C.private_dir(C.state_path('send'))
    path = directory / (key + '.lock')
    with C.D.parent_fd(path) as (parent, name):
        fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=parent)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_nlink != 1 or st.st_mode & 0o077:
            raise SendProblem('unsafe Send transaction state; no Send created')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    except BlockingIOError:
        raise SendProblem('another Send request is active for this source') from None
    finally:
        os.close(fd)


def read_transaction(C, key):
    record = C.read_state('send/' + key + '.json')
    if not record:
        return {}
    fields = {'version', 'request', 'created', 'deletion', 'type', 'source', 'source_ident', 'mapping',
              'origin', 'status', 'id', 'env'}
    if set(record) - fields or record.get('version') != 1 or not REQUEST.fullmatch(record.get('request', '')):
        raise SendProblem('invalid Send transaction state; inspect existing Sends before retrying')
    if record.get('type') not in (0, 1) or record.get('status') not in ('pending', 'created', 'copy-failed', 'policy-failed', 'delivered'):
        raise SendProblem('invalid Send transaction state; inspect existing Sends before retrying')
    if record.get('id') is not None and not UUID.fullmatch(record['id']):
        raise SendProblem('invalid Send transaction identity')
    if utc(record['deletion']) - utc(record['created']) != timedelta(days=1):
        raise SendProblem('invalid Send transaction policy')
    origin(record['origin'])
    return record


def save(C, key, record):
    C.write_state('send/' + key + '.json', record)


def validate_result(result, record, require_window=False):
    if not isinstance(result, dict) or not UUID.fullmatch(result.get('id', '')):
        raise SendProblem('Send identity could not be verified; no link copied')
    if record.get('id') and result['id'] != record['id']:
        raise SendProblem('Send identity could not be verified; no link copied')
    if (result.get('name') != record['request'] or type(result.get('type')) is not int or result['type'] != record['type']
            or type(result.get('maxAccessCount')) is not int or result['maxAccessCount'] != 1
            or result.get('disabled') is not False or result.get('expirationDate', 'missing') is not None
            or utc(result.get('deletionDate')) != utc(record['deletion'])):
        raise SendProblem('Send policy could not be verified; no link copied')
    if result.get('passwordSet') not in (None, False) or result.get('emails') not in (None, []):
        raise SendProblem('Send policy could not be verified; no link copied')
    if record['type'] == 0 and (not isinstance(result.get('text'), dict) or result['text'].get('hidden') is not True):
        raise SendProblem('Send policy could not be verified; no link copied')
    if record['type'] == 1 and (not isinstance(result.get('file'), dict) or result['file'].get('fileName') != 'environment.env'):
        raise SendProblem('Send policy could not be verified; no link copied')
    if require_window:
        revised = utc(result.get('creationDate') or result.get('revisionDate'))
        created = utc(record['created'])
        if not created - timedelta(seconds=60) <= revised <= created + timedelta(minutes=5):
            raise SendProblem('Send request provenance could not be verified; inspect existing Sends')
    link = result.get('accessUrl')
    if origin(link, True) != record['origin']:
        raise SendProblem('Send link could not be verified; no link copied')
    return link


def verified_result(backend, result, record):
    if not isinstance(result, dict) or not UUID.fullmatch(result.get('id', '')):
        raise SendProblem(UNKNOWN)
    record['id'] = result['id']
    # A full object is requested, but missing echoes may be verified with an
    # authenticated exact-ID management read. Policy mismatches never pass.
    required = ('name', 'type', 'maxAccessCount', 'disabled', 'deletionDate', 'expirationDate', 'accessUrl')
    if any(field not in result for field in required):
        result = backend.get_send_result(record['id'])
    return validate_result(result, record)


def copy_result(C, key, record, link, backend, binaries):
    try:
        backend.copy_sensitive_send_link(link, binaries['wl-copy'], binaries['wl-paste'],
                                         clear_after=0.3 if C.E.test_mode() else 30)
    except BaseException:
        record['status'] = 'copy-failed'
        save(C, key, record)
        raise SendProblem(f"Send {record['id']} was created but clipboard copy failed; run envs send --recover {record['id']}") from None
    record['status'] = 'delivered'
    save(C, key, record)
    count = '1 download' if record['type'] else '1 access'
    C.E.say(f'Send created; link copied ({count}, deletes in 1 day)')


def recover(args, C, backend, binaries):
    requested = getattr(args, 'recover', True)
    requested = None if requested is True else requested
    if requested is not None and not UUID.fullmatch(requested):
        raise SendProblem('invalid recovery Send ID')
    directory = C.private_dir(C.state_path('send'))
    candidates = []
    unidentified = []
    supplied_result = None
    for name in os.listdir(directory):
        if re.fullmatch(r'[0-9a-f]{64}\.json', name):
            key = name[:-5]
            record = read_transaction(C, key)
            if record and not record.get('id') and record['status'] != 'delivered':
                unidentified.append((key, record))
            if record and (requested and record.get('id') == requested or not requested and record['status'] != 'delivered'):
                candidates.append((key, record))
    if requested and not candidates and unidentified:
        authorize_backend(C.E, backend)
        supplied_result = backend.get_send_result(requested)
        candidates = [(key, record) for key, record in unidentified if supplied_result.get('name') == record['request']]
    if not candidates:
        raise SendProblem('no matching recorded request; inspect existing Sends in the vault')
    if len(candidates) != 1:
        raise SendProblem('multiple pending requests; inspect existing Sends and recover an exact recorded ID')
    key, selected = candidates[0]
    with transaction_lock(C, key):
        record = read_transaction(C, key)
        if (record != selected or (requested and record.get('id') not in (None, requested))
                or (not requested and record.get('status') == 'delivered')):
            raise SendProblem('Send transaction changed; inspect existing requests and retry recovery')
        authorize_backend(C.E, backend)
        if origin(backend.send_server_origin()) != record['origin']:
            raise SendProblem('Send server identity changed; no link copied')
        if record.get('id'):
            result = backend.get_send_result(record['id'])
        elif supplied_result is not None:
            result = supplied_result
            validate_result(result, record, require_window=True)
        else:
            matches = backend.find_send_results(record['request'])
            if len(matches) != 1:
                raise SendProblem('request lookup is unresolved; inspect existing Sends before trying again')
            result = matches[0]
            validate_result(result, record, require_window=True)
            result = backend.get_send_result(result['id'])
        link = validate_result(result, record, require_window=not record.get('id'))
        record['id'] = result['id']
        record['status'] = 'created'
        save(C, key, record)
        copy_result(C, key, record, link, backend, binaries)


def record_type(args):
    return int(bool(getattr(args, 'file_send', False)))


def create(args, C, R, backend, binaries):
    context = C.prepare_export(args, require_source=True)
    relative, snapshot, document = context['source']
    key = key_for(context, C)
    with transaction_lock(C, key):
        previous = read_transaction(C, key)
        if previous and previous['status'] != 'delivered':
            raise SendProblem(UNKNOWN)
        plain = [r.name for r in document.records if r.name not in context['specs']['names']]
        count = '1 download' if getattr(args, 'file_send', False) else '1 access'
        C.E.say('Source: ' + label(relative) + '; environment: ' + label(context['env']))
        C.E.say('Plain names: ' + ', '.join(plain))
        C.E.say('Secret names: ' + ', '.join(context['wanted']) + f" ({len(context['wanted'])}); {count}; delete after 1 day")
        if not C.E.confirm(('Create a one-download Send' if record_type(args) else 'Create a one-access Send') + ' of this rendered env and copy its link?'):
            C.E.say('Cancelled; no Send created')
            return
        authorize_backend(C.E, backend)
        expected_origin = origin(backend.send_server_origin())
        values = C.resolve_export(context)
        text = R.render_document(document, values, context['specs']['names'], omit_unselected=True, dialect='envs')
        maximum = FILE_LIMIT if getattr(args, 'file_send', False) else TEXT_LIMIT
        if len(text.encode('utf-8')) > maximum:
            raise SendProblem('rendered env is too large for text Send; no Send created' if maximum == TEXT_LIMIT
                              else 'rendered env exceeds the file Send limit; no Send created')
        def verify_source():
            snapshot.verify()
            fresh = C.prepare_export(args, require_source=True)
            if (fresh['source'][1].ident != snapshot.ident or fresh['wanted'] != context['wanted']
                    or C.mapping_digest(fresh['cfg'], fresh['env'], fresh['specs']) != C.mapping_digest(context['cfg'], context['env'], context['specs'])):
                raise SendProblem('source or mapping changed; no Send created')
        verify_source()
        now = datetime.now(timezone.utc)
        created = stamp(now)
        deletion = stamp(utc(created) + timedelta(days=1))
        record = {'version': 1, 'request': 'envs-' + secrets.token_hex(16), 'created': created, 'deletion': deletion,
                  'type': int(bool(getattr(args, 'file_send', False))), 'source': relative, 'source_ident': list(snapshot.ident),
                  'mapping': C.mapping_digest(context['cfg'], context['env'], context['specs']), 'origin': expected_origin,
                  'status': 'pending', 'env': context['env']}
        payload = {'name': record['request'], 'notes': None, 'type': record['type'], 'text': None,
                   'file': None, 'maxAccessCount': 1, 'deletionDate': deletion, 'expirationDate': None,
                   'disabled': False, 'password': None, 'emails': None, 'hideEmail': False}
        if record['type']:
            payload['file'] = {'fileName': 'environment.env'}
            artifact = C.private_envfile(text)
        else:
            payload['text'] = {'text': text, 'hidden': True}
            artifact = contextlib.nullcontext(None)
        with artifact as path:
            # No payload/link/value digest in this marker. Creation can have an
            # unknown remote outcome, so write it durably before ONE dispatch.
            save(C, key, record)
            try:
                # Artifact creation and durable state writes may take time. Recheck
                # immediately before dispatch; no backend attempt has happened yet.
                verify_source()
            except BaseException:
                save(C, key, previous)
                raise
            try:
                result = backend.create_send_result(payload, *(['--file', str(path)] if path else []))
            except BaseException:
                raise SendProblem(UNKNOWN) from None
        try:
            link = verified_result(backend, result, record)
        except BaseException:
            record['status'] = 'policy-failed'
            save(C, key, record)
            raise SendProblem('Send response or policy could not be verified; recover the existing request before trying again') from None
        record['status'] = 'created'
        save(C, key, record)
        copy_result(C, key, record, link, backend, binaries)


def run(args, C, R):
    E = C.E
    # Every form, including recovery, refuses before reading source/vault/state.
    if E.managed_user():
        E.fail("Send creation is available only in the owner's session; managed users use a read-only vault broker", 4)
    if E.agent_context():
        E.fail('agents cannot create or recover Sends; use an owner terminal', 4)
    if not E.tty():
        E.fail('Send requires an owner terminal and sensitive Wayland clipboard', 4)
    previous = {}
    def interrupted(sig, frame):
        raise Interrupted()
    try:
        protect_process()
        binaries, backend = preflight(E)
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous[sig] = signal.signal(sig, interrupted)
        if getattr(args, 'recover', False):
            return recover(args, C, backend, binaries)
        return create(args, C, R, backend, binaries)
    except SendProblem as error:
        E.fail(str(error), 1)
    except C.D.Problem:
        E.fail('approved env source or policy is unsafe or unavailable; no Send created', 4)
    except (Interrupted, KeyboardInterrupt, EOFError):
        E.fail('Send interrupted; recover any pending request before trying again', 130)
    except (Exception, SystemExit):
        # No raw resolver/backend/clipboard exception repr or output.
        E.fail('Send operation could not be completed; recover any pending request before trying again', 1)
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
