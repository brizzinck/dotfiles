"""Bounded binary output masking and private tmpfs files for the envs supervisor."""
import base64
import contextlib
import ctypes
import errno
import json
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import subprocess
import time
import urllib.parse

MAX_PATTERN_BYTES = 4 * 1024 * 1024
MAX_PATTERN = 65536
MAX_PATTERNS = 4096
MAX_RENDERED = 4 * 1024 * 1024


class RuntimeProblem(Exception):
    pass


def secret_patterns(values):
    patterns = {}
    for name, value in values.items():
        if not isinstance(value, str) or len(value) < 6 or "\x00" in value:
            raise RuntimeProblem("secret cannot be masked")
        raw = value.encode("utf-8")
        forms = {raw, raw.hex().encode(), raw.hex().upper().encode()}
        for encoded in (base64.b64encode(raw), base64.urlsafe_b64encode(raw)):
            forms.update((encoded, encoded.rstrip(b"=")))
        for encode in (lambda x: urllib.parse.quote(x, safe=""), urllib.parse.quote,
                       lambda x: urllib.parse.quote_plus(x, safe="")):
            escaped = encode(value).encode()
            forms.add(escaped)
            forms.add(re.sub(rb"%[0-9A-Fa-f]{2}", lambda m: m[0].lower(), escaped))
        for form in forms:
            if len(form) > MAX_PATTERN:
                raise RuntimeProblem("secret masking input exceeds supported limits")
            patterns.setdefault(form, set()).add(name)
    if len(patterns) > MAX_PATTERNS or sum(len(p) for p in patterns) > MAX_PATTERN_BYTES:
        raise RuntimeProblem("secret masking input exceeds supported limits")
    return {pattern: ("[secret " + ",".join(sorted(names)) + "]").encode() for pattern, names in patterns.items()}


class StreamingMasker:
    def __init__(self, patterns):
        self.keep = max((len(p) for p in patterns), default=1) - 1
        self.by_first = {}
        for pattern, label in sorted(patterns.items(), key=lambda pair: (-len(pair[0]), pair[0])):
            self.by_first.setdefault(pattern[0], []).append((pattern, label))
        self.pending = b""
        self.covered = []
        self.masked_active = False

    def feed(self, data, final=False):
        # Retain raw bytes only where a future match may start. Known coverage crosses
        # chunk boundaries as bounded intervals, never as an ever-growing overlap union.
        buf = self.pending + data
        intervals = list(self.covered)
        limit = len(buf)
        for i, byte in enumerate(buf):
            remaining = len(buf) - i
            for pattern, label in self.by_first.get(byte, ()):
                if not final and remaining < len(pattern) and pattern.startswith(buf[i:]):
                    limit = min(limit, i)
                elif buf.startswith(pattern, i):
                    intervals.append((i, i + len(pattern), label))
        merged = []
        for start, end, label in sorted(intervals, key=lambda value: (value[0], -value[1])):
            if merged and start <= merged[-1][1]:
                old_start, old_end, old_label = merged[-1]
                merged[-1] = (old_start, max(old_end, end), old_label)
            else:
                merged.append((start, end, label))
        out, cursor, active = [], 0, self.masked_active
        for start, end, label in merged:
            if start >= limit:
                break
            if start > cursor:
                out.append(buf[cursor:start]); active = False
            if not active:
                out.append(label)
            cursor = min(end, limit)
            active = end >= limit
            if cursor == limit:
                break
        if cursor < limit:
            out.append(buf[cursor:limit]); active = False
        self.masked_active = active if limit else self.masked_active
        self.pending = buf[limit:]
        self.covered = [(max(start, limit) - limit, end - limit, label)
                        for start, end, label in merged if end > limit]
        assert len(self.pending) <= self.keep or final
        return b"".join(out)


def dotenv_literal(value):
    """Strict double-quoted dotenv encoding; never shell-source this generated consumer file."""
    if not isinstance(value, str) or "\x00" in value or "\r" in value:
        raise RuntimeProblem("value cannot be represented by the supported dotenv serializer")
    # Dollar escapes are not uniformly honored by dotenv expansion libraries. Refuse instead of inventing portability.
    if "$" in value:
        raise RuntimeProblem("dollar-bearing values require a verified consumer-specific serializer")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t") + '"'


def render_document(doc, values, names, omit_unselected=False):
    refs = doc.references()
    replacements = {name: dotenv_literal(value) for name, value in values.items()}
    omitted = set(refs) - set(values) if omit_unselected else set()
    # A legacy name cannot silently overwrite an ordinary literal in this source.
    for record in doc.records:
        if record.name in names and record.name not in refs:
            raise RuntimeProblem("literal assignment conflicts with a declared secret")
    text = doc.rewrite(replacements, omitted)
    if len(text.encode("utf-8")) > MAX_RENDERED:
        raise RuntimeProblem("rendered env exceeds supported limits")
    return text


def _tmpfs(fd):
    # Linux fstatfs: only f_type is needed. Reserve a whole struct-sized buffer for libc.
    libc = ctypes.CDLL(None, use_errno=True)
    data = ctypes.create_string_buffer(256)
    if libc.fstatfs(fd, ctypes.byref(data)) != 0:
        return False
    return ctypes.c_long.from_buffer(data).value == 0x01021994


@contextlib.contextmanager
def _directory(path, create=False):
    path = Path(path)
    current = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in path.parts[1:]:
            try:
                child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=current)
            except FileNotFoundError:
                if not create:
                    raise
                os.mkdir(component, 0o700, dir_fd=current)
                child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=current)
            os.close(current); current = child
        st = os.fstat(current)
        if st.st_uid != os.getuid() or st.st_mode & 0o077 or not _tmpfs(current):
            raise RuntimeProblem("private tmpfs runtime is unavailable")
        yield current
    finally:
        os.close(current)


def runtime_base():
    # Never trust a project-provided runtime path. Tests use the same inert /dev/shm fallback.
    canonical = Path(f"/run/user/{os.getuid()}")
    try:
        with _directory(canonical):
            return canonical / "envs"
    except (OSError, RuntimeProblem):
        return Path(f"/dev/shm/envs-run-{os.getuid()}")


def _start_time(pid):
    try:
        return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]
    except (OSError, IndexError):
        return None


def _cleanup_run(basefd, name, require_dead=True):
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=basefd)
    try:
        st = os.fstat(fd)
        if st.st_uid != os.getuid() or st.st_mode & 0o077:
            raise RuntimeProblem("unsafe stale runtime directory")
        children = os.listdir(fd)
        if set(children) - {"owner.json", "environment.env"}:
            raise RuntimeProblem("unknown stale runtime contents")
        markerfd = os.open("owner.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        with os.fdopen(markerfd, "rb") as marker:
            mst = os.fstat(marker.fileno())
            if not stat.S_ISREG(mst.st_mode) or mst.st_uid != os.getuid() or mst.st_nlink != 1 or mst.st_mode & 0o077:
                raise RuntimeProblem("unsafe runtime marker")
            metadata = json.loads(marker.read(1024))
        pid, started = metadata.get("pid"), metadata.get("start")
        if not isinstance(pid, int) or pid <= 0 or not isinstance(started, str) or not started.isdigit():
            raise RuntimeProblem("unsafe runtime marker identity")
        if require_dead:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                pass  # Positive absence, rather than an unreadable /proc record.
            except PermissionError:
                return
            else:
                current = _start_time(pid)
                if current is None or current == started:
                    return
        for child in children:
            cst = os.stat(child, dir_fd=fd, follow_symlinks=False)
            if not stat.S_ISREG(cst.st_mode) or cst.st_uid != os.getuid() or cst.st_nlink != 1 or cst.st_mode & 0o077:
                raise RuntimeProblem("unsafe stale runtime file")
        for child in children:
            os.unlink(child, dir_fd=fd)
    finally:
        os.close(fd)
    os.rmdir(name, dir_fd=basefd)


@contextlib.contextmanager
def private_envfile(text, base=None):
    data = text.encode("utf-8")
    if len(data) > MAX_RENDERED:
        raise RuntimeProblem("rendered env exceeds supported limits")
    base = Path(base) if base is not None else runtime_base()
    with _directory(base, create=True) as basefd:
        for stale in os.listdir(basefd):
            if re.fullmatch(r"run-[0-9]+-[0-9a-f]{24}", stale):
                with contextlib.suppress(OSError, ValueError, KeyError, RuntimeProblem):
                    _cleanup_run(basefd, stale)
        started = _start_time(os.getpid())
        if started is None:
            raise RuntimeProblem("runtime process identity is unavailable")
        name = f"run-{os.getpid()}-" + os.urandom(12).hex()
        os.mkdir(name, 0o700, dir_fd=basefd)
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=basefd)
        try:
            for file, payload in (("owner.json", json.dumps({"pid": os.getpid(), "start": started}).encode()),
                                  ("environment.env", data)):
                target = os.open(file, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
                with os.fdopen(target, "wb") as f:
                    f.write(payload); f.flush(); os.fsync(f.fileno())
            yield base / name / "environment.env"
        finally:
            os.close(fd)
            _cleanup_run(basefd, name, require_dead=False)


def supervise_run(argv, env, values=None, agent=False, on_error=None):
    patterns = secret_patterns(values or {}) if agent else None
    proc = None
    previous, signaled, deadline = {}, [], [None]
    output_flags = {}
    foreground = None

    def send(sig):
        if proc is not None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(proc.pid, sig)

    def relay(sig, frame):
        signaled.append(sig); deadline[0] = time.monotonic() + 2
        send(sig)

    def set_foreground(group):
        old = signal.signal(signal.SIGTTOU, signal.SIG_IGN)
        try:
            os.tcsetpgrp(0, group)
        finally:
            signal.signal(signal.SIGTTOU, old)

    try:
        if not agent and os.isatty(0) and os.tcgetpgrp(0) == os.getpgrp():
            foreground = os.tcgetpgrp(0)
        proc = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL if agent else None,
                                stdout=subprocess.PIPE if agent else None, stderr=subprocess.PIPE if agent else None,
                                close_fds=True, start_new_session=agent, process_group=None if agent else 0)
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous[sig] = signal.signal(sig, relay)
        if foreground is not None:
            set_foreground(proc.pid)
            send(signal.SIGCONT)  # A child that raced the handoff may already have SIGTTIN.
        if agent:
            import select
            poller = select.poll()
            streams, queues = {}, {1: bytearray(), 2: bytearray()}
            for pipe, output in ((proc.stdout, 1), (proc.stderr, 2)):
                os.set_blocking(pipe.fileno(), False)
                streams[pipe.fileno()] = (pipe, output, StreamingMasker(patterns))
            for output in queues:
                output_flags[output] = os.get_blocking(output)
                os.set_blocking(output, False)
            exited, last_read = None, {}
            while streams or any(queues.values()):
                now = time.monotonic()
                if proc.poll() is not None and exited is None:
                    exited = now
                if deadline[0] is not None and now >= deadline[0]:
                    send(signal.SIGKILL)
                    queues = {1: bytearray(), 2: bytearray()}
                    break
                if exited is not None and now - exited > 1 and streams:
                    send(signal.SIGKILL)
                    # A slow reader can leave ordinary child bytes in the pipes.
                    # Terminate descendants, then drain before considering an escaped,
                    # idle pipe holder. Backpressured queues never trigger truncation.
                    for fd, (pipe, output, masker) in list(streams.items()):
                        probe = select.poll(); probe.register(fd, select.POLLIN)
                        if (now - max(exited, last_read.get(fd, exited)) > 2
                                and len(queues[output]) < 262144 and not probe.poll(0)):
                            queues[output].extend(masker.feed(b"", final=True))
                            pipe.close(); del streams[fd]
                poller = select.poll()
                for fd, (_, output, _) in streams.items():
                    if len(queues[output]) < 262144:
                        poller.register(fd, select.POLLIN)
                for output, queue in queues.items():
                    if queue:
                        poller.register(output, select.POLLOUT)
                for fd, event in poller.poll(50):
                    if fd in streams:
                        pipe, output, masker = streams[fd]
                        try:
                            block = os.read(fd, 8192)
                        except BlockingIOError:
                            continue
                        if block:
                            last_read[fd] = time.monotonic()
                        queues[output].extend(masker.feed(block, final=not block))
                        if len(queues[output]) > 1048576:
                            raise RuntimeProblem("masked output exceeds bounded queue")
                        if not block:
                            pipe.close(); del streams[fd]
                    elif fd in queues and queues[fd]:
                        try:
                            written = os.write(fd, queues[fd])
                            del queues[fd][:written]
                        except BlockingIOError:
                            pass
        while proc.poll() is None:
            if deadline[0] is not None and time.monotonic() >= deadline[0]:
                send(signal.SIGKILL); deadline[0] = None
            time.sleep(0.02)
        code = proc.wait()
        send(signal.SIGTERM); send(signal.SIGKILL)
        return 128 + signaled[-1] if signaled else (128 - code if code < 0 else code)
    except BrokenPipeError:
        send(signal.SIGKILL)
        if proc:
            proc.wait()
        return 128 + signal.SIGPIPE
    except Exception:
        send(signal.SIGKILL)
        if proc:
            proc.wait()
        if on_error:
            on_error("output masking failed; command stopped")
        return 127 if proc is None else 1
    finally:
        if foreground is not None:
            with contextlib.suppress(OSError):
                set_foreground(foreground)
        for output, blocking in output_flags.items():
            os.set_blocking(output, blocking)
        for sig, handler in previous.items():
            signal.signal(sig, handler)
        if proc is not None:
            for pipe in (proc.stdout, proc.stderr):
                if pipe:
                    pipe.close()
