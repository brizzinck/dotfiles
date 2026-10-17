#!/usr/bin/env bash
# shellcheck disable=SC2016
# Offline test of the MCP stack (gateway script, installer, mcp-run, mcp-add, desktop-ro, chrome wrappers, a real gateway
# process with a fake server). Everything runs in a scratch directory with fake binaries (./bin); the owner's Claude/Codex
# configs, Bitwarden, Hyprland and clipboard are never touched (XDG_RUNTIME_DIR points into the scratch directory).
#   run.sh [--quick]   --quick (doctor) skips the pieces that start a real gateway and the real `claude` CLI
# The desktop-ro and gateway parts need the pinned venv and mcp-proxy (mcp-install); without them they print SKIP.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
QUICK=0
[[ ${1:-} == --quick ]] && QUICK=1
GW="$REPO/.local/bin/mcp-gateway"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/mcp-test.XXXXXX")
GWPID=""
cleanup() { [[ -n $GWPID ]] && kill "$GWPID" 2>/dev/null; rm -rf "$SCRATCH"; }
trap cleanup EXIT
export FAKE_DIR="$SCRATCH/fake" MCP_STATE_DIR="$SCRATCH/state" MCP_RUNTIME_DIR="$SCRATCH/run" MCP_CONFIG_DIR="$REPO/.config/mcp"
export XDG_RUNTIME_DIR="$SCRATCH/xdg-run"
mkdir -p "$FAKE_DIR/vault" "$XDG_RUNTIME_DIR"
: >"$FAKE_DIR/argv.log"
PASS=0 FAILS=0 SKIPS=0
check() { # check NAME CMD...
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); else FAILS=$((FAILS + 1)); echo "FAIL: $name"; fi
}
skip() { SKIPS=$((SKIPS + 1)); echo "SKIP: $1"; }
VENV_PY="${MCP_HOME:-$HOME/.local/share/mcp}/venv/bin/python"
PROXY="${MCP_HOME:-$HOME/.local/share/mcp}/bin/mcp-proxy"
count_py() { # run a python test that prints ok/FAIL lines and count them
  local out line
  out=$("$@" 2>&1)
  while IFS= read -r line; do
    case $line in
      "ok "*) PASS=$((PASS + 1)) ;;
      "FAIL "*) FAILS=$((FAILS + 1)); echo "FAIL: ${line#FAIL }" ;;
    esac
  done <<<"$out"
  if ! grep -q '^ok ' <<<"$out"; then FAILS=$((FAILS + 1)); echo "FAIL: python test produced no result"; printf '%s\n' "$out" | tail -5; fi
}

# --- gateway script ------------------------------------------------------------------------------------------------
check "headers without a token fail" bash -c '! "$1" headers' _ "$GW"
check "token ensure creates the file" bash -c '"$1" token ensure >/dev/null && [ -s "$2/gateway.token" ]' _ "$GW" "$MCP_STATE_DIR"
check "token file is mode 600" bash -c '[ "$(stat -c %a "$1/gateway.token")" = 600 ]' _ "$MCP_STATE_DIR"
check "state directory is mode 700" bash -c '[ "$(stat -c %a "$1")" = 700 ]' _ "$MCP_STATE_DIR"
T1=$(<"$MCP_STATE_DIR/gateway.token")
"$GW" token ensure >/dev/null
check "token ensure is idempotent" bash -c '[ "$(cat "$1/gateway.token")" = "$2" ]' _ "$MCP_STATE_DIR" "$T1"
check "token is long and URL-safe" bash -c '[[ $1 =~ ^[A-Za-z0-9_-]{40,}$ ]]' _ "$T1"
check "headers print a Bearer JSON object" bash -c '"$1" headers | jq -e ".Authorization == \"Bearer $2\""' _ "$GW" "$T1"
check "mcp-gateway-headers is the same" bash -c '[ "$("$1")" = "$("$2" headers)" ]' _ "$REPO/.local/bin/mcp-gateway-headers" "$GW"
check "gateway.json is valid JSON with a 127.0.0.1 bind" jq -e '.mcpProxy.addr | startswith("127.0.0.1:")' "$MCP_CONFIG_DIR/gateway.json"
check "gateway.json holds no literal token" bash -c '! grep -E "authTokens\": \[\"[A-Za-z0-9]{20,}" "$1"' _ "$MCP_CONFIG_DIR/gateway.json"
check "telegram absent without its token" bash -c '! "$1" servers | grep -qx telegram' _ "$GW"
check "desktop-ro and the chrome pair are served" bash -c 's=$("$1" servers); grep -qx desktop-ro <<<"$s" && grep -qx chrome-devtools <<<"$s" && grep -qx chrome-devtools-mine <<<"$s" && grep -qx context7 <<<"$s"' _ "$GW"
check "url for an unknown server fails" bash -c '! "$1" url telegram' _ "$GW"
echo "tg-token" >"$MCP_STATE_DIR/telegram.token"
check "telegram appears once its token exists" bash -c '"$1" servers | grep -qx telegram' _ "$GW"
check "url shape" bash -c '[ "$("$1" url telegram)" = "http://127.0.0.1:37411/telegram/mcp" ]' _ "$GW"
rm -f "$MCP_STATE_DIR/telegram.token"
check "no toolFilter lists a send/edit/delete tool for telegram" bash -c '! jq -r ".mcpServers.telegram.options.toolFilter.list[]" "$1" | grep -E "^(send|reply|edit|delete|forward|mark|save|upload|download|press|join|leave|invite|ban|pin|set_|create|update|promote|demote|add_|remove|block|mute|archive|import|export)"' _ "$MCP_CONFIG_DIR/gateway.json"
check "telegram toolFilter is an allow list" jq -e '.mcpServers.telegram.options.toolFilter.mode == "allow"' "$MCP_CONFIG_DIR/gateway.json"

# `run` with a fake mcp-proxy: the token reaches it through the environment only
cat >"$SCRATCH/fake-proxy" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [[ $a == -check-config ]] && exit 0; done
printf '%s\n' "$@" >"$FAKE_DIR/proxy-argv"
printf '%s' "${MCP_GATEWAY_TOKEN:-}" >"$FAKE_DIR/proxy-env-token"
printf '%s' "${MCP_TELEGRAM_TOKEN:-}" >"$FAKE_DIR/proxy-env-tg"
cp "$2" "$FAKE_DIR/proxy-config" 2>/dev/null
EOF
chmod +x "$SCRATCH/fake-proxy"
MCP_PROXY_BIN="$SCRATCH/fake-proxy" "$GW" run
check "run passes the token in the environment" bash -c '[ "$(cat "$1/proxy-env-token")" = "$2" ]' _ "$FAKE_DIR" "$T1"
check "run never puts the token on argv" bash -c '! grep -q "$2" "$1/proxy-argv"' _ "$FAKE_DIR" "$T1"
check "effective config has the placeholder, not the token" bash -c '! grep -q "$2" "$1/proxy-config" && grep -q "MCP_GATEWAY_TOKEN" "$1/proxy-config"' _ "$FAKE_DIR" "$T1"
check "effective config is on tmpfs-style runtime dir, mode 600" bash -c '[ "$(stat -c %a "$1/config.json")" = 600 ]' _ "$MCP_RUNTIME_DIR"
check "effective config drops telegram without a token" bash -c '! jq -e ".mcpServers.telegram" "$1" >/dev/null' _ "$FAKE_DIR/proxy-config"
echo "tg-token" >"$MCP_STATE_DIR/telegram.token"
MCP_PROXY_BIN="$SCRATCH/fake-proxy" "$GW" run
check "telegram token reaches the proxy environment" bash -c '[ "$(cat "$1/proxy-env-tg")" = tg-token ]' _ "$FAKE_DIR"
check "telegram stays in the effective config" jq -e '.mcpServers.telegram' "$FAKE_DIR/proxy-config"
rm -f "$MCP_STATE_DIR/telegram.token"

# --- installer: checksum gate --------------------------------------------------------------------------------------
case $(uname -m) in x86_64) ARCH=amd64 ;; aarch64) ARCH=arm64 ;; *) ARCH="" ;; esac
if [[ -n $ARCH ]]; then
  CFG="$SCRATCH/cfg"; cp -r "$REPO/.config/mcp" "$CFG"
  REL="$SCRATCH/rel/v9.9.9"; mkdir -p "$REL" "$SCRATCH/tarsrc"
  printf '#!/bin/sh\necho fake-proxy\n' >"$SCRATCH/tarsrc/mcp-proxy"; chmod +x "$SCRATCH/tarsrc/mcp-proxy"
  tar -czf "$REL/mcp-proxy_9.9.9_linux_$ARCH.tar.gz" -C "$SCRATCH/tarsrc" mcp-proxy
  GOOD=$(sha256sum "$REL/mcp-proxy_9.9.9_linux_$ARCH.tar.gz" | cut -d' ' -f1)
  sed -i -e 's/^MCP_PROXY_VERSION=.*/MCP_PROXY_VERSION=9.9.9/' -e "s/^MCP_PROXY_SHA256_linux_$ARCH=.*/MCP_PROXY_SHA256_linux_$ARCH=$GOOD/" "$CFG/pins.env"
  export MCP_PROXY_URL_BASE="file://$SCRATCH/rel"
  check "installer --check fails on an empty home" bash -c '! MCP_CONFIG_DIR="$2" MCP_HOME="$3" "$1" --check --only proxy' _ "$REPO/.local/bin/mcp-install" "$CFG" "$SCRATCH/mh1"
  check "installer installs a tarball with the pinned sha256" bash -c 'MCP_CONFIG_DIR="$2" MCP_HOME="$3" "$1" --only proxy && [ "$("$3/bin/mcp-proxy")" = fake-proxy ] && [ "$(cat "$3/bin/.version")" = 9.9.9 ]' _ "$REPO/.local/bin/mcp-install" "$CFG" "$SCRATCH/mh1"
  check "installer --check passes afterwards" bash -c 'MCP_CONFIG_DIR="$2" MCP_HOME="$3" "$1" --check --only proxy' _ "$REPO/.local/bin/mcp-install" "$CFG" "$SCRATCH/mh1"
  sed -i "s/^MCP_PROXY_SHA256_linux_$ARCH=.*/MCP_PROXY_SHA256_linux_$ARCH=0000000000000000000000000000000000000000000000000000000000000000/" "$CFG/pins.env"
  check "installer refuses a checksum mismatch and installs nothing" bash -c 'out=$(MCP_CONFIG_DIR="$2" MCP_HOME="$3" "$1" --only proxy 2>&1); rc=$?; [ $rc -ne 0 ] && grep -q "CHECKSUM MISMATCH" <<<"$out" && [ ! -e "$3/bin/mcp-proxy" ]' _ "$REPO/.local/bin/mcp-install" "$CFG" "$SCRATCH/mh2"
  unset MCP_PROXY_URL_BASE
fi
check "pins.env pins a version and a sha256 per arch" bash -c '. "$1/pins.env"; [ -n "$MCP_PROXY_VERSION" ] && [[ $MCP_PROXY_SHA256_linux_amd64 =~ ^[0-9a-f]{64}$ ]] && [[ $MCP_PROXY_SHA256_linux_arm64 =~ ^[0-9a-f]{64}$ ]]' _ "$MCP_CONFIG_DIR"
check "desktop-ro requirements are hash-pinned" bash -c '! grep -E "^[A-Za-z0-9_.-]+==" "$1" | grep -v "\\\\$" | grep -q . ; grep -q -- "--hash=sha256:" "$1"' _ "$MCP_CONFIG_DIR/requirements-desktop-ro.txt"
check "node lockfile pins chrome-devtools-mcp with an integrity hash" jq -e '.packages["node_modules/chrome-devtools-mcp"].integrity | startswith("sha512-")' "$MCP_CONFIG_DIR/node/package-lock.json"

# --- mcp-run (fake rbw) --------------------------------------------------------------------------------------------
RUNCFG="$SCRATCH/runcfg"; mkdir -p "$RUNCFG"
cat >"$RUNCFG/stdio.json" <<EOF
{"servers": {"demo": {"command": "bash", "args": ["-c", "printf '%s|%s|%s' \"\$MY_TOKEN\" \"\$PLAIN\" \"\$*\" >\"\${OUT_FILE}\"", "x"],
  "env": {"PLAIN": "visible"}, "secrets": {"MY_TOKEN": {"item": "demo-item", "field": "api_hash"}}}}}
EOF
printf 'S3CRET-VALUE\n' >"$FAKE_DIR/vault/MCP__demo-item__api_hash"
export OUT_FILE="$SCRATCH/mcp-run.out"
: >"$FAKE_DIR/argv.log"
MCP_CONFIG_DIR="$RUNCFG" MCP_RBW="$HERE/bin/rbw" "$REPO/.local/bin/mcp-run" demo -- extra
check "mcp-run injects the secret into the child environment" bash -c '[ "$(cat "$1")" = "S3CRET-VALUE|visible|extra" ]' _ "$OUT_FILE"
check "mcp-run asks rbw for folder MCP and the field" grep -qx 'rbw get --folder MCP --field api_hash demo-item' "$FAKE_DIR/argv.log"
check "the secret is not in any argv log" bash -c '! grep -q S3CRET "$1"' _ "$FAKE_DIR/argv.log"
check "mcp-run --dry-run shows names only" bash -c 'out=$(MCP_CONFIG_DIR="$1" MCP_RBW="$2" "$3" --dry-run demo); grep -q "MY_TOKEN <- MCP/demo-item field api_hash" <<<"$out" && ! grep -q S3CRET <<<"$out"' _ "$RUNCFG" "$HERE/bin/rbw" "$REPO/.local/bin/mcp-run"
check "mcp-run reports a missing vault item without a traceback" bash -c 'rm -f "$1/vault/MCP__demo-item__api_hash"; out=$(MCP_CONFIG_DIR="$2" MCP_RBW="$3" "$4" demo 2>&1); rc=$?; [ $rc -ne 0 ] && grep -q "cannot read MCP/demo-item" <<<"$out" && ! grep -q Traceback <<<"$out"' _ "$FAKE_DIR" "$RUNCFG" "$HERE/bin/rbw" "$REPO/.local/bin/mcp-run"
check "mcp-run refuses an unknown server" bash -c '! MCP_CONFIG_DIR="$1" "$2" nope' _ "$RUNCFG" "$REPO/.local/bin/mcp-run"
check "the shipped stdio.json is valid" jq -e '.servers | type == "object"' "$MCP_CONFIG_DIR/stdio.json"

# --- chrome wrappers -----------------------------------------------------------------------------------------------
CH="$REPO/.local/bin/mcp-chrome-devtools"
cat >"$SCRATCH/fake-cdt" <<'EOF'
#!/usr/bin/env bash
printf 'cdt %s\n' "$*"
EOF
cat >"$SCRATCH/fake-py" <<'EOF'
#!/usr/bin/env bash
printf 'stub %s\n' "$*"
EOF
chmod +x "$SCRATCH/fake-cdt" "$SCRATCH/fake-py"
cat >"$SCRATCH/chromium" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$SCRATCH/chromium"
cdt() { MCP_CHROME_DEVTOOLS_BIN="$SCRATCH/fake-cdt" MCP_STUB_PYTHON="$SCRATCH/fake-py" MCP_CHROMIUM="${CHROMIUM:-$SCRATCH/chromium}" "$CH" "$@"; }
check "clean: isolated headless automation Chromium, telemetry off" bash -c 'out=$(MCP_CHROME_DEVTOOLS_BIN="$2" MCP_STUB_PYTHON="$3" MCP_CHROMIUM="$4" "$1" clean); grep -q -- "--isolated" <<<"$out" && grep -q -- "--headless" <<<"$out" && grep -q -- "--executablePath $4" <<<"$out" && grep -q -- "--no-usage-statistics" <<<"$out"' _ "$CH" "$SCRATCH/fake-cdt" "$SCRATCH/fake-py" "$SCRATCH/chromium"
check "clean: never uses the owner's profile" bash -c '! MCP_CHROME_DEVTOOLS_BIN="$2" MCP_STUB_PYTHON="$3" MCP_CHROMIUM="$4" "$1" clean | grep -q -E "autoConnect|google-chrome|userDataDir"' _ "$CH" "$SCRATCH/fake-cdt" "$SCRATCH/fake-py" "$SCRATCH/chromium"
check "clean: MCP_CHROME_HEADED=1 drops --headless" bash -c '! MCP_CHROME_HEADED=1 MCP_CHROME_DEVTOOLS_BIN="$2" MCP_STUB_PYTHON="$3" MCP_CHROMIUM="$4" "$1" clean | grep -q -- "--headless"' _ "$CH" "$SCRATCH/fake-cdt" "$SCRATCH/fake-py" "$SCRATCH/chromium"
check "clean: without Chromium a stub explains how to install it" bash -c 'out=$(MCP_CHROME_DEVTOOLS_BIN="$2" MCP_STUB_PYTHON="$3" MCP_CHROMIUM=/nonexistent "$1" clean); grep -q "^stub" <<<"$out" && grep -q "apply-system.sh --only mcp" <<<"$out"' _ "$CH" "$SCRATCH/fake-cdt" "$SCRATCH/fake-py"
check "mine: OFF by default -> stub, no autoConnect" bash -c 'out=$(MCP_STATE_DIR="$5" MCP_CHROME_DEVTOOLS_BIN="$2" MCP_STUB_PYTHON="$3" "$1" mine); grep -q "^stub" <<<"$out" && ! grep -q autoConnect <<<"$out"' _ "$CH" "$SCRATCH/fake-cdt" "$SCRATCH/fake-py" x "$SCRATCH/state"
check "mine: ON -> --autoConnect with the owner's Chrome profile" bash -c 'mkdir -p "$5"; touch "$5/chrome-mine.enabled"; out=$(MCP_STATE_DIR="$5" MCP_CHROME_DEVTOOLS_BIN="$2" MCP_STUB_PYTHON="$3" "$1" mine); grep -q -- "--autoConnect" <<<"$out" && grep -q "com.google.Chrome" <<<"$out"; rc=$?; rm -f "$5/chrome-mine.enabled"; exit $rc' _ "$CH" "$SCRATCH/fake-cdt" "$SCRATCH/fake-py" x "$SCRATCH/state"
MC="$REPO/.local/bin/mcp-chrome"
export MCP_CHROME_NO_RESTART=1 MCP_CHROME_NO_TIMER=1
check "mcp-chrome status is OFF (exit 1) by default" bash -c '! "$1" mine status' _ "$MC"
check "mcp-chrome mine on sets the flag" bash -c '"$1" mine on --ttl 5 >/dev/null && [ -e "$2/chrome-mine.enabled" ] && "$1" mine status >/dev/null' _ "$MC" "$MCP_STATE_DIR"
check "mcp-chrome mine off clears it" bash -c '"$1" mine off >/dev/null && [ ! -e "$2/chrome-mine.enabled" ]' _ "$MC" "$MCP_STATE_DIR"
check "mcp-chrome toggle flips" bash -c '"$1" mine toggle >/dev/null; "$1" mine status >/dev/null && "$1" mine toggle >/dev/null; ! "$1" mine status >/dev/null' _ "$MC"
check "mcp-chrome rejects a bad ttl" bash -c '! "$1" mine on --ttl abc' _ "$MC"
unset MCP_CHROME_NO_RESTART MCP_CHROME_NO_TIMER

# --- mcp-add against throwaway Claude / Codex homes ----------------------------------------------------------------
cat >"$SCRATCH/fake-gw" <<'EOF'
#!/usr/bin/env bash
case $1 in
  servers) printf 'desktop-ro\nchrome-devtools\ncontext7\n' ;;
  url) printf 'http://127.0.0.1:37411/%s/mcp\n' "$2" ;;
esac
EOF
chmod +x "$SCRATCH/fake-gw"
ADDCFG="$SCRATCH/addcfg"; mkdir -p "$ADDCFG"
printf '{"servers": {"demo": {"command": "true", "args": []}}}\n' >"$ADDCFG/stdio.json"
CODEX_DIR="$SCRATCH/codex-home"; mkdir -p "$CODEX_DIR"
cat >"$CODEX_DIR/config.toml" <<'EOF'
model = "gpt-test"   # keep this comment
approval_policy = "never"

[mcp_servers.mcphub]
command = "/x/mcp-remote"
args = ["http://localhost:37373/mcp", "--transport", "sse-only"]
startup_timeout_sec = 30.0

[mcp_servers.http-toolkit]
command = "/opt/httptoolkit/resources/httptoolkit-mcp"

[marketplaces.codex-hud]
source_type = "git"
ref = "v0.9.8"
EOF
ADD="$REPO/.local/bin/mcp-add"
export MCP_GATEWAY_CMD="$SCRATCH/fake-gw" CODEX_HOME="$CODEX_DIR"
CLAUDE_BIN=$(command -v claude || true)
if [[ $QUICK -eq 0 && -n $CLAUDE_BIN ]]; then
  export CLAUDE_CONFIG_DIR="$SCRATCH/claude-home"; mkdir -p "$CLAUDE_CONFIG_DIR"
  claude mcp add -s user --transport http mcphub http://localhost:37373/mcp >/dev/null 2>&1
  claude mcp add -s user chrome-devtools -- /x/chrome-devtools-mcp --autoConnect >/dev/null 2>&1
  claude mcp add -s user keepme -- /bin/true >/dev/null 2>&1
  CJ="$CLAUDE_CONFIG_DIR/.claude.json"
  cp "$CJ" "$SCRATCH/claude-before.json"; cp "$CODEX_DIR/config.toml" "$SCRATCH/codex-before.toml"
  MCP_CONFIG_DIR="$ADDCFG" "$ADD" --dry-run >"$SCRATCH/add-dry.out" 2>&1
  check "mcp-add --dry-run changes nothing" bash -c 'cmp -s "$1" "$2" && cmp -s "$3" "$4"' _ "$CJ" "$SCRATCH/claude-before.json" "$CODEX_DIR/config.toml" "$SCRATCH/codex-before.toml"
  check "mcp-add --dry-run lists the steps" grep -q 'claude: remove legacy entry mcphub' "$SCRATCH/add-dry.out"
  MCP_CONFIG_DIR="$ADDCFG" "$ADD" >"$SCRATCH/add.out" 2>&1
  check "mcp-add exits 0" grep -q '^done\.' "$SCRATCH/add.out"
  check "claude: mcphub removed" bash -c '! jq -e ".mcpServers.mcphub" "$1"' _ "$CJ"
  check "claude: direct chrome-devtools replaced by the gateway entry" jq -e '.mcpServers["chrome-devtools"] | .type == "http" and (.url | endswith("/chrome-devtools/mcp"))' "$CJ"
  check "claude: gateway servers registered with a headers helper" jq -e '[.mcpServers["desktop-ro"], .mcpServers["context7"]] | all(.type == "http" and (.headersHelper | endswith("mcp-gateway-headers")))' "$CJ"
  check "claude: stdio entry goes through mcp-run" jq -e '.mcpServers.demo | .type == "stdio" and (.command | endswith("/mcp-run")) and .args == ["demo"]' "$CJ"
  check "claude: unrelated entry kept" jq -e '.mcpServers.keepme' "$CJ"
  check "claude: no token anywhere in the config" bash -c '! grep -q -i -F -e "$2" -e "Bearer" "$1"' _ "$CJ" "$T1"
  cp "$CJ" "$SCRATCH/claude-after1.json"
  MCP_CONFIG_DIR="$ADDCFG" "$ADD" >/dev/null 2>&1
  check "claude: a second run is idempotent" bash -c 'diff <(jq -S .mcpServers "$1") <(jq -S .mcpServers "$2")' _ "$CJ" "$SCRATCH/claude-after1.json"
else
  skip "mcp-add Claude part (--quick or no claude CLI)"
fi
CT="$CODEX_DIR/config.toml"
if [[ ! -f $SCRATCH/claude-before.json ]]; then MCP_CONFIG_DIR="$ADDCFG" "$ADD" --codex >/dev/null 2>&1; fi
check "codex: mcphub removed" bash -c '! grep -q "mcp_servers.mcphub" "$1"' _ "$CT"
check "codex: gateway servers use url + http_headers_helper" python3 -I -c '
import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))["mcp_servers"]
for n in ("desktop-ro", "chrome-devtools", "context7"):
    assert d[n]["url"].endswith(f"/{n}/mcp") and d[n]["http_headers_helper"].endswith("mcp-gateway-headers"), n
assert d["demo"]["command"].endswith("/mcp-run") and d["demo"]["args"] == ["demo"]
' "$CT"
check "codex: unrelated tables, keys and the comment survive" bash -c 'grep -q "keep this comment" "$1" && grep -q "mcp_servers.http-toolkit" "$1" && grep -q "marketplaces.codex-hud" "$1" && grep -q "approval_policy" "$1"' _ "$CT"
check "codex: a timestamped backup was written" bash -c 'ls "$1"/config.toml.bak-mcp-add-* >/dev/null' _ "$CODEX_DIR"
check "codex: no token in config.toml" bash -c '! grep -q -i -F -e "$2" -e "Bearer" "$1"' _ "$CT" "$T1"
cp "$CT" "$SCRATCH/codex-after1.toml"
MCP_CONFIG_DIR="$ADDCFG" "$ADD" --codex >/dev/null 2>&1
check "codex: a second run is idempotent" cmp -s "$CT" "$SCRATCH/codex-after1.toml"
printf 'model = "x"\n[broken\n' >"$CODEX_DIR/config.toml"
check "codex: an unparsable config is left untouched" bash -c 'MCP_CONFIG_DIR="$1" "$2" --codex >/dev/null 2>&1; grep -q "^\[broken" "$3/config.toml"' _ "$ADDCFG" "$ADD" "$CODEX_DIR"
unset MCP_GATEWAY_CMD CLAUDE_CONFIG_DIR CODEX_HOME

# --- desktop-ro ----------------------------------------------------------------------------------------------------
if [[ -x $VENV_PY ]]; then
  count_py "$VENV_PY" "$HERE/test_desktop_ro.py" "$REPO/.config/mcp/desktop-ro/server.py" "$HERE/bin" "$FAKE_DIR"
else
  skip "desktop-ro protocol test (no venv: run mcp-install)"
fi

# --- a real gateway with a fake server ----------------------------------------------------------------------------
if [[ $QUICK -eq 0 && -x $VENV_PY && -x $PROXY ]]; then
  PORT=$((38000 + RANDOM % 1500))
  GCFG="$SCRATCH/gwcfg"; mkdir -p "$GCFG"
  jq --arg addr "127.0.0.1:$PORT" --arg py "$VENV_PY" --arg srv "$HERE/fake_server.py" '
    .mcpProxy.addr = $addr | .mcpProxy.baseURL = ("http://" + $addr)
    | .mcpServers = {fake: {command: $py, args: [$srv], options: {toolFilter: {mode: "allow", list: ["read_thing"]}}}}' \
    "$MCP_CONFIG_DIR/gateway.json" >"$GCFG/gateway.json"
  GSTATE="$SCRATCH/gwstate"
  MCP_CONFIG_DIR="$GCFG" MCP_STATE_DIR="$GSTATE" MCP_PROXY_BIN="$PROXY" "$GW" run >"$SCRATCH/gw.log" 2>&1 &
  GWPID=$!
  up=0
  for _ in $(seq 1 40); do curl -fs "http://127.0.0.1:$PORT/_healthz" >/dev/null 2>&1 && { up=1; break; }; sleep 0.25; done
  check "gateway process starts and answers /_healthz" test "$up" = 1
  if [[ $up -eq 1 ]]; then
    check "gateway listens on 127.0.0.1 only" bash -c 'ss -ltn "sport = :$1" | grep -q "127.0.0.1:$1" && ! ss -ltn "sport = :$1" | grep -qE "0.0.0.0:$1|\[::\]:$1|\*:$1"' _ "$PORT"
    count_py "$VENV_PY" "$HERE/test_gateway_client.py" "http://127.0.0.1:$PORT" "$(<"$GSTATE/gateway.token")"
    if [[ -n $CLAUDE_BIN ]]; then
      export CLAUDE_CONFIG_DIR="$SCRATCH/claude-e2e"; mkdir -p "$CLAUDE_CONFIG_DIR"
      claude mcp add-json -s user fake "{\"type\":\"http\",\"url\":\"http://127.0.0.1:$PORT/fake/mcp\",\"headersHelper\":\"$REPO/.local/bin/mcp-gateway-headers\"}" >/dev/null 2>&1
      check "Claude Code connects through the headers helper" bash -c 'MCP_STATE_DIR="$2" claude mcp get fake 2>&1 | grep -q "Connected"' _ x "$GSTATE"
      unset CLAUDE_CONFIG_DIR
    fi
  else
    sed 's/^/    gateway log: /' "$SCRATCH/gw.log" | tail -5
  fi
  kill "$GWPID" 2>/dev/null; GWPID=""
else
  skip "real gateway test (--quick or no pinned venv/mcp-proxy)"
fi

echo "mcp tests: $PASS passed, $FAILS failed, $SKIPS skipped"
[[ $FAILS -eq 0 ]]
