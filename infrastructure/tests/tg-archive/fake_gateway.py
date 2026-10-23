"""Fake MCP gateway for the tg-archive suite: streamable-HTTP JSON-RPC on 127.0.0.1, bearer token, a session id, and two
tools. list_chats returns the chats in $FAKE_CHATS (JSON); export_history plays the telegram-mcp side: it writes the files of
$FAKE_EXPORT_SRC/<chat id>/ (messages.jsonl, media/) into $TG_ARCHIVE_EXPORT/<chat id>/ in two slices, like the real tool
over two calls, with the service's file bookkeeping (kinds left out, max_file_mb, refetch, restart). A chat that is not in
$FAKE_CHATS gets upstream's privacy-policy text (not an isError, like the real server). While $FAKE_LOG's folder holds the
file http503, the next export_history call answers HTTP 503 (a restarting service) and removes it. Every tools/call is
logged to $FAKE_LOG. Under /notion it also plays Notion's public API: loadPageChunk (the pages of $FAKE_NOTION, a JSON
file {page id: [recordMap chunk, ...]}, one chunk per call with a cursor), queryCollection (rows from the same file under
"rows") and /notion/image/... (a PNG); /web/article is a blog page and /files/guide.pdf a PDF.
  fake_gateway.py PORTFILE TOKEN
"""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import shutil
import sys

PORTFILE, TOKEN = sys.argv[1], sys.argv[2]
EXPORT = Path(os.environ['TG_ARCHIVE_EXPORT'])
SRC = Path(os.environ['FAKE_EXPORT_SRC'])
calls = {}


def export_history(args):
    if os.environ.get('FAKE_TIMEOUT_ONCE') and not calls.get('timed_out'):
        calls['timed_out'] = 1      # what upstream answers when it cancels a tool after 55 s
        return True, 'Telegram MCP tool timed out after 55s (code: GEN-TIMEOUT). Completion is unknown.'
    cid = int(args['chat_id']) if str(args['chat_id']).lstrip('-').isdigit() else None
    chats = json.loads(os.environ['FAKE_CHATS'])
    chat = next((c for c in chats if c['chat_id'] == cid or ('@' + (c.get('username') or '')) == args['chat_id']), None)
    if chat is None:      # upstream answers a chat outside TELEGRAM_ALLOWED_CHAT_IDS with plain text, not an isError
        return False, f"Access to chat '{args['chat_id']}' is restricted by privacy policy (TELEGRAM_ALLOWED_CHAT_IDS)."
    cid = chat['chat_id']
    src, dst = SRC / str(cid), EXPORT / str(cid)
    (dst / 'media').mkdir(parents=True, exist_ok=True)
    n = calls[cid] = calls.get(cid, 0) + 1
    lines = (src / 'messages.jsonl').read_text().splitlines() if (src / 'messages.jsonl').exists() else []
    state = json.loads((dst / 'state.json').read_text()) if (dst / 'state.json').exists() else {'sent': 0, 'files': []}
    if args.get('restart'):
        state['sent'] = 0
    refetched = [x for x in str(args.get('refetch') or '').split(',') if x]
    for mid in refetched:     # the real tool deletes the copy and downloads it again
        for f in (src / 'media').glob(f'{mid}-*'):
            if f.name in state['files']:
                state['files'].remove(f.name)
    if Path(os.environ['FAKE_LOG']).with_name('idle').exists():       # a stuck chat: never any progress
        return False, json.dumps({'chat_id': -1005678, 'title': 'x', 'kind': 'group', 'dir': '', 'new_messages': 0,
                                  'messages_total': 0, 'history_complete': True, 'media_pending': 1, 'media_done': 0,
                                  'media_skipped': 0, 'media_failed': 0, 'bytes': 0, 'done': False, 'next': 'again'})
    half = (len(lines) + 1) // 2 if state['sent'] == 0 and len(lines) > 1 else len(lines)
    new = lines[state['sent']:half]
    with open(dst / 'messages.jsonl', 'a') as fh:
        fh.writelines(l + '\n' for l in new)
    state['sent'] += len(new)
    kinds = (args.get('kinds') or 'all').split(',')
    limit = int(args.get('max_file_mb') or 4000)
    files = {r['id']: r['media'] for r in map(json.loads, lines) if 'file' in (r.get('media') or {})}
    skipped, excluded, done = state.get('skipped', {}), set(state.get('excluded', [])), set(state.get('done', []))
    if args.get('restart'):
        excluded = set()
    for mid in refetched:
        excluded.discard(int(mid))
        skipped.pop(mid, None)
        done.discard(int(mid))
    fresh = {json.loads(l)['id'] for l in new} | {int(x) for x in refetched}
    if args.get('restart'):
        fresh = set(files)
    if args.get('media', True):         # like the service: files of the messages read now, and the refetched ones
        for mid, m in files.items():
            if mid not in fresh or m['file'] in state['files'] or str(mid) in skipped or mid in excluded:
                continue
            if kinds != ['all'] and m['kind'] not in kinds:
                excluded.add(mid)
            elif (m.get('size') or 0) > limit * 1024 * 1024:
                skipped[str(mid)] = f'bigger than {limit} MB'
            elif (src / 'media' / m['file']).is_file():
                shutil.copyfile(src / 'media' / m['file'], dst / 'media' / m['file'])
                state['files'].append(m['file'])
                done.add(mid)
    excluded = sorted(excluded)
    (dst / 'state.json').write_text(json.dumps({**state, 'skipped': skipped, 'failed': {}, 'excluded': excluded,
                                                'done': sorted(done), 'pending': []}))
    (dst / 'chat.json').write_text(json.dumps({'id': cid, 'title': chat['title'], 'kind': chat['type'].lower(),
                                               'username': chat.get('username'), 'about': 'About text'}))
    done = state['sent'] >= len(lines)
    return False, json.dumps({'chat_id': cid, 'title': chat['title'], 'kind': chat['type'].lower(), 'dir': str(dst),
                              'new_messages': len(new), 'messages_total': state['sent'], 'history_complete': done,
                              'media_pending': 0, 'media_done': len(state['files']), 'media_skipped': len(skipped),
                              'media_failed': 0,
                              'media_excluded': len(excluded), 'refetched': len(refetched),
                              'bytes': 123, 'done': done, 'next': None})


def notion(path, body):
    pages = json.loads(Path(os.environ['FAKE_NOTION']).read_text())
    with open(os.environ['FAKE_LOG'], 'a') as fh:
        fh.write(json.dumps({'notion': path.rsplit('/', 1)[1], 'body': body}) + '\n')
    if path.endswith('/loadPageChunk'):
        chunks = pages.get(body['pageId']) or [{}]
        n = body.get('chunkNumber', 0)
        more = n + 1 < len(chunks)
        return {'recordMap': chunks[min(n, len(chunks) - 1)],
                'cursor': {'stack': [[{'table': 'block', 'id': body['pageId'], 'index': n}]] if more else []}}
    if path.endswith('/queryCollection'):
        rows = pages.get('rows', {}).get(body['collection']['id'], {})
        return {'result': {'reducerResults': {'collection_group_results': {'blockIds': list(rows)}}},
                'recordMap': {'block': rows}}
    return {}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, data, ctype):
        self.send_response(200)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.startswith('/notion/image/'):
            return self.reply(Path(os.environ['FAKE_NOTION_IMAGE']).read_bytes(), 'image/png')
        if self.path == '/web/article':         # an article page of a blog: chrome around an <article>
            return self.reply(('<html><head><title>Стаття про гроші</title></head><body><nav>меню меню</nav><article>'
                               '<h1>Гроші</h1><p>Перший абзац статті про <b>гроші</b> і заощадження. ' + 'Текст. ' * 40 +
                               '</p><ul><li>пункт один</li></ul></article><footer>підвал</footer></body></html>').encode(),
                              'text/html; charset=utf-8')
        if self.path == '/files/guide.pdf':
            return self.reply(b'%PDF-1.4 fake guide', 'application/pdf')
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        if self.path.startswith('/notion/api/v3/'):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            return self.reply(json.dumps(notion(self.path, body)).encode(), 'application/json')
        if self.headers.get('Authorization') != f'Bearer {TOKEN}':
            self.send_response(401)
            self.end_headers()
            return
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        method = body.get('method')
        if method == 'notifications/initialized':
            self.send_response(202)
            self.end_headers()
            return
        if method == 'initialize':
            res = {'protocolVersion': '2025-06-18', 'capabilities': {}, 'serverInfo': {'name': 'fake', 'version': '1'}}
        elif method == 'tools/call':
            name, args = body['params']['name'], body['params']['arguments']
            with open(os.environ['FAKE_LOG'], 'a') as fh:
                fh.write(json.dumps({'tool': name, 'args': args, 'session': self.headers.get('mcp-session-id')}) + '\n')
            if name == 'list_chats':
                err, text = False, json.dumps({'results': json.loads(os.environ['FAKE_CHATS'])})
            elif name == 'export_history':
                flag = Path(os.environ['FAKE_LOG']).with_name('http503')
                if flag.exists():           # the service restarts (a chat was connected): the gateway answers 503
                    flag.unlink()
                    self.send_response(503)
                    self.end_headers()
                    return
                err, text = export_history(args)
            else:
                err, text = True, f'Unknown tool: {name}'
            res = {'content': [{'type': 'text', 'text': text}], 'isError': err}
        else:
            res = {}
        data = ('event: message\ndata: ' + json.dumps({'jsonrpc': '2.0', 'id': body.get('id'), 'result': res}) + '\n\n').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('mcp-session-id', 'sess-1')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


srv = ThreadingHTTPServer(('127.0.0.1', 0), H)
Path(PORTFILE).write_text(str(srv.server_address[1]))
srv.serve_forever()
