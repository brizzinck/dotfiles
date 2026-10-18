"""Literal dotenv documents, exact vault references and local authorization for envs.

This module never executes a document. Callers print names and fixed errors only;
the original text and values stay inside the runner/import transaction.
"""
import contextlib
import hashlib
import json
import os
import re
import stat
import tempfile
import unicodedata
import urllib.parse
from dataclasses import dataclass
from pathlib import Path

MAX_DOCUMENT = 4 * 1024 * 1024
NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
UNRESERVED = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
BUILTINS = frozenset(("password", "username", "notes", "uris"))


class Problem(Exception):
    """Only fixed reason codes and line numbers, never excerpts from a value."""
    def __init__(self, reason, line=0):
        super().__init__(reason)
        self.reason, self.line = reason, line


@dataclass(frozen=True)
class Ref:
    folder: str
    item: str
    kind: str
    field: str
    canonical: str

    @property
    def selector(self):
        return "field:" + self.field if self.kind == "field" else self.field


def _decode_segment(value, slash=False):
    if not value:
        raise Problem("empty reference segment")
    i = 0
    while i < len(value):
        c = value[i]
        if c == "%":
            if i + 2 >= len(value) or not re.fullmatch(r"[0-9a-fA-F]{2}", value[i + 1:i + 3]):
                raise Problem("invalid reference escape")
            i += 3
        elif c in UNRESERVED:
            i += 1
        else:
            raise Problem("reserved reference character must be encoded")
    try:
        text = unicodedata.normalize("NFC", urllib.parse.unquote_to_bytes(value).decode("utf-8", "strict"))
    except (UnicodeError, ValueError):
        raise Problem("invalid reference encoding") from None
    if text in (".", "..") or any(ord(c) < 32 or 0x7f <= ord(c) <= 0x9f or unicodedata.category(c) in ("Cf", "Cs") for c in text):
        raise Problem("unsafe reference segment")
    if "\\" in text or ("/" in text and not slash):
        raise Problem("unsupported reference slash")
    return text


def _encode(text):
    return urllib.parse.quote(unicodedata.normalize("NFC", text), safe="-._~", encoding="utf-8", errors="strict")


def format_bw_ref(folder, item, field, kind="field"):
    path = "/".join(_encode(x) for x in folder.split("/")) if folder else "@root"
    selector = (field if NAME.fullmatch(field) else "field:" + _encode(field)) if kind == "field" else "@" + field
    return "bw://" + path + "/" + _encode(item) + "#" + selector


def parse_bw_ref(value):
    if not isinstance(value, str) or not value.startswith("bw://") or value.count("#") != 1:
        raise Problem("invalid reference grammar")
    path, selector = value[5:].split("#")
    segments = path.split("/")
    if len(segments) < 2:
        raise Problem("reference needs folder and item")
    root = segments[0] == "@root"
    if root and len(segments) != 2:
        raise Problem("invalid root reference")
    folder = "" if root else "/".join(_decode_segment(s) for s in segments[:-1])
    # v1 deliberately refuses slash-bearing item names: neither backend has a distinct item-segment API.
    item = _decode_segment(segments[-1])
    if selector.startswith("field:"):
        kind, field = "field", _decode_segment(selector[6:])
    elif selector.startswith("@"):
        kind, field = "builtin", selector[1:]
        if field not in BUILTINS:
            raise Problem("unsupported builtin reference")
    elif NAME.fullmatch(selector):
        kind, field = "field", selector
    else:
        raise Problem("invalid reference selector")
    canonical = format_bw_ref(folder, item, field, kind)
    if len(canonical.encode()) > 2048 or len(folder) > 512 or len(item) > 512 or len(field) > 100:
        raise Problem("reference exceeds supported limits")
    return Ref(folder, item, kind, field, canonical)


@dataclass(frozen=True)
class Record:
    name: str
    value: str
    start: int
    end: int
    line: int


class DotenvDocument:
    def __init__(self, text, shell=False):
        self.shell = shell
        if not isinstance(text, str) or "\x00" in text:
            raise Problem("unsupported literal syntax", 1)
        if shell and "\r" in text:
            raise Problem("carriage return is unsupported in shell source", text[:text.index("\r")].count("\n") + 1)
        self.text = text
        self.records = []
        self.newline = "\r\n" if "\r\n" in text else "\n"
        self._parse()

    def _parse(self):
        text, pos, line = self.text, 0, 1
        while pos < len(text):
            start, first_line = pos, line
            end = text.find("\n", pos)
            end = len(text) if end < 0 else end + 1
            raw = text[pos:end]
            if not raw.strip() or raw.lstrip().startswith("#"):
                line += raw.count("\n"); pos = end
                continue
            pattern = r"[ \t]*(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)=" if self.shell else r"[ \t]*(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*"
            match = re.match(pattern, raw)
            if not match:
                raise Problem("unsupported literal syntax", line)
            name = match.group(1)
            i = pos + match.end()
            if self.shell and i < end and text[i] in " \t":
                rest = text[i:end].strip()
                if rest and not rest.startswith("#"):
                    raise Problem("unsupported shell syntax", first_line)
            value = []
            if i < len(text) and text[i] in ("'", '"'):
                quote = text[i]; i += 1
                closed = False
                while i < len(text):
                    c = text[i]
                    if c == quote:
                        i += 1; closed = True
                        break
                    if c == "\\" and quote == '"':
                        i += 1
                        if i >= len(text):
                            break
                        c = text[i]
                        if c not in ('"', "\\", "n", "r", "t", "$", "`", "\n", "\r"):
                            raise Problem("unsupported literal escape", first_line)
                        if self.shell:
                            if c in ('"', "\\", "$", "`"):
                                value.append(c)
                            elif c == "\n":
                                pass       # POSIX shell line continuation
                            else:
                                value.append("\\" + c)
                        else:
                            value.append({"n": "\n", "r": "\r", "t": "\t"}.get(c, c))
                    elif quote == '"' and c in ("$", "`"):
                        raise Problem("unsupported shell syntax", first_line)
                    else:
                        value.append(c)
                    i += 1
                if not closed:
                    raise Problem("unterminated literal", first_line)
                tail_end = text.find("\n", i)
                end = len(text) if tail_end < 0 else tail_end + 1
                raw_tail = text[i:end]
                tail = raw_tail.strip()
                if tail and (not tail.startswith("#") or (self.shell and raw_tail[:1] not in (" ", "\t"))):
                    raise Problem("unsupported shell syntax", first_line)
                literal = "".join(value)
            else:
                body = text[i:end].rstrip("\r\n")
                body = re.split(r"[ \t]+#", body, maxsplit=1)[0].rstrip(" \t")
                if any(c in body for c in ("$", "`", ";", "|", "&", "<", ">", "\\", "'", '"', "(", ")")) or (self.shell and (re.search(r"[ \t]", body) or "~" in body)):
                    raise Problem("unsupported shell syntax", first_line)
                literal = body
            self.records.append(Record(name, literal, start, end, first_line))
            line += text[start:end].count("\n"); pos = end

    def values(self):
        return {r.name: r.value for r in self.records}

    def references(self):
        refs, counts = {}, {}
        for r in self.records:
            counts[r.name] = counts.get(r.name, 0) + 1
            if r.value.startswith("bw://"):
                try:
                    refs[r.name] = parse_bw_ref(r.value)
                except Problem as p:
                    raise Problem(p.reason, r.line) from None
        for name in refs:
            if counts[name] != 1:
                raise Problem("duplicate reference assignment", next(r.line for r in self.records if r.name == name))
        return refs

    def rewrite(self, replacements, drop=()):
        """Rewrite every assignment span for selected names; preserve unrelated bytes and final-newline convention."""
        seen, out, pos = set(), [], 0
        for r in self.records:
            out.append(self.text[pos:r.start])
            if r.name in drop:
                pass
            elif r.name in replacements:
                if r.name not in seen:
                    suffix = self.newline if self.text[r.start:r.end].endswith("\n") else ""
                    out.append(r.name + "=" + replacements[r.name] + suffix)
                    seen.add(r.name)
            else:
                out.append(self.text[r.start:r.end])
            pos = r.end
        out.append(self.text[pos:])
        result = "".join(out)
        for name, value in replacements.items():
            if name not in seen:
                if result and not result.endswith("\n"):
                    result += self.newline
                result += name + "=" + value + self.newline
        if self.text and not self.text.endswith("\n") and result.endswith(self.newline):
            result = result[:-len(self.newline)]
        return result


def _identity(st):
    return st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns


@contextlib.contextmanager
def parent_fd(path):
    """Walk lexical absolute components with O_NOFOLLOW; never resolve a possibly hostile symlink first."""
    path = Path(os.path.abspath(path))
    if any(x in (".", "..") for x in path.parts[1:]):
        raise Problem("unsafe source path")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in path.parts[1:-1]:
            new = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd); fd = new
        yield fd, path.name
    finally:
        os.close(fd)


@dataclass
class Snapshot:
    path: Path
    text: str
    ident: tuple

    def verify(self):
        try:
            with parent_fd(self.path) as (fd, name):
                st = os.stat(name, dir_fd=fd, follow_symlinks=False)
            if _identity(st) != self.ident or not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
                raise Problem("source changed; retry")
        except OSError:
            raise Problem("source changed; retry") from None

    def replace(self, text, recovery_dir=None):
        """Linux atomic exchange, with displaced-version validation and conditional rollback.

        POSIX replace has no compare-and-swap precondition. Exchange lets us inspect
        the displaced inode/content and restore an ordinary concurrent editor's version.
        A malicious same-uid writer can still race every conditional check; ambiguous
        displaced versions are retained in a private recovery directory, never discarded.
        """
        if recovery_dir is None:
            raise Problem("verified private recovery directory is required")
        with parent_fd(Path(recovery_dir) / "placeholder") as (recovery_fd, _):
            recovery_st = os.fstat(recovery_fd)
            if recovery_st.st_uid != os.getuid() or recovery_st.st_mode & 0o077:
                raise Problem("unsafe recovery directory")
        data = text.encode("utf-8")
        if len(data) > MAX_DOCUMENT:
            raise Problem("document exceeds supported limit")
        self.verify()
        with parent_fd(self.path) as (fd, name):
            parent_ident = (os.fstat(fd).st_dev, os.fstat(fd).st_ino)
            temp = ".envs-" + os.urandom(12).hex()
            newfd = os.open(temp, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
            created = None
            exchanged = False
            try:
                with os.fdopen(newfd, "wb") as f:
                    f.write(data); f.flush(); os.fsync(f.fileno())
                    created = (os.fstat(f.fileno()).st_dev, os.fstat(f.fileno()).st_ino)
                self.verify()
                _exchange(fd, temp, name)
                exchanged = True
                # A rename changes ctime. Check the displaced inode/mtime plus exact
                # in-memory bytes, rather than pretending pre-rename ctime can match.
                oldfd = os.open(temp, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
                with os.fdopen(oldfd, "rb") as f:
                    before = os.fstat(f.fileno())
                    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or _identity(before)[:4] != self.ident[:4]:
                        raise Problem("source changed; retry")
                    old = f.read(MAX_DOCUMENT + 1)
                    if _identity(os.fstat(f.fileno())) != _identity(before) or old != self.text.encode("utf-8"):
                        raise Problem("source changed; retry")
                with parent_fd(self.path) as (current, _):
                    if (os.fstat(current).st_dev, os.fstat(current).st_ino) != parent_ident:
                        raise Problem("source parent changed; retry")
                    now = os.stat(name, dir_fd=current, follow_symlinks=False)
                    if (now.st_dev, now.st_ino) != created or not _payload_matches(current, name, created, data):
                        raise Problem("source changed; retry")
                os.unlink(temp, dir_fd=fd)
                exchanged = False
                os.fsync(fd)
            except BaseException:
                if exchanged:
                    try:
                        current = os.stat(name, dir_fd=fd, follow_symlinks=False)
                        if (current.st_dev, current.st_ino) != created or not _payload_matches(fd, name, created, data):
                            raise Problem("source changed during rollback")
                        _exchange(fd, temp, name)
                        # The temporary slot should now hold only our new version.
                        current = os.stat(temp, dir_fd=fd, follow_symlinks=False)
                        if (current.st_dev, current.st_ino) != created or not _payload_matches(fd, temp, created, data):
                            raise Problem("source changed during rollback")
                        os.unlink(temp, dir_fd=fd)
                        exchanged = False
                    except (OSError, Problem):
                        _recover_displaced(fd, temp, recovery_dir)
                        exchanged = False
                raise
            finally:
                if not exchanged:
                    with contextlib.suppress(FileNotFoundError):
                        os.unlink(temp, dir_fd=fd)


def _payload_matches(fd, name, ident, expected):
    try:
        opened = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        with os.fdopen(opened, "rb") as f:
            before = os.fstat(f.fileno())
            if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or (before.st_dev, before.st_ino) != ident:
                return False
            raw = f.read(MAX_DOCUMENT + 1)
            return raw == expected and _identity(os.fstat(f.fileno())) == _identity(before)
    except OSError:
        return False


def _exchange(fd, source, target):
    import ctypes
    import errno
    libc = ctypes.CDLL(None, use_errno=True)
    rename = getattr(libc, "renameat2", None)
    if rename is None:
        raise Problem("atomic guarded replacement is unavailable")
    rename.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    rename.restype = ctypes.c_int
    if rename(fd, os.fsencode(source), fd, os.fsencode(target), 2) != 0:       # RENAME_EXCHANGE
        code = ctypes.get_errno()
        if code in (errno.ENOSYS, errno.EINVAL, errno.ENOTSUP):
            raise Problem("atomic guarded replacement is unavailable")
        raise OSError(code, "guarded replacement failed")


def _recover_displaced(source_fd, name, recovery_dir):
    """Bounded fd copy+fsync also works across filesystems. Never discard an unverified version."""
    import errno
    with parent_fd(Path(recovery_dir) / "placeholder") as (outer, _):
        st = os.fstat(outer)
        if st.st_uid != os.getuid() or st.st_mode & 0o077:
            raise Problem("unsafe recovery directory")
        child = ".envs-recovery-" + os.urandom(12).hex()
        os.mkdir(child, 0o700, dir_fd=outer)
        target = os.open(child, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=outer)
        source = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=source_fd)
        try:
            # Tighten the remaining source first: even a failed cross-filesystem recovery leaves it owner-only.
            original = os.fstat(source)
            if not stat.S_ISREG(original.st_mode) or original.st_uid != os.getuid() or original.st_nlink != 1:
                raise Problem("unsafe displaced source; recovery required")
            os.fchmod(source, 0o600)
            before = os.fstat(source)
            if before.st_size > MAX_DOCUMENT:
                raise Problem("displaced source exceeds supported recovery limit")
            dest = os.open("displaced.env", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=target)
            try:
                remaining = MAX_DOCUMENT + 1
                while remaining:
                    block = os.read(source, min(65536, remaining))
                    if not block:
                        break
                    remaining -= len(block)
                    view = memoryview(block)
                    while view:
                        view = view[os.write(dest, view):]
                if not remaining or _identity(os.fstat(source)) != _identity(before):
                    raise Problem("displaced source changed during recovery")
                os.fsync(dest)
            finally:
                os.close(dest)
            current = os.stat(name, dir_fd=source_fd, follow_symlinks=False)
            if _identity(current) != _identity(before):
                raise Problem("displaced source changed during recovery")
            os.fsync(target); os.fsync(outer)
            os.unlink(name, dir_fd=source_fd)
            os.fsync(source_fd)
        finally:
            os.close(source)
            os.close(target)


def read_document(path, root=None, private=False):
    path = Path(os.path.abspath(path))
    if root is not None:
        root = Path(os.path.abspath(root))
        try:
            rel = path.relative_to(root)
        except ValueError:
            raise Problem("source is outside approved root") from None
        if any(x in (".git", ".ssh", ".gnupg", ".claude", ".codex", ".gemini") for x in rel.parts):
            raise Problem("source is a credential location")
    try:
        with parent_fd(path) as (pfd, name):
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=pfd)
        with os.fdopen(fd, "rb") as f:
            st = os.fstat(f.fileno())
            if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_nlink != 1 or st.st_size > MAX_DOCUMENT:
                raise Problem("unsafe source ownership, type or size")
            if private and st.st_mode & 0o077:
                raise Problem("source permissions must be 0600")
            data = f.read(MAX_DOCUMENT + 1)
            if len(data) > MAX_DOCUMENT or _identity(os.fstat(f.fileno())) != _identity(st):
                raise Problem("source changed; retry")
        snapshot = Snapshot(path, data.decode("utf-8", "strict"), _identity(st))
        snapshot.verify()
        return snapshot
    except (OSError, UnicodeError):
        raise Problem("cannot safely read source") from None


def digest(data):
    return hashlib.sha256(json.dumps(data, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()).hexdigest()
