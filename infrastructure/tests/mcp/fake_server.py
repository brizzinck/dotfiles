#!/usr/bin/env python3
"""Fake stdio MCP server for the gateway test: one read tool and two write-ish tools (the gateway toolFilter must hide them)."""
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("fake")


@mcp.tool()
def read_thing() -> str:
    """Read something."""
    return "thing"


@mcp.tool()
def send_message(text: str) -> str:
    """Pretend to send a message."""
    return "SENT " + text


@mcp.tool()
def delete_thing() -> str:
    """Pretend to delete."""
    return "DELETED"


if __name__ == "__main__":
    mcp.run(transport="stdio")
