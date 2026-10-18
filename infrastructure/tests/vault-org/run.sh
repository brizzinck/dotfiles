#!/usr/bin/env bash
# shellcheck disable=SC2016  # the check bodies are single-quoted on purpose: they run in their own bash -c
# Test of vault-audit (.config/hypr/scripts/vault-org.py: audit, plan, review, apply) against the FAKE rbw / bw / bw serve of
# tests/vault-browse/bin. The real vault is never touched; every name, host and value in fixture.json is invented.
#
#   run.sh            full run (the reviewer in a private tmux)
#   run.sh --quick    no tmux (used by doctor.sh)
#   run.sh --keep     keep the temp dir
#   ONLY=1,3          run only these sections
set -u
export PYTHONDONTWRITEBYTECODE=1
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
SCRIPTS="$REPO/.config/hypr/scripts"
VA="$REPO/.local/bin/vault-audit"
VB="$HERE/../vault-browse/bin"
QUICK=0 KEEP=0
for a in "$@"; do case $a in --quick) QUICK=1 ;; --keep) KEEP=1 ;; *) echo "usage: run.sh [--quick] [--keep]" >&2; exit 2 ;; esac; done

ROOT=$(mktemp -d /tmp/vorg.XXXXXX)      # short: bw-serve listens on a unix socket below it
FAKE="$ROOT/fake" RUN="$ROOT/run"
PASS=0 FAILS=0
SENT=('PW-mail-1' 'PW-acme-new' 'PW-acme-old' 'PW-shop-1' 'PW-shop-guest' 'PW-px-1' 'PW-px-2' 'PW-totp-1' 'PW-oops' 'PW-tg'
  'LINUXPASS-skalse' 'LINUXPASS-ghost' 'LINUXNOTE-td' 'WIFI-secret-note' 'NOTE-acme-new' 'TOKEN-hidden-xyz' 'TOKEN-hidden-other'
  'JBSWY3DPEHPK3PXP' 'SSHPRIVATE-vo' '4111111111111111' 'CVV-secret-737' 'alice-mail' 'bob-acme' 'carol-shop' 'dave-px' 'erin-totp'
  'master-pw' 'SESSION-KEY-abc')
cleanup() {
  stop_bw
  [[ -n ${SAMPLER:-} ]] && kill "$SAMPLER" 2>/dev/null
  if ((KEEP)); then echo "kept: $ROOT"; else rm -rf "$ROOT"; fi
}
trap cleanup EXIT

cat >"$ROOT/env.sh" <<ENV
export FAKE_DIR='$FAKE' XDG_RUNTIME_DIR='$RUN' XDG_STATE_HOME='$ROOT/state' XDG_DATA_HOME='$ROOT/data' XDG_CONFIG_HOME='$ROOT/conf' XDG_CACHE_HOME='$ROOT/cache'
export PATH='$VB':/usr/bin:/bin
export RBW_BIN=rbw BW_BIN=bw PINENTRY_BIN='$VB/pinentry' VAULT_RBW_CONF='$FAKE/rbw.json'
export VAULT_BW_LAUNCH=popen VAULT_BW_SERVE_POLL=0.3 VAULT_BW_RBW_POLL=0.3 VAULT_BW_NODUMP=0
export ENVS_TOOL_PATH='$VB' ENVS_TEST_ROOT_PID=$$ VAULT_ORG_USERS=skalse,td,yc FZF_MENU_NO_SERVER=1 HOME='$ROOT/home'
unset WAYLAND_DISPLAY DISPLAY CLAUDECODE TMUX TMUX_PANE
ENV
mkdir -p "$FAKE" "$ROOT/home" "$ROOT/state" "$ROOT/data" "$ROOT/conf" "$ROOT/cache"
echo '{"email":"test@example.com"}' >"$FAKE/rbw.json"
# shellcheck disable=SC1091
. "$ROOT/env.sh"
A() { python3 -I -B "$SCRIPTS/vault-org.py" "$@"; }     # vault-audit without the wrapper
FILT=",${ONLY:-},"
want() { [[ -z ${ONLY:-} || $FILT == *",$1,"* ]]; }

stop_bw() {
  local pid
  pid=$(cat "$RUN/vault/bw-serve.pid" 2>/dev/null)
  if [[ -n $pid ]] && grep -aq 'vault-bw.py' "/proc/$pid/cmdline" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    for _ in $(seq 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  fi
}
reset() { # [unlocked] [fixture]
  stop_bw
  rm -rf "$RUN" "$ROOT/state" "$ROOT/data" "$FAKE"/{lock-state,rbw-view.json,rbw-locked,bw-unlocked,seq,argv.log,notify.log,last-*,fail-*}
  mkdir -p "$RUN/vault" "$ROOT/state" "$ROOT/data"
  chmod 700 "$RUN" "$RUN/vault"
  cp "$HERE/${2:-fixture.json}" "$FAKE/vault.json"
  : >"$FAKE/argv.log"
  if [[ ${1:-} == unlocked ]]; then
    printf 'SESSION-KEY-abc' >"$RUN/vault/bw-session"
    chmod 600 "$RUN/vault/bw-session"
    touch "$FAKE/bw-unlocked"
  fi
}
check() { local name=$1; shift; if "$@"; then PASS=$((PASS + 1)); printf 'ok    %s\n' "$name"; else FAILS=$((FAILS + 1)); printf 'FAIL  %s\n' "$name"; fi; }
file_has() { grep -aqE -- "$2" "$1" 2>/dev/null; }
mode_of() { stat -c %a "$1" 2>/dev/null; }
sentinel_in() { # FILE...: print the first sentinel found
  local f s
  for f in "$@"; do for s in "${SENT[@]}"; do grep -aqF -- "$s" "$f" 2>/dev/null && { echo "$s in $f"; return 0; }; done; done
  return 1
}
no_sentinel() { ! sentinel_in "$@" >/dev/null; }
AJ() { echo "$RUN/vault/org/audit.json"; }
jqa() { jq -r "$1" "$(AJ)"; }

# ───────────── 1: audit ─────────────
section1() {
  local out err ps_log
  reset unlocked
  ps_log="$ROOT/ps.log"
  : >"$ps_log"
  ( while :; do ps -eo args >>"$ps_log" 2>/dev/null; sleep 0.05; done ) & SAMPLER=$!
  out=$(A audit 2>"$ROOT/err.txt"); echo "$out" >"$ROOT/out.txt"
  kill "$SAMPLER" 2>/dev/null; SAMPLER=""
  check "1.1 audit succeeds, audit.json is 600 in a 700 dir" bash -c '[ -f "$1" ] && [ "$(stat -c %a "$1")" = 600 ] && [ "$(stat -c %a "$(dirname "$1")")" = 700 ]' _ "$(AJ)"
  check "1.1 counts: 23 items, 1 trash, 10 folders" bash -c '[ "$(jq ".items|length" "$1")" = 23 ] && [ "$(jq .trash "$1")" = 1 ] && [ "$(jq ".folders|length" "$1")" = 10 ]' _ "$(AJ)"
  check "1.2 groups: g1 identical (3), g2 same-login (2), g3 no-user (4), nothing else" bash -c '
    j=$(jq -c "[.groups[]|[.id,.class,(.members|length)]]" "$1"); [ "$j" = "[[\"g1\",\"identical\",3],[\"g2\",\"same-login\",2],[\"g3\",\"no-user\",4]]" ]' _ "$(AJ)"
  check "1.2 keep: g1 i-01 (newest), g2 i-04 (notes, newer), g3 i-06 (the item with the username)" bash -c '
    [ "$(jq -r "[.groups[].keep]|join(\",\")" "$1")" = "i-01,i-04,i-06" ]' _ "$(AJ)"
  check "1.2 g2 differs: password and notes; relations of the members" bash -c '
    [ "$(jq -r ".groups[1].differs|join(\",\")" "$1")" = "notes,password" ] && [ "$(jq -r ".groups[1].rel[\"i-05\"]" "$1")" = "differs:password" ] \
    && [ "$(jq -r ".groups[0].rel[\"i-03\"]" "$1")" = identical ] && [ "$(jq -r ".groups[2].rel[\"i-07\"]" "$1")" = identical ] \
    && [ "$(jq -r ".groups[2].rel[\"i-09\"]" "$1")" = subset ] && [ "$(jq -r ".groups[2].rel[\"i-08\"]" "$1")" = "differs:password" ]' _ "$(AJ)"
  check "1.3 findings: no-folder 6, empty folders 3, near-dup folders, near-dup names, marked 2" bash -c '
    f=".findings"; [ "$(jq "$f.no_folder|length" "$1")" = 6 ] && [ "$(jq "$f.empty_folder|sort|join(\",\")" -r "$1")" = "f-arch,f-empty,f-old2" ] \
    && [ "$(jq -c "$f.near_dup_folder" "$1")" = "[[\"f-old\",\"f-old2\"]]" ] && [ "$(jq -c "$f.near_dup_name" "$1")" = "[[\"i-10\",\"i-11\"]]" ] \
    && [ "$(jq "$f.marked|sort|join(\",\")" -r "$1")" = "i-21,i-22" ]' _ "$(AJ)"
  check "1.3 tool-folder problems: note in Linux, unknown Linux user, duplicate Env name, login in Env" bash -c '
    [ "$(jq -r ".findings.tool_folder|map(.id)|sort|join(\",\")" "$1")" = "i-13,i-14,i-16,i-17" ]' _ "$(AJ)"
  check "1.3 Env/Linux/MCP items are in no duplicate group and the tool folders are never 'empty'" bash -c '
    ! jq -e "[.groups[].members[]]|map(select(IN(\"i-12\",\"i-13\",\"i-14\",\"i-15\",\"i-16\",\"i-17\",\"i-18\")))|length>0" "$1" >/dev/null' _ "$(AJ)"
  check "1.4 sentinels: not in stdout, stderr, audit.json, the argv log, the ps samples" no_sentinel "$ROOT/out.txt" "$ROOT/err.txt" "$(AJ)" "$FAKE/argv.log" "$ps_log"
  check "1.4 no 64-hex string and no HMAC in audit.json" bash -c '! grep -qE "[0-9a-f]{64}" "$1"' _ "$(AJ)"
  check "1.4 the report names items and ids (names are allowed)" bash -c 'grep -q "Example Mail" "$1" && grep -q "group g1" "$1"' _ "$ROOT/out.txt"
  out=$(A audit --names-hidden 2>&1)
  check "1.5 --names-hidden prints no item or folder name, but ids and hosts" bash -c '
    ! grep -qE "Example Mail|Acme Portal|Pixelcraft|Shop|Old Stuff|Wi-Fi|deploy-key|Visa" <<<"$1" && grep -q "i-01" <<<"$1" && grep -q "portal.acme-corp.test" <<<"$1"' _ "$out"
  # 1.6 locked bw under an agent ancestor: exit 3, no unlock attempt
  reset
  ln -sf "$(command -v bash)" "$ROOT/claude"
  "$ROOT/claude" -c "python3 -I -B '$SCRIPTS/vault-org.py' audit; exit \$?" >"$ROOT/o6.txt" 2>"$ROOT/e6.txt"
  local rc=$?
  check "1.6 fake claude ancestor + locked bw: exit 3 and the owner is told to run it himself" bash -c '[ "$1" = 3 ] && grep -q "owner runs vault-audit" "$2"' _ "$rc" "$ROOT/e6.txt"
  check "1.6 ...and no bw unlock / pinentry happened" bash -c '! grep -q "^bw unlock" "$1" && [ ! -e "$2/vault/bw-session" ]' _ "$FAKE/argv.log" "$RUN"
  # locked bw as the owner: the fake pinentry unlocks
  reset
  A audit >/dev/null 2>"$ROOT/e6b.txt"; rc=$?
  check "1.6b locked bw, no agent: pinentry unlock then audit (exit 0)" bash -c '[ "$1" = 0 ] && grep -q "^bw unlock" "$2"' _ "$rc" "$FAKE/argv.log"
  # 1.7 deterministic
  reset unlocked
  A audit --json >"$ROOT/a1.json" 2>/dev/null
  A audit --json >"$ROOT/a2.json" 2>/dev/null
  check "1.7 a second run is byte-identical apart from 'created'" bash -c '[ "$(jq "del(.created)" "$1")" = "$(jq "del(.created)" "$2")" ] && [ -s "$1" ]' _ "$ROOT/a1.json" "$ROOT/a2.json"
  check "1.8 the audit made no write request" bash -c '! grep -qE "^bw-serve (POST|PUT|DELETE)" "$1"' _ "$FAKE/argv.log"
  check "1.8 usage error is exit 2" bash -c 'A() { python3 -I -B "$1/vault-org.py" "${@:2}"; }; A "$1" audit --bogus >/dev/null 2>&1; [ $? = 2 ]' _ "$SCRIPTS"
}

want 1 && section1

echo
echo "passed $PASS, failed $FAILS"
exit $((FAILS > 0))
