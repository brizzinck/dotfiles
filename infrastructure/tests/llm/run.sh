#!/usr/bin/env bash
# Offline test of the local LLM (DEV-e): `llm` (models, token, serve argv, presets, client, bench), the unit files, the model catalogue.
# Everything runs against a FAKE llama-server speaking HTTP over a unix socket (fake_server.py), a fake curl / systemctl / fzf-menu / git
# identity and a private HOME + XDG dirs: WAYLAND_DISPLAY, DISPLAY and HYPRLAND_INSTANCE_SIGNATURE are unset and the fakes come first
# on PATH, so no test can open a window, notify, touch the real ~/.local/state/llm, /run/user/1000/llm or start the real model.
#   infrastructure/tests/llm/run.sh [--quick] [--keep] [--only=N,M]
# --quick skips the live systemd part (transient units in the real user manager, section 5); doctor runs --quick.
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
# fake systemctl: logs the call; is-active answers by FAKE_LOADED (1 = the server is loaded); show prints the properties llm status reads
cat >"$T/fakes/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"${FAKE_LOG:-/dev/null}"
case "$*" in
  *"is-active"*) [ "${FAKE_LOADED:-0}" = 1 ] ;;
  *" show "*)
    if [ "${FAKE_LOADED:-0}" = 1 ]; then printf 'ActiveState=active\nActiveEnterTimestamp=Sun 2026-10-18 10:00:00 CEST\nMemoryCurrent=734003200\n'
    else printf 'ActiveState=inactive\nActiveEnterTimestamp=\nMemoryCurrent=[not set]\n'; fi ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$T/fakes/systemctl"
# fake pacman (versions for the device cache key) and fake fzf-menu are created where they are used
printf '#!/usr/bin/env bash\n[ "$1 $2" = "-Q ggml-vulkan" ] && { echo "ggml-vulkan 0.26.0-1"; exit 0; }\n[ "$1 $2" = "-Q llama-cpp" ] && { echo "llama-cpp 0.6.0-1"; exit 0; }\nexit 1\n' >"$T/fakes/pacman"
chmod +x "$T/fakes/pacman"
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

# ---- client sections: a fake llama-server on the public socket
FAKE_PID=""
fake_up() { # fake_up [token-file]
  fake_down
  mkdir -p "$XDG_RUNTIME_DIR/llm"; chmod 700 "$XDG_RUNTIME_DIR/llm"
  : >"$T/req.log"; : >"$T/conns.log"
  FAKE_LLM_CONNS="$T/conns.log" python3 -I "$HERE/fake_server.py" --host "$XDG_RUNTIME_DIR/llm/llm.sock" --api-key-file "${1:-$ST/token}" \
    --log "$T/req.log" --ctl "$T/ctl.json" >/dev/null 2>&1 &
  FAKE_PID=$!
  for _ in $(seq 50); do [ -S "$XDG_RUNTIME_DIR/llm/llm.sock" ] && break; sleep 0.1; done
}
fake_down() {
  [ -n "$FAKE_PID" ] && { kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; }
  FAKE_PID=""
  rm -f "$XDG_RUNTIME_DIR/llm/llm.sock"
}
ctl() { if [ -n "$1" ]; then printf '%s' "$1" >"$T/ctl.json"; else rm -f "$T/ctl.json"; fi; }
req() { tail -1 "$T/req.log" | jq -r "$1"; }   # a field of the last request body
nreq() { wc -l <"$T/req.log" | tr -d ' '; }
client_setup() {
  export FAKE_CURL_SRC="$T/src-default.bin"; run models fetch tm-default; unset FAKE_CURL_SRC
  rm -f "$ST/model"; run token ensure
  export LLM_SERVER_BIN="$HERE/fake_server.py"
  ctl ''
  fake_up
}
client_teardown() { fake_down; unset LLM_SERVER_BIN; ctl ''; }

sec_presets() {
  echo "-- 6 presets: request bodies, input, output"
  client_setup
  run ask "what is 2+2"
  check "ask: answer on stdout, nothing else" $([ $RC = 0 ] && [ "$OUT" = "fake reply" ] && echo 0 || echo 1) "$RC $OUT $ERR"
  check "ask body: model, system, temperature 0.3, top_p 0.9, max_tokens 800, no stream, enable_thinking false" $([ "$(req .model)" = tm-default ] && [[ "$(req '.messages[0].content')" == *"helpful assistant"* ]] && [ "$(req .temperature)" = 0.3 ] && [ "$(req .top_p)" = 0.9 ] && [ "$(req .max_tokens)" = 800 ] && [ "$(req .stream)" = false ] && [ "$(req .chat_template_kwargs.enable_thinking)" = false ] && echo 0 || echo 1) "$(tail -1 "$T/req.log")"
  check "ask body: user message is the text, no grammar" $([ "$(req '.messages[1].content')" = "what is 2+2" ] && [ "$(req 'has("grammar")')" = false ] && echo 0 || echo 1)
  run "plain question without a preset"
  check "no preset named = ask with the arguments" $([ $RC = 0 ] && [ "$(req '.messages[1].content')" = "plain question without a preset" ] && [[ "$(req '.messages[0].content')" == *"helpful assistant"* ]] && echo 0 || echo 1) "$RC $ERR"
  runin "from stdin" ask
  check "text from stdin (one trailing newline dropped)" $([ "$(req '.messages[1].content')" = "from stdin" ] && echo 0 || echo 1) "$(req '.messages[1].content')"
  runin "ignored stdin" ask "args win"
  check "arguments win over stdin" $([ "$(req '.messages[1].content')" = "args win" ] && echo 0 || echo 1)
  run translate "Привет, мир"
  check "translate: Cyrillic text goes to English (system names the languages, temperature 0.2)" $([[ "$(req '.messages[0].content')" == *"into English"* ]] && [[ "$(req '.messages[0].content')" == *"detect it"* ]] && [ "$(req .temperature)" = 0.2 ] && echo 0 || echo 1) "$(req '.messages[0].content')"
  run translate "Hello, world"
  check "translate: Latin text goes to Russian" $([[ "$(req '.messages[0].content')" == *"into Russian"* ]] && echo 0 || echo 1)
  run translate --to uk --from en "Hello"
  check "translate --to uk --from en names both" $([[ "$(req '.messages[0].content')" == *"from English into Ukrainian"* ]] && echo 0 || echo 1) "$(req '.messages[0].content')"
  check "translate max_tokens = 2*len//3+64 (5 chars -> 67)" $([ "$(req .max_tokens)" = 67 ] && echo 0 || echo 1) "$(req .max_tokens)"
  long=$(head -c 6000 /dev/zero | tr '\0' 'a')
  run translate "$long"
  check "translate max_tokens is capped at 2048 (6000 chars)" $([ "$(req .max_tokens)" = 2048 ] && echo 0 || echo 1) "$(req .max_tokens)"
  run translate --to de "x"
  check "translate: unknown language = exit 2" $([ $RC = 2 ] && echo 0 || echo 1)
  run fix --to en "x"
  check "--to with another preset = exit 2" $([ $RC = 2 ] && echo 0 || echo 1)
  run shorten "twelve chars"
  check "shorten: max_tokens = len//4+64 and temperature 0.3" $([ "$(req .max_tokens)" = 67 ] && [ "$(req .temperature)" = 0.3 ] && echo 0 || echo 1) "$(req .max_tokens)"
  run explain "x"; ex_ok=$([ "$(req .max_tokens)" = 600 ] && echo 0 || echo 1)
  run fix "x"; fx_ok=$([ "$(req .temperature)" = 0.1 ] && [[ "$(req '.messages[0].content')" == *"Fix punctuation"* ]] && echo 0 || echo 1)
  run rewrite "x"; rw_ok=$([ "$(req .temperature)" = 0.5 ] && echo 0 || echo 1)
  check "explain 600 tokens, fix temperature 0.1, rewrite temperature 0.5" $([ "$ex_ok$fx_ok$rw_ok" = 000 ] && echo 0 || echo 1)
  run ask --max-tokens 33 --temperature 0.9 "x"
  check "--max-tokens and --temperature override the preset" $([ "$(req .max_tokens)" = 33 ] && [ "$(req .temperature)" = 0.9 ] && echo 0 || echo 1)
  run ask --model tm-default "x"
  check "--model with the active model is fine" $([ $RC = 0 ] && echo 0 || echo 1)
  run ask --model qwen3.5-4b "x"
  check "--model with another model = exit 2, no implicit switch" $([ $RC = 2 ] && has "$ERR" "llm model" && echo 0 || echo 1) "$ERR"
  n0=$(nreq); run ask --model nope "x"
  check "no request was sent for the refused model" $([ "$(nreq)" = "$n0" ] && echo 0 || echo 1)

  run ask --json "x"
  check "--json: text, model, timings" $([ "$(jq -r .text <<<"$OUT")" = "fake reply" ] && [ "$(jq -r .model <<<"$OUT")" = tm-default ] && [ "$(jq -r .timings.prompt_n <<<"$OUT")" = 12 ] && jq -e '.timings.predicted_ms == 40' <<<"$OUT" >/dev/null && echo 0 || echo 1) "$OUT"
  ctl '{"fence": true, "reply": "Привет, мир"}'
  run translate "Hello world"
  check "translate: a wrapping code fence is stripped" $([ "$OUT" = "Привет, мир" ] && echo 0 || echo 1) "$OUT"
  run ask "x"
  check "ask: the fence is kept (not pasted verbatim anywhere)" $([[ "$OUT" == '```'* ]] && echo 0 || echo 1) "$OUT"
  ctl '{"reply": "\"Привіт, світе\""}'
  run translate --to uk "Hello world"
  check "translate: one pair of wrapping quotes is stripped" $([ "$OUT" = "Привіт, світе" ] && echo 0 || echo 1) "$OUT"
  ctl '{"reply": "He said \"hi\" and \"bye\""}'
  run fix "x"
  check "fix: inner quotes are kept (only a wrapping pair goes)" $([ "$OUT" = 'He said "hi" and "bye"' ] && echo 0 || echo 1) "$OUT"
  ctl '{"reply": "  spaced  \n"}'
  run fix "x"
  check "fix: surrounding whitespace is stripped" $([ "$OUT" = "spaced" ] && echo 0 || echo 1) "[$OUT]"
  ctl '{"reply": "<think>reasoning</think>The answer", "reasoning": "hidden thoughts"}'
  run ask "x"
  check "reasoning_content and <think> blocks never reach stdout" $([ "$OUT" = "The answer" ] && echo 0 || echo 1) "$OUT"
  ctl ''
  # input limit
  big=$(head -c 12001 /dev/zero | tr '\0' 'a')
  run ask "$big"
  check "12001 characters = exit 2 text too long" $([ $RC = 2 ] && has "$ERR" "too long" && echo 0 || echo 1) "$ERR"
  ok12=$(head -c 12000 /dev/zero | tr '\0' 'a')
  run ask "$ok12"
  check "12000 characters are accepted" $([ $RC = 0 ] && echo 0 || echo 1)
  run ask
  check "no text at all = exit 2" $([ $RC = 2 ] && echo 0 || echo 1) "$ERR"
  run ask --bogus x
  check "unknown option = exit 2" $([ $RC = 2 ] && echo 0 || echo 1)
  OUT=$("$LLM" 2>/dev/null); RC=$?
  check "llm with no arguments = exit 2" $([ $RC = 2 ] && echo 0 || echo 1)
  run --help
  check "--help prints the reference, exit 0" $([ $RC = 0 ] && has "$OUT" "fix-layout" && has "$OUT" "llm bench" && echo 0 || echo 1)
  # streaming only on a terminal
  n0=$(nreq)
  script -qec "$LLM ask hi" /dev/null >"$T/pty.out" 2>&1
  check "on a terminal the request streams and the answer is printed" $([ "$(nreq)" = $((n0 + 1)) ] && [ "$(req .stream)" = true ] && grep -q 'fake reply' "$T/pty.out" && echo 0 || echo 1) "$(cat "$T/pty.out")"
  run ask --no-stream "x"; check "--no-stream and a pipe: not streamed" $([ "$(req .stream)" = false ] && echo 0 || echo 1)
  script -qec "$LLM ask --no-stream hi" /dev/null >"$T/pty.out" 2>&1
  check "--no-stream on a terminal: not streamed" $([ "$(req .stream)" = false ] && echo 0 || echo 1)
  script -qec "$LLM ask --json hi" /dev/null >"$T/pty.out" 2>&1
  check "--json on a terminal: not streamed" $([ "$(req .stream)" = false ] && echo 0 || echo 1)
  client_teardown
}

sec_commit() {
  echo "-- 7 commit-msg in a temp git repo"
  client_setup
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  local r="$T/repo"; mkdir -p "$r"; git -C "$r" init -q; printf 'one\n' >"$r/a.txt"; git -C "$r" add a.txt; git -C "$r" commit -qm init
  printf 'one\ntwo\n' >"$r/a.txt"; printf 'new file\n' >"$r/b.txt"; git -C "$r" add a.txt b.txt
  OUT=$(cd "$r" && "$LLM" commit-msg 2>"$T/err" </dev/null); RC=$?; ERR=$(cat "$T/err")
  check "commit-msg works in a repo with staged changes" $([ $RC = 0 ] && [ "$OUT" = "fake reply" ] && echo 0 || echo 1) "$RC $OUT $ERR"
  u=$(req '.messages[1].content')
  check "user message = diffstat first, then the staged diff" $([[ "$u" == "Staged changes:"* ]] && [[ "$u" == *" a.txt | +1 -0"* ]] && [[ "$u" == *" b.txt | +1 -0"* ]] && [[ "$u" == *"2 files changed"* ]] && [[ "$u" == *"diff --git a/a.txt b/a.txt"* ]] && [[ "$u" == *"+two"* ]] && echo 0 || echo 1) "$u"
  check "commit-msg body: Conventional Commits system prompt, max_tokens 200, temperature 0.2" $([[ "$(req '.messages[0].content')" == *"Conventional Commits"* ]] && [ "$(req .max_tokens)" = 200 ] && [ "$(req .temperature)" = 0.2 ] && echo 0 || echo 1)
  OUT=$(cd "$r" && printf 'unstaged\n' >>a.txt && git reset -q && "$LLM" commit-msg 2>"$T/err" </dev/null); RC=$?; ERR=$(cat "$T/err")
  check "nothing staged = exit 2 with the hint" $([ $RC = 2 ] && has "$ERR" "nothing staged" && echo 0 || echo 1) "$RC $ERR"
  OUT=$(cd "$T" && "$LLM" commit-msg 2>"$T/err" </dev/null); RC=$?; ERR=$(cat "$T/err")
  check "outside a repo = exit 2" $([ $RC = 2 ] && has "$ERR" "git" && echo 0 || echo 1) "$ERR"
  # a diff on stdin replaces the staged one
  d=$(cat "$REPO/.config/llm/eval/commit/001.diff")
  OUT=$(cd "$r" && "$LLM" commit-msg 2>"$T/err" <<<"$d"); RC=$?
  u=$(req '.messages[1].content')
  check "a diff on stdin is used instead of git (stat computed from it)" $([ $RC = 0 ] && [[ "$u" == *" internal/auth/token.go | +4 -1"* ]] && echo 0 || echo 1) "$u"
  # truncation
  head -c 30000 /dev/urandom | base64 -w 80 >"$r/big.txt"; git -C "$r" add big.txt
  OUT=$(cd "$r" && "$LLM" commit-msg 2>"$T/err" </dev/null); RC=$?
  u=$(req '.messages[1].content')
  check "a big diff is cut at 12000 characters with the [diff truncated] marker" $([ $RC = 0 ] && [[ "$u" == *"[diff truncated]" ]] && [ ${#u} -lt 12600 ] && [[ "$u" == *" big.txt | +"* ]] && echo 0 || echo 1) "${#u}"
  ctl '{"fence": true, "reply": "feat(core): add b"}'
  OUT=$(cd "$r" && "$LLM" commit-msg 2>"$T/err" </dev/null)
  check "commit-msg: a wrapping code fence is stripped" $([ "$OUT" = "feat(core): add b" ] && echo 0 || echo 1) "$OUT"
  unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  client_teardown
}

sec_layout() {
  echo "-- 8 fix-layout"
  client_setup
  ctl '{"pick": "1"}'
  run fix-layout ghbdtn
  check "ghbdtn -> the model picked candidate 1 (привет)" $([ $RC = 0 ] && [ "$OUT" = "привет" ] && echo 0 || echo 1) "$OUT $ERR"
  check "request: grammar root ::= [0-1] (two distinct candidates), max_tokens 1, temperature 0" $([ "$(req .grammar)" = 'root ::= [0-1]' ] && [ "$(req .max_tokens)" = 1 ] && [ "$(req '.temperature == 0')" = true ] && echo 0 || echo 1) "$(tail -1 "$T/req.log")"
  check "request: the candidates are listed by index" $([ "$(req '.messages[1].content')" = $'0: ghbdtn\n1: привет' ] && echo 0 || echo 1) "$(req '.messages[1].content')"
  ctl '{"pick": "2"}'
  run fix-layout ghbdsn
  check "ghbdsn (ua): three candidates, the model picks привіт" $([ "$OUT" = "привіт" ] && [ "$(req .grammar)" = 'root ::= [0-2]' ] && echo 0 || echo 1) "$OUT $(req .grammar)"
  check "ghbdsn candidates: as typed, us->ru (привыт), us->ua (привіт)" $([ "$(req '.messages[1].content')" = $'0: ghbdsn\n1: привыт\n2: привіт' ] && echo 0 || echo 1) "$(req '.messages[1].content')"
  ctl '{"pick": "1"}'
  run fix-layout "руддщ"
  check "руддщ -> hello" $([ "$OUT" = "hello" ] && echo 0 || echo 1) "$OUT"
  ctl '{"pick": "0"}'
  run fix-layout "hello world"
  check "English is kept as typed when the model says 0" $([ "$OUT" = "hello world" ] && echo 0 || echo 1) "$OUT"
  runin "ghbdtn" fix-layout
  check "text on stdin works" $([ "$(req '.messages[1].content')" = $'0: ghbdtn\n1: привет' ] && echo 0 || echo 1)
  run fix-layout "1234 !!!"
  check "text without letters has one candidate: printed as is, the model is not asked" $([ "$OUT" = "1234 !!!" ] && echo 0 || echo 1) "$OUT"
  n0=$(nreq); run fix-layout --no-llm ghbdtn
  check "--no-llm: heuristic pick, no request" $([ "$OUT" = "привет" ] && [ "$(nreq)" = "$n0" ] && echo 0 || echo 1) "$OUT"
  # the heuristic over the whole eval set
  good=0 tot=0 miss=""
  while IFS=$'\t' read -r typed want; do
    case $typed in ''|'#'*) continue ;; esac
    tot=$((tot + 1)); got=$("$LLM" fix-layout --no-llm "$typed" 2>/dev/null </dev/null)
    if [ "$got" = "$want" ]; then good=$((good + 1)); else miss="$miss [$typed -> $got]"; fi
  done <"$REPO/.config/llm/eval/layout.tsv"
  check "the offline guess gets every row of eval/layout.tsv ($good/$tot)" $([ "$good" = "$tot" ] && echo 0 || echo 1) "$miss"
  # the model cannot answer: nonsense, error, no server -> offline guess, exit 0
  ctl '{"pick": "9"}'
  run fix-layout ghbdtn
  check "a nonsense answer falls back to the offline guess" $([ $RC = 0 ] && [ "$OUT" = "привет" ] && echo 0 || echo 1) "$OUT"
  ctl '{"status": 503}'
  run fix-layout ghbdtn
  check "a server error falls back to the offline guess (stderr says so)" $([ $RC = 0 ] && [ "$OUT" = "привет" ] && has "$ERR" "offline guess" && echo 0 || echo 1) "$OUT $ERR"
  ctl ''; fake_down
  run fix-layout ghbdtn
  check "no socket: offline guess, exit 0" $([ $RC = 0 ] && [ "$OUT" = "привет" ] && echo 0 || echo 1) "$RC $OUT $ERR"
  run fix-layout --dry-run ghbdtn
  check "fix-layout --dry-run lists the candidates and the grammar, not the text" $([ $RC = 0 ] && has "$OUT" 'root ::= [0-1]' && has "$OUT" "candidates: 2" && echo 0 || echo 1) "$OUT"
  client_teardown
}

sec_errors() {
  echo "-- 9 errors and exit codes"
  client_setup
  LLM_SERVER_BIN="$T/nope" run ask "x"
  check "no llama-server = exit 3 with the install command" $([ $RC = 3 ] && has "$ERR" "apply-system.sh --only install" && echo 0 || echo 1) "$RC $ERR"
  printf 'tm-tiny\n' >"$ST/model"
  run ask "x"
  check "model not fetched = exit 3 with the fetch command" $([ $RC = 3 ] && has "$ERR" "llm models fetch tm-tiny" && echo 0 || echo 1) "$RC $ERR"
  rm -f "$ST/model"
  fake_down
  run ask "x"
  check "no socket = exit 3 with the enable command" $([ $RC = 3 ] && has "$ERR" "systemctl --user enable --now llm.socket" && echo 0 || echo 1) "$RC $ERR"
  printf 'other-token\n' >"$T/other-token"
  fake_up "$T/other-token"
  run ask "x"
  check "a refused token = exit 1 mentioning the token" $([ $RC = 1 ] && has "$ERR" "token" && echo 0 || echo 1) "$RC $ERR"
  fake_up
  ctl '{"status": 503}'
  run ask "x"
  check "server 503 = exit 1 with the message" $([ $RC = 1 ] && has "$ERR" "server error 503" && has "$ERR" "overloaded" && echo 0 || echo 1) "$RC $ERR"
  ctl '{"sleep": 3}'
  t0=$(date +%s)
  run ask --timeout 1 "x"
  check "no answer within --timeout = exit 4" $([ $RC = 4 ] && [ $(( $(date +%s) - t0 )) -lt 3 ] && echo 0 || echo 1) "$RC $ERR"
  ctl '{"close": true}'
  run ask "x"
  check "the connection closed early = exit 1 with the journal hint" $([ $RC = 1 ] && has "$ERR" "journalctl --user -u llm-server" && echo 0 || echo 1) "$RC $ERR"
  ctl ''
  fake_down
  run ask --dry-run "SECRET-SENTINEL-4711 text"
  check "--dry-run needs no server and exits 0" $([ $RC = 0 ] && has "$OUT" "preset: ask" && echo 0 || echo 1) "$RC $ERR"
  check "--dry-run never prints the input text (only its length)" $(! has "$OUT" "SECRET-SENTINEL" && ! has "$ERR" "SECRET-SENTINEL" && has "$OUT" "input: 25 characters" && echo 0 || echo 1) "$OUT"
  runin "STDIN-SENTINEL-4711" translate --dry-run
  check "--dry-run with stdin: text not printed either" $(! has "$OUT" "STDIN-SENTINEL" && echo 0 || echo 1)
  run translate --dry-run --to uk "SECRET-SENTINEL-4711"
  check "--dry-run translate prints the system prompt with the languages and max_tokens" $(has "$OUT" "into Ukrainian" && has "$OUT" "max_tokens: 77" && ! has "$OUT" "SECRET-SENTINEL" && echo 0 || echo 1) "$OUT"
  client_teardown
}

sec_status() {
  echo "-- 10 status, start, stop"
  client_setup
  : >"$T/conns.log"
  run status
  check "status prints package, device, model, socket, server lines" $([ $RC = 0 ] && has "$OUT" "package:" && has "$OUT" "Vulkan0: AMD Radeon 860M" && has "$OUT" "model:    tm-default" && has "$OUT" "listening" && has "$OUT" "not loaded" && echo 0 || echo 1) "$OUT"
  check "status never connects to the model socket" $([ ! -s "$T/conns.log" ] && echo 0 || echo 1) "$(cat "$T/conns.log")"
  check "status caches the device list" $([ -f "$ST/devices.json" ] && echo 0 || echo 1)
  run status
  check "second status reads the cache" $(has "$OUT" "(cached)" && echo 0 || echo 1)
  FAKE_LOADED=1 run status
  check "loaded: since and memory" $(has "$OUT" "loaded since Sun 2026-10-18" && has "$OUT" "memory 734.0 MB" && echo 0 || echo 1) "$OUT"
  run status --json
  check "status --json is valid JSON with the fields" $([ "$(jq -r .model <<<"$OUT")" = tm-default ] && [ "$(jq -r .socket <<<"$OUT")" = true ] && [ "$(jq -r .loaded <<<"$OUT")" = false ] && [ "$(jq -r .gpu <<<"$OUT")" = true ] && echo 0 || echo 1) "$OUT"
  LLM_SERVER_BIN="$T/nope" run status
  check "status without the package says how to install it (exit 0)" $([ $RC = 0 ] && has "$OUT" "not installed" && echo 0 || echo 1) "$OUT"
  : >"$FAKE_LOG"
  FAKE_LOADED=1 run start
  check "start: systemctl start llm-proxy.service, reports the model" $([ $RC = 0 ] && grep -q 'systemctl --user start llm-proxy.service' "$FAKE_LOG" && has "$OUT" "loaded tm-default" && echo 0 || echo 1) "$RC $OUT $ERR"
  run start
  check "start that does not end up loaded = exit 1 with the journal hint" $([ $RC = 1 ] && has "$ERR" "journalctl" && echo 0 || echo 1) "$ERR"
  : >"$FAKE_LOG"
  run stop
  check "stop: stops proxy and server, exit 0" $([ $RC = 0 ] && grep -q 'systemctl --user stop llm-proxy.service llm-server.service' "$FAKE_LOG" && echo 0 || echo 1)
  FAKE_LOADED=1 run stop
  check "stop that leaves it running = exit 1" $([ $RC = 1 ] && echo 0 || echo 1)
  client_teardown
}

sec_bench() {
  echo "-- 11 bench and chrF"
  out=$(PYTHONPYCACHEPREFIX="$T/pycache" python3 -I - "$LLM" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("llmmod", sys.argv[1])
spec = importlib.util.spec_from_loader("llmmod", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
print("same", round(m.chrf("Привет, мир", "Привет, мир")))
print("diff", m.chrf("совсем другое", "Привет, мир") < 40)
print("close", 40 < m.chrf("Привет мир", "Привет, мир") < 100)
print("empty", m.chrf("", "abc"))
print("ws", round(m.chrf("a b c", "abc")))
PY
)
  check "chrF: identical = 100, unrelated < 40, close in between, empty = 0, whitespace ignored" $([ "$out" = $'same 100\ndiff True\nclose True\nempty 0.0\nws 100' ] && echo 0 || echo 1) "$out"
  client_setup
  run bench
  check "bench: speed rows from the server timings" $([ $RC = 0 ] && has "$OUT" "prompt processing" && has "$OUT" "600 t/s" && has "$OUT" "generation" && has "$OUT" "40.0 t/s" && has "$OUT" "time to first token" && has "$OUT" "warm one-sentence translate" && echo 0 || echo 1) "$RC $OUT $ERR"
  check "bench writes a tsv under the state dir" $(ls "$ST/bench/tm-default-"*.tsv >/dev/null 2>&1 && echo 0 || echo 1)
  run bench --model nope
  check "bench --model for a non-active model = exit 2" $([ $RC = 2 ] && echo 0 || echo 1)
  run bench --quality
  check "bench --quality: chrF per direction, layout match, commit-msg checks" $([ $RC = 0 ] && has "$OUT" "chrF ru-en" && has "$OUT" "chrF uk-en" && has "$OUT" "chrF en-ru" && has "$OUT" "chrF en-uk" && has "$OUT" "chrF ru-uk" && has "$OUT" "layout exact match" && has "$OUT" "commit-msg Conventional Commits" && has "$OUT" "commit-msg subject" && has "$OUT" "names the area" && echo 0 || echo 1) "$RC $OUT $ERR"
  run bench --cold
  check "bench --cold: two cold starts and the GPU memory after stop" $([ $RC = 0 ] && has "$OUT" "cold start (first load" && has "$OUT" "cold start again" && has "$OUT" "after stop" && echo 0 || echo 1) "$RC $OUT $ERR"
  run bench --bogus
  check "bench usage error = exit 2" $([ $RC = 2 ] && echo 0 || echo 1)
  client_teardown
}

# ----------------------------------------------------------------------------------------------------------------------------
SECTIONS=(models:sec_models model:sec_model serve:sec_serve units:sec_units live:sec_live presets:sec_presets commit:sec_commit layout:sec_layout errors:sec_errors status:sec_status bench:sec_bench)
secno=0
for sec in "${SECTIONS[@]}"; do
  secno=$((secno + 1))
  want_section "$secno" || continue
  "${sec#*:}"
done
echo "llm tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] && [ "$PASS" -gt 0 ]
