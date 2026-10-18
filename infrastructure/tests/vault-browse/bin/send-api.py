#!/usr/bin/python3 -IB
"""Fake Send management only. Private payload capture is an assertion channel."""
import base64
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import time

root = Path(os.environ['FAKE_DIR'])
args = sys.argv[1:]
if args == ['config', 'server']:
    print(os.environ.get('FAKE_SEND_SERVER', 'https://send.example'))
    sys.exit(0)
if (root / 'bw-unlocked').exists() is False or os.environ.get('BW_SESSION') != 'SESSION-KEY-abc':
    print('fake vault locked', file=sys.stderr)
    sys.exit(1)
store = root / 'sends.json'
sends = json.loads(store.read_text()) if store.exists() else []
action = args[1]
if action == 'create':
    payload = json.loads(base64.b64decode(sys.stdin.read()))
    (root / 'send-payload.json').write_text(json.dumps(payload))
    ident = '11111111-2222-4333-8444-' + f'{len(sends) + 1:012d}'
    result = dict(payload, id=ident, accessUrl='https://send.example/#accessid/invented-bearer-key',
                  revisionDate=datetime.now(timezone.utc).isoformat(), accessCount=0, passwordSet=False)
    if payload['type'] == 1:
        # Match the actual official CLI precedence, not a permissive fake:
        # req.file.fileName ?? options.file is read, then basename is saved.
        path = Path(payload.get('file', {}).get('fileName') or args[args.index('--file') + 1])
        (root / 'send-file-capture').write_bytes(path.read_bytes())
        result['file'] = {'fileName': path.name}
    scenario = os.environ.get('FAKE_SEND_SCENARIO', '')
    if scenario == 'count':
        result['maxAccessCount'] = None
    if scenario == 'url':
        result['accessUrl'] = 'https://unexpected.example/#invented-poison-url'
    if scenario == 'type':
        result['type'] = 1 - payload['type']
    if scenario == 'deletion':
        result['deletionDate'] = '2099-01-01T00:00:00Z'
    if scenario == 'id':
        result['id'] = 'not-a-uuid-invented-poison'
    sends.append(result)
    store.write_text(json.dumps(sends))
    with (root / 'send-events').open('a') as events:
        events.write('create\n')
    if scenario == 'hang':
        (root / 'send.pid').write_text(str(os.getpid()))
        time.sleep(30)
    if scenario in ('oversized-stdout', 'oversized-stderr'):
        descriptor = 1 if scenario == 'oversized-stdout' else 2
        while True:
            os.write(descriptor, b'invented-poison-response' * 4096)
    if scenario == 'timeout':
        print('invented-poison-stderr', file=sys.stderr)
        sys.exit(1)
    if scenario == 'invalid-json':
        print('invented-poison-stdout')
    elif scenario == 'missing-id':
        print(json.dumps({k: v for k, v in result.items() if k != 'id'}))
    elif scenario == 'missing-echo':
        print(json.dumps({'id': result['id']}))
    else:
        print(json.dumps(result))
elif action == 'get':
    if len(args) != 3:
        raise SystemExit('management get only')
    hit = next((row for row in sends if row['id'] == args[2]), None)
    if hit is None:
        sys.exit(1)
    print(json.dumps(hit))
elif action == 'list':
    print(json.dumps(sends))
else:
    raise SystemExit('recipient endpoints and unsupported commands are forbidden')
