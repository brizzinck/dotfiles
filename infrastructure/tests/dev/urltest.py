"""DEV-d: db URL building, config generation and docker resolution against the fake docker. Loads `db` as a module (nothing runs on
import) and calls its functions with fake secret values; prints `ok` / `FAIL` lines like the other python harnesses.
usage: urltest.py DB ROOT        (env of run.sh: FAKE_DIR, ENVS_TOOL_PATH with the fakes, scratch XDG dirs)"""
import http.server
import importlib.machinery
import importlib.util
import os
import socket
import sys
import threading
import tomllib
from urllib.parse import quote, unquote, urlsplit

DBPATH, ROOT = sys.argv[1], sys.argv[2]
loader = importlib.machinery.SourceFileLoader("db_mod", DBPATH)
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("db_mod", loader))
loader.exec_module(m)
fails = 0


def expect(name, cond, extra=""):
    global fails
    print(("ok    " if cond else "FAIL  ") + name + (f"\n      {extra}" if (extra and not cond) else ""))
    fails += not cond


PW = "SECRET-p@ss:w/rd#?%"                       # every URL-significant character

# 2: URL building ------------------------------------------------------------------------------------------------------
c = {"driver": "mariadb", "docker": "mariadb", "database": "app", "user": "app", "password": "DB_PASSWORD"}
url, extra = m.build_url(c, "127.0.0.1", 32768, {"DB_PASSWORD": PW})
expect("2: mariadb URL holds the placeholder, never the password", url == "mysql://app:${pw}@127.0.0.1:32768/app" and PW not in url, url)
final = url.replace("${pw}", extra["DB_PW"])
sp = urlsplit(final)
expect("2: the password `p@ss:w/rd#?%` survives a round trip through urllib parsing",
       unquote(sp.password) == PW and sp.username == "app" and sp.hostname == "127.0.0.1" and sp.port == 32768 and sp.path == "/app",
       final)
c = {"driver": "postgres", "host": "127.0.0.1", "port": 5432, "database": "appdb", "user": "svc", "password": "DB_PASSWORD"}
url, extra = m.build_url(c, "127.0.0.1", 5432, {"DB_PASSWORD": PW})
expect("2: postgres on loopback gets sslmode=disable", url == "postgres://svc:${pw}@127.0.0.1:5432/appdb?sslmode=disable", url)
url, extra = m.build_url({**c, "host": "db.example.com"}, "db.example.com", 5432, {"DB_PASSWORD": PW})
expect("2: postgres on a remote host keeps the driver default", url == "postgres://svc:${pw}@db.example.com:5432/appdb", url)
url, extra = m.build_url({"driver": "clickhouse", "host": "h", "database": "d", "user": "u", "password": "DB_PASSWORD"}, "h", 9000, {"DB_PASSWORD": "x"})
expect("2: clickhouse scheme and native port", url == "clickhouse://u:${pw}@h:9000/d", url)
url, extra = m.build_url({"driver": "mysql", "host": "::1", "user": "u"}, "::1", 3306, {})
expect("2: an IPv6 host is bracketed, no password part without a password", url == "mysql://u@[::1]:3306/", url)
url, extra = m.build_url({"driver": "mysql", "host": "h", "user_secret": "DB_USER", "password": "DB_PASSWORD", "database": "a.b-c$"}, "h", 3306,
                         {"DB_USER": "svc-SECRET-user", "DB_PASSWORD": "x"})
expect("2: user_secret becomes ${usr} (value encoded into DB_USR); the database name is percent-encoded",
       url == "mysql://${usr}:${pw}@h:3306/a.b-c%24" and extra["DB_USR"] == "svc-SECRET-user", url)
URLSECRET = "postgres://svc:SECRET-url-pw@dbhost:5432/appdb?sslmode=require&application_name=SECRET-url-query"
url, extra = m.build_url({"driver": "postgres", "url": "DB_URL"}, None, None, {"DB_URL": URLSECRET})
expect("2: a url secret is split: password and query go to the environment, the rest is the template",
       url == "postgres://svc:${pw}@dbhost:5432/appdb?${q}" and extra == {"DB_PW": "SECRET-url-pw",
                                                                         "DB_QUERY": "sslmode=require&application_name=SECRET-url-query"}, f"{url} {extra}")
url, extra = m.build_url({"driver": "postgres", "url": "DB_URL"}, None, None, {"DB_URL": "postgres://dbhost/appdb"})
expect("2: a url secret without credentials is taken as it is", url == "postgres://dbhost/appdb" and extra == {}, url)
try:
    m.build_url({"driver": "postgres", "url": "DB_URL"}, None, None, {"DB_URL": "not a url"})
    expect("2: a url secret that is not a URL is refused", False)
except m.D.DevError:
    expect("2: a url secret that is not a URL is refused", True)
# tunnel: the ssh forward goes through lazysql's Commands, the URL points at the local port placeholder
c = {"driver": "mysql", "host": "10.0.0.5", "port": 3306, "user": "u", "password": "DB_PASSWORD", "tunnel": "bastion"}
url, extra = m.build_url(c, "10.0.0.5", 3306, {"DB_PASSWORD": "x"})
cb = m.commands_block(c, extra, "10.0.0.5", 3306)
expect("2: tunnel: the URL uses localhost:${port}", url == "mysql://u:${pw}@localhost:${port}/", url)
expect("2: tunnel: Commands carry the ssh forward and WaitForPort (no secret in them)",
       "ssh -N -o ExitOnForwardFailure=yes -o BatchMode=yes -L ${port}:10.0.0.5:3306 bastion" in cb and "WaitForPort" in cb
       and 'printf %s \\"$DB_PW\\"' in cb and "SaveOutputTo" in cb, cb)
# the generated config parses as TOML and holds placeholders only
cfg = m.lazysql_config("main (dev)", {"driver": "mariadb", "database": "app"}, "mysql://app:${pw}@127.0.0.1:32768/app", {"DB_PW": "x"},
                       "127.0.0.1", 32768, True)
doc = tomllib.loads(cfg)
dbs = doc["database"][0]
expect("2: the lazysql config is valid TOML: provider, DBName, URL placeholder, ReadOnly, the printf command",
       dbs["Provider"] == "mysql" and dbs["DBName"] == "app" and dbs["URL"] == "mysql://app:${pw}@127.0.0.1:32768/app" and dbs["ReadOnly"] is True
       and dbs["Commands"] == [{"Command": 'printf %s "$DB_PW"', "SaveOutputTo": "pw"}] and doc["application"]["DisableUpdateCheck"] is True, cfg)
cfg = m.lazysql_config("lite (dev)", {"driver": "sqlite"}, None, {}, None, None, False, "/tmp/x y/app.sqlite")
expect("2: sqlite: Provider sqlite3 and the absolute path as URL", tomllib.loads(cfg)["database"][0]["Provider"] == "sqlite3"
       and tomllib.loads(cfg)["database"][0]["URL"] == "/tmp/x y/app.sqlite")
cfg = m.lazysql_config('na"me', {"driver": "mysql", "database": 'a"b'}, "x", {}, None, None, False)
expect("2: a name with a quote cannot break out of its TOML string", tomllib.loads(cfg)["database"][0]["Name"] == 'na"me')

# 3: docker resolution (fake docker, JSON fixture) ---------------------------------------------------------------------
c = {"driver": "mariadb", "docker": "mariadb"}
expect("3: compose service of THIS root: the ephemeral host port comes from `docker port`",
       m.resolve_endpoint("main", c, ROOT) == ("127.0.0.1", 32768))
expect("3: ... and the same service name of another project (other working_dir, port 41000) is not taken",
       m.resolve_endpoint("main", c, "/somewhere/else") == ("127.0.0.1", 41000))
try:
    m.resolve_endpoint("pgd", {"driver": "postgres", "docker": "pg"}, ROOT)
    expect("3: a stopped container stops the open with a message", False)
except m.D.DevError as e:
    expect("3: a stopped container stops the open with the compose command (never started by itself)",
           "exited" in e.msg and "docker compose --project-directory" in e.msg and "up -d pg" in e.msg, e.msg)
try:
    m.resolve_endpoint("x", {"driver": "mysql", "docker": "nothere"}, ROOT)
    expect("3: an unknown service is an error", False)
except m.D.DevError as e:
    expect("3: an unknown service is an error naming it", "nothere" in e.msg, e.msg)
expect("3: container = NAME with the default native ClickHouse port",
       m.resolve_endpoint("ch", {"driver": "clickhouse", "container": "td-clickhouse"}, None) == ("127.0.0.1", 19000))
try:
    m.resolve_endpoint("x", {"driver": "mysql", "container": "plain-nginx"}, None)
    expect("3: a running container without that published port is an error", False)
except m.D.DevError as e:
    expect("3: a running container without that published port is an error", "not published" in e.msg, e.msg)
expect("3: host + port as written, default port per driver", m.resolve_endpoint("h", {"driver": "postgres", "host": "h"}, None) == ("h", 5432))


class Ping(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"Ok.\n" if self.path == "/ping" else b"nope"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = http.server.HTTPServer(("127.0.0.1", 0), Ping)
threading.Thread(target=srv.serve_forever, daemon=True).start()
raw = socket.socket()
raw.bind(("127.0.0.1", 0))
raw.listen(1)
threading.Thread(target=lambda: [raw.accept()[0].sendall(b"\x00\x01garbage") for _ in range(3)], daemon=True).start()
expect("3: ClickHouse HTTP port (GET /ping answers Ok.) is recognised", m.clickhouse_is_http("127.0.0.1", srv.server_address[1]) is True)
expect("3: a native-protocol port (no HTTP answer) is not", m.clickhouse_is_http("127.0.0.1", raw.getsockname()[1]) is False)
expect("3: a closed port is not", m.clickhouse_is_http("127.0.0.1", 1) is False)
print(f"PORTS http={srv.server_address[1]}")
sys.exit(1 if fails else 0)
