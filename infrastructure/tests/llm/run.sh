#!/usr/bin/env bash
# Offline test of the local LLM (DEV-e): `llm` (models, token, serve argv, presets, client, bench), the unit files, the model catalogue.
# Everything runs against a FAKE llama-server speaking HTTP over a unix socket (fake_server.py), a fake curl / systemctl / fzf-menu / git
# identity and a private HOME + XDG dirs: WAYLAND_DISPLAY, DISPLAY and HYPRLAND_INSTANCE_SIGNATURE are unset and the fakes come first
# on PATH, so no test can open a window, notify, touch the real ~/.local/state/llm, /run/user/1000/llm or start the real model.
#   infrastructure/tests/llm/run.sh [--quick] [--keep] [--only=N,M]
# --quick skips the live systemd part (transient units in the real user manager, section 12); doctor runs --quick.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
LLM="$REPO/.local/bin/llm"
QUICK=0 KEEP=0 ONLY=""
for a in "$@"; do case $a in --quick) QUICK=1 ;; --keep) KEEP=1 ;; --only=*) ONLY=${a#--only=} ;; *) echo "usage: run.sh [--quick] [--keep] [--only=N,M]" >&2; exit 2 ;; esac; done

T=$(mktemp -d "${TMPDIR:-/tmp}/llm-test.XXXXXX")
LIVE_UNITS=""
# the REAL user manager (the test environment points XDG_RUNTIME_DIR at a private dir)
sc() { XDG_RUNTIME_DIR="/run/user/$(id -u)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus" /usr/bin/systemctl --user "$@"; }
live_cleanup() {
  [ -n "$LIVE_UNITS" ] || return 0
  sc stop llmtest.socket llmtest-proxy.service llmtest-server.service >/dev/null 2>&1
  rm -f $LIVE_UNITS "/run/user/$(id -u)/llmtest-token"
  rmdir "/run/user/$(id -u)/llmtest" 2>/dev/null
  sc daemon-reload >/dev/null 2>&1
  LIVE_UNITS=""
}
cleanup() {
  live_cleanup
  [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null
  [ "$KEEP" = 1 ] && { echo "kept $T"; return; }
  rm -rf "$T"
}
trap cleanup EXIT
unset WAYLAND_DISPLAY DISPLAY HYPRLAND_INSTANCE_SIGNATURE
export HOME="$T/home" XDG_RUNTIME_DIR="$T/run" XDG_STATE_HOME="$T/home/.local/state" XDG_DATA_HOME="$T/home/.local/share" \
  XDG_CONFIG_HOME="$T/home/.config" XDG_CACHE_HOME="$T/home/.cache"
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$T/fakes"
chmod 700 "$XDG_RUNTIME_DIR"
export PYTHONDONTWRITEBYTECODE=1 PYTHONPYCACHEPREFIX="$T/pycache"
export FAKE_LOG="$T/fake.log"
: >"$FAKE_LOG"
cp "$HERE/bin/"* "$T/fakes/"
export PATH="$T/fakes:$PATH"
# the catalogue and the config the tests use: tiny files instead of 1.3 GB models
export LLM_CATALOG="$T/models.tsv" LLM_CONFIG_DIR="$REPO/.config/llm"

PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1${2:+  [$2]}"; }
check() { # check NAME CONDITION-EXIT-CODE [detail]
  if [ "$2" = 0 ]; then ok "$1"; else bad "$1" "${3:-}"; fi
}
has() { grep -qF -- "$2" <<<"$1"; }
want_section() { [ -z "$ONLY" ] || [[ ",$ONLY," == *",$1,"* ]]; }
# run llm: OUT, ERR, RC
run() {
  OUT=$("$LLM" "$@" 2>"$T/err" </dev/null); RC=$?; ERR=$(cat "$T/err")
}
runin() { # runin STDIN args...
  local in=$1; shift
  OUT=$("$LLM" "$@" 2>"$T/err" <<<"$in"); RC=$?; ERR=$(cat "$T/err")
}

mkfixture() { # a catalogue of three small "models"
  head -c 300000 /dev/urandom >"$T/src-default.bin"
  head -c 120000 /dev/urandom >"$T/src-alt.bin"
  head -c 5000 /dev/urandom >"$T/src-tiny.bin"
  local s_d s_a s_t
  s_d=$(sha256sum "$T/src-default.bin" | cut -d' ' -f1)
  s_a=$(sha256sum "$T/src-alt.bin" | cut -d' ' -f1)
  s_t=$(sha256sum "$T/src-tiny.bin" | cut -d' ' -f1)
  {
    echo "# test catalogue"
    printf 'tm-default\ttm-default.gguf\thttps://example.invalid/default.gguf\t%s\t%s\tdefault\tthe default\n' "$s_d" "$(stat -c %s "$T/src-default.bin")"
    printf 'tm-alt\ttm-alt.gguf\thttps://example.invalid/alt.gguf\t%s\t%s\tquality\tthe quality one\n' "$s_a" "$(stat -c %s "$T/src-alt.bin")"
    printf 'tm-tiny\ttm-tiny.gguf\thttps://example.invalid/tiny.gguf\t%s\t%s\ttiny\tnever by default\n' "$s_t" "$(stat -c %s "$T/src-tiny.bin")"
  } >"$LLM_CATALOG"
}
mkfixture
MD="$XDG_DATA_HOME/llm/models" ST="$XDG_STATE_HOME/llm"

# ----------------------------------------------------------------------------------------------------------------------------
sec_models() {
  echo "-- 1 models: catalogue, fetch, stamps"
  run models list
  check "list shows every id, the active marker on the default" $([ $RC = 0 ] && has "$OUT" "* tm-default" && has "$OUT" "tm-alt" && has "$OUT" "tm-tiny" && echo 0 || echo 1) "$OUT"
  check "list: nothing fetched yet" $(has "$OUT" "missing" && ! has "$OUT" "fetched" && echo 0 || echo 1)
  run models path tm-alt
  check "path prints the file path under the models dir" $([ "$OUT" = "$MD/tm-alt.gguf" ] && echo 0 || echo 1) "$OUT"
  run models path nope
  check "path of an unknown id = exit 2" $([ $RC = 2 ] && has "$ERR" "unknown model" && echo 0 || echo 1)

  export FAKE_CURL_SRC="$T/src-default.bin"
  : >"$FAKE_LOG"
  run models fetch --default
  check "fetch --default downloads, verifies, stamps" $([ $RC = 0 ] && [ -f "$MD/tm-default.gguf" ] && [ -f "$ST/fetched/tm-default.gguf.ok" ] && [ ! -e "$MD/tm-default.gguf.part" ] && echo 0 || echo 1) "$RC $OUT $ERR"
  check "fetch uses curl -fL with resume and https only" $(grep -q -- '-fL' "$FAKE_LOG" && grep -q -- '-C -' "$FAKE_LOG" && grep -q -- '--proto =https' "$FAKE_LOG" && echo 0 || echo 1) "$(cat "$FAKE_LOG")"
  check "model file is 0600, the models dir 0700" $([ "$(stat -c %a "$MD/tm-default.gguf")" = 600 ] && [ "$(stat -c %a "$MD")" = 700 ] && echo 0 || echo 1)
  run models fetch --default
  check "second fetch is a no-op (no curl call)" $([ $RC = 0 ] && has "$OUT" "already fetched" && [ "$(grep -c '^curl' "$FAKE_LOG")" = 1 ] && echo 0 || echo 1)
  run models list
  check "list: fetched" $(has "$OUT" "fetched" && echo 0 || echo 1)
  run models check
  check "check: fetched file ok, exit 0" $([ $RC = 0 ] && has "$OUT" "tm-default: fetched" && echo 0 || echo 1) "$OUT"
  run models check --deep
  check "check --deep re-hashes and passes" $([ $RC = 0 ] && echo 0 || echo 1)

  # changed file: same size, new mtime -> stamp mismatch; unverified (no stamp) is re-hashed by fetch
  touch -d '2001-01-01' "$MD/tm-default.gguf"
  run models check
  check "touched file = changed, exit 1" $([ $RC = 1 ] && has "$OUT" "changed" && echo 0 || echo 1) "$OUT"
  run models fetch --default
  check "fetch re-verifies a changed file by hash and re-stamps it without downloading" $([ $RC = 0 ] && has "$OUT" "verified existing" && [ "$(grep -c '^curl' "$FAKE_LOG")" = 1 ] && echo 0 || echo 1) "$OUT $ERR"
  printf 'x' >>"$MD/tm-default.gguf"
  run models fetch --default
  check "a corrupted file is downloaded again" $([ $RC = 0 ] && [ "$(sha256sum "$MD/tm-default.gguf" | cut -d' ' -f1)" = "$(sha256sum "$T/src-default.bin" | cut -d' ' -f1)" ] && echo 0 || echo 1) "$OUT $ERR"

  # wrong hash: the download is deleted
  export FAKE_CURL_SRC="$T/src-tiny.bin"
  head -c 5000 /dev/urandom >"$T/src-wrong.bin"
  export FAKE_CURL_SRC="$T/src-wrong.bin"
  run models fetch tm-tiny
  check "wrong sha256: exit 1, part removed, no model file, no stamp" $([ $RC = 1 ] && has "$ERR" "sha256 does not match" && [ ! -e "$MD/tm-tiny.gguf.part" ] && [ ! -e "$MD/tm-tiny.gguf" ] && [ ! -e "$ST/fetched/tm-tiny.gguf.ok" ] && echo 0 || echo 1) "$RC $ERR"
  # wrong size
  head -c 100 /dev/urandom >"$T/src-short.bin"
  export FAKE_CURL_SRC="$T/src-short.bin"
  run models fetch tm-tiny
  check "wrong size: exit 1, part removed" $([ $RC = 1 ] && [ ! -e "$MD/tm-tiny.gguf.part" ] && [ ! -e "$MD/tm-tiny.gguf" ] && echo 0 || echo 1) "$ERR"

  # resume: a dropped connection keeps the part, the next run continues with -C - and ends verified
  export FAKE_CURL_SRC="$T/src-alt.bin"
  FAKE_CURL_CUT=50000 run models fetch tm-alt
  check "dropped connection: exit 1, part kept" $([ $RC = 1 ] && [ "$(stat -c %s "$MD/tm-alt.gguf.part")" = 50000 ] && [ ! -e "$MD/tm-alt.gguf" ] && echo 0 || echo 1) "$RC $ERR"
  run models list
  check "list shows the partial download" $(has "$OUT" "partial" && echo 0 || echo 1) "$OUT"
  run models fetch tm-alt
  check "resume completes from the part file" $([ $RC = 0 ] && [ -f "$ST/fetched/tm-alt.gguf.ok" ] && [ "$(sha256sum "$MD/tm-alt.gguf" | cut -d' ' -f1)" = "$(sha256sum "$T/src-alt.bin" | cut -d' ' -f1)" ] && echo 0 || echo 1) "$RC $ERR"
  # a complete part file (crash between download and rename) is verified without curl
  rm -f "$MD/tm-alt.gguf" "$ST/fetched/tm-alt.gguf.ok"; cp "$T/src-alt.bin" "$MD/tm-alt.gguf.part"
  n=$(grep -c '^curl' "$FAKE_LOG")
  run models fetch tm-alt
  check "a complete .part is verified and renamed without curl" $([ $RC = 0 ] && [ "$(grep -c '^curl' "$FAKE_LOG")" = "$n" ] && [ -f "$MD/tm-alt.gguf" ] && echo 0 || echo 1) "$ERR"
  FAKE_CURL_FAIL=22 run models fetch tm-tiny
  check "curl failure: exit 1 and says it can resume" $([ $RC = 1 ] && has "$ERR" "resume" && echo 0 || echo 1) "$ERR"
  unset FAKE_CURL_SRC

  rm -rf "$MD" "$ST/fetched"
  run models fetch --all-candidates
  check "--all-candidates skips the tiny role (fails here only because the fake curl has no source)" $(! has "$ERR" "tm-tiny" && echo 0 || echo 1) "$ERR"
  run models fetch nope
  check "fetch of an unknown id = exit 2" $([ $RC = 2 ] && echo 0 || echo 1)
  run models fetch --bogus
  check "fetch with an unknown option = exit 2" $([ $RC = 2 ] && echo 0 || echo 1)

  # catalogue sanity: the real catalogue
  local real="$REPO/.config/llm/models.tsv"
  check "real catalogue: every row has 6+ columns, a 64-hex sha256, a pinned 40-hex commit url, size" $(awk -F'\t' '!/^#/ && NF>0 { if (NF<6 || $4 !~ /^[0-9a-f]{64}$/ || $5 !~ /^[0-9]+$/ || $3 !~ /^https:\/\/huggingface\.co\/[^\/]+\/[^\/]+\/resolve\/[0-9a-f]{40}\//) bad=1; n++ } END { exit (bad || n<5) }' "$real" && echo 0 || echo 1)
  check "real catalogue: exactly one default row, qwen3.5-2b" $([ "$(awk -F'\t' '!/^#/ && $6=="default" {print $1}' "$real")" = "qwen3.5-2b" ] && echo 0 || echo 1)
  LLM_CATALOG="$real" run models list
  check "real catalogue parses" $([ $RC = 0 ] && has "$OUT" "qwen3.5-2b" && echo 0 || echo 1) "$ERR"
  mkfixture
}

sec_model() {
  echo "-- 2 model (active) and token"
  export FAKE_CURL_SRC="$T/src-default.bin"; run models fetch tm-default
  export FAKE_CURL_SRC="$T/src-alt.bin"; run models fetch tm-alt
  run model
  check "model: the default is active before anything is set" $([ $RC = 0 ] && has "$OUT" "tm-default" && echo 0 || echo 1) "$OUT"
  run model tm-tiny
  check "model NAME refuses a model that is not fetched (exit 3, tells the fix)" $([ $RC = 3 ] && has "$ERR" "llm models fetch tm-tiny" && echo 0 || echo 1) "$ERR"
  run model nope
  check "model: unknown id = exit 2" $([ $RC = 2 ] && echo 0 || echo 1)
  run model tm-alt
  check "model NAME sets the state file" $([ $RC = 0 ] && [ "$(cat "$ST/model")" = tm-alt ] && echo 0 || echo 1) "$OUT $ERR"
  run models list
  check "list marks the new active model" $(has "$OUT" "* tm-alt" && echo 0 || echo 1)
  # a loaded server is restarted (fake systemctl says active), an idle one is not
  cat >"$T/fakes/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"${FAKE_LOG:-/dev/null}"
case "$*" in
  *"is-active"*) [ "${FAKE_LOADED:-0}" = 1 ] ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$T/fakes/systemctl"
  : >"$FAKE_LOG"
  run model tm-default
  check "idle server: no restart" $(! grep -q 'systemctl --user stop' "$FAKE_LOG" && ! has "$OUT" restarted && echo 0 || echo 1) "$(cat "$FAKE_LOG")"
  : >"$FAKE_LOG"
  FAKE_LOADED=1 run model tm-alt
  check "loaded server: stopped and started again with the new model" $(grep -q 'systemctl --user stop llm-proxy.service llm-server.service' "$FAKE_LOG" && grep -q 'systemctl --user start llm-proxy.service' "$FAKE_LOG" && has "$OUT" restarted && echo 0 || echo 1) "$(cat "$FAKE_LOG")"
  # --pick through a fake fzf-menu
  cat >"$T/fakes/fzf-menu" <<'EOF'
#!/usr/bin/env bash
# fake: prints the row named by $FAKE_PICK (first tab field) from the rows on stdin; exit 1 = cancel
rows=$(cat)
printf '%s\n' "$rows" >"${FAKE_MENU_ROWS:-/dev/null}"
[ -n "${FAKE_PICK:-}" ] || exit 1
grep -P "^${FAKE_PICK}\t" <<<"$rows" | head -1
EOF
  chmod +x "$T/fakes/fzf-menu"
  FAKE_MENU_ROWS="$T/rows" FAKE_PICK=tm-default run model --pick
  check "--pick sets the chosen model; the active one is listed first" $([ $RC = 0 ] && [ "$(cat "$ST/model")" = tm-default ] && head -1 "$T/rows" | grep -q '^tm-alt' && echo 0 || echo 1) "$(head -2 "$T/rows")"
  FAKE_PICK= run model --pick
  check "--pick cancelled = nothing changes, exit 0" $([ $RC = 0 ] && [ "$(cat "$ST/model")" = tm-default ] && echo 0 || echo 1)
  FAKE_PICK=tm-tiny run model --pick
  check "--pick of a model that is not fetched = exit 3" $([ $RC = 3 ] && echo 0 || echo 1)
  unset FAKE_CURL_SRC

  echo "-- 2b token"
  run token path
  check "token path" $([ "$OUT" = "$ST/token" ] && echo 0 || echo 1)
  rm -f "$ST/token"
  run token ensure
  check "token ensure creates a 0600 file in a 0700 dir" $([ $RC = 0 ] && [ "$(stat -c %a "$ST/token")" = 600 ] && [ "$(stat -c %a "$ST")" = 700 ] && echo 0 || echo 1)
  t1=$(cat "$ST/token")
  check "token is long and url-safe" $([ ${#t1} -ge 40 ] && [[ $t1 =~ ^[A-Za-z0-9_-]+$ ]] && echo 0 || echo 1) "$t1"
  run token ensure
  check "ensure keeps the existing token" $([ "$(cat "$ST/token")" = "$t1" ] && echo 0 || echo 1)
  chmod 644 "$ST/token"; run token ensure
  check "ensure repairs a loose mode" $([ "$(stat -c %a "$ST/token")" = 600 ] && echo 0 || echo 1)
  : >"$FAKE_LOG"
  run token rotate
  check "rotate writes a new token (0600), idle server is not restarted" $([ "$(cat "$ST/token")" != "$t1" ] && [ "$(stat -c %a "$ST/token")" = 600 ] && ! grep -q 'systemctl --user stop' "$FAKE_LOG" && echo 0 || echo 1)
  FAKE_LOADED=1 run token rotate
  check "rotate restarts a loaded server" $(grep -q 'systemctl --user stop llm-proxy.service' "$FAKE_LOG" && echo 0 || echo 1)
  check "no tmp token left behind" $([ ! -e "$ST/token.tmp" ] && echo 0 || echo 1)
  run token bogus
  check "token usage error = exit 2" $([ $RC = 2 ] && echo 0 || echo 1)
}

sec_serve() {
  echo "-- 3 _serve: argv, checks, token, stale socket"
  export FAKE_CURL_SRC="$T/src-default.bin"
  run models fetch tm-default; unset FAKE_CURL_SRC
  rm -f "$ST/model" "$ST/token"
  export LLM_SERVER_BIN="$HERE/fake_server.py"
  run _serve --dry-run
  argv=$OUT
  check "dry-run exits 0 and prints one argument per line" $([ $RC = 0 ] && [ "$(head -1 <<<"$argv")" = "$HERE/fake_server.py" ] && echo 0 || echo 1) "$RC $ERR"
  for want in "--host" "$XDG_RUNTIME_DIR/llm-server/llama.sock" "--api-key-file" "$ST/token" "--cache-ram" "--no-webui" "--no-slots" "--offline" "--reasoning"; do
    check "argv has $want" $(grep -qxF -- "$want" <<<"$argv" && echo 0 || echo 1)
  done
  a=$(tr '\n' ' ' <<<"$argv")
  check "argv: -np 1, --cache-ram 0, --reasoning off, -ngl all, -fa auto, -c 8192, -t 4 -tb 4" $(has "$a" " -np 1 " && has "$a" "--cache-ram 0 " && has "$a" "--reasoning off " && has "$a" " -ngl all " && has "$a" " -fa auto " && has "$a" " -c 8192 " && has "$a" " -t 4 -tb 4" && echo 0 || echo 1) "$a"
  check "argv: model file and alias" $(has "$a" "-m $MD/tm-default.gguf " && has "$a" "-a tm-default " && echo 0 || echo 1) "$a"
  check "argv: no --port, no -v / --verbose, no --log-prompts-dir, no TCP address" $(! grep -qE '^(--port|-v|--verbose|--log-verbose|--log-prompts-dir|--log-file)$' <<<"$argv" && ! grep -qE '^(127\.|0\.0\.0\.0|::)' <<<"$argv" && echo 0 || echo 1)
  check "dry-run created the token (0600) but no socket dir" $([ "$(stat -c %a "$ST/token")" = 600 ] && [ ! -e "$XDG_RUNTIME_DIR/llm-server" ] && echo 0 || echo 1)
  # server.conf: keys, local override, unknown and bad values
  mkdir -p "$T/conf"
  printf 'ctx=4096\nthreads=2  # comment\nflash_attn=off\ngpu_layers=0\nbogus=1\n' >"$T/conf/server.conf"
  printf 'ctx=999999\nthreads=3\n' >"$T/conf/server.local.conf"
  LLM_CONFIG_DIR="$T/conf" run _serve --dry-run
  a=$(tr '\n' ' ' <<<"$OUT")
  check "server.conf values and the local override are applied" $(has "$a" " -c 4096 " && has "$a" " -t 3 -tb 3" && has "$a" " -fa off " && has "$a" " -ngl 0 " && echo 0 || echo 1) "$a"
  check "unknown key and bad value are warned about, not used" $(has "$ERR" "unknown key 'bogus'" && has "$ERR" "bad value for ctx" && echo 0 || echo 1) "$ERR"
  # the active model comes from the state file
  export FAKE_CURL_SRC="$T/src-alt.bin"; run models fetch tm-alt; run model tm-alt; unset FAKE_CURL_SRC
  run _serve --dry-run
  check "the active model is the one served" $(has "$OUT" "$MD/tm-alt.gguf" && has "$OUT" "tm-alt" && echo 0 || echo 1)
  # checks: missing / changed model = 78, missing server binary = 78
  touch -d '2002-02-02' "$MD/tm-alt.gguf"
  run _serve --dry-run
  check "changed model file = exit 78 with the fix" $([ $RC = 78 ] && has "$ERR" "llm models fetch tm-alt" && echo 0 || echo 1) "$RC $ERR"
  rm -f "$MD/tm-alt.gguf"
  run _serve --dry-run
  check "missing model file = exit 78" $([ $RC = 78 ] && has "$ERR" "missing" && echo 0 || echo 1) "$ERR"
  rm -f "$ST/model"
  LLM_SERVER_BIN="$T/nope" run _serve
  check "missing llama-server = exit 78 naming apply-system.sh" $([ $RC = 78 ] && has "$ERR" "apply-system.sh --only install" && echo 0 || echo 1) "$ERR"
  run _serve --bogus
  check "_serve usage error = exit 2" $([ $RC = 2 ] && echo 0 || echo 1)
  # real run: stale socket removed, device line logged, fake server up
  mkdir -p "$XDG_RUNTIME_DIR/llm-server"; : >"$XDG_RUNTIME_DIR/llm-server/llama.sock"
  "$LLM" _serve >"$T/serve.out" 2>"$T/serve.err" &
  SRV_PID=$!
  for _ in $(seq 50); do [ -S "$XDG_RUNTIME_DIR/llm-server/llama.sock" ] && break; sleep 0.1; done
  check "_serve execs the server on the unix socket (stale socket file replaced)" $([ -S "$XDG_RUNTIME_DIR/llm-server/llama.sock" ] && echo 0 || echo 1)
  check "device line is logged first" $(grep -q '^llm: model tm-default, devices: Vulkan0: AMD Radeon 860M' "$T/serve.out" && echo 0 || echo 1) "$(cat "$T/serve.out")"
  check "server dir is 0700" $([ "$(stat -c %a "$XDG_RUNTIME_DIR/llm-server")" = 700 ] && echo 0 || echo 1)
  code=$(/usr/bin/curl -s --unix-socket "$XDG_RUNTIME_DIR/llm-server/llama.sock" -o /dev/null -w '%{http_code}' http://x/health 2>/dev/null)
  check "the server answers /health through the socket" $([ "$code" = 200 ] && echo 0 || echo 1) "$code"
  kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=
  unset LLM_SERVER_BIN
}

sec_units() {
  echo "-- 4 unit files"
  U="$REPO/.config/systemd/user"
  sock=$(<"$U/llm.socket"); srv=$(<"$U/llm-server.service"); prx=$(<"$U/llm-proxy.service")
  check "socket is under %t, SocketMode=0600, DirectoryMode=0700, Service=llm-proxy.service" $(has "$sock" "ListenStream=%t/llm/llm.sock" && has "$sock" "SocketMode=0600" && has "$sock" "DirectoryMode=0700" && has "$sock" "Service=llm-proxy.service" && echo 0 || echo 1)
  check "no ListenStream with an address or port (unix socket only)" $(! grep -E '^ListenStream=' "$U/llm.socket" | grep -vq '^ListenStream=%t/' && ! grep -qE 'ListenStream=[0-9.:]+$|ListenStream=\[|127\.0\.0\.1|0\.0\.0\.0' "$U/llm.socket" && echo 0 || echo 1)
  check "socket is wanted by sockets.target (the only thing started at login)" $(has "$sock" "WantedBy=sockets.target" && echo 0 || echo 1)
  check "server: StopWhenUnneeded=yes, no [Install], Restart=no" $(has "$srv" "StopWhenUnneeded=yes" && ! has "$srv" "[Install]" && has "$srv" "Restart=no" && echo 0 || echo 1)
  check "proxy: --exit-idle-time=5min towards the backend socket, no [Install], Requires+After the server" $(has "$prx" "--exit-idle-time=5min %t/llm-server/llama.sock" && ! has "$prx" "[Install]" && has "$prx" "Requires=llm-server.service" && has "$prx" "After=llm-server.service" && echo 0 || echo 1)
  check "server limits: MemoryMax=, MemoryHigh=, CPUQuota=, MemorySwapMax=0, TasksMax=, Nice=, OOMScoreAdjust=" $(for k in MemoryMax= MemoryHigh= CPUQuota= MemorySwapMax=0 TasksMax= Nice= OOMScoreAdjust= CPUWeight= IOWeight=; do has "$srv" "$k" || exit 1; done && echo 0 || echo 1)
  check "server sandbox: NoNewPrivileges, PrivateTmp, ProtectSystem=strict, ProtectHome=read-only, AF_UNIX only, no PrivateDevices" $(has "$srv" "NoNewPrivileges=yes" && has "$srv" "PrivateTmp=yes" && has "$srv" "ProtectSystem=strict" && has "$srv" "ProtectHome=read-only" && has "$srv" "RestrictAddressFamilies=AF_UNIX" && ! grep -q '^PrivateDevices' "$U/llm-server.service" && echo 0 || echo 1)
  check "proxy sandbox: AF_UNIX only, ProtectSystem=strict" $(has "$prx" "RestrictAddressFamilies=AF_UNIX" && has "$prx" "ProtectSystem=strict" && echo 0 || echo 1)
  check "server waits for /health with a bound and stops waiting when the server died" $(has "$srv" "ExecStartPost=" && has "$srv" "timeout 180" && has "$srv" "/health" && has "$srv" 'kill -0' && has "$srv" "TimeoutStartSec=200" && echo 0 || echo 1)
  check "server ExecStart is llm _serve, condition on /usr/bin/llama-server" $(has "$srv" "ExecStart=%h/.local/bin/llm _serve" && has "$srv" "ConditionPathExists=/usr/bin/llama-server" && echo 0 || echo 1)
  check "no unit pulls the packaged llama-server.service or listens on a TCP port" $(! grep -vE '^\s*#' "$U"/llm*.service "$U/llm.socket" | grep -qE 'llama-server\.service|--port|ListenStream=[0-9]' && echo 0 || echo 1)
  if command -v systemd-analyze >/dev/null; then
    v=$(HOME=$(getent passwd "$(id -u)" | cut -d: -f6) systemd-analyze --user verify "$U/llm.socket" "$U/llm-proxy.service" "$U/llm-server.service" 2>&1 | grep -i 'llm' | grep -v 'marked executable')
    check "systemd-analyze --user verify: no complaint about the llm units" $([ -z "$v" ] && echo 0 || echo 1) "$v"
  fi
}

sec_live() {
  echo "-- live: the three units as transient llmtest-* copies in the real user manager (fake server, 3 s idle)"
  if [ "$QUICK" = 1 ]; then echo "skipped (--quick)"; return; fi
  local rr="/run/user/$(id -u)" U="$REPO/.config/systemd/user" ud
  ud="$rr/systemd/user"
  if [ ! -S "$rr/bus" ] || ! sc show -p Version >/dev/null 2>&1; then
    echo "skipped (no user manager)"; return
  fi
  mkdir -p "$ud"
  # the server runs with PrivateTmp: the token file lives in the runtime dir (0700, not in /tmp)
  head -c 24 /dev/urandom | base64 | tr -d '/+=\n' >"$rr/llmtest-token"
  local tok; tok=$(<"$rr/llmtest-token")
  sed -e 's#%t/llm/llm.sock#%t/llmtest/llm.sock#' -e 's#llm-proxy.service#llmtest-proxy.service#' "$U/llm.socket" >"$ud/llmtest.socket"
  sed -e 's#llm-server.service#llmtest-server.service#g' -e 's#--exit-idle-time=5min#--exit-idle-time=3s#' -e 's#%t/llm-server/#%t/llmtest-server/#g' "$U/llm-proxy.service" >"$ud/llmtest-proxy.service"
  sed -e '/^ConditionPathExists=/d' -e '/^Documentation=/d' -e 's#%t/llm-server/#%t/llmtest-server/#g' -e 's#^RuntimeDirectory=llm-server#RuntimeDirectory=llmtest-server#' \
      -e "s#^ExecStart=.*#ExecStart=/usr/bin/python3 -I $HERE/fake_server.py --host %t/llmtest-server/llama.sock --api-key-file $rr/llmtest-token --log %t/llmtest-server/requests.log#" "$U/llm-server.service" >"$ud/llmtest-server.service"
  LIVE_UNITS="$ud/llmtest.socket $ud/llmtest-proxy.service $ud/llmtest-server.service"
  sc daemon-reload
  sc start llmtest.socket
  active() { sc is-active "$1" 2>/dev/null; }
  local sock="$rr/llmtest/llm.sock"
  check "socket unit is listening, mode 0600, dir 0700" $([ "$(active llmtest.socket)" = active ] && [ "$(stat -c %a "$sock")" = 600 ] && [ "$(stat -c %a "$rr/llmtest")" = 700 ] && echo 0 || echo 1) "$(ls -l "$rr/llmtest" 2>&1)"
  check "before the first connection proxy and server are inactive" $([ "$(active llmtest-server.service)" != active ] && [ "$(active llmtest-proxy.service)" != active ] && echo 0 || echo 1)
  local code
  code=$(/usr/bin/curl -s --max-time 30 --unix-socket "$sock" -o /dev/null -w '%{http_code}' http://x/health)
  check "first connect starts proxy + server and /health answers 200 through the proxy" $([ "$code" = 200 ] && echo 0 || echo 1) "$code"
  check "both units are active after the first connect" $([ "$(active llmtest-server.service)" = active ] && [ "$(active llmtest-proxy.service)" = active ] && echo 0 || echo 1)
  code=$(/usr/bin/curl -s --max-time 30 --unix-socket "$sock" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d '{"model":"x","messages":[{"role":"user","content":"hi"}]}' -o "$T/live-resp" -w '%{http_code}' http://x/v1/chat/completions)
  check "a chat request works through socket -> proxy -> server (bearer token)" $([ "$code" = 200 ] && grep -q 'fake reply' "$T/live-resp" && echo 0 || echo 1) "$code $(cat "$T/live-resp" 2>/dev/null)"
  code=$(/usr/bin/curl -s --max-time 30 --unix-socket "$sock" -H 'Authorization: Bearer wrong' -d '{}' -o /dev/null -w '%{http_code}' http://x/v1/chat/completions)
  check "a wrong token is refused with 401" $([ "$code" = 401 ] && echo 0 || echo 1) "$code"
  local i gone=1
  for i in $(seq 40); do
    if [ "$(active llmtest-server.service)" != active ] && [ "$(active llmtest-proxy.service)" != active ]; then gone=0; break; fi
    sleep 0.5
  done
  check "4 s idle later proxy and server are inactive (the model would be unloaded)" $gone "$(active llmtest-proxy.service) $(active llmtest-server.service)"
  check "the socket still listens after the unload" $([ "$(active llmtest.socket)" = active ] && [ -S "$sock" ] && echo 0 || echo 1)
  check "the backend runtime dir is gone with the server" $([ ! -e "$rr/llmtest-server" ] && echo 0 || echo 1)
  code=$(/usr/bin/curl -s --max-time 30 --unix-socket "$sock" -o /dev/null -w '%{http_code}' http://x/health)
  check "the next connection starts it again" $([ "$code" = 200 ] && [ "$(active llmtest-server.service)" = active ] && echo 0 || echo 1) "$code"
  sc stop llmtest-proxy.service llmtest-server.service >/dev/null 2>&1
  check "stopping proxy and server (llm stop) leaves both inactive and the socket listening" $([ "$(active llmtest-server.service)" != active ] && [ "$(active llmtest-proxy.service)" != active ] && [ "$(active llmtest.socket)" = active ] && echo 0 || echo 1)
  live_cleanup
  check "cleanup removed the test units" $([ ! -e "$ud/llmtest.socket" ] && [ "$(sc is-active llmtest.socket 2>/dev/null)" != active ] && echo 0 || echo 1)
}

# ----------------------------------------------------------------------------------------------------------------------------
SECTIONS=(models:sec_models model:sec_model serve:sec_serve units:sec_units live:sec_live)
n=0
for s in "${SECTIONS[@]}"; do
  n=$((n + 1))
  want_section "$n" || continue
  "${s#*:}"
done
echo "llm tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] && [ "$PASS" -gt 0 ]
