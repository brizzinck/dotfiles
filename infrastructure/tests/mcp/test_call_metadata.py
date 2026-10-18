"""Offline regression tests for exact call durations and bounded attachments."""
import base64
from datetime import datetime, timezone
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / 'infrastructure/mcp/telegram'))
import call_metadata as calls
from telegram_files import MAX_FILE_BYTES, snapshot_file, validate_attachment

results = []


def check(name, value):
    results.append(bool(value))
    print(('ok ' if value else 'FAIL ') + name)


MessageActionPhoneCall = type('MessageActionPhoneCall', (SimpleNamespace,), {})
Missed = type('PhoneCallDiscardReasonMissed', (), {})
Hangup = type('PhoneCallDiscardReasonHangup', (), {})


def message(call_id, duration=None, reason=None, date='2026-08-31T22:30:00+00:00'):
    return SimpleNamespace(date=datetime.fromisoformat(date),
                           action=MessageActionPhoneCall(call_id=call_id, duration=duration, reason=reason, video=False))


records = [message(1, 3600, Hangup()), message(1, 1000, Hangup()), message(2, reason=Missed()),
           message(3), message(4, 0), SimpleNamespace(action=None)]
out = calls.summarize_calls(records, 'Europe/Kyiv')
check('calls: duplicate call ID is counted once with longest recorded duration', out['calls'] == 4
      and out['duration_seconds'] == 3600 and out['hours'] == 1)
check('calls: missing duration, missed calls and zero duration are distinct',
      out['with_duration'] == 2 and out['missed_or_busy'] == 1 and out['unknown_duration'] == 1)
check('calls: monthly buckets use the requested timezone', out['monthly'][0]['month'] == '2026-09')
check('calls: partial result is explicitly marked', calls.summarize_calls(records, complete=False)['complete'] is False)
check('calls: invalid negative duration is unknown', calls.call_info(message(1, -1))['duration_seconds'] is None)

with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / 'chart.png'
    path.write_bytes(b'original bytes')
    attachment = snapshot_file(str(path))
    path.write_bytes(b'changed')
    check('attachment: bytes are fixed before confirmation', validate_attachment(attachment) == b'original bytes')
    for name, values in [('corrupt base64', {'data': 'bad!'}), ('path traversal', {'name': '../chart.png'}),
                         ('control in filename', {'name': 'bad\nname'}), ('wrong digest', {'sha256': '0' * 64}),
                         ('too large', {'size': MAX_FILE_BYTES + 1}), ('boolean size', {'size': True})]:
        try:
            validate_attachment({**attachment, **values})
        except ValueError:
            check('attachment: rejects ' + name, True)
        else:
            check('attachment: rejects ' + name, False)
    fifo = Path(tmp) / 'fifo'
    os.mkfifo(fifo)
    try:
        snapshot_file(str(fifo))
    except ValueError:
        check('attachment: FIFO rejected without blocking', True)
    else:
        check('attachment: FIFO rejected without blocking', False)

sys.exit(0 if all(results) else 1)
