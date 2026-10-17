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
export MCP_TGCONFIRM_UNIT="$SCRATCH/no-tgconfirm.service" MCP_TGCONFIRM_SOCK="$SCRATCH/no-tgconfirm.sock"   # a real broker on this machine must not change the results
mkdir -p "$FAKE_DIR/vault" "$XDG_RUNTIME_DIR"
# nothing in this suite may reach the owner's desktop, systemd user manager or waybar: fakes come first on PATH for every check
# (notify-send logs to $FAKE_DIR/notify.log), and every script's own no-notify / no-restart / no-timer hook is set as well
SAFEBIN="$SCRATCH/safebin"; mkdir -p "$SAFEBIN"
for f in notify-send systemctl pkill; do ln -s "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin/$f" "$SAFEBIN/$f"; done
printf '#!/usr/bin/env bash\necho "systemd-run $*" >>"${FAKE_DIR:-/tmp}/argv.log"\n' >"$SAFEBIN/systemd-run"; chmod +x "$SAFEBIN/systemd-run"
export PATH="$SAFEBIN:$PATH"
export MCP_CHROME_NO_NOTIFY=1 MCP_CHROME_NO_RESTART=1 MCP_CHROME_NO_TIMER=1 MCP_TGSEND_NO_NOTIFY=1 MCP_TGSEND_NO_POKE=1 MCP_TGSEND_NO_TIMER=1 AI_ASK_NO_NOTIFY=1
export MCP_GATEWAY_UNIT=mcp-gateway-test.service
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
check "telegram-send is held back while the tgconfirm broker is not installed" bash -c '! "$1" servers | grep -qx telegram-send' _ "$GW"
check "telegram-send appears once the broker unit exists" bash -c ': >"$2"; MCP_TGCONFIRM_UNIT="$2" "$1" servers | grep -qx telegram-send' _ "$GW" "$SCRATCH/tgc.service"
check "telegram-send appears while the broker socket exists" bash -c 'python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); import time; time.sleep(3)" "$2" & sleep 0.5; MCP_TGCONFIRM_SOCK="$2" "$1" servers | grep -qx telegram-send; rc=$?; kill %1 2>/dev/null; exit $rc' _ "$GW" "$SCRATCH/tgc.sock"
check "telegram-send toolFilter: an allow list of exactly send_message and status" jq -e '.mcpServers["telegram-send"].options.toolFilter | .mode == "allow" and (.list | sort) == ["send_message","status"]' "$MCP_CONFIG_DIR/gateway.json"
check "telegram-send: stdio server from the pinned venv, no secret and no URL in its entry, timeout 90s" jq -e '.mcpServers["telegram-send"] | .timeout == "90s" and (.command | endswith("/venv/bin/python")) and (.args[0] | endswith("/telegram-send.py")) and (has("env") | not) and (has("headers") | not) and (has("url") | not)' "$MCP_CONFIG_DIR/gateway.json"
check "the effective config with the broker installed passes mcp-proxy's own check" bash -c 'p="$2"; [ -x "$p" ] || exit 0; : >"$3"; MCP_TGCONFIRM_UNIT="$3" MCP_PROXY_BIN="$p" "$1" check' _ "$GW" "$PROXY" "$SCRATCH/tgc.service"
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
check "effective config drops telegram-send without the broker" bash -c '! jq -e ".mcpServers[\"telegram-send\"]" "$1" >/dev/null' _ "$FAKE_DIR/proxy-config"
: >"$SCRATCH/tgc.service"
MCP_TGCONFIRM_UNIT="$SCRATCH/tgc.service" MCP_PROXY_BIN="$SCRATCH/fake-proxy" "$GW" run
check "effective config keeps telegram-send once the broker is installed, and never its token (it has none)" bash -c 'jq -e ".mcpServers[\"telegram-send\"]" "$1" >/dev/null && ! grep -q -i "MCP_.*TOKEN" <(jq -c ".mcpServers[\"telegram-send\"]" "$1")' _ "$FAKE_DIR/proxy-config"
rm -f "$SCRATCH/tgc.service"
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
check "mcp-chrome status is OFF (exit 1) by default" bash -c '! "$1" mine status' _ "$MC"
check "mcp-chrome mine on sets the flag" bash -c '"$1" mine on --ttl 5 >/dev/null && [ -e "$2/chrome-mine.enabled" ] && "$1" mine status >/dev/null' _ "$MC" "$MCP_STATE_DIR"
check "mcp-chrome mine off clears it" bash -c '"$1" mine off >/dev/null && [ ! -e "$2/chrome-mine.enabled" ]' _ "$MC" "$MCP_STATE_DIR"
check "mcp-chrome toggle flips" bash -c '"$1" mine toggle >/dev/null; "$1" mine status >/dev/null && "$1" mine toggle >/dev/null; ! "$1" mine status >/dev/null' _ "$MC"
check "mcp-chrome rejects a bad ttl" bash -c '! "$1" mine on --ttl abc' _ "$MC"

# --- mcp-add against throwaway Claude / Codex homes ----------------------------------------------------------------
cat >"$SCRATCH/fake-gw" <<'EOF'
#!/usr/bin/env bash
case $1 in
  servers) printf 'desktop-ro\nchrome-devtools\ncontext7\ntelegram-send\n' ;;
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

[mcp_servers.telegram-send]
url = "http://127.0.0.1:37411/telegram-send/mcp"

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
  check "claude: telegram-send is registered (Claude Code only)" jq -e '.mcpServers["telegram-send"] | .type == "http" and (.url | endswith("/telegram-send/mcp")) and (.headersHelper | endswith("mcp-gateway-headers"))' "$CJ"
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
check "codex: telegram-send is never registered and a leftover entry is removed" bash -c '! grep -q "telegram-send" "$1"' _ "$CT"
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

# --- Telegram: units, credential helper, run wrapper, serve.py, setup helper --------------------------------------------
TGD="$REPO/infrastructure/mcp/telegram"
UNIT="$TGD/telegram-mcp.service"
check "unit: runs as aimcp, not root" bash -c 'grep -q "^User=aimcp" "$1" && ! grep -q "^User=root" "$1"' _ "$UNIT"
check "unit: five encrypted credentials" bash -c '[ "$(grep -c "^LoadCredentialEncrypted=" "$1")" = 5 ]' _ "$UNIT"
check "unit: no secret in Environment=/ExecStart" bash -c '! grep -E "^(Environment|ExecStart)=.*(API_HASH|SESSION|TOKEN|password)" "$1"' _ "$UNIT"
check "unit: sandboxed (no home, strict system, no caps, IP+unix sockets only)" bash -c 'grep -q "^ProtectHome=yes" "$1" && grep -q "^ProtectSystem=strict" "$1" && grep -q "^NoNewPrivileges=yes" "$1" && grep -q "^CapabilityBoundingSet=$" "$1" && grep -q "^RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX" "$1"' _ "$UNIT"
check "unit: only starts once all credentials exist" bash -c '[ "$(grep -c "^ConditionPathExists=/etc/credstore.encrypted/telegram-mcp\." "$1")" = 5 ]' _ "$UNIT"
check "unit: a refusal to start (78) is not retried in a loop" grep -q '^RestartPreventExitStatus=78' "$UNIT"
check "whisper: bound to loopback (socket and server)" bash -c 'grep -q "^ListenStream=127.0.0.1:8766" "$1/telegram-whisper-proxy.socket" && grep -q -- "--host 127.0.0.1" "$1/telegram-whisper.service" && grep -q "127.0.0.1:8767" "$1/telegram-whisper-proxy.service"' _ "$TGD"
check "whisper: on demand and stopped when idle" bash -c 'grep -q "^StopWhenUnneeded=yes" "$1/telegram-whisper.service" && grep -q -- "--exit-idle-time" "$1/telegram-whisper-proxy.service"' _ "$TGD"
check "whisper: model from /srv/models (shared path), cloud engines unreachable" bash -c 'grep -q "/srv/models/ggml-small.bin" "$1/telegram-whisper.service" && ! grep -rqiE "export .*groq|GROQ_API_KEY=" "$1/run" "$1/telegram-mcp.service" "$1/telegram-whisper.service"' _ "$TGD"
check "pins: commit is a full sha, model sha256 is pinned" bash -c '. "$1/pins.env"; [[ $TELEGRAM_MCP_COMMIT =~ ^[0-9a-f]{40}$ ]] && [[ $WHISPER_MODEL_SHA256 =~ ^[0-9a-f]{64}$ ]]' _ "$TGD"
check "telegram requirements are hash-pinned" bash -c 'grep -q -- "--hash=sha256:" "$1/requirements.txt" && grep -q "^telethon==" "$1/requirements.txt"' _ "$TGD"
check "units pass systemd-analyze (paths aside)" bash -c 'systemd-analyze verify --man=no "$1/telegram-mcp.service" "$1/telegram-whisper-proxy.socket" 2>&1 | grep -v -E "not executable|marked executable|No such file" | grep -q -E "Unknown|Invalid|Failed to parse|bad setting" && exit 1; exit 0' _ "$TGD"

# creds-install with a fake systemd-creds / systemctl
CS="$SCRATCH/credstore"
SESS="1$(printf 'A%.0s' $(seq 1 130))"
PAYLOAD=$(jq -cn --arg s "$SESS" '{api_id:"12345678", api_hash:"0123456789abcdef0123456789abcdef", session:$s, allowlist:"-1001111,42", token:"tttttttttttttttttttttttttttttttttttttttttt"}')
export CREDSTORE_DIR="$CS" SYSTEMD_CREDS_BIN="$HERE/bin/systemd-creds" SYSTEMCTL_BIN="$HERE/bin/fake-systemctl" CREDS_INSTALL_ALLOW_NONROOT=1
CI="$TGD/creds-install"
: >"$FAKE_DIR/argv.log"
printf '%s' "$PAYLOAD" | "$CI" >/dev/null 2>&1
check "creds-install: five sealed credentials" bash -c 'for k in api_id api_hash session allowlist token; do [ -s "$1/telegram-mcp.$k" ] || exit 1; done' _ "$CS"
check "creds-install: credstore dir 700, files 600" bash -c '[ "$(stat -c %a "$1")" = 700 ] && [ "$(stat -c %a "$1/telegram-mcp.session")" = 600 ]' _ "$CS"
check "creds-install: sealed with tpm2+host and the credential name" bash -c 'grep -q -- "--with-key=tpm2+host --name=session - " "$1"' _ "$FAKE_DIR/argv.log"
check "creds-install: no plaintext in the sealed files" bash -c '! grep -q -F -e "$2" -e 0123456789abcdef "$1"/telegram-mcp.*' _ "$CS" "$SESS"
check "creds-install: secrets never on argv" bash -c '! grep -q -F -e "$2" -e 0123456789abcdef -e tttttttttt "$1"' _ "$FAKE_DIR/argv.log" "$SESS"
check "creds-install: enables the whisper socket and restarts the service" bash -c 'grep -q "systemctl enable --now telegram-whisper-proxy.socket" "$1" && grep -q "systemctl restart telegram-mcp.service" "$1"' _ "$FAKE_DIR/argv.log"
: >"$FAKE_DIR/argv.log"; cp "$CS/telegram-mcp.session" "$SCRATCH/session.before"
printf '{"allowlist":"42"}' | "$CI" >/dev/null 2>&1
check "creds-install: a partial update touches only that credential" bash -c 'cmp -s "$1/telegram-mcp.session" "$2" && ! cmp -s "$1/telegram-mcp.allowlist" /dev/null' _ "$CS" "$SCRATCH/session.before"
check "creds-install: rejects an empty allowlist" bash -c '! printf "{\"allowlist\":\"\"}" | "$1"' _ "$CI"
check "creds-install: rejects a non-numeric allowlist" bash -c '! printf "{\"allowlist\":\"abc,1\"}" | "$1"' _ "$CI"
check "creds-install: rejects an unknown key" bash -c '! printf "{\"evil\":\"x\"}" | "$1"' _ "$CI"
check "creds-install: rejects bad JSON and an empty object" bash -c '! printf "nope" | "$1" && ! printf "{}" | "$1"' _ "$CI"
check "creds-install: refuses to run as a normal user without the test hook" bash -c '! env -u CREDS_INSTALL_ALLOW_NONROOT "$1" --status' _ "$CI"
rm -rf "$CS"; : >"$FAKE_DIR/argv.log"
printf '{"allowlist":"1"}' | "$CI" >/dev/null 2>&1
check "creds-install: the service is not started while credentials are missing" bash -c '! grep -q "restart telegram-mcp.service" "$1" && grep -q "enable telegram-mcp.service" "$1"' _ "$FAKE_DIR/argv.log"
# optional send credentials: two sealed copies (route + broker), a drop-in only while both exist, broker restarted
DROP="$SCRATCH/dropin"; UD="$SCRATCH/units"; mkdir -p "$UD"; : >"$UD/tgconfirm.service"
export DROPIN_DIR="$DROP" SEND_CONF_SRC="$TGD/send.conf" UNIT_DIR="$UD"
SENDTOK="sendtokensendtokensendtokensendtoken1234"
rm -rf "$CS"; : >"$FAKE_DIR/argv.log"
printf '%s' "$PAYLOAD" | "$CI" >/dev/null 2>&1
check "send creds: the base setup alone installs no drop-in" bash -c '[ ! -e "$1/send.conf" ]' _ "$DROP"
printf '{"send_token":"%s"}' "$SENDTOK" | "$CI" >/dev/null 2>&1
check "send creds: a send token alone installs no drop-in (the unit would fail on the missing allowlist)" bash -c '[ ! -e "$1/send.conf" ]' _ "$DROP"
printf '{"send_token":"%s","send_allowlist":"-1001111"}' "$SENDTOK" | "$CI" >/dev/null 2>&1
check "send creds: sealed for the route AND for the tgconfirm broker" bash -c '[ -s "$1/telegram-mcp.send_token" ] && [ -s "$1/telegram-mcp.send_allowlist" ] && [ -s "$1/tgconfirm.send_token" ]' _ "$CS"
check "send creds: both copies sealed with the credential name send_token" bash -c '[ "$(grep -c -- "--name=send_token - " "$1")" -ge 2 ]' _ "$FAKE_DIR/argv.log"
check "send creds: the drop-in loads exactly the two send credentials" bash -c 'grep -q "^LoadCredentialEncrypted=send_token:/etc/credstore.encrypted/telegram-mcp.send_token" "$1/send.conf" && grep -q "^LoadCredentialEncrypted=send_allowlist:" "$1/send.conf" && [ "$(grep -c "^LoadCredentialEncrypted=" "$1/send.conf")" = 2 ]' _ "$DROP"
check "send creds: the send token never reaches argv or a plain file" bash -c '! grep -q "$2" "$1" && ! grep -rq "$2" "$3"' _ "$FAKE_DIR/argv.log" "$SENDTOK" "$CS"
check "send creds: the broker is enabled and restarted when a send token was stored" bash -c 'grep -q "systemctl enable tgconfirm.service" "$1" && grep -q "systemctl restart tgconfirm.service" "$1"' _ "$FAKE_DIR/argv.log"
check "send creds: a send token equal to the MCP token is refused" bash -c '! printf "{\"token\":\"%s\",\"send_token\":\"%s\"}" "$2" "$2" | "$1"' _ "$CI" "$SENDTOK"
check "send creds: a bad send allowlist is refused" bash -c '! printf "{\"send_allowlist\":\"@x\"}" | "$1"' _ "$CI"
check "send creds: --status lists the send credentials" bash -c '"$1" --status | grep -q "^send_token: present" && "$1" --status | grep -q "^tgconfirm send_token: present"' _ "$CI"
# the root helper generates the send token itself: it is never given, never printed, sealed twice with the same value
rm -rf "$CS" "$DROP"; : >"$FAKE_DIR/argv.log"
printf '%s' "$PAYLOAD" | "$CI" >/dev/null 2>&1
GEN_OUT=$(printf '{"send_allowlist":"-1001111"}' | "$CI" --ensure-send-token 2>&1)
check "send token: generated when missing, sealed for the route AND the broker, the allowlist stored with it" bash -c '[ -s "$1/telegram-mcp.send_token" ] && [ -s "$1/tgconfirm.send_token" ] && [ -s "$1/telegram-mcp.send_allowlist" ] && [ -e "$2/send.conf" ]' _ "$CS" "$DROP"
check "send token: both sealed copies hold the same value, which is not the MCP token" bash -c 'cmp -s "$1/telegram-mcp.send_token" "$1/tgconfirm.send_token" && ! cmp -s "$1/telegram-mcp.send_token" "$1/telegram-mcp.token"' _ "$CS"
check "send token: the helper says it generated one but prints no value" bash -c 'grep -q "generated a new send token" <<<"$1" && ! grep -qE "[A-Za-z0-9_-]{32,}" <<<"$1"' _ "$GEN_OUT"
check "send token: never on argv" bash -c '! grep -E "systemd-creds.*[A-Za-z0-9_-]{43}" "$1" | grep -qv -e "--name=" ' _ "$FAKE_DIR/argv.log"
cp "$CS/tgconfirm.send_token" "$SCRATCH/send-token.before"
printf '{"send_allowlist":"-1001111,42"}' | "$CI" --ensure-send-token >/dev/null 2>&1
check "send token: --ensure keeps the existing token when both copies exist" cmp -s "$CS/tgconfirm.send_token" "$SCRATCH/send-token.before"
printf '{"send_allowlist":"-1001111,42"}' | "$CI" --rotate-send-token >/dev/null 2>&1
check "send token: --rotate replaces both copies with a new value" bash -c '! cmp -s "$1/tgconfirm.send_token" "$2" && cmp -s "$1/tgconfirm.send_token" "$1/telegram-mcp.send_token"' _ "$CS" "$SCRATCH/send-token.before"
rm -f "$CS/tgconfirm.send_token"; printf '{"send_allowlist":"-1001111"}' | "$CI" --ensure-send-token >/dev/null 2>&1
check "send token: --ensure repairs a missing broker copy" bash -c 'cmp -s "$1/tgconfirm.send_token" "$1/telegram-mcp.send_token"' _ "$CS"
check "send token: a token on stdin together with a generate flag is refused" bash -c '! printf "{\"send_token\":\"%s\"}" "$2" | "$1" --ensure-send-token' _ "$CI" "$SENDTOK"
check "send token: the flag alone works with an empty object (token only)" bash -c 'rm -rf "$2"; printf "{}" | "$1" --ensure-send-token >/dev/null && [ -s "$2/tgconfirm.send_token" ]' _ "$CI" "$CS"
rm -rf "$CS"; : >"$FAKE_DIR/argv.log"; printf '%s' "$PAYLOAD" | "$CI" >/dev/null 2>&1
printf '{"send_token":"%s","send_allowlist":"-1001111"}' "$SENDTOK" | "$CI" >/dev/null 2>&1
rm -f "$CS/telegram-mcp.send_allowlist"; "$CI" --sync >/dev/null 2>&1
check "send creds: --sync removes the drop-in when a send credential is gone" bash -c '[ ! -e "$1/send.conf" ]' _ "$DROP"
unset DROPIN_DIR SEND_CONF_SRC UNIT_DIR
unset CREDSTORE_DIR SYSTEMD_CREDS_BIN SYSTEMCTL_BIN CREDS_INSTALL_ALLOW_NONROOT

# run wrapper: credentials directory -> environment, fail closed
CRED="$SCRATCH/cred"; mkdir -p "$CRED"
printf '12345678' >"$CRED/api_id"; printf '0123456789abcdef0123456789abcdef' >"$CRED/api_hash"; printf '%s' "$SESS" >"$CRED/session"
printf -- '-1001111,42\n' >"$CRED/allowlist"; printf 'bearer-token-value' >"$CRED/token"
cat >"$SCRATCH/fake-envpy" <<'EOF'
#!/usr/bin/env bash
env | grep -E '^(TELEGRAM_|MCP_|GROQ)' | sort >"$FAKE_DIR/run-env.txt"
echo "args: $*" >>"$FAKE_DIR/run-env.txt"
EOF
chmod +x "$SCRATCH/fake-envpy"
TG_RUN=(env CREDENTIALS_DIRECTORY="$CRED" TELEGRAM_MCP_PYTHON="$SCRATCH/fake-envpy" TELEGRAM_MCP_SERVE=/x/serve.py STATE_DIRECTORY="$SCRATCH/state-dir" "$TGD/run")
"${TG_RUN[@]}" >/dev/null 2>&1
check "run: read-only exposure" grep -qx 'TELEGRAM_EXPOSED_TOOLS=read-only' "$FAKE_DIR/run-env.txt"
check "run: allowlist from the credential" grep -qx 'TELEGRAM_ALLOWED_CHAT_IDS=-1001111,42' "$FAKE_DIR/run-env.txt"
check "run: session string, api id/hash and token reach the environment" bash -c 'grep -q "^TELEGRAM_SESSION_STRING=1AAAA" "$1" && grep -qx "TELEGRAM_API_ID=12345678" "$1" && grep -qx "TELEGRAM_MCP_TOKEN=bearer-token-value" "$1"' _ "$FAKE_DIR/run-env.txt"
check "run: HTTP on loopback only, local whisper engine, no cloud key" bash -c 'grep -qx "MCP_HOST=127.0.0.1" "$1" && grep -qx "MCP_TRANSPORT=http" "$1" && grep -qx "TELEGRAM_TRANSCRIBE_ENGINE=openai" "$1" && grep -qx "TELEGRAM_TRANSCRIBE_OPENAI_URL=http://127.0.0.1:8766" "$1" && ! grep -q GROQ "$1"' _ "$FAKE_DIR/run-env.txt"
check "run: secrets are not in the argument list" bash -c 'grep "^args:" "$1" | grep -qv -e AAAA -e bearer-token -e 0123456789abcdef' _ "$FAKE_DIR/run-env.txt"
check "run: no send credentials, no send environment" bash -c '! grep -q "TELEGRAM_SEND" "$1"' _ "$FAKE_DIR/run-env.txt"
printf 'send-token-value-send-token-value-1' >"$CRED/send_token"; printf -- '-1001111\n' >"$CRED/send_allowlist"
"${TG_RUN[@]}" >/dev/null 2>&1
check "run: both send credentials reach the environment" bash -c 'grep -qx "TELEGRAM_SEND_TOKEN=send-token-value-send-token-value-1" "$1" && grep -qx "TELEGRAM_SEND_ALLOWLIST=-1001111" "$1"' _ "$FAKE_DIR/run-env.txt"
check "run: the exposure stays read-only with the send credentials" grep -qx 'TELEGRAM_EXPOSED_TOOLS=read-only' "$FAKE_DIR/run-env.txt"
rm -f "$CRED/send_allowlist"
"${TG_RUN[@]}" >/dev/null 2>&1
check "run: a send token without an allowlist is not exported" bash -c '! grep -q "TELEGRAM_SEND" "$1"' _ "$FAKE_DIR/run-env.txt"
rm -f "$CRED/send_token"
printf '\n' >"$CRED/allowlist"
check "run: an empty allowlist refuses to start (78)" bash -c '"${@}" >/dev/null 2>&1; [ $? -eq 78 ]' _ "${TG_RUN[@]}"
printf -- '-1001111\n' >"$CRED/allowlist"; rm -f "$CRED/session"
check "run: a missing credential refuses to start (78)" bash -c '"${@}" >/dev/null 2>&1; [ $? -eq 78 ]' _ "${TG_RUN[@]}"

# serve.py: env check, bearer middleware, and the real server surface when the telegram-mcp venv exists
TG_PY="${TELEGRAM_MCP_PY:-/opt/telegram-mcp/venv/bin/python}"
if [[ -x $TG_PY && -d ${TELEGRAM_MCP_SRC:-/opt/telegram-mcp/src} ]]; then
  count_py env TELEGRAM_MCP_PY="$TG_PY" TELEGRAM_MCP_SRC="${TELEGRAM_MCP_SRC:-/opt/telegram-mcp/src}" python3 -I "$HERE/test_telegram_serve.py" "$REPO"
else
  count_py python3 -I "$HERE/test_telegram_serve.py" "$REPO"
  skip "real telegram-mcp tool surface and gateway allowlist names (no /opt/telegram-mcp yet; set TELEGRAM_MCP_PY/TELEGRAM_MCP_SRC)"
fi

# mcp-telegram-setup against fake bw / login / creds helper / picker / gateway
SETUP="$REPO/.local/bin/mcp-telegram-setup"
cat >"$FAKE_DIR/bw-item.json" <<'EOF'
{"id":"I1","name":"telegram-mcp","folderId":"F1","type":1,"login":{"username":null,"password":null},
 "fields":[{"name":"api_id","value":"12345678","type":0},{"name":"api_hash","value":"0123456789abcdef0123456789abcdef","type":0}]}
EOF
setup_env() {
  env BW_BIN="$HERE/bin/bw" VAULT_BW="$REPO/.config/hypr/scripts/vault-bw.py" VAULT_RBW_CONF=/nonexistent PATH="$HERE/bin:$PATH" \
    MCP_TG_PYTHON=/usr/bin/python3 MCP_TG_LOGIN="$HERE/fake_login.py" MCP_TG_CREDS="$HERE/fake_creds.sh" MCP_TG_SUDO=env \
    MCP_TG_PICK="$HERE/fake_pick.sh" MCP_GATEWAY_CMD="$HERE/fake_gw_tg.sh" MCP_ADD_CMD="$HERE/fake_add.sh" MCP_TG_NO_VERIFY=1 \
    MCP_STATE_DIR="$SCRATCH/setup-state" "$@"
}
rm -rf "$SCRATCH/setup-state"; : >"$FAKE_DIR/argv.log"; : >"$FAKE_DIR/login.log"
FAKE_PICK_IDS="-1001111 42" setup_env "$SETUP" >"$SCRATCH/setup.out" 2>&1
check "setup: first run does a QR login" grep -q '^mode=qr api_id=12345678 has_session=no' "$FAKE_DIR/login.log"
check "setup: the picker shows every chat" bash -c '[ "$(wc -l <"$1")" -ge 4 ]' _ "$FAKE_DIR/pick-rows.txt"
check "setup: Bitwarden gets a hidden session field and a text allowlist field" jq -e '(.fields[] | select(.name=="session") | .type == 1 and (.value | startswith("1FRESH"))) and (.fields[] | select(.name=="allowlist") | .type == 0 and .value == "-1001111,42") and ([.fields[].name] | index("api_hash") != null)' "$FAKE_DIR/bw-item.json"
check "setup: the root helper gets all five values on stdin" jq -e '.api_id == "12345678" and (.session | startswith("1FRESH")) and .allowlist == "-1001111,42" and (.token | length >= 32) and .api_hash != null' "$FAKE_DIR/creds-payload.json"
check "setup: the session never appears on any argv" bash -c '! grep -q FRESHSESSION "$1"' _ "$FAKE_DIR/argv.log"
check "setup: telegram.token is a 0600 file equal to the stored token" bash -c '[ "$(stat -c %a "$1/telegram.token")" = 600 ] && [ "$(cat "$1/telegram.token")" = "$(jq -r .token "$2")" ]' _ "$SCRATCH/setup-state" "$FAKE_DIR/creds-payload.json"
check "setup: gateway restarted and mcp-add run" bash -c 'grep -q "gateway restart" "$1" && grep -q "mcp-add called" "$1"' _ "$FAKE_DIR/argv.log"
check "setup: output names the allowed chats and the kill switch" bash -c 'grep -q "Work chat" "$1" && grep -q "Ann" "$1" && ! grep -q "Secret person" "$1" && grep -q "Devices" "$1"' _ "$SCRATCH/setup.out"
: >"$FAKE_DIR/login.log"; rm -f "$FAKE_DIR/creds-payload.json"
FAKE_PICK_IDS="42 777" setup_env "$SETUP" chats >"$SCRATCH/chats.out" 2>&1
check "chats: reuses the stored session (list mode, no QR)" bash -c 'grep -q "^mode=list .*has_session=yes" "$1" && ! grep -q "^mode=qr" "$1"' _ "$FAKE_DIR/login.log"
check "chats: ticking an allowed chat removes it, ticking a new one adds it" jq -e '(.fields[] | select(.name=="allowlist") | .value) == "-1001111,777"' "$FAKE_DIR/bw-item.json"
check "chats: only the allowlist (and the token) go to the root helper" bash -c 'jq -e ".allowlist == \"-1001111,777\" and (has(\"session\") | not) and (has(\"api_hash\") | not)" "$1"' _ "$FAKE_DIR/creds-payload.json"
check "chats: the picker marks the allowed chats" grep -q '\[allowed\].*Work chat' "$FAKE_DIR/pick-rows.txt"
# send-chats: a subset of the readable chats; the send token is generated by the root helper and never touches Bitwarden
: >"$FAKE_DIR/login.log"; rm -f "$FAKE_DIR/creds-payload.json" "$FAKE_DIR/creds-args.txt"
FAKE_PICK_IDS="-1001111" setup_env "$SETUP" send-chats >"$SCRATCH/sendchats.out" 2>&1
check "send-chats: uses the stored session (list mode, no QR)" bash -c 'grep -q "^mode=list .*has_session=yes" "$1" && ! grep -q "^mode=qr" "$1"' _ "$FAKE_DIR/login.log"
check "send-chats: the picker offers only the readable chats" bash -c 'grep -q "Work chat" "$1" && grep -q "Secret person" "$1" && ! grep -q -e "Ann" -e "News" "$1" && [ "$(wc -l <"$1")" = 2 ]' _ "$FAKE_DIR/pick-rows.txt"
check "send-chats: Bitwarden gets the text field send_allowlist and no send token anywhere" jq -e '(.fields[] | select(.name=="send_allowlist") | .type == 0 and .value == "-1001111") and ([.fields[].name] | map(test("send_token|token")) | any | not) and (.fields[] | select(.name=="allowlist") | .value) == "-1001111,777"' "$FAKE_DIR/bw-item.json"
check "send-chats: the root helper gets only send_allowlist on stdin, asked to generate the token itself" bash -c 'jq -e "keys == [\"send_allowlist\"] and .send_allowlist == \"-1001111\"" "$1" && [ "$(cat "$2")" = "--ensure-send-token" ]' _ "$FAKE_DIR/creds-payload.json" "$FAKE_DIR/creds-args.txt"
check "send-chats: no send token in the payload, on any argv or in the state directory" bash -c '! grep -rqi "send_token\|sendtoken" "$1" "$2" 2>/dev/null' _ "$FAKE_DIR/argv.log" "$SCRATCH/setup-state"
check "send-chats: gateway restarted, Claude-only registration, sending stays OFF" bash -c 'grep -q "gateway restart" "$1" && grep -q "mcp-add called" "$1" && grep -q "OFF until you switch it on" "$2" && grep -q "Work chat" "$2"' _ "$FAKE_DIR/argv.log" "$SCRATCH/sendchats.out"
FAKE_PICK_IDS="777" setup_env "$SETUP" send-chats >/dev/null 2>&1
check "send-chats: ticking a new chat adds it" jq -e '(.fields[] | select(.name=="send_allowlist") | .value) == "-1001111,777"' "$FAKE_DIR/bw-item.json"
FAKE_PICK_IDS="-1001111" setup_env "$SETUP" send-chats >/dev/null 2>&1
check "send-chats: ticking a [send] chat removes it" jq -e '(.fields[] | select(.name=="send_allowlist") | .value) == "777"' "$FAKE_DIR/bw-item.json"
rm -f "$FAKE_DIR/creds-payload.json"
FAKE_PICK_IDS="777" setup_env "$SETUP" send-chats >/dev/null 2>&1
check "send-chats: removing the last send chat is refused and nothing is sent to the root helper" bash -c '[ ! -e "$1" ] && jq -e "(.fields[] | select(.name==\"send_allowlist\") | .value) == \"777\"" "$2"' _ "$FAKE_DIR/creds-payload.json" "$FAKE_DIR/bw-item.json"
check "send-chats: an account other than main is refused until M1b" bash -c '! FAKE_PICK_IDS=777 "${@:2}" "$1" send-chats --account work >/dev/null 2>&1' _ "$SETUP" env BW_BIN="$HERE/bin/bw" VAULT_BW="$REPO/.config/hypr/scripts/vault-bw.py" VAULT_RBW_CONF=/nonexistent PATH="$HERE/bin:$PATH" MCP_TG_PYTHON=/usr/bin/python3 MCP_TG_LOGIN="$HERE/fake_login.py" MCP_TG_CREDS="$HERE/fake_creds.sh" MCP_TG_SUDO=env MCP_TG_PICK="$HERE/fake_pick.sh" MCP_GATEWAY_CMD="$HERE/fake_gw_tg.sh" MCP_ADD_CMD="$HERE/fake_add.sh" MCP_TG_NO_VERIFY=1 MCP_STATE_DIR="$SCRATCH/setup-state"
check "send-chats: bad usage is a usage error" bash -c '"${@:2}" "$1" send-chats extra >/dev/null 2>&1; [ $? -eq 2 ]' _ "$SETUP" env MCP_STATE_DIR="$SCRATCH/setup-state"
# shrinking the readable chats also trims the send list (it must stay a subset)
FAKE_PICK_IDS="-1001111" setup_env "$SETUP" send-chats >/dev/null 2>&1   # send list is -1001111,777 again
FAKE_PICK_IDS="-1001111" setup_env "$SETUP" chats >/dev/null 2>&1   # removes -1001111 ([allowed]) from the read list
check "chats: removing a readable chat also trims the send list, in Bitwarden and for the root helper" bash -c 'jq -e "(.fields[] | select(.name==\"allowlist\") | .value) == \"777\" and (.fields[] | select(.name==\"send_allowlist\") | .value) == \"777\"" "$1" && jq -e ".allowlist == \"777\" and .send_allowlist == \"777\"" "$2"' _ "$FAKE_DIR/bw-item.json" "$FAKE_DIR/creds-payload.json"
# a stale stored session falls back to the QR login
jq '(.fields[] | select(.name=="session") | .value) = "1STALE"' "$FAKE_DIR/bw-item.json" >"$FAKE_DIR/x.json" && mv "$FAKE_DIR/x.json" "$FAKE_DIR/bw-item.json"
: >"$FAKE_DIR/login.log"
FAKE_PICK_IDS="42" setup_env "$SETUP" >/dev/null 2>&1
check "setup: a stale stored session falls back to a QR login" bash -c 'grep -q "^mode=list" "$1" && grep -q "^mode=qr" "$1"' _ "$FAKE_DIR/login.log"
check "setup: --new-login skips the stored session" bash -c ': >"$2"; FAKE_PICK_IDS=42 "${@:3}" "$1" --new-login >/dev/null 2>&1; ! grep -q "^mode=list" "$2" && grep -q "^mode=qr" "$2"' _ "$SETUP" "$FAKE_DIR/login.log" env BW_BIN="$HERE/bin/bw" VAULT_BW="$REPO/.config/hypr/scripts/vault-bw.py" VAULT_RBW_CONF=/nonexistent PATH="$HERE/bin:$PATH" MCP_TG_PYTHON=/usr/bin/python3 MCP_TG_LOGIN="$HERE/fake_login.py" MCP_TG_CREDS="$HERE/fake_creds.sh" MCP_TG_SUDO=env MCP_TG_PICK="$HERE/fake_pick.sh" MCP_GATEWAY_CMD="$HERE/fake_gw_tg.sh" MCP_ADD_CMD="$HERE/fake_add.sh" MCP_TG_NO_VERIFY=1 MCP_STATE_DIR="$SCRATCH/setup-state"
check "setup: nothing ticked and no allowlist -> refuses, nothing sent to the root helper" bash -c 'rm -f "$3"; jq "del(.fields[] | select(.name==\"allowlist\" or .name==\"session\"))" "$2" >"$2.x" && mv "$2.x" "$2"; FAKE_PICK_IDS="" "${@:4}" "$1" >/dev/null 2>&1; rc=$?; [ $rc -ne 0 ] && [ ! -e "$3" ]' _ "$SETUP" "$FAKE_DIR/bw-item.json" "$FAKE_DIR/creds-payload.json" env BW_BIN="$HERE/bin/bw" VAULT_BW="$REPO/.config/hypr/scripts/vault-bw.py" VAULT_RBW_CONF=/nonexistent PATH="$HERE/bin:$PATH" MCP_TG_PYTHON=/usr/bin/python3 MCP_TG_LOGIN="$HERE/fake_login.py" MCP_TG_CREDS="$HERE/fake_creds.sh" MCP_TG_SUDO=env MCP_TG_PICK="$HERE/fake_pick.sh" MCP_GATEWAY_CMD="$HERE/fake_gw_tg.sh" MCP_ADD_CMD="$HERE/fake_add.sh" MCP_TG_NO_VERIFY=1 MCP_STATE_DIR="$SCRATCH/setup-state"
check "setup: a missing Bitwarden folder gives instructions" bash -c 'out=$(FAKE_BW_NOFOLDER=1 "${@:2}" "$1" 2>&1); grep -q "no folder MCP" <<<"$out"' _ "$SETUP" env BW_BIN="$HERE/bin/bw" VAULT_BW="$REPO/.config/hypr/scripts/vault-bw.py" VAULT_RBW_CONF=/nonexistent PATH="$HERE/bin:$PATH" MCP_TG_PYTHON=/usr/bin/python3 MCP_TG_LOGIN="$HERE/fake_login.py" MCP_TG_CREDS="$HERE/fake_creds.sh" MCP_TG_SUDO=env MCP_TG_PICK="$HERE/fake_pick.sh" MCP_GATEWAY_CMD="$HERE/fake_gw_tg.sh" MCP_ADD_CMD="$HERE/fake_add.sh" MCP_TG_NO_VERIFY=1 MCP_STATE_DIR="$SCRATCH/setup-state"

# the agents' send-request server (telegram-send.py) against a fake broker socket
if [[ -x $VENV_PY ]]; then
  count_py "$VENV_PY" "$HERE/test_telegram_send.py" "$REPO/.config/mcp/telegram-send.py"
else
  skip "telegram-send protocol test (no venv: run mcp-install)"
fi

# the real broker + fake popup + fake /x-send, driven by the on/off switch and by the agents' MCP server
if [[ -x $VENV_PY ]]; then
  count_py "$VENV_PY" "$HERE/test_send_e2e.py" "$REPO"
else
  skip "send end-to-end test (no venv: run mcp-install)"
fi
# hub row, leader key and the waybar switch of the Telegram sending toggle
check "hub: toggle row tg-send with live state and leader x m" bash -c 'grep -P "^tg-send\tAI\tTelegram: allow sending\t-\ttoggle\tmcp-telegram-send toggle\tmcp-telegram-send status\t" "$1" | grep -q "x m;Telegram: allow sending$"' _ "$REPO/.config/hub/actions.d/m1.tsv"
TS="$REPO/.config/waybar/scripts/toggles.sh"
echo '{"enabled":true,"until":4102444800}' >"$SCRATCH/tg-state.json"
check "waybar: the tgsend switch is ON (class enabled) while the broker state says enabled" bash -c 'MCP_TGSEND_STATE="$2" "$1" switch tgsend | jq -e ".class == \"enabled\"" && MCP_TGSEND_STATE="$2" "$1" state tgsend' _ "$TS" "$SCRATCH/tg-state.json"
echo '{"enabled":true,"until":1000}' >"$SCRATCH/tg-state.json"
check "waybar: an expired state file counts as off (class dim)" bash -c 'MCP_TGSEND_STATE="$2" "$1" switch tgsend | jq -e ".class == \"dim\"" && ! MCP_TGSEND_STATE="$2" "$1" state tgsend' _ "$TS" "$SCRATCH/tg-state.json"
check "waybar: without the broker's state file the switch is hidden (empty text) and not in the summary" bash -c 'MCP_TGSEND_STATE=/nonexistent "$1" switch tgsend | jq -e ".text == \"\"" && ! MCP_TGSEND_STATE=/nonexistent "$1" summary | jq -r .tooltip | grep -q Telegram' _ "$TS"
check "waybar: the drawer has the tgsend module and the css styles it" bash -c 'grep -q "custom/sw-tgsend\", \"custom/power" "$1" && grep -q "\"custom/sw-tgsend\": {" "$1" && grep -q "#custom-sw-tgsend" "$2"' _ "$REPO/.config/waybar/modules.jsonc" "$REPO/.config/waybar/style.css"

# --- tgconfirm: the owner-confirmation broker, its popup, unit and window rule ---------------------------------------------
CFD="$REPO/infrastructure/mcp/confirm"
TGU="$CFD/tgconfirm.service"
check "tgconfirm unit: runs as tgconfirm, never as root or aimcp" bash -c 'grep -q "^User=tgconfirm" "$1" && ! grep -q "^User=root\|^User=aimcp" "$1"' _ "$TGU"
check "tgconfirm unit: exactly one encrypted credential (the send token), and only starts once it exists" bash -c '[ "$(grep -c "^LoadCredentialEncrypted=" "$1")" = 1 ] && grep -q "^LoadCredentialEncrypted=send_token:/etc/credstore.encrypted/tgconfirm.send_token" "$1" && grep -q "^ConditionPathExists=/etc/credstore.encrypted/tgconfirm.send_token" "$1"' _ "$TGU"
check "tgconfirm unit: sandboxed, loopback only, no homes, no capabilities" bash -c 'grep -q "^NoNewPrivileges=yes" "$1" && grep -q "^ProtectSystem=strict" "$1" && grep -q "^InaccessiblePaths=/home /root" "$1" && grep -q "^IPAddressDeny=any" "$1" && grep -q "^IPAddressAllow=127.0.0.0/8" "$1" && grep -q "^CapabilityBoundingSet=$" "$1" && grep -q "^RestrictAddressFamilies=AF_UNIX AF_INET$" "$1" && ! grep -q "^ProtectHome=yes" "$1"' _ "$TGU"
check "tgconfirm unit: no secret and no owner uid in the repo file (the uid comes from the rendered drop-in)" bash -c '! grep -E "TOKEN=|OWNER_UID=[0-9]" "$1"' _ "$TGU"
check "tgconfirm unit: a refusal to start (78) is not retried in a loop" grep -q '^RestartPreventExitStatus=78' "$TGU"
check "tgconfirm unit passes systemd-analyze (paths aside)" bash -c 'systemd-analyze verify --man=no "$1" 2>&1 | grep -v -E "not executable|marked executable|No such file|Failed to create|User .* not found|credential" | grep -q -E "Unknown|Invalid|Failed to parse|bad setting" && exit 1; exit 0' _ "$TGU"
check "managed.tsv: tgconfirm is a service user with no ACL, no become, created by apply-system, with the Wayland ACL" bash -c '. "$1/infrastructure/users/lib.sh"; managed_has tgconfirm service && ! managed_has tgconfirm acl && ! managed_has tgconfirm become && managed_has tgconfirm create && managed_has tgconfirm wayland && ! managed_has tgconfirm clipboard && ! managed_has tgconfirm profile' _ "$REPO"
check "window rule float-confirm: float, center, pin, stay_focused, no_screen_share, class float.confirm" bash -c 'r=$(sed -n "/name = \"float-confirm\"/,/^})/p" "$1"); for k in "float = true" "center = true" "pin = true" "stay_focused = true" "no_screen_share = true"; do grep -qF "$k" <<<"$r" || exit 1; done; grep -q "class = .*float.*confirm" <<<"$r"' _ "$REPO/.config/hypr/hyprland.lua"
check "popup ghostty config: no keybinds, no clipboard access, no shell integration, nothing from the owner's config" bash -c 'grep -q "^keybind = clear" "$1" && grep -q "^clipboard-read = deny" "$1" && grep -q "^clipboard-write = deny" "$1" && grep -q "^shell-integration = none" "$1" && ! grep -q "config-file" "$1"' _ "$CFD/ghostty-popup.conf"
check "popup.py: the code comes from the system RNG and is never written or logged" bash -c 'grep -q "SystemRandom" "$1" && ! grep -n "print(.*code\|write.*code\|json.dump.*code" "$1"' _ "$CFD/popup.py"
count_py python3 -I "$HERE/test_confirm.py" "$REPO"
count_py python3 -I "$HERE/test_popup.py" "$REPO"

# --- mcp-guard: deny rules in a throwaway settings.json -----------------------------------------------------------------------
GUARD="$REPO/.local/bin/mcp-guard"
GS="$SCRATCH/guard/settings.json"; mkdir -p "$SCRATCH/guard"
printf '{\n  "permissions": {"allow": ["mcp__x"], "deny": ["Bash(rm -rf /:*)"], "defaultMode": "auto"},\n  "model": "opus"\n}\n' >"$GS"
cp "$GS" "$SCRATCH/guard/before.json"
check "guard --check fails before the rules exist" bash -c '! MCP_GUARD_SETTINGS="$2" "$1" --check' _ "$GUARD" "$GS"
MCP_GUARD_SETTINGS="$GS" "$GUARD" --dry-run >/dev/null
check "guard --dry-run writes nothing" cmp -s "$GS" "$SCRATCH/guard/before.json"
MCP_GUARD_SETTINGS="$GS" "$GUARD" >/dev/null
check "guard: the key-injection and capture tools are denied for the agents' Bash" bash -c 'for r in "Bash(wtype:*)" "Bash(wlrctl:*)" "Bash(hyprd:*)" "Bash(hyprctl eval:*)" "Bash(hyprctl dispatch:*)" "Bash(grim:*)"; do jq -e --arg r "$r" ".permissions.deny | index(\$r)" "$1" >/dev/null || exit 1; done' _ "$GS"
check "guard: existing rules, allow list, model and mode are kept" jq -e '.permissions.deny[0] == "Bash(rm -rf /:*)" and .permissions.allow == ["mcp__x"] and .permissions.defaultMode == "auto" and .model == "opus"' "$GS"
check "guard: a timestamped backup of the old file exists" bash -c 'ls "$1"/settings.json.bak-mcp-guard-* >/dev/null && cmp -s "$(ls "$1"/settings.json.bak-mcp-guard-* | head -1)" "$2"' _ "$SCRATCH/guard" "$SCRATCH/guard/before.json"
cp "$GS" "$SCRATCH/guard/after1.json"
MCP_GUARD_SETTINGS="$GS" "$GUARD" >/dev/null
check "guard: a second run is idempotent" cmp -s "$GS" "$SCRATCH/guard/after1.json"
check "guard --check passes afterwards" bash -c 'MCP_GUARD_SETTINGS="$2" "$1" --check' _ "$GUARD" "$GS"
MCP_GUARD_SETTINGS="$GS" "$GUARD" --remove >/dev/null
check "guard --remove restores the original content" bash -c 'diff <(jq -S . "$1") <(jq -S . "$2")' _ "$GS" "$SCRATCH/guard/before.json"
printf '{ broken' >"$GS"
check "guard: an unparsable settings file is left untouched" bash -c '! MCP_GUARD_SETTINGS="$2" "$1" >/dev/null 2>&1 && [ "$(cat "$2")" = "{ broken" ]' _ "$GUARD" "$GS"
check "guard: a missing settings file is created with the rules (mode 600)" bash -c 'rm -f "$2"; MCP_GUARD_SETTINGS="$2" "$1" >/dev/null && [ "$(stat -c %a "$2")" = 600 ] && MCP_GUARD_SETTINGS="$2" "$1" --check' _ "$GUARD" "$GS"

# --- AI hotkeys (ai-ask.sh) with fake hyprctl / grim / wl-paste / terminal / claude ---------------------------------------
AA="$REPO/.config/hypr/scripts/ai-ask.sh"
AADIR="$SCRATCH/ai-ask"
aa() { env PATH="$HERE/bin:$PATH" AI_ASK_DIR="$AADIR" AI_ASK_TERMINAL="$HERE/bin/fake-term" AI_ASK_CLAUDE="$HERE/bin/fake-claude" AI_ASK_NO_NOTIFY=1 \
  AI_ASK_GATEWAY="${AA_GW:-$HERE/fake_gw_tg.sh}" AI_ASK_HEADERS=/home/x/.local/bin/mcp-gateway-headers "$@"; }
wait_done() {
  local n=0
  while ((n < 50)); do
    grep -qx "done" "$FAKE_DIR/claude-session.txt" 2>/dev/null && return 0
    sleep 0.1
    n=$((n + 1))
  done
  return 1
}
reset_aa() { rm -rf "$AADIR" "$FAKE_DIR/claude-session.txt"; : >"$FAKE_DIR/argv.log"; : >"$FAKE_DIR/notify.log"; }
reset_aa
aa "$AA" --dry-run window >"$SCRATCH/aa-dry.out" 2>&1
check "dry-run window: plans a screenshot of that window only and the popup" bash -c 'grep -q "grim -g \"10,20 800x600\"" "$1" && grep -q "_session window" "$1"' _ "$SCRATCH/aa-dry.out"
check "dry-run touches nothing (no grim call, no directory)" bash -c '! grep -q "^grim" "$1" && [ ! -e "$2" ]' _ "$FAKE_DIR/argv.log" "$AADIR"
aa "$AA" --dry-run selection >/dev/null 2>&1; aa "$AA" --dry-run telegram >/dev/null 2>&1
check "dry-run selection/telegram create no files" test ! -e "$AADIR"
export FAKE_PRIMARY_TYPES="text/plain" FAKE_PRIMARY_TEXT="def f(): pass  # PRIMARY-SELECTION" FAKE_CLIP_TYPES="text/plain" FAKE_CLIP_TEXT="CLIPBOARD-TEXT"

reset_aa; aa "$AA" window; wait_done
check "window: claude runs in the context directory with context.md and window.png" bash -c 'grep -q "^cwd: $1$" "$2" && grep -q "files: .*context.md" "$2" && grep -q "window.png" "$2"' _ "$AADIR" "$FAKE_DIR/claude-session.txt"
check "window: context has class, title and the screenshot note" bash -c 'grep -q "application class: com.mitchellh.ghostty" "$1" && grep -q "title: nvim" "$1" && grep -q "screenshot of this window only" "$1"' _ "$FAKE_DIR/claude-session.txt"
check "window: grim got the window geometry only" grep -qx 'grim -g 10,20 800x600 '"$AADIR"'/window.png' "$FAKE_DIR/argv.log"
check "window: the desktop-ro tools are pre-allowed, the prompt is generic" bash -c 'grep "^argv:" "$1" | grep -q -- "--allowedTools mcp__desktop-ro" && ! grep "^argv:" "$1" | grep -q "nvim"' _ "$FAKE_DIR/claude-session.txt"
check "window: context files are removed when the session ends" bash -c '[ ! -e "$1/context.md" ] && [ ! -e "$1/window.png" ]' _ "$AADIR"
check "window: the context directory is private (700)" bash -c '[ "$(stat -c %a "$1")" = 700 ]' _ "$AADIR"

check "window: a strict MCP config with desktop-ro only" bash -c 'a=$(grep "^argv:" "$1"); grep -q -- "--strict-mcp-config" <<<"$a" && grep -q -- "--mcp-config" <<<"$a" && jq -e ".mcpServers | keys == [\"desktop-ro\"]" <(sed -n "/^--- mcp.json/,\$p" "$1" | sed 1d | sed "/^done/d")' _ "$FAKE_DIR/claude-session.txt"

reset_aa; aa "$AA" window --no-shot; wait_done
check "window --no-shot: no grim call, text only" bash -c '! grep -q "^grim" "$1" && grep -q "text only" "$2"' _ "$FAKE_DIR/argv.log" "$FAKE_DIR/claude-session.txt"
reset_aa; FAKE_ACTIVE='{"address":"0x1","class":"Bitwarden","title":"Vault","pid":5,"at":[0,0],"size":[500,500]}' aa "$AA" window; wait_done
check "window: a password-manager class is never screenshotted" bash -c '! grep -q "^grim" "$1" && grep -q "application class: Bitwarden" "$2"' _ "$FAKE_DIR/argv.log" "$FAKE_DIR/claude-session.txt"
reset_aa; FAKE_ACTIVE='{"address":"0x2","class":"org.telegram.desktop","title":"Ann","pid":6,"at":[0,0],"size":[500,500]}' aa "$AA" window --no-shot; wait_done
check "window: a Telegram window gets the chat-title hint" grep -q 'window title is the open chat' "$FAKE_DIR/claude-session.txt"

reset_aa; FAKE_TERM_INPUT="What does this do?" aa "$AA" selection; wait_done
check "selection: the primary selection is in context.md, not on argv" bash -c 'grep -q "PRIMARY-SELECTION" "$1" && ! grep "^argv:" "$1" | grep -q "PRIMARY-SELECTION"' _ "$FAKE_DIR/claude-session.txt"
check "selection: a strict MCP config with desktop-ro only (no telegram, no telegram-send)" bash -c 'a=$(grep "^argv:" "$1"); grep -q -- "--strict-mcp-config" <<<"$a" && jq -e ".mcpServers | keys == [\"desktop-ro\"]" <(sed -n "/^--- mcp.json/,\$p" "$1" | sed 1d | sed "/^done/d")' _ "$FAKE_DIR/claude-session.txt"
check "selection: the typed question reaches the prompt" bash -c 'grep "^argv:" "$1" | grep -q "Question: What does this do?"' _ "$FAKE_DIR/claude-session.txt"
reset_aa; FAKE_TERM_INPUT="" aa "$AA" selection; wait_done
check "selection: Enter alone asks to explain it" bash -c 'grep "^argv:" "$1" | grep -q "Explain what this is"' _ "$FAKE_DIR/claude-session.txt"
reset_aa; FAKE_PRIMARY_TYPES="" FAKE_PRIMARY_TEXT="" aa "$AA" selection; wait_done
check "selection: falls back to the clipboard text" grep -q 'CLIPBOARD-TEXT' "$FAKE_DIR/claude-session.txt"
reset_aa; FAKE_PRIMARY_TYPES="text/plain\nx-kde-passwordManagerHint" FAKE_CLIP_TYPES="text/plain\nx-kde-passwordManagerHint" aa "$AA" selection
check "selection: sensitive entries are refused, nothing launched" bash -c '[ ! -e "$1" ] && grep -q "nothing selected" <<<"$(AI_ASK_NO_NOTIFY=1 PATH="$2:$PATH" AI_ASK_DIR="$3" FAKE_PRIMARY_TYPES="text/plain\nx-kde-passwordManagerHint" FAKE_CLIP_TYPES="text/plain\nx-kde-passwordManagerHint" "$4" selection 2>&1)"' _ "$FAKE_DIR/claude-session.txt" "$HERE/bin" "$AADIR" "$AA"
reset_aa; FAKE_PRIMARY_TYPES="" FAKE_CLIP_TYPES="" aa "$AA" selection
check "selection: empty everywhere launches nothing" test ! -e "$FAKE_DIR/claude-session.txt"

reset_aa; aa "$AA" telegram; wait_done
check "telegram: strict MCP config with only the telegram server" bash -c 'a=$(grep "^argv:" "$1"); grep -q -- "--strict-mcp-config" <<<"$a" && grep -q -- "--mcp-config" <<<"$a" && jq -e ".mcpServers | keys == [\"telegram\"]" <(sed -n "/^--- mcp.json/,\$p" "$1" | sed 1d | sed "/^done/d")' _ "$FAKE_DIR/claude-session.txt"
check "telegram: without telegram-send on the gateway the session has the read server only and no send tool is pre-allowed beyond the names" bash -c 'jq -e ".mcpServers | has(\"telegram-send\") | not" <(sed -n "/^--- mcp.json/,\$p" "$1" | sed 1d | sed "/^done/d")' _ "$FAKE_DIR/claude-session.txt"
reset_aa; FAKE_GW_SEND=1 aa "$AA" telegram; wait_done
check "telegram: with the broker installed the session also gets telegram-send, nothing else" bash -c 'jq -e ".mcpServers | keys == [\"telegram\",\"telegram-send\"]" <(sed -n "/^--- mcp.json/,\$p" "$1" | sed 1d | sed "/^done/d")' _ "$FAKE_DIR/claude-session.txt"
check "telegram: only send_message and status of telegram-send are pre-allowed, never the whole server" bash -c 'a=$(grep "^argv:" "$1"); grep -q "mcp__telegram-send__send_message" <<<"$a" && ! grep -qE "mcp__telegram-send([ ,]|$)" <<<"$a"' _ "$FAKE_DIR/claude-session.txt"
reset_aa; aa "$AA" telegram; wait_done
check "telegram: the MCP config uses the headers helper, never a token" bash -c 'grep -q "headersHelper" "$1" && ! grep -q -i -E "bearer|test-gateway-token" "$1"' _ "$FAKE_DIR/claude-session.txt"
check "telegram: built-in tools limited to Bash, allowed only for wl-copy; no web tools" bash -c 'a=$(grep "^argv:" "$1"); grep -q -- "--tools Bash" <<<"$a" && grep -q -- "--allowedTools mcp__telegram,mcp__telegram-send__send_message,mcp__telegram-send__status,Bash(wl-copy:\*)" <<<"$a" && ! grep -q -i "web" <<<"$a"' _ "$FAKE_DIR/claude-session.txt"
check "telegram: the prompt forbids sending and marking read" bash -c 'grep "^argv:" "$1" | grep -q "never send anything" && grep "^argv:" "$1" | grep -q "Do not mark anything as read"' _ "$FAKE_DIR/claude-session.txt"
check "telegram: the session files are cleaned up" bash -c '[ ! -e "$1/mcp.json" ]' _ "$AADIR"
reset_aa; AA_GW=/bin/false aa "$AA" telegram; sleep 0.3
check "telegram: not set up -> no session, a clear message" bash -c '[ ! -e "$1" ]' _ "$FAKE_DIR/claude-session.txt"
check "the three AI binds exist in hyprland.lua" bash -c '[ "$(grep -c "scripts .. \"/ai-ask.sh" "$1")" = 3 ]' _ "$REPO/.config/hypr/hyprland.lua"
unset FAKE_PRIMARY_TYPES FAKE_PRIMARY_TEXT FAKE_CLIP_TYPES FAKE_CLIP_TEXT

echo "mcp tests: $PASS passed, $FAILS failed, $SKIPS skipped"
[[ $FAILS -eq 0 ]]
