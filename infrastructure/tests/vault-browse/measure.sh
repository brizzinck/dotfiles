#!/usr/bin/env bash
# Before / after numbers for BW1 (faster Bitwarden): every flow runs against the fakes of this directory, where the fake `bw` sleeps
# FAKE_BW_DELAY (default 0.9 s, what the real CLI needs just to start) per PROCESS and the fake bw serve answers a request in ~20 ms.
# The bw processes (`bw ...` lines, a server start counts as one) and the server requests (`bw-serve ...`) are counted from the
# argv log. Usage: measure.sh --old DIR [--new DIR]   (DIR = a tree with .config/hypr/scripts and .local/bin, e.g. from
#   `git archive REV .config/hypr/scripts .local/bin | tar -x -C DIR`); --new defaults to this repository.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
OLD="" NEW="$REPO"
while (($#)); do case $1 in --old) OLD=$2; shift 2 ;; --new) NEW=$2; shift 2 ;; *) echo "usage: measure.sh --old DIR [--new DIR]" >&2; exit 2 ;; esac; done
[[ -n $OLD ]] || { echo "usage: measure.sh --old DIR [--new DIR]" >&2; exit 2; }
BIN="$HERE/bin"
FAKE=$(mktemp -d "${TMPDIR:-/tmp}/bw1-measure.XXXXXX")
trap 'stop_server; rm -rf "$FAKE"' EXIT
RUN="$FAKE/run"
export FAKE_DIR="$FAKE" XDG_RUNTIME_DIR="$RUN" PATH="$BIN:$PATH" RBW_BIN=rbw BW_BIN=bw PINENTRY_BIN="$BIN/pinentry" \
  VAULT_RBW_CONF="$FAKE/rbw.json" EDITOR="$BIN/editor" VISUAL= BW_DOWNLOAD_DIR="$FAKE/dl" HYPRLAND_INSTANCE_SIGNATURE=fake \
  VAULT_BW_LAUNCH=popen VAULT_CLEAR_AFTER=1 FAKE_BW_DELAY="${FAKE_BW_DELAY:-0.9}" FZF_MENU_NO_SERVER=1
echo '{"email":"test@example.com","lock_timeout":3600}' >"$FAKE/rbw.json"

stop_server() {
  local pid; pid=$(cat "$RUN/vault/bw-serve.pid" 2>/dev/null)
  [[ -n $pid ]] && grep -aq vault-bw.py "/proc/$pid/cmdline" 2>/dev/null && { kill "$pid"; for _ in $(seq 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done; }
}
fresh() { # tree warm|cold|old
  stop_server
  rm -rf "$RUN" "$FAKE/dl"; mkdir -p "$RUN/vault" "$FAKE/dl"; chmod 700 "$RUN" "$RUN/vault"
  jq '(.items[] | select(.id=="i-tgmcp") | .fields) = [{"name":"api_id","value":"1","type":0},{"name":"api_hash","value":"abcdef","type":0}]' "$HERE/fixture.json" >"$FAKE/vault.json"
  rm -f "$FAKE"/{rbw-view.json,rbw-locked,seq,editor-calls,typed.log,notify.log,clip.txt,clip.args,clip.events,last-*}
  echo 0xAAA >"$FAKE/active"
  printf 'SESSION-KEY-abc' >"$RUN/vault/bw-session"; chmod 600 "$RUN/vault/bw-session"; touch "$FAKE/bw-unlocked"
  : >"$FAKE/argv.log"
  echo '.name = "github edited" | .login.username = "brizz2"' >"$FAKE/editor-script"
  if [[ $1 == warm ]]; then python3 -I -B "$2/.config/hypr/scripts/vault-bw.py" call status </dev/null >/dev/null; : >"$FAKE/argv.log"; fi
}
run() { # tree mode flow: prints "procs/requests/seconds"
  local tree=$1 mode=$2 flow=$3 secs
  fresh "$mode" "$tree"
  case $flow in
    linux-pass-list) local t0; t0=$(date +%s.%N); ( cd "$FAKE" && "$tree/.local/bin/linux-pass" --list </dev/null >/dev/null 2>&1 ); secs=$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN { printf "%.2f", b - a }') ;;
    *) secs=$(MEASURE_SETUP="$tree/.local/bin/mcp-telegram-setup" VAULT_BW="$tree/.config/hypr/scripts/vault-bw.py" \
         python3 -I -B "$HERE/measure_flows.py" "$flow" "$tree/.config/hypr/scripts" "$BIN" 2>/dev/null | tail -1) ;;
  esac
  printf '%s/%s/%ss' "$(grep -ac '^bw ' "$FAKE/argv.log")" "$(grep -ac '^bw-serve ' "$FAKE/argv.log")" "$secs"
}
printf '%-18s | %-16s | %-16s | %-16s   (bw processes / server requests / seconds; bw process start = %ss)\n' flow "old" "new cold" "new warm" "$FAKE_BW_DELAY"
for flow in browser-open copy type edit new-login trash-open trash-restore linux-pass-list send-chats-prep; do
  printf '%-18s | %-16s | %-16s | %-16s\n' "$flow" "$(run "$OLD" old "$flow")" "$(run "$NEW" cold "$flow")" "$(run "$NEW" warm "$flow")"
done
