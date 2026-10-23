"""Local, upgrade-safe bulk export for the pinned upstream server: the MCP tool export_history.

One call exports the next slice of a read-allowlisted chat into EXPORT_ROOT/<chat id>/ and returns a short JSON status; the
caller (tg-archive, or an agent) repeats the call until "done" is true. Nothing is ever sent to Telegram: the tool only reads
history and downloads files, so its only side effect is files below EXPORT_ROOT (outside /home, see telegram-mcp.service).

  <chat id>/chat.json        title, kind, username, about (refreshed every call)
  <chat id>/messages.jsonl   one normalised message per line, appended in id order (tg-archive moves it away when it imports;
                             the next call starts a new file)
  <chat id>/media/<id>-<name>  downloaded files; a big document is fetched in 512 KiB requests into <name>.part and resumed
                             by the next call, so no single call outlives the gateway timeout
  <chat id>/state.json       last exported message id, media queue, done / skipped / failed media

Docs: CLAUDE.md "MCP gateway and agents (M1)" and "Telegram archive (tg-archive)".
"""
import asyncio
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import sys
import time
from typing import Optional, Union

EXPORT_ROOT = Path(os.environ.get('TELEGRAM_EXPORT_DIR', '/srv/telegram-export'))
MAX_SECONDS = 45            # upstream cancels every tool after 55 s (TELEGRAM_TOOL_TIMEOUT_SECONDS)
REQUEST = 512 * 1024        # Telegram: offset % limit == 0, limit divides 1 MiB; resumed .part files are cut to this
SAVE_EVERY = 200            # messages between state saves
PARALLEL = 8                # files downloaded at the same time
FETCH_AHEAD = 300           # queued messages looked up per call (enough for one call)
POOL_MIN = 8 * 1024 * 1024  # files at least this big are fetched over the connection pool
CONNECTIONS = 8             # extra MTProto connections per DC: one connection gives ~1.3 MB/s per file stream
POOL_REQUEST = 1024 * 1024  # the biggest upload.getFile Telegram serves: Telegram limits the RATE of getFile requests
                            # (FLOOD_WAIT_1 with 8 connections of 512 KiB requests), so bigger requests carry more
MIN_WORKERS = 2             # a pool worker that hits a flood wait retires while more than this many are left
_pools: dict = {}
_pool_lock = asyncio.Lock()
_no_pool: set = set()       # documents Telegram serves through a CDN: the single stream handles those
FLOOD_SLEEP = 15            # a pool request told to wait up to this long waits and retries; longer -> the single stream
MAX_ATTEMPTS = 8            # calls that end in a transient error for one file before it counts as failed
MIN_FREE = 2 * 1024 ** 3    # bytes left free on the export disk (/srv is on the root filesystem)
floods = {'n': 0, 'seconds': 0}
TRANSIENT = ('FloodWaitError', 'FloodPremiumWaitError', 'FloodTestPhoneWaitError', 'TimeoutError', 'ServerError',
             'RpcCallFailError', 'PoolBroken', 'ConnectionError')   # the file stays queued for the next call
FILE_KINDS = ('photo', 'voice', 'video_note', 'video', 'gif', 'audio', 'document')
_locks: dict = {}


def iso(dt) -> Optional[str]:
    return dt.astimezone(timezone.utc).isoformat() if dt else None


def plain(x):
    """Telegram strings that newer layers wrap in TextWithEntities."""
    return getattr(x, 'text', x)


def media_kind(m) -> Optional[str]:
    if getattr(m, 'media', None) is None:
        return None
    if getattr(m, 'web_preview', None) is not None or type(m.media).__name__ == 'MessageMediaWebPage':
        return 'webpage'      # first: m.photo also answers for a preview with a picture; an empty/pending preview too
    for kind in ('voice', 'video_note', 'gif', 'sticker', 'video', 'audio', 'photo', 'document', 'poll', 'geo', 'contact',
                 'dice'):
        if getattr(m, kind, None) is not None:
            return kind
    return 'other'


def safe_name(name: str, limit: int = 80) -> str:
    name = re.sub(r'[^\w.+-]+', '_', name, flags=re.UNICODE).strip('._')
    return name[:limit] or 'file'


def file_name(m, kind: str) -> str:
    f = m.file
    ext = (getattr(f, 'ext', None) or '') if f else ''
    name = getattr(f, 'name', None) if f else None
    if name:
        return f'{m.id}-{safe_name(name)}' + ('' if '.' in name else ext)
    return f'{m.id}-{kind}{ext}'


def media_record(m, kind: str) -> dict:
    out = {'kind': kind}
    f = m.file
    if f is not None and kind != 'webpage':
        for key in ('name', 'mime_type', 'size', 'duration', 'width', 'height', 'title', 'performer', 'emoji'):
            try:
                v = getattr(f, key, None)
            except Exception:   # Telethon raises for some attributes on some media
                v = None
            if v not in (None, ''):
                out['mime' if key == 'mime_type' else key] = v
    if kind in FILE_KINDS:
        out['file'] = file_name(m, kind)
    if kind == 'webpage':
        w = m.web_preview
        out.update({k: getattr(w, k) for k in ('url', 'site_name', 'title', 'description') if getattr(w, k, None)})
    elif kind == 'poll':
        p = m.poll
        votes = {}
        for r in (getattr(getattr(p, 'results', None), 'results', None) or []):
            votes[r.option] = r.voters
        out['question'] = plain(p.poll.question)
        out['answers'] = [{'text': plain(a.text), 'votes': votes.get(a.option)} for a in p.poll.answers]
    elif kind == 'geo':
        out.update(lat=m.geo.lat, long=m.geo.long)
    elif kind == 'contact':
        c = m.contact
        out.update(name=' '.join(x for x in (c.first_name, c.last_name) if x), phone=c.phone_number)
    elif kind == 'dice':
        out.update(emoji=m.dice.emoticon, value=m.dice.value)
    return out


def action_record(action) -> dict:
    """Service message: its type plus the scalar fields (titles, user ids, durations); never bytes."""
    out = {'type': type(action).__name__.removeprefix('MessageAction')}
    try:
        d = action.to_dict()
    except Exception:
        return out
    for k, v in d.items():
        if k == '_' or isinstance(v, (bytes, dict)):
            continue
        if isinstance(v, (str, int, float, bool)) or (isinstance(v, list) and all(isinstance(x, int) for x in v)):
            out[k] = v
        elif hasattr(v, 'isoformat'):
            out[k] = iso(v)
    return out


def display_name(entity) -> str:
    from telethon import utils
    return utils.get_display_name(entity) or ''


def peer_id(peer) -> Optional[int]:
    from telethon import utils
    try:
        return utils.get_peer_id(peer)
    except Exception:
        return None


def message_record(m) -> dict:
    r = {'id': m.id, 'date': iso(m.date)}
    if getattr(m, 'edit_date', None):
        r['edited'] = iso(m.edit_date)
    sender = getattr(m, 'sender', None)
    if sender is not None:
        r['from'] = {'id': m.sender_id, 'name': display_name(sender)}
        if getattr(sender, 'username', None):
            r['from']['username'] = sender.username
    elif getattr(m, 'sender_id', None):
        r['from'] = {'id': m.sender_id}
    if getattr(m, 'post_author', None):
        r['author'] = m.post_author
    if getattr(m, 'out', False):
        r['out'] = True
    try:
        text = m.text
    except Exception:   # a service message has no text to unparse
        text = None
    if text:
        r['text'] = text
    if getattr(m, 'action', None) is not None:
        r['action'] = action_record(m.action)
    rt = getattr(m, 'reply_to', None)
    if rt is not None:
        if getattr(rt, 'reply_to_msg_id', None):
            r['reply_to'] = rt.reply_to_msg_id
        if getattr(rt, 'reply_to_top_id', None):
            r['topic'] = rt.reply_to_top_id
        elif getattr(rt, 'forum_topic', False) and getattr(rt, 'reply_to_msg_id', None):
            r['topic'] = rt.reply_to_msg_id
    fwd = getattr(m, 'fwd_from', None)
    if fwd is not None:
        f = {'date': iso(fwd.date)}
        name = fwd.from_name
        if not name:
            fw = getattr(m, 'forward', None)
            ent = (getattr(fw, 'chat', None) or getattr(fw, 'sender', None)) if fw is not None else None
            name = display_name(ent) if ent is not None else None
        if name:
            f['name'] = name
        if fwd.from_id is not None:
            f['id'] = peer_id(fwd.from_id)
        if fwd.channel_post:
            f['post'] = fwd.channel_post
        r['forwarded'] = f
    for key in ('grouped_id', 'views', 'forwards'):
        if getattr(m, key, None):
            r[key] = getattr(m, key)
    replies = getattr(m, 'replies', None)
    if replies is not None and getattr(replies, 'replies', 0):
        r['replies'] = replies.replies
    reactions = getattr(m, 'reactions', None)
    if reactions is not None and getattr(reactions, 'results', None):
        r['reactions'] = [{'emoji': getattr(x.reaction, 'emoticon', None) or type(x.reaction).__name__.removeprefix('Reaction'),
                           'count': x.count} for x in reactions.results]
    kind = media_kind(m)
    if kind:
        r['media'] = media_record(m, kind)
    return r


def entity_kind(entity) -> str:
    name = type(entity).__name__
    if name == 'User':
        return 'bot' if getattr(entity, 'bot', False) else 'user'
    if name == 'Channel':
        return 'forum' if getattr(entity, 'forum', False) else ('group' if getattr(entity, 'megagroup', False) else 'channel')
    return 'group'


# The owner (and so an agent running as the owner) can write the export folder through its ACL. Nothing here may follow a
# link planted there: directories are checked, every file is opened with O_NOFOLLOW, renames and unlinks never follow.
def open_nofollow(path: Path, flags: int, mode: int = 0o666) -> int:
    return os.open(path, flags | os.O_NOFOLLOW | os.O_CLOEXEC, mode)


def safe_dir(path: Path, root: Path) -> Path:
    """mkdir -p below root, refusing a symlink on the way."""
    root.mkdir(parents=True, exist_ok=True)
    p = root
    for part in path.relative_to(root).parts:
        p = p / part
        if p.is_symlink():
            raise ValueError(f'{p} is a symlink: refusing to write through it')
        p.mkdir(exist_ok=True)
    if not path.resolve().is_relative_to(root.resolve()):
        raise ValueError(f'{path} is outside {root}')
    return path


def load_state(path: Path) -> dict:
    try:
        with os.fdopen(open_nofollow(path, os.O_RDONLY), encoding='utf-8') as fh:
            st = json.loads(fh.read())
        if isinstance(st, dict) and st.get('version') == 1:
            return st
    except (OSError, ValueError):
        pass
    return {'version': 1, 'last_id': 0, 'messages': 0, 'history_complete': False, 'pending': [], 'done': [], 'skipped': {},
            'failed': {}, 'bytes': 0}


def save_json(path: Path, data) -> None:
    tmp = path.with_name(path.name + '.tmp')
    tmp.unlink(missing_ok=True)                     # unlink never follows a link
    with os.fdopen(open_nofollow(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL), 'w', encoding='utf-8') as fh:
        fh.write(json.dumps(data, ensure_ascii=False, indent=1))
    os.replace(tmp, path)                           # rename replaces a link itself, never its target


class PoolBroken(Exception):
    """The pool cannot serve this file (CDN redirect, lost connection): fall back to Telethon's single stream."""


class StopSlice(Exception):
    """A flood wait would end after this call's deadline: stop the worker, the next call goes on."""


class Pool:
    """CONNECTIONS extra connections to one DC, one upload.getFile request in flight on each (Telegram Desktop downloads
    over several connections too). The owner's session is reused: on its home DC with the same auth key, on another DC
    the first connection imports an exported authorization (as Telethon's own borrowed sender does) and the others reuse
    that key. Kept between calls; dropped on any connection trouble."""

    def __init__(self, cl, dc_id):
        self.cl, self.dc_id, self.senders, self.free, self.fresh = cl, dc_id, [], asyncio.Queue(), set()
        self.flooded = 0

    async def open(self):
        import copy
        from telethon.network import MTProtoSender
        from telethon.tl import functions
        from telethon.tl.alltlobjects import LAYER
        cl = self.cl
        dc = await cl._get_dc(self.dc_id)
        key = cl.session.auth_key if self.dc_id == cl.session.dc_id else None
        try:
            for _ in range(CONNECTIONS):
                s = MTProtoSender(key, loggers=cl._log)
                await s.connect(cl._connection(dc.ip_address, dc.port, dc.id, loggers=cl._log, proxy=cl._proxy,
                                               local_addr=cl._local_addr))
                self.senders.append(s)
                if key is None:   # the first connection to a foreign DC imports the authorization; the others reuse its key
                    auth = await cl(functions.auth.ExportAuthorizationRequest(self.dc_id))
                    init = copy.copy(cl._init_request)      # never mutate the client's own init request
                    init.query = functions.auth.ImportAuthorizationRequest(id=auth.id, bytes=auth.bytes)
                    await s.send(functions.InvokeWithLayerRequest(LAYER, init))
                    key = s.auth_key
                else:             # its first getFile goes out wrapped in initConnection (as Telethon's own first request)
                    self.fresh.add(s)
                self.free.put_nowait(s)
        except BaseException as e:
            await self.close()
            if isinstance(e, Exception) and not isinstance(e, (ConnectionError, OSError, asyncio.TimeoutError)):
                raise PoolBroken(type(e).__name__)
            raise
        print(f'export_history: pool of {len(self.senders)} connections to DC {self.dc_id}', file=sys.stderr)
        return self

    async def chunk(self, location, offset: int, limit: int, deadline: float = float('inf')) -> bytes:
        import copy
        from telethon.errors import FloodError
        from telethon.tl import functions, types
        from telethon.tl.alltlobjects import LAYER
        s = await self.free.get()
        try:
            while True:
                req = functions.upload.GetFileRequest(location, offset, limit)
                if s in self.fresh:
                    init = copy.copy(self.cl._init_request)
                    init.query = req
                    req = functions.InvokeWithLayerRequest(LAYER, init)
                try:
                    r = await s.send(req)
                    self.fresh.discard(s)
                    break
                except FloodError as e:
                    self.flooded += 1
                    floods['n'] += 1
                    floods['seconds'] += e.seconds
                    print(f'export_history: {type(e).__name__} {e.seconds} s on getFile (pool)', file=sys.stderr)
                    if e.seconds > FLOOD_SLEEP:
                        raise PoolBroken(f'flood {e.seconds} s')
                    if time.monotonic() + e.seconds + 0.5 > deadline:
                        raise StopSlice()
                    await asyncio.sleep(e.seconds + 0.5)
        except (ConnectionError, OSError, asyncio.TimeoutError) as e:
            raise PoolBroken(type(e).__name__)
        finally:
            self.free.put_nowait(s)
        if isinstance(r, types.upload.FileCdnRedirect):
            raise PoolBroken('cdn')
        return r.bytes

    async def close(self):
        for s in self.senders:
            try:
                await s.disconnect()
            except Exception:
                pass


async def pool_for(cl, dc_id):
    async with _pool_lock:
        p = _pools.get(dc_id)
        if p is None or p.cl is not cl:
            p = _pools[dc_id] = await Pool(cl, dc_id).open()
        return p


async def drop_pool(dc_id):
    p = _pools.pop(dc_id, None)
    if p is not None:
        await p.close()


class Progress:
    """The contiguous start of a .part file that is really on disk, advanced as pooled requests land."""

    def __init__(self, prefix: int):
        self.prefix, self.done = prefix, set()

    def landed(self, off: int, size: int):
        self.done.add(off)
        while self.prefix in self.done:
            self.prefix += POOL_REQUEST


async def fetch_pooled(pool, location, fd: int, prog: Progress, size: int, deadline: float) -> None:
    """Fetch [prog.prefix, size) in POOL_REQUEST requests over the pool connections. Requests land out of order; prog
    keeps the contiguous start, and the caller cuts the file back to it on EVERY exit (deadline, error, cancellation by
    the upstream tool timeout), so a resumed file never has a hole. Workers that hit a flood wait retire down to
    MIN_WORKERS, so the request rate settles just under Telegram's limit."""
    offsets = iter(range(prog.prefix, size, POOL_REQUEST))
    active = [CONNECTIONS]

    async def worker():
        for off in offsets:               # one shared iterator: every offset goes to exactly one worker
            if time.monotonic() > deadline:
                return
            before = pool.flooded
            try:
                data = await pool.chunk(location, off, POOL_REQUEST, deadline)
            except StopSlice:
                return
            if data:
                os.pwrite(fd, data, off)
                prog.landed(off, size)
            if pool.flooded > before and active[0] > MIN_WORKERS:
                active[0] -= 1
                return

    results = await asyncio.gather(*(worker() for _ in range(CONNECTIONS)), return_exceptions=True)
    errors = [r for r in results if isinstance(r, BaseException)]
    if errors:
        raise errors[0] if not isinstance(errors[0], PoolBroken) else PoolBroken(str(errors[0]))


async def fetch_file(cl, m, dest: Path, deadline: float) -> bool:
    """Download one file; True when it is complete. Documents resume from <dest>.part; whatever stops a call, the .part
    keeps only its contiguous start."""
    part = dest.with_name(dest.name + '.part')
    if m.document is None:     # a photo: small, Telethon picks the biggest size; written here, never through a link
        data = await cl.download_media(m, file=bytes)
        with os.fdopen(open_nofollow(part, os.O_WRONLY | os.O_CREAT | os.O_TRUNC), 'wb') as fh:
            fh.write(data or b'')
        os.replace(part, dest)
        return True
    size = m.file.size or 0
    with os.fdopen(open_nofollow(part, os.O_RDWR | os.O_CREAT), 'r+b') as fh:
        have = os.fstat(fh.fileno()).st_size
        have -= have % REQUEST
        fh.truncate(have)
        if size >= POOL_MIN and have < size and getattr(m.document, 'id', None) not in _no_pool:
            from telethon import utils
            dc_id, location = utils.get_input_location(m.document)
            prog = Progress(have - have % POOL_REQUEST)
            fallback = False
            try:
                pool = await pool_for(cl, dc_id)
                await fetch_pooled(pool, location, fh.fileno(), prog, size, deadline)
            except PoolBroken as e:
                if str(e) == 'cdn':
                    _no_pool.add(getattr(m.document, 'id', None))
                elif not str(e).startswith('flood'):
                    await drop_pool(dc_id)
                fallback = True
            except (ConnectionError, OSError, asyncio.TimeoutError):   # the pool could not even open
                await drop_pool(dc_id)
                fallback = True
            finally:
                have = min(prog.prefix, size)
                fh.truncate(have)                   # on every exit, also an exception or a cancellation
            if have >= size:
                os.replace(part, dest)
                return True
            if not fallback:
                return False                        # the deadline: the next call resumes at the prefix
        fh.seek(have)
        if not size or have < size:
            async for chunk in cl.iter_download(m.document, offset=have, request_size=REQUEST, file_size=size or None):
                fh.write(chunk)
                if time.monotonic() > deadline:
                    return False
    os.replace(part, dest)
    return True


def parse_kinds(kinds) -> tuple:
    """'photo,video' / a list / None (= every kind with a file) -> the kinds to download."""
    if kinds in (None, '', 'all'):
        return FILE_KINDS
    names = [k.strip() for k in (kinds.split(',') if isinstance(kinds, str) else kinds) if k.strip()]
    bad = [k for k in names if k not in FILE_KINDS]
    if bad or not names:
        raise ValueError(f"kinds: unknown {', '.join(bad) or '(empty)'}; use 'all' or a subset of {','.join(FILE_KINDS)}")
    return tuple(names)


def parse_ids(refetch) -> list:
    if not refetch:
        return []
    ids = [x.strip() for x in str(refetch).split(',') if x.strip()]
    if not all(re.fullmatch(r'\d{1,12}', x) for x in ids) or len(ids) > 1000:
        raise ValueError('refetch: a comma list of message ids')
    return [int(x) for x in ids]


async def export(cl, entity, chat_id: int, media: bool = True, max_seconds: int = 40, max_file_mb: int = 4000,
                 restart: bool = False, about: str = None, root: Path = None, kinds=None, deadline: float = None,
                 refetch=None) -> dict:
    deadline = deadline or time.monotonic() + max_seconds
    root = root or EXPORT_ROOT
    d = root / str(chat_id)
    safe_dir(d / 'media', root)
    state_path = d / 'state.json'
    st = load_state(state_path)
    st.setdefault('excluded', [])
    st.setdefault('attempts', {})
    refetched = 0
    for mid in parse_ids(refetch):     # files the caller found damaged: fetch them again from scratch
        for key in ('done', 'excluded'):
            if mid in st[key]:
                st[key].remove(mid)
        for key in ('failed', 'skipped', 'attempts'):
            st[key].pop(str(mid), None)
        for f in (d / 'media').glob(f'{mid}-*'):
            f.unlink()                 # unlink never follows a link
        if mid not in st['pending']:
            st['pending'].append(mid)
        refetched += 1
    for k in [k for k, v in st['failed'].items() if v in TRANSIENT]:   # left by an older version: queue them again
        st['failed'].pop(k)
        if int(k) not in st['pending']:
            st['pending'].append(int(k))
    flood0 = dict(floods)
    want = parse_kinds(kinds)
    if restart:   # read the whole history again (edits, reactions, older media); finished files are not fetched again
        st.update(last_id=0, messages=0, history_complete=False)
    info = {'id': chat_id, 'title': display_name(entity), 'kind': entity_kind(entity),
            'username': getattr(entity, 'username', None), 'exported': datetime.now(timezone.utc).isoformat()}
    if about:
        info['about'] = about
    save_json(d / 'chat.json', info)

    # 1. history after the last exported id, oldest first
    new = 0
    finished = True
    known = set(st['done']) | set(st['pending']) | {int(k) for k in st['skipped']}
    if restart:   # files of kinds that were not wanted before may be wanted now
        st['excluded'] = []
    with os.fdopen(open_nofollow(d / 'messages.jsonl', os.O_WRONLY | os.O_CREAT | os.O_APPEND), 'a', encoding='utf-8') as out:
        async for m in cl.iter_messages(entity, min_id=st['last_id'], reverse=True, wait_time=0):
            rec = message_record(m)
            out.write(json.dumps(rec, ensure_ascii=False) + '\n')
            new += 1
            st['messages'] += 1
            st['last_id'] = max(st['last_id'], m.id)
            if media and rec.get('media', {}).get('file') and m.id not in known and m.id not in st['excluded']:
                st['pending'].append(m.id)
                known.add(m.id)
            if new % SAVE_EVERY == 0:
                out.flush()
                save_json(state_path, st)
            if time.monotonic() > deadline:
                finished = False
                break
    st['history_complete'] = finished
    save_json(state_path, st)

    # 2. queued files, PARALLEL at a time (one file is a chain of 512 KiB round trips, so parallel files are what fills the
    #    line); a document cut by the deadline stays queued and resumes next call
    limit = max_file_mb * 1024 * 1024
    msgs = {}
    head = st['pending'][:FETCH_AHEAD]
    for i in range(0, len(head), 100):
        batch = head[i:i + 100]
        msgs.update(zip(batch, await cl.get_messages(entity, ids=batch)))
    order = iter(list(head))
    lock = asyncio.Lock()
    flags = {'disk_low': False, 'transient': 0}

    async def finish(mid, outcome, size=0):
        async with lock:
            if outcome == 'done':
                st['failed'].pop(str(mid), None)
                st['attempts'].pop(str(mid), None)
                st['done'].append(mid)
                st['bytes'] += size
            elif outcome == 'excluded':     # a kind the caller did not ask for: never downloaded, restart reconsiders it
                st['excluded'].append(mid)
                part = d / 'media' / (file_name(msgs[mid], media_kind(msgs[mid])) + '.part')
                part.unlink(missing_ok=True)
            elif outcome:
                st['skipped' if outcome.startswith(('gone', 'bigger')) else 'failed'][str(mid)] = outcome
            st['pending'].remove(mid)
            save_json(state_path, st)     # after every file: a cancelled call (server timeout) loses nothing

    async def worker():
        for mid in order:                 # one shared iterator: every message goes to exactly one worker
            if time.monotonic() > deadline:
                return
            m = msgs.get(mid)
            kind = media_kind(m) if m is not None else None
            if kind not in FILE_KINDS:
                await finish(mid, 'gone')
            elif kind not in want:
                await finish(mid, 'excluded')
            elif (m.file.size or 0) > limit:
                await finish(mid, f'bigger than {max_file_mb} MB')
            elif shutil.disk_usage(d).free < (m.file.size or 0) + MIN_FREE:
                flags['disk_low'] = True         # stays queued; the caller is told to free space
                return
            else:
                try:
                    if not await fetch_file(cl, m, d / 'media' / file_name(m, kind), deadline):
                        return
                except asyncio.CancelledError:
                    raise
                except Exception as e:   # one bad file must not stop the export; restart=true tries it again
                    if type(e).__name__ in TRANSIENT or isinstance(e, (ConnectionError, asyncio.TimeoutError)):
                        async with lock:
                            flags['transient'] += 1
                            n = st['attempts'][str(mid)] = st['attempts'].get(str(mid), 0) + 1
                            save_json(state_path, st)
                        print(f'export_history: #{mid} {type(e).__name__} (attempt {n}/{MAX_ATTEMPTS})', file=sys.stderr)
                        if n < MAX_ATTEMPTS:
                            return       # flood wait, timeout, lost connection: the next call tries again
                        await finish(mid, f'{type(e).__name__} x{n}')
                        continue
                    await finish(mid, type(e).__name__)
                else:
                    await finish(mid, 'done', m.file.size or 0)

    if st['pending'] and time.monotonic() < deadline:
        await asyncio.gather(*(worker() for _ in range(PARALLEL)))

    st['updated'] = datetime.now(timezone.utc).isoformat()
    save_json(state_path, st)
    done = st['history_complete'] and not st['pending']
    return {'chat_id': chat_id, 'title': info['title'], 'kind': info['kind'], 'dir': str(d), 'new_messages': new,
            'messages_total': st['messages'], 'history_complete': st['history_complete'], 'media_pending': len(st['pending']),
            'media_done': len(st['done']), 'media_skipped': len(st['skipped']), 'media_failed': len(st['failed']),
            'media_excluded': len(st['excluded']), 'flood_waits': floods['n'] - flood0['n'],
            'flood_seconds': floods['seconds'] - flood0['seconds'], 'transient_errors': flags['transient'],
            'disk_low': flags['disk_low'], 'refetched': refetched,
            'bytes': st['bytes'], 'done': done,
            'next': None if done else 'call export_history again with the same chat_id to continue'}


def install():
    from telegram_mcp import runtime as rt
    from mcp.types import ToolAnnotations

    if getattr(rt, '_chat_export_installed', False):
        return

    @rt.mcp.tool(annotations=ToolAnnotations(title='Export History', readOnlyHint=False, destructiveHint=False,
                                             idempotentHint=True, openWorldHint=True))
    @rt.with_account(readonly=True)
    @rt.validate_id('chat_id')
    async def export_history(chat_id: Union[int, str], media: bool = True, kinds: str = 'all', max_seconds: int = 40,
                             max_file_mb: int = 4000, restart: bool = False, refetch: str = '',
                             account: Optional[str] = None) -> str:
        """Export the next slice of a read-allowlisted chat to the local export folder (never sends anything).
        Writes messages.jsonl, media files and state.json under <export dir>/<chat id>/ and returns a short JSON status.
        Repeat the call with the same chat_id until "done" is true; each call works at most max_seconds (10..45).
        media=false skips files; kinds limits them ('all' or a comma list of photo,voice,video_note,video,gif,audio,document).
        restart=true reads the whole history again (finished files are kept, not fetched again).
        refetch='12,34' downloads those messages' files again from scratch (the caller found them damaged).
        """
        deadline = time.monotonic() + max_seconds     # from the start of the tool: lookups below count too
        if not 10 <= max_seconds <= MAX_SECONDS:
            raise ValueError(f'max_seconds must be between 10 and {MAX_SECONDS}')
        if max_file_mb < 1:
            raise ValueError('max_file_mb must be positive')
        parse_kinds(kinds)
        parse_ids(refetch)
        cl = rt.get_client(account)
        entity = await rt.resolve_entity(chat_id, cl)
        if rt.is_chat_allowlist_enabled() and not rt.is_chat_allowed(chat_id, entity):
            raise rt.ChatAccessDeniedError(rt.check_chat_access(chat_id, entity))
        cid = peer_id(entity)
        lock = _locks.setdefault(cid, asyncio.Lock())
        if lock.locked():
            raise ValueError('an export of this chat is already running; wait for it and call again')
        async with lock:
            about = None
            if type(entity).__name__ == 'Channel':
                from telethon.tl.functions.channels import GetFullChannelRequest
                try:
                    about = (await cl(GetFullChannelRequest(entity))).full_chat.about
                except Exception:   # the description is optional
                    pass
            out = await export(cl, entity, cid, media, max_seconds, max_file_mb, restart, about, kinds=kinds,
                               deadline=deadline, refetch=refetch)
        return json.dumps(out, ensure_ascii=False)

    rt._chat_export_installed = True
