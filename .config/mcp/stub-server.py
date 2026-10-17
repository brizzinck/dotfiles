#!/usr/bin/env python3
"""Placeholder MCP server for a gateway entry whose real server is switched off (or cannot start).

Usage: stub-server.py NAME "message". It exposes one read-only tool, `status`, that returns the message, so the entry stays
connected in the clients and the agent is told why the real tools are missing and how to enable them.

Standard library only (run as `python3 -I -S`): the FastMCP version of this file cost about 45 MB of resident memory for an
answer that never changes, this one about 9 MB. It speaks MCP's stdio transport (one JSON-RPC message per line) and answers
exactly what the FastMCP stub answered: initialize (protocol version negotiated), ping, tools/list, tools/call for `status`
(an unknown tool is an error result), empty prompts / resources lists, -32601 for any other method.
"""

import json
import sys

NAME = sys.argv[1] if len(sys.argv) > 1 else "stub"
MESSAGE = sys.argv[2] if len(sys.argv) > 2 else "This MCP server is not available."
VERSIONS = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
DESCRIPTION = "Why this server has no tools right now, and how to enable it."

TOOL = {
    "name": "status",
    "description": DESCRIPTION,
    "inputSchema": {"properties": {}, "title": "statusArguments", "type": "object"},
    "outputSchema": {
        "properties": {"result": {"title": "Result", "type": "string"}},
        "required": ["result"],
        "title": "statusOutput",
        "type": "object",
    },
    "annotations": {"readOnlyHint": True, "openWorldHint": False},
}


def handle(method, params):
    """Return (result, error) for one request; a notification never reaches here."""
    if method == "initialize":
        want = params.get("protocolVersion") if isinstance(params, dict) else None
        return {
            "protocolVersion": want if want in VERSIONS else VERSIONS[-1],
            "capabilities": {
                "experimental": {},
                "prompts": {"listChanged": False},
                "resources": {"subscribe": False, "listChanged": False},
                "tools": {"listChanged": False},
            },
            "serverInfo": {"name": NAME, "version": "1.0.0"},
        }, None
    if method == "ping":
        return {}, None
    if method == "tools/list":
        return {"tools": [TOOL]}, None
    if method == "tools/call":
        tool = params.get("name") if isinstance(params, dict) else None
        if tool != "status":
            return {"content": [{"type": "text", "text": f"Unknown tool: {tool}"}], "isError": True}, None
        return {"content": [{"type": "text", "text": MESSAGE}], "structuredContent": {"result": MESSAGE}, "isError": False}, None
    if method == "prompts/list":
        return {"prompts": []}, None
    if method == "resources/list":
        return {"resources": []}, None
    if method == "resources/templates/list":
        return {"resourceTemplates": []}, None
    return None, {"code": -32601, "message": f"Method not found: {method}"}


def main():
    out = sys.stdout
    while True:
        line = sys.stdin.readline()
        if not line:
            return
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            reply = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}
        else:
            if not isinstance(msg, dict) or "method" not in msg or "id" not in msg:
                continue  # a notification (notifications/initialized, cancelled, ...), or a response we never asked for
            result, error = handle(msg["method"], msg.get("params"))
            reply = {"jsonrpc": "2.0", "id": msg["id"]}
            if error is not None:
                reply["error"] = error
            else:
                reply["result"] = result
        out.write(json.dumps(reply, separators=(",", ":")) + "\n")
        out.flush()


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, BrokenPipeError):
        pass
