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
cleanup() {
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

# ----------------------------------------------------------------------------------------------------------------------------
SECTIONS=(models:sec_models model:sec_model)
n=0
for s in "${SECTIONS[@]}"; do
  n=$((n + 1))
  want_section "$n" || continue
  "${s#*:}"
done
echo "llm tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] && [ "$PASS" -gt 0 ]
