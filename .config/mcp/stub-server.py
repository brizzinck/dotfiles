#!/usr/bin/env python3
"""Placeholder MCP server for a gateway entry whose real server is switched off (or cannot start).

Usage: stub-server.py NAME "message". It exposes one read-only tool, `status`, that returns the message, so the entry stays
connected in the clients and the agent is told why the real tools are missing and how to enable them.
"""

import sys

from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations

name = sys.argv[1] if len(sys.argv) > 1 else "stub"
message = sys.argv[2] if len(sys.argv) > 2 else "This MCP server is not available."
mcp = FastMCP(name)


@mcp.tool(annotations=ToolAnnotations(readOnlyHint=True, openWorldHint=False))
def status() -> str:
    """Why this server has no tools right now, and how to enable it."""
    return message


if __name__ == "__main__":
    mcp.run(transport="stdio")
