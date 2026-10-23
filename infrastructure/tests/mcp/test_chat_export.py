"""Offline tests of export_history (chat_export.py) against a fake Telethon client: history slices, resume, media queue,
resumable big files, size limit, restart, normalised records. Runs in the telegram-mcp venv (needs telethon.utils)."""
import asyncio
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace as NS

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / 'infrastructure/mcp/telegram'))
import chat_export as ce

results = []


def check(name, value):
    results.append(bool(value))
    print(('ok ' if value else 'FAIL ') + name)


class Clock:
    t = 0.0

    def monotonic(self):
        return self.t


clock = Clock()
ce.time = clock
ce.REQUEST = 4          # tiny requests so a "big" file needs several of them


def msg(mid, text='', **kw):
    base = dict(id=mid, date=datetime(2026, 1, 1, 12, mid % 60, tzinfo=timezone.utc), edit_date=None, sender=None,
                sender_id=None, post_author=None, out=False, text=text, action=None, reply_to=None, fwd_from=None, forward=None,
                grouped_id=None, views=None, forwards=None, replies=None, reactions=None, media=None, file=None, document=None,
                web_preview=None, voice=None, video_note=None, gif=None, sticker=None, video=None, audio=None, photo=None,
                poll=None, geo=None, contact=None, dice=None)
    base.update(kw)
    return NS(**base)


def voice(mid, data):
    f = NS(name=None, ext='.ogg', mime_type='audio/ogg', size=len(data), duration=3, width=None, height=None, title=None,
           performer=None, emoji=None)
    doc = NS(data=data)
    return msg(mid, media=object(), voice=doc, document=doc, file=f)


def document(mid, name, data):
    f = NS(name=name, ext='.pdf', mime_type='application/pdf', size=len(data), duration=None, width=None, height=None,
           title=None, performer=None, emoji=None)
    doc = NS(data=data, id=mid)
    return msg(mid, media=object(), document=doc, file=f)


def photo(mid, data):
    f = NS(name=None, ext='.jpg', mime_type='image/jpeg', size=len(data), duration=None, width=10, height=10, title=None,
           performer=None, emoji=None)
    return msg(mid, media=object(), photo=NS(data=data), file=f)


class Client:
    def __init__(self, messages):
        self.messages = {m.id: m for m in messages}
        self.downloads = 0

    async def iter_messages(self, entity, min_id=0, reverse=False, wait_time=None):
        for mid in sorted(self.messages):
            if mid > min_id:
                clock.t += 1
                yield self.messages[mid]

    async def get_messages(self, entity, ids=None):
        return [self.messages.get(i) for i in ids]

    async def download_media(self, m, file=None):
        self.downloads += 1
        if file is bytes:
            return m.photo.data
        Path(file).write_bytes(m.photo.data)

    async def iter_download(self, doc, offset=0, request_size=4, file_size=None):
        self.downloads += 1
        for i in range(offset, len(doc.data), request_size):
            clock.t += 8
            yield doc.data[i:i + request_size]


from telethon.tl import types

chat = types.Channel(id=1001, title='Курс', photo=types.ChatPhotoEmpty(), date=datetime.now(timezone.utc), broadcast=True)


def run(client, **kw):
    clock.t = 0
    return asyncio.run(ce.export(client, chat, -1001, root=root, **kw))


with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    big = bytes(range(40))
    msgs = [msg(1, 'hello'), voice(2, b'OGGDATA'), photo(3, b'JPEG'), document(4, '../../etc/passwd.pdf', big)]
    cl = Client(msgs)
    out = run(cl, max_seconds=40)
    d = root / '-1001'
    lines = [json.loads(x) for x in (d / 'messages.jsonl').read_text().splitlines()]
    check('history: every message exported once, oldest first', [r['id'] for r in lines] == [1, 2, 3, 4])
    check('history: complete flag set after the last message', out['history_complete'] is True)
    check('media: small files done in the first call', (d / 'media/2-voice.ogg').read_bytes() == b'OGGDATA'
          and (d / 'media/3-photo.jpg').read_bytes() == b'JPEG')
    part = d / 'media/4-etc_passwd.pdf.part'
    check('media: a big document stops at the deadline and keeps its .part', out['done'] is False and out['media_pending'] == 1
          and part.exists() and part.stat().st_size > 0)
    check('media: names stay inside media/ (no path traversal)', not any(p.name.startswith('.') for p in (d / 'media').iterdir())
          and all(p.parent == d / 'media' for p in (d / 'media').iterdir()))
    for _ in range(10):
        out = run(cl, max_seconds=40)
        if out['done']:
            break
    check('media: the big document resumes across calls and ends byte-identical',
          out['done'] is True and (d / 'media/4-etc_passwd.pdf').read_bytes() == big and not part.exists())
    lines = (d / 'messages.jsonl').read_text().splitlines()
    check('history: repeated calls add no duplicates', len(lines) == 4)
    cl.messages[5] = msg(5, 'new one')
    out = run(cl, max_seconds=40)
    lines = [json.loads(x) for x in (d / 'messages.jsonl').read_text().splitlines()]
    check('history: only the new message is appended', [r['id'] for r in lines] == [1, 2, 3, 4, 5] and out['new_messages'] == 1)
    before = cl.downloads
    (d / 'messages.jsonl').rename(d / 'imported.jsonl')    # what tg-archive does when it imports
    out = run(cl, max_seconds=40, restart=True)
    lines = [json.loads(x) for x in (d / 'messages.jsonl').read_text().splitlines()]
    check('restart: whole history again in a fresh file, finished files are not downloaded again',
          len(lines) == 5 and cl.downloads == before and out['done'] is True)
    st = json.loads((d / 'state.json').read_text())
    check('state: version, last id, done list', st['version'] == 1 and st['last_id'] == 5 and sorted(st['done']) == [2, 3, 4])
    info = json.loads((d / 'chat.json').read_text())
    check('chat.json: title kept as UTF-8, kind channel', info['title'] == 'Курс' and info['id'] == -1001 and info['kind'] == 'channel')

    root2 = Path(tmp) / 'r2'
    root = root2
    cl2 = Client([document(1, 'film.mp4', bytes(100))])
    out = run(cl2, max_seconds=40, max_file_mb=0.00001)
    st = json.loads((root2 / '-1001/state.json').read_text())
    check('limit: a file over max_file_mb is skipped with the reason, nothing downloaded',
          out['done'] and cl2.downloads == 0 and 'bigger than' in st['skipped']['1'])
    cl3 = Client([voice(7, b'x')])
    root = Path(tmp) / 'r3'
    out = run(cl3, max_seconds=40, media=False)
    check('media=false: nothing queued, nothing downloaded', out['done'] and cl3.downloads == 0 and out['media_done'] == 0)

    root = Path(tmp) / 'r4'
    cl4 = Client([voice(1, b'VOICE'), photo(2, b'PIC'), document(3, 'app.apk', bytes(64))])
    ((root / '-1001/media')).mkdir(parents=True)
    (root / '-1001/media/3-app.apk.part').write_bytes(b'xxxx')     # left by an earlier call
    out = run(cl4, max_seconds=40, kinds='photo,voice')
    m4 = root / '-1001/media'
    check('kinds: only the asked kinds are downloaded, the rest excluded and its .part removed',
          out['done'] and (m4 / '1-voice.ogg').exists() and (m4 / '2-photo.jpg').exists()
          and not (m4 / '3-app.apk').exists() and not (m4 / '3-app.apk.part').exists() and out['media_excluded'] == 1)
    out = run(cl4, max_seconds=40)
    check('kinds: an excluded file stays excluded on a plain repeat', out['media_excluded'] == 1 and not (m4 / '3-app.apk').exists())
    for _ in range(5):
        out = run(cl4, max_seconds=40, restart=True, kinds='all') if _ == 0 else run(cl4, max_seconds=40, kinds='all')
        if out['done']:
            break
    check('kinds: restart with all kinds fetches the excluded file', (m4 / '3-app.apk').read_bytes() == bytes(64))
    try:
        ce.parse_kinds('photo,apk')
        check('kinds: an unknown kind is refused', False)
    except ValueError:
        check('kinds: an unknown kind is refused', True)
    check('kinds: all / empty mean every kind with a file', ce.parse_kinds('all') == ce.FILE_KINDS == ce.parse_kinds(None))

    # the connection pool for big files (fake pool: the same 4-byte requests, served from the document bytes)
    import telethon.utils
    telethon.utils.get_input_location = lambda doc: (4, doc)
    ce.POOL_MIN = 16
    ce.POOL_REQUEST = 8     # a multiple of REQUEST, like 1 MiB and 512 KiB

    class FakePool:
        def __init__(self, broken=False):
            self.requests, self.broken, self.closed, self.flooded = [], broken, False, 0

        async def chunk(self, location, offset, limit, deadline=None):
            self.requests.append(offset)
            clock.t += 3
            if self.broken:
                raise ce.PoolBroken('cdn')
            return location.data[offset:offset + limit]

        async def close(self):
            self.closed = True

    pools = []

    async def fake_pool_for(cl, dc_id):
        if dc_id not in ce._pools:
            ce._pools[dc_id] = FakePool(broken=getattr(cl, 'broken_pool', False))
            pools.append(ce._pools[dc_id])
        return ce._pools[dc_id]

    ce.pool_for = fake_pool_for
    root = Path(tmp) / 'r5'
    film = bytes(range(256)) * 2          # 512 bytes = 128 requests of 4 bytes
    cl5 = Client([document(1, 'film.mp4', film)])
    outs = []
    for _ in range(20):
        outs.append(run(cl5, max_seconds=40))
        if outs[-1]['done']:
            break
    check('pool: a big file is fetched over the pool, resumed across calls, byte-identical',
          outs[-1]['done'] and len(outs) > 1 and (root / '-1001/media/1-film.mp4').read_bytes() == film
          and cl5.downloads == 0 and pools and len(pools[0].requests) >= 64)
    check('pool: the pool is kept between calls (one pool for the DC)', len(pools) == 1)
    check('pool: requests are POOL_REQUEST long and aligned', all(o % 8 == 0 for o in pools[0].requests))

    class Flooding(FakePool):    # every 3rd request reports a flood wait (slept inside chunk, as the real Pool does)
        flooded = 0

        async def chunk(self, location, offset, limit, deadline=None):
            self.requests.append(offset)
            clock.t += 1
            if len(self.requests) % 3 == 0:
                self.flooded += 1
            return location.data[offset:offset + limit]

    ce._pools.clear()
    ce._pools[4] = fl = Flooding()
    root = Path(tmp) / 'r9'
    cl9 = Client([document(1, 'film.mp4', film)])
    for _ in range(20):
        out = run(cl9, max_seconds=40)
        if out['done']:
            break
    check('pool: workers retire on flood waits down to MIN_WORKERS and the file still completes',
          out['done'] and (root / '-1001/media/1-film.mp4').read_bytes() == film and fl.flooded > ce.CONNECTIONS)
    ce._pools.clear()
    ce._pools.clear()
    root = Path(tmp) / 'r6'
    cl6 = Client([document(1, 'film.mp4', film)])
    cl6.broken_pool = True
    for _ in range(40):
        out = run(cl6, max_seconds=40)
        if out['done']:
            break
    check('pool: a CDN redirect falls back to the single stream and that file never tries the pool again',
          out['done'] and (root / '-1001/media/1-film.mp4').read_bytes() == film and cl6.downloads > 0
          and len(pools[-1].requests) <= ce.CONNECTIONS and not out['media_failed'])
    ce._pools.clear()
    ce._no_pool.clear()

    class Lost(FakePool):
        async def chunk(self, location, offset, limit, deadline=None):
            raise ce.PoolBroken('ConnectionError')

    async def lost_pool_for(cl, dc_id):
        if dc_id not in ce._pools:
            ce._pools[dc_id] = Lost()
            pools.append(ce._pools[dc_id])
        return ce._pools[dc_id]

    ce.pool_for = lost_pool_for
    root = Path(tmp) / 'r7'
    cl7 = Client([document(1, 'film.mp4', film)])
    out = run(cl7, max_seconds=40)
    check('pool: a lost connection drops (closes) the pool, the call goes on with the single stream',
          pools[-1].closed and 4 not in ce._pools and cl7.downloads == 1 and not out['media_failed'])
    ce.pool_for = fake_pool_for
    ce._pools.clear()

    # Pool.chunk against a fake sender: a short flood wait is slept and retried, a long one gives up the pool for this file
    from telethon.errors import FloodWaitError
    from telethon.tl import functions, types as tltypes

    class Sender:
        def __init__(self, waits):
            self.waits, self.sent = list(waits), []

        async def send(self, req):
            self.sent.append(req)
            if self.waits:
                raise FloodWaitError(request=None, capture=self.waits.pop(0))
            return tltypes.upload.File(type=tltypes.storage.FileUnknown(), mtime=0, bytes=b'DATA')

    slept = []

    async def nosleep(t):
        slept.append(t)

    real_sleep, ce.asyncio.sleep = ce.asyncio.sleep, nosleep
    init = functions.InitConnectionRequest(api_id=1, device_model='d', system_version='s', app_version='a',
                                           system_lang_code='en', lang_pack='', lang_code='en',
                                           query=functions.help.GetConfigRequest())

    async def pool_case(waits):
        pool = ce.Pool(NS(_init_request=init), 2)
        snd = Sender(waits)
        pool.senders.append(snd)
        pool.free.put_nowait(snd)
        pool.fresh.add(snd)
        try:
            return await pool.chunk('loc', 0, 4), snd, pool
        except ce.PoolBroken as e:
            return e, snd, pool

    data, snd, pool = asyncio.run(pool_case([3]))
    check('pool: a 3 s flood wait is slept and the request retried, the first request carries initConnection',
          data == b'DATA' and slept == [3.5] and type(snd.sent[0]).__name__ == 'InvokeWithLayerRequest'
          and init.query.__class__.__name__ == 'GetConfigRequest' and snd not in pool.fresh)
    err, snd, pool = asyncio.run(pool_case([600]))
    check('pool: a 600 s flood wait gives up the pool for this file (PoolBroken flood), the sender goes back',
          isinstance(err, ce.PoolBroken) and str(err).startswith('flood') and pool.free.qsize() == 1)
    ce.asyncio.sleep = real_sleep

    # a transient error keeps the file queued; a failed entry of that kind left by an older version is queued again
    root = Path(tmp) / 'r8'
    cl8 = Client([document(1, 'film.mp4', film)])

    async def flood_pool_for(cl, dc_id):
        raise FloodWaitError(request=None, capture=30)

    ce.pool_for = flood_pool_for
    out = run(cl8, max_seconds=40)
    st = json.loads((root / '-1001/state.json').read_text())
    check('transient: a flood wait leaves the file queued, not failed', st['pending'] == [1] and not st['failed'])
    st['pending'], st['failed'] = [], {'1': 'FloodWaitError'}
    (root / '-1001/state.json').write_text(json.dumps(st))
    ce.pool_for = fake_pool_for
    for _ in range(40):
        out = run(cl8, max_seconds=40)
        if out['done']:
            break
    check('transient: an old FloodWaitError failure is queued again and finishes',
          out['done'] and (root / '-1001/media/1-film.mp4').read_bytes() == film and not out['media_failed'])
    ce._pools.clear()

    # review fixes: no holes after an error or a cancellation, links in the export folder, refetch, attempts, disk
    ce.pool_for = fake_pool_for

    class Erring(FakePool):     # out-of-order landing, then a server error at offset 16 (more requests already landed)
        async def chunk(self, location, offset, limit, deadline=None):
            self.requests.append(offset)
            await asyncio.sleep(0)
            clock.t += 1
            if offset == 16 and not getattr(self, 'tripped', False):
                self.tripped = True
                raise type('ServerError', (Exception,), {})()
            return location.data[offset:offset + limit]

    def holeless(path, data):
        b = path.read_bytes()
        return b == data[:len(b)]

    ce._pools.clear()
    ce._pools[4] = Erring()
    root = Path(tmp) / 'r10'
    cl10 = Client([document(1, 'film.mp4', film)])
    out = run(cl10, max_seconds=40)
    part10 = root / '-1001/media/1-film.mp4.part'
    check('holes: after a server error mid-pool the .part keeps only its contiguous start (no zeros inside)',
          part10.exists() and holeless(part10, film) and out['media_pending'] == 1 and out['transient_errors'] == 1)
    for _ in range(20):
        out = run(cl10, max_seconds=40)
        if out['done']:
            break
    check('holes: the next calls finish the file byte-identical', (root / '-1001/media/1-film.mp4').read_bytes() == film)

    class Cancelling(FakePool):
        async def chunk(self, location, offset, limit, deadline=None):
            self.requests.append(offset)
            await asyncio.sleep(0)
            if offset >= 40:
                raise asyncio.CancelledError()
            return location.data[offset:offset + limit]

    ce._pools.clear()
    ce._pools[4] = Cancelling()
    root = Path(tmp) / 'r11'
    try:
        run(Client([document(1, 'film.mp4', film)]), max_seconds=40)
        cancelled = False
    except asyncio.CancelledError:
        cancelled = True
    part11 = root / '-1001/media/1-film.mp4.part'
    check('holes: a cancelled call (the upstream tool timeout) leaves the .part cut to its contiguous start',
          cancelled and part11.exists() and holeless(part11, film) and part11.stat().st_size % 8 == 0)
    ce._pools.clear()

    root = Path(tmp) / 'r12'
    victim = Path(tmp) / 'victim.json'
    victim.write_text('{"keep": true}')
    (root / '-1001/media').mkdir(parents=True)
    (root / '-1001/media/1-film.mp4.part').symlink_to(victim)
    (root / '-1001/state.json').symlink_to(victim)
    out = run(Client([document(1, 'film.mp4', film)]), max_seconds=40)
    check('links: a planted .part or state.json link is never written through (state.json becomes a real file)',
          victim.read_text() == '{"keep": true}' and not (root / '-1001/state.json').is_symlink() and out['media_failed'] == 1)
    root = Path(tmp) / 'r13'
    root.mkdir()
    (Path(tmp) / 'elsewhere').mkdir()
    (root / '-1001').symlink_to(Path(tmp) / 'elsewhere')
    try:
        run(Client([msg(1, 'x')]), max_seconds=40)
        refused = False
    except ValueError:
        refused = True
    check('links: a chat folder that is a link is refused, nothing written there',
          refused and not any((Path(tmp) / 'elsewhere').iterdir()))

    root = Path(tmp) / 'r14'
    cl14 = Client([voice(1, b'GOOD')])
    run(cl14, max_seconds=40)
    (root / '-1001/media/1-voice.ogg').write_bytes(b'BAD!')
    n0 = cl14.downloads
    out = run(cl14, max_seconds=40, refetch='1')
    check('refetch: a damaged file is downloaded again from scratch',
          out['refetched'] == 1 and cl14.downloads == n0 + 1 and (root / '-1001/media/1-voice.ogg').read_bytes() == b'GOOD')
    try:
        ce.parse_ids('1,../2')
        check('refetch: only message ids are accepted', False)
    except ValueError:
        check('refetch: only message ids are accepted', True)

    root = Path(tmp) / 'r15'
    cl15 = Client([document(1, 'film.mp4', film)])
    ce.pool_for = flood_pool_for
    outs = [run(cl15, max_seconds=40) for _ in range(ce.MAX_ATTEMPTS)]
    st = json.loads((root / '-1001/state.json').read_text())
    check('attempts: a file that keeps failing transiently becomes failed after MAX_ATTEMPTS calls',
          outs[-1]['done'] and st['failed'].get('1', '').startswith('FloodWaitError x') and not st['pending'])
    ce.pool_for = fake_pool_for

    real_usage = ce.shutil.disk_usage
    ce.shutil.disk_usage = lambda p: NS(total=1, used=1, free=0)
    root = Path(tmp) / 'r16'
    out = run(Client([voice(1, b'V')]), max_seconds=40)
    ce.shutil.disk_usage = real_usage
    check('disk: below the free-space floor nothing is downloaded, the file stays queued, disk_low is reported',
          out['disk_low'] and out['media_pending'] == 1 and not (root / '-1001/media/1-voice.ogg').exists())

    # records
    web = msg(9, 'see https://x.org', media=object(), web_preview=NS(url='https://x.org', site_name='X', title='T',
                                                                       description='D'), photo=NS(data=b''))
    r = ce.message_record(web)
    check('record: a link preview with a picture is a webpage, not a photo to download',
          r['media']['kind'] == 'webpage' and 'file' not in r['media'] and r['media']['url'] == 'https://x.org')
    fwd = msg(10, 'fw', fwd_from=NS(date=datetime(2025, 5, 1, tzinfo=timezone.utc), from_name='Somebody', from_id=None,
                                    channel_post=None), reply_to=NS(reply_to_msg_id=3, reply_to_top_id=None, forum_topic=False),
              reactions=NS(results=[NS(reaction=NS(emoticon='👍'), count=4)]), views=120, grouped_id=77)
    r = ce.message_record(fwd)
    check('record: reply, forward, reactions, views and album id are kept',
          r['reply_to'] == 3 and r['forwarded']['name'] == 'Somebody' and r['reactions'] == [{'emoji': '👍', 'count': 4}]
          and r['views'] == 120 and r['grouped_id'] == 77)
    poll = msg(11, media=object(), poll=NS(poll=NS(question=NS(text='Q?'), answers=[NS(text=NS(text='A'), option=b'0'),
                                                                                     NS(text='B', option=b'1')]),
                                          results=NS(results=[NS(option=b'0', voters=3)])))
    r = ce.message_record(poll)
    check('record: poll question, answers and votes (TextWithEntities or str)',
          r['media']['question'] == 'Q?' and r['media']['answers'] == [{'text': 'A', 'votes': 3}, {'text': 'B', 'votes': None}])
    check('names: unsafe characters replaced, extension kept', ce.safe_name('a b/c?.pdf') == 'a_b_c_.pdf')

sys.exit(0 if all(results) else 1)
