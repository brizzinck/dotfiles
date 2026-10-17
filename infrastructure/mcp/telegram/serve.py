#!/usr/bin/env python3
"""Entry point of the telegram-mcp service (runs as the service user aimcp, started by `run`).

It wraps chigwell/telegram-mcp (source checkout in /opt/telegram-mcp/src, deps in /opt/telegram-mcp/venv) with three guards the
upstream HTTP mode does not have:

  1. fail closed before anything connects: the server must be in read-only mode and the chat allowlist must be non-empty
     (upstream treats an EMPTY allowlist as "every chat is allowed");
  2. a bearer token on every HTTP request (TELEGRAM_MCP_TOKEN, a credential shared only with the gateway user), so another
     local user or a browser page cannot talk to 127.0.0.1:8765 directly;
  3. a startup report on stderr: which tools are exposed, how many chats are allowed (never their ids or any secret).

Everything else (session string, api id/hash, allowlist, read-only mode, transcription engine) comes from the environment that
`run` built from the systemd credentials. Test hooks: TELEGRAM_MCP_SRC.
"""

from __future__ import annotations

import hmac
import os
import sys

SRC = os.environ.get("TELEGRAM_MCP_SRC", "/opt/telegram-mcp/src")


def check_env(env=os.environ) -> list[str]:
    """Problems that must stop the service from starting (empty list = fine)."""
    problems = []
    mode = env.get("TELEGRAM_EXPOSED_TOOLS", "").strip().lower()
    if mode != "read-only":
        problems.append(f"TELEGRAM_EXPOSED_TOOLS must be exactly 'read-only' (got {mode!r}): no write tool may be registered")
    allow = [t for t in env.get("TELEGRAM_ALLOWED_CHAT_IDS", "").replace(" ", "").split(",") if t]
    if not allow:
        problems.append("TELEGRAM_ALLOWED_CHAT_IDS is empty: upstream would allow every chat, refusing to start")
    if not env.get("TELEGRAM_MCP_TOKEN"):
        problems.append("TELEGRAM_MCP_TOKEN is empty: the HTTP endpoint would be unauthenticated")
    if env.get("MCP_TRANSPORT", "").lower() != "http":
        problems.append("MCP_TRANSPORT must be http")
    if env.get("MCP_HOST", "127.0.0.1") not in ("127.0.0.1", "localhost", "::1"):
        problems.append("MCP_HOST must be a loopback address")
    return problems


class BearerAuth:
    """Pure ASGI middleware: 401 unless `Authorization: Bearer <token>` matches (constant-time compare)."""

    def __init__(self, app, token: str):
        self.app = app
        self.token = token.encode()

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            supplied = b""
            for k, v in scope.get("headers", []):
                if k == b"authorization":
                    supplied = v[7:] if v[:7].lower() == b"bearer " else v
                    break
            if not hmac.compare_digest(supplied.strip(), self.token):
                body = b'{"error":"unauthorized"}'
                await send({"type": "http.response.start", "status": 401,
                            "headers": [(b"content-type", b"application/json"), (b"content-length", str(len(body)).encode()),
                                        (b"www-authenticate", b"Bearer")]})
                await send({"type": "http.response.body", "body": body})
                return
        await self.app(scope, receive, send)


def install_auth(server, token: str) -> None:
    """Make every ASGI app the FastMCP server builds go through BearerAuth."""
    original = server.streamable_http_app

    def with_auth(*args, **kwargs):
        # a plain ASGI wrapper: the app FastMCP returns is not always a Starlette instance (mcp 1.30 wraps it in a protocol
        # negotiation middleware), so add_middleware is not available; uvicorn and TestClient take any ASGI callable
        return BearerAuth(original(*args, **kwargs), token)

    server.streamable_http_app = with_auth


def main() -> None:
    problems = check_env()
    if problems:
        for p in problems:
            print(f"telegram-mcp: {p}", file=sys.stderr)
        sys.exit(78)  # EX_CONFIG
    token = os.environ.pop("TELEGRAM_MCP_TOKEN")
    sys.path.insert(0, SRC)
    os.chdir(os.environ.get("TELEGRAM_MCP_WORKDIR", "/var/lib/telegram-mcp"))
    import telegram_mcp.runner as runner  # builds the Telethon clients from the environment, registers the tools
    from telegram_mcp import runtime

    install_auth(runtime.mcp, token)
    print("telegram-mcp: read-only, allowlist of "
          f"{len([t for t in os.environ['TELEGRAM_ALLOWED_CHAT_IDS'].split(',') if t.strip()])} chat(s), bearer auth on", file=sys.stderr)
    runner.main()


if __name__ == "__main__":
    main()
