#!/usr/bin/env python3
"""HTTP client test of a running gateway: test_gateway_client.py BASE_URL TOKEN. Prints `ok NAME` / `FAIL NAME`."""
import asyncio
import sys
import urllib.error
import urllib.request

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

base, token = sys.argv[1:3]
results = []


def check(name, cond):
    results.append(cond)
    print(("ok " if cond else "FAIL ") + name)


def status(url, headers=None, data=None):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method="POST" if data else "GET")
    try:
        return urllib.request.urlopen(req, timeout=5).status
    except urllib.error.HTTPError as e:
        return e.code


async def main():
    init = b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
    hdr = {"content-type": "application/json", "accept": "application/json, text/event-stream"}
    check("no token -> 401", status(f"{base}/fake/mcp", hdr, init) == 401)
    check("wrong token -> 401", status(f"{base}/fake/mcp", {**hdr, "Authorization": "Bearer nope"}, init) == 401)
    check("right token -> 200", status(f"{base}/fake/mcp", {**hdr, "Authorization": f"Bearer {token}"}, init) == 200)
    check("health endpoint answers without a token", status(f"{base}/_healthz") == 200)
    async with streamablehttp_client(f"{base}/fake/mcp", headers={"Authorization": f"Bearer {token}"}) as (r, w, _):
        async with ClientSession(r, w) as s:
            await s.initialize()
            names = sorted(t.name for t in (await s.list_tools()).tools)
            check("toolFilter: only the allowed tool is listed", names == ["read_thing"])
            res = await s.call_tool("read_thing", {})
            check("allowed tool works", not res.isError and "thing" in res.content[0].text)
            for blocked in ("send_message", "delete_thing"):
                try:
                    res = await s.call_tool(blocked, {"text": "x"} if blocked == "send_message" else {})
                    check(f"toolFilter: {blocked} is refused", bool(res.isError) and "SENT" not in str(res.content))
                except Exception as e:  # McpError: tool not found
                    check(f"toolFilter: {blocked} is refused", "not found" in str(e))


asyncio.run(main())
sys.exit(0 if all(results) else 1)
