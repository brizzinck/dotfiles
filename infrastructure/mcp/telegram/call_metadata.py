"""Local, upgrade-safe call metadata extension for the pinned upstream server."""
from collections import defaultdict
from functools import wraps
import json
from typing import Optional, Union
from zoneinfo import ZoneInfo


def call_info(msg):
    action = getattr(msg, 'action', None)
    if type(action).__name__ != 'MessageActionPhoneCall':
        return None
    duration = getattr(action, 'duration', None)
    return dict(id=str(action.call_id),
                duration_seconds=duration if type(duration) is int and duration >= 0 else None,
                reason=type(action.reason).__name__ if getattr(action, 'reason', None) is not None else None,
                video=bool(getattr(action, 'video', False)))


def summarize_calls(messages, timezone='UTC', complete=True):
    """Deduplicate by call ID; an absent duration is unknown, never invented."""
    tz = ZoneInfo(timezone)
    calls = {}
    for msg in messages:
        info = call_info(msg)
        if info is None:
            continue
        previous = calls.get(info['id'])
        if previous is None or (info['duration_seconds'] is not None
                                and (previous[1]['duration_seconds'] is None
                                     or info['duration_seconds'] > previous[1]['duration_seconds'])):
            calls[info['id']] = (msg, info)
    monthly = defaultdict(lambda: dict(calls=0, duration_seconds=0, with_duration=0,
                                      missed_or_busy=0, unknown_duration=0))
    for msg, info in calls.values():
        m = monthly[msg.date.astimezone(tz).strftime('%Y-%m')]
        m['calls'] += 1
        if info['duration_seconds'] is not None:
            m['duration_seconds'] += info['duration_seconds']
            m['with_duration'] += 1
        elif info['reason'] in ('PhoneCallDiscardReasonMissed', 'PhoneCallDiscardReasonBusy'):
            m['missed_or_busy'] += 1
        else:
            m['unknown_duration'] += 1
    totals = {k: sum(m[k] for m in monthly.values()) for k in
              ('calls', 'duration_seconds', 'with_duration', 'missed_or_busy', 'unknown_duration')}
    return dict(**totals, hours=round(totals['duration_seconds'] / 3600, 6),
                complete=complete, timezone=timezone,
                monthly=[dict(month=k, **v) for k, v in sorted(monthly.items())])


def install():
    from telegram_mcp.tools import messages
    from telegram_mcp import runtime as rt
    from mcp.types import ToolAnnotations

    if getattr(messages, '_call_metadata_installed', False):
        return
    original_dict, original_line = messages.message_to_dict, messages.format_message_line

    @wraps(original_dict)
    def as_dict(msg, *args, **kwargs):
        result = original_dict(msg, *args, **kwargs)
        info = call_info(msg)
        if info is not None:
            result['call'] = info
        return result

    @wraps(original_line)
    def as_line(msg, *args, **kwargs):
        result = original_line(msg, *args, **kwargs)
        info = call_info(msg)
        if info is not None:
            result += ' | call: ' + json.dumps(info, ensure_ascii=False)
        return result

    messages.message_to_dict, messages.format_message_line = as_dict, as_line

    @rt.mcp.tool(annotations=ToolAnnotations(title='Get Call Statistics', readOnlyHint=True, openWorldHint=True))
    @rt.with_account(readonly=True)
    @rt.validate_id('chat_id')
    async def get_call_statistics(chat_id: Union[int, str], limit: int = 2000,
                                  offset_id: int = 0, timezone: str = 'UTC',
                                  account: Optional[str] = None) -> str:
        """Sum call durations from a page of the selected read-allowlisted chat.
        limit: 1..3000 messages scanned, newest first. If complete=false, request
        the next page with offset_id=next_offset_id. Totals cover this page only.
        Merge call_records by call ID across pages, keeping the longest recorded
        duration. Missed/busy and unknown durations are separate. No global search.
        """
        if not 1 <= limit <= 3000:
            raise ValueError('limit must be between 1 and 3000 messages')
        if offset_id < 0:
            raise ValueError('offset_id must be non-negative')
        ZoneInfo(timezone)
        cl = rt.get_client(account)
        entity = await rt.resolve_entity(chat_id, cl)
        if rt.is_chat_allowlist_enabled() and not rt.is_chat_allowed(chat_id, entity):
            raise rt.ChatAccessDeniedError(rt.check_chat_access(chat_id, entity))
        # Telegram rejects the phone-call search filter for this peer. Reading
        # bounded pages of this chat also avoids searching any other chat, and
        # explicit wait_time=0 avoids Telethon's delay for large history limits.
        found = [m async for m in cl.iter_messages(entity, limit=limit + 1,
                                                  offset_id=offset_id, wait_time=0)]
        page = found[:limit]
        complete = len(found) <= limit
        out = summarize_calls(page, timezone, complete=complete)
        out.update(scanned_messages=len(page),
                   next_offset_id=page[-1].id if not complete else None,
                   call_records=[dict(message_id=m.id, date=m.date.isoformat(), **call_info(m))
                                 for m in page if call_info(m) is not None])
        return json.dumps(out)

    messages._call_metadata_installed = True
