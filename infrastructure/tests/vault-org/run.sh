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
  tmux_cleanup 2>/dev/null
  stop_bw
  [[ -n ${SAMPLER:-} ]] && kill "$SAMPLER" 2>/dev/null
  if ((KEEP)); then echo "kept: $ROOT"; else rm -rf "$ROOT"; fi
}
trap cleanup EXIT

cat >"$ROOT/env.sh" <<ENV
export FAKE_DIR='$FAKE' XDG_RUNTIME_DIR='$RUN' XDG_STATE_HOME='$ROOT/state' XDG_DATA_HOME='$ROOT/data' XDG_CACHE_HOME='$ROOT/cache'
export PATH='$VB':'$REPO/.local/bin':/usr/bin:/bin
export RBW_BIN=rbw BW_BIN=bw PINENTRY_BIN='$VB/pinentry' VAULT_RBW_CONF='$FAKE/rbw.json'
export VAULT_BW_LAUNCH=popen VAULT_BW_SERVE_POLL=0.3 VAULT_BW_RBW_POLL=0.3 VAULT_BW_NODUMP=0
export ENVS_TOOL_PATH='$VB' ENVS_TEST_ROOT_PID=$$ VAULT_ORG_USERS=skalse,td,yc FZF_MENU_NO_SERVER=1 VAULT_ORG_CONF='$ROOT/conf' VAULT_ORG_SCOPES=/nonexistent/scopes.tsv
unset WAYLAND_DISPLAY DISPLAY CLAUDECODE TMUX TMUX_PANE
ENV
mkdir -p "$FAKE" "$ROOT/state" "$ROOT/data" "$ROOT/conf/vault-org" "$ROOT/conf/vault-share" "$ROOT/cache"
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


# ───────────── 2: plan, validation, reviewer ─────────────
PLANF() { echo "$ROOT/state/vault/org-plan.tsv"; }
META() { echo "$ROOT/state/vault/org-plan.meta.json"; }
fresh_plan() { # unlocked fixture, audit + plan with the example rules and a td overlay
  reset unlocked
  cp "$REPO/infrastructure/vault-org/rules.example.tsv" "$ROOT/conf/vault-org/rules.tsv"
  chmod 600 "$ROOT/conf/vault-org/rules.tsv"
  printf 'td\tWork/Acme/**\nyc\tWork/Globex/**\n' >"$ROOT/conf/vault-share/scopes.local.tsv"
  chmod 600 "$ROOT/conf/vault-share/scopes.local.tsv"
  A audit >/dev/null 2>&1
  A plan >"$ROOT/plan-out.txt" 2>&1
}
norm_plan() { sed '1s/audit=[^ ]* items=\([0-9]*\) generated=.*/audit=AUDIT items=\1 generated=GEN/' "$1"; }
plan_row() { awk -F'\t' -v id="$1" '$1==id || ($1=="@folder" && $2==id)' "$(PLANF)"; }
plan_target() { plan_row "$1" | awk -F'\t' '{ print ($1=="@folder") ? $4 : $4 }'; }
variant() { # NAME sed-expression: the golden plan with one edit becomes the plan file
  norm_plan "$HERE/plan.golden.tsv" | sed '1s/AUDIT/'"$(jq -r .created "$(AJ)")"'/; 1s/GEN/2026-10-18T00:00:00Z/' | sed "$2" >"$(PLANF)"
}
bad_plan() { A check >"$ROOT/chk.txt" 2>&1; local rc=$?; [[ $rc == 4 ]]; }

section2() {
  local rc
  fresh_plan
  check "2.3 plan is 600 and matches the golden file (example rules)" bash -c '
    [ "$(stat -c %a "$1")" = 600 ] && [ "$(sed "1s/audit=[^ ]* items=\([0-9]*\) generated=.*/audit=AUDIT items=\1 generated=GEN/" "$1")" = "$(cat "$2")" ]' _ "$(PLANF)" "$HERE/plan.golden.tsv"
  check "2.3 plan summary: moves, trash, deletes and the scope impact per user (counts only)" bash -c '
    grep -q "6 moves, 4 duplicates to the trash, 0 folder renames, 3 empty folders deleted" "$1" && grep -qE "td: [0-9]+ -> [0-9]+ items in scope" "$1" && grep -qE "yc: " "$1"' _ "$ROOT/plan-out.txt"
  check "2.3 the td overlay shows: Acme items move into td's scope (0 -> 2)" grep -q "td: 0 -> 2" "$ROOT/plan-out.txt"
  A check >/dev/null 2>&1; check "2.3 check accepts the generated plan" test $? = 0
  A plan --rules "$ROOT/conf/vault-org/rules.tsv" >/dev/null 2>&1; rc=$?
  check "2.3 a second plan over a clean plan is allowed (nothing was edited)" test $rc = 0
  A plan >/dev/null 2>&1; echo "x" >>"$(PLANF)"
  A plan >/dev/null 2>"$ROOT/p2.txt"; rc=$?
  check "2.3 plan refuses to overwrite manual edits, --force keeps a .bak" bash -c '[ "$1" = 4 ]' _ "$rc"
  A plan --force >/dev/null 2>&1
  check "2.3 --force replaced it and kept the old one as .bak" bash -c '[ -f "$1.bak" ] && tail -1 "$1.bak" | grep -q "^x$" && ! grep -q "^x$" "$1"' _ "$(PLANF)"
  A plan --force --rules "$ROOT/none.tsv" >"$ROOT/p3.txt" 2>&1
  check "2.3 no rules file: every proposal stays (only duplicates and empty folders change)" bash -c 'grep -q "no rules file" "$1" && ! grep -q "folder:" "$2"' _ "$ROOT/p3.txt" "$(PLANF)"
  # validation
  fresh_plan
  variant a 's/^i-20\t\(.*\)\tfolder:Home\t/i-20\t\1\tfolder:Ho*me\t/'; bad_plan
  check "2.4 a * in a target folder is refused (exit 4)" grep -q "Ho\*me" "$ROOT/chk.txt"
  variant b 's/trash-duplicate-of:i-01/trash-duplicate-of:i-99/'; bad_plan
  check "2.4 a duplicate of an unknown id is refused" grep -q "i-99 is not in the plan" "$ROOT/chk.txt"
  variant c 's/^\(i-01\t[^\t]*\t[^\t]*\t\)folder:Mail/\1trash-duplicate-of:i-02/'; bad_plan
  check "2.4 a cycle / chain (i-01 -> i-02 -> i-01) is refused" grep -q "no chains or cycles" "$ROOT/chk.txt"
  variant d 's/^\(i-12\t[^\t]*\t[^\t]*\t\)keep/\1folder:Personal/'; bad_plan
  check "2.4 moving the Linux item out of its tool folder is refused" grep -q "i-12: moves between a tool folder" "$ROOT/chk.txt"
  variant d2 's/^\(@folder\tf-linux\tLinux\t\)keep/\1rename:Linux2/'; bad_plan
  check "2.4 renaming Linux is refused (Linux/td stays)" grep -q "folder f-linux: a tool folder is never renamed" "$ROOT/chk.txt"
  A check --allow-tool-folders >/dev/null 2>&1; check "2.4 --allow-tool-folders lifts the tool-folder guard" test $? = 0
  variant e 's/^\(@folder\tf-old\tOld Stuff\t\)keep/\1rename:Mail/'; bad_plan
  check "2.4 renaming onto an existing folder is refused (move the items instead)" grep -q "exists already" "$ROOT/chk.txt"
  variant f 's/^\(i-10\t[^\t]*\t[^\t]*\t\)folder:Design/\1trash-duplicate-of:i-11/'; bad_plan
  check "2.4 a duplicate pair outside one audit group needs the manual flag" grep -q "not in the same audit group" "$ROOT/chk.txt"
  variant f2 's/^\(i-10\t[^\t]*\t[^\t]*\t\)folder:Design\t\([^\t]*\)\t.*/\1trash-duplicate-of:i-11\t\2\tmanual/'; A check >/dev/null 2>&1
  check "2.4 ...and passes with the manual flag" test $? = 0
  variant g 's/^i-08\tShop guest/i-08\tShop\tguest/'; bad_plan
  check "2.4 a tab inside a name breaks the row (6 columns) and is refused" grep -q "6 columns" "$ROOT/chk.txt"
  variant h '1s/v1/v2/'; bad_plan
  check "2.4 a wrong header version is refused" grep -q "plan version" "$ROOT/chk.txt"
  variant i 's/^\(i-13\t[^\t]*\t[^\t]*\t\)keep/\1trash-duplicate-of:i-12/'; bad_plan
  check "2.4 an item of a tool folder is never trashed" grep -q "tool folder are never trashed" "$ROOT/chk.txt"
  check "2.6 sentinels: not in the plan, the meta file, the preview or the check output" no_sentinel "$(PLANF)" "$(META)" "$ROOT/plan-out.txt" "$ROOT/chk.txt"
  fresh_plan
  check "2.6 the preview shows metadata and the scope, no value" bash -c '
    out=$(python3 -I -B "$1" _preview i-04 2>&1); grep -q "portal.acme-corp.test" <<<"$out" && grep -q "shared with: td" <<<"$out" && grep -q "group g2" <<<"$out"' _ "$SCRIPTS/vault-org.py"
  python3 -I -B "$SCRIPTS/vault-org.py" _preview i-04 >"$ROOT/prev.txt" 2>&1
  check "2.6 preview has no sentinel" no_sentinel "$ROOT/prev.txt"
  check "2.6 the argv log of plan/check has no sentinel and no write request" bash -c '! grep -qE "^bw-serve (POST|PUT|DELETE)" "$1"' _ "$FAKE/argv.log"
  ((QUICK)) || section2_tmux
}

# the reviewer in a private tmux server (the real fzf-menu --here, the display unset)
SOCKT="vorg-$$"
T=(tmux -L "$SOCKT")
tmux_cleanup() { "${T[@]}" kill-server 2>/dev/null; rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCKT"; }
screen() { local out s; out=$("${T[@]}" capture-pane -p -J -t t 2>/dev/null)
  for s in "${SENT[@]}"; do grep -aqF -- "$s" <<<"$out" && echo "$s" >>"$ROOT/leaks.log"; done; printf '%s\n' "$out"; }
screen_has() { screen | grep -aqE -- "$1"; }
wait_for() { local i max=$(( ${2:-8} * 5 )); for ((i = 0; i < max; i++)); do screen_has "$1" && return 0; sleep 0.2; done; return 1; }
k() { local x; for x in "$@"; do "${T[@]}" send-keys -t t "$x"; sleep 0.2; done; }
lit() { "${T[@]}" send-keys -t t -l "$1"; sleep 0.2; }
wait_target() { # ID VALUE [seconds]: the plan row's target reaches VALUE
  local i; for ((i = 0; i < ${3:-10} * 5; i++)); do [[ $(plan_target "$1") == "$2" ]] && return 0; sleep 0.2; done; return 1; }

section2_tmux() {
  fresh_plan
  rm -f "$ROOT/leaks.log"
  "${T[@]}" new-session -d -s t -x 160 -y 40 "bash --noprofile --norc -c '. $ROOT/env.sh; python3 -I -B $SCRIPTS/vault-org.py review; echo EXIT[\$?]; sleep 30'"
  check "2.5 the reviewer opens: header with counts and the keys" wait_for 'Reorganise.*filter all' 15
  check "2.5 rows show the mark, name, folder, target and the td scope column" wait_for 'Acme Portal +Work +→ Work/Acme +\[td\]' 4
  # f: folder picker. Query filters, Esc = NORMAL, f opens the picker, type Mail, Enter
  lit "Wi-Fi"; k Escape; k f
  check "2.5 f opens the folder picker" wait_for 'folder>' 8
  lit "Home"; k Enter
  check "2.5 f then Home then Enter: the plan row is folder:Home" wait_target i-20 "folder:Home" 6
  lit "Wi-Fi"; k Escape; k f; wait_for 'folder>' 8; lit "Mail"; k Enter
  check "2.5 f picks another folder: Mail" wait_target i-20 "folder:Mail" 6
  check "2.5 the plan file stays 600 after each step" test "$(mode_of "$(PLANF)")" = 600
  # the ua/ru twin of n (keep) is the same physical key: Cyrillic т
  lit "Wi-Fi"; k Escape; lit "т"
  check "2.5 the ua/ru twin of n sets keep" wait_target i-20 keep 6
  # n then D: i-03 keep, then D on i-01 trashes the others again
  lit "Old Stuff"; k Escape; k n
  check "2.5 n on i-03 sets keep" wait_target i-03 keep 6
  lit "Example"; k Escape; k D
  check "2.5 D on i-01 trashes the other members of its group" wait_target i-03 "trash-duplicate-of:i-01" 6
  # u undo restores i-03 to keep
  k Escape; k u
  check "2.5 u undoes the D" wait_target i-03 keep 6
  # t filter
  k Escape; k t
  check "2.5 t cycles the filter (changes)" wait_for 'filter changes' 6
  # Enter marks reviewed
  k Enter; sleep 0.6
  check "2.5 Enter marks the row reviewed (meta file)" bash -c '[ "$(jq ".reviewed|length" "$1")" -ge 1 ]' _ "$(META)"
  check "2.5 the plan file is still valid after the session" bash -c 'A() { python3 -I -B "$1" "${@:2}"; }; A "$2" check >/dev/null 2>&1' _ "$SCRIPTS/vault-org.py" "$SCRIPTS/vault-org.py"
  k Escape; k Escape; k q
  check "2.5 the reviewer ends with exit 0" wait_for 'EXIT\[0\]' 8
  check "2.6 no sentinel on any reviewer screen" test ! -s "$ROOT/leaks.log"
  tmux_cleanup
}

# ───────────── 3: apply ─────────────
mark() { MARK=$(wc -l <"$FAKE/argv.log" 2>/dev/null || echo 0); }
since() { tail -n +"$((MARK + 1))" "$FAKE/argv.log"; }
writes_since() { since | grep -acE '^bw-serve (POST|PUT|DELETE) /(object|restore|attachment)' || true; }   # POST /sync is no change
JOURNALF() { echo "$ROOT/state/vault/org-journal.tsv"; }
vjq() { jq -r "$1" "$FAKE/vault.json"; }
# the state the golden plan must produce: 4 new folders (Work/Acme Design Finance Home), the 3 empty ones gone, 6 moves, 4 trashed
expected_state() {
  [[ $(vjq '[.folders[].name]|sort|join(",")') == "Design,Env,Env/demo,Finance,Home,Linux,MCP,Mail,Old Stuff,Work,Work/Acme" ]] || return 1
  local fid
  fid() { vjq ".folders[]|select(.name==\"$1\")|.id"; }
  [[ $(vjq ".items[]|select(.id==\"i-04\")|.folderId") == "$(fid Work/Acme)" ]] || return 1
  [[ $(vjq ".items[]|select(.id==\"i-05\")|.folderId") == "$(fid Work/Acme)" ]] || return 1
  [[ $(vjq ".items[]|select(.id==\"i-01\")|.folderId") == "$(fid Mail)" ]] || return 1
  [[ $(vjq ".items[]|select(.id==\"i-10\")|.folderId") == "$(fid Design)" ]] || return 1
  [[ $(vjq ".items[]|select(.id==\"i-19\")|.folderId") == "$(fid Finance)" ]] || return 1
  [[ $(vjq ".items[]|select(.id==\"i-20\")|.folderId") == "$(fid Home)" ]] || return 1
  [[ $(vjq '[.items[]|select(.deletedDate!=null)|.id]|sort|join(",")') == "i-02,i-03,i-07,i-09,i-24" ]] || return 1
  [[ $(vjq '[.items[]|select(.id=="i-12" or .id=="i-13" or .id=="i-15")|.folderId]|join(",")') == "f-linux,f-linux,f-env" ]] || return 1
}

not_finished() { ! expected_state && [[ $(vjq '[.items[]|select((.folderId // "")|test("^f-new"))]|length') -ge 1 ]]; }

section3() {
  local rc out
  fresh_plan
  # 3.1 dry run: offline
  rm -rf "$ROOT/data/vault-backups"; mark
  out=$(A apply --dry-run 2>&1); rc=$?
  check "3.1 dry-run exit 0, it names the backup, the moves, the trash and the folder deletes" bash -c '
    [ "$1" = 0 ] && grep -q "would write an encrypted backup" <<<"$2" && grep -q "would move i-04 Acme Portal: Work -> Work/Acme" <<<"$2" \
    && grep -q "would trash i-02" <<<"$2" && grep -q "would create folder Work/Acme" <<<"$2" && grep -q "would delete folder f-empty" <<<"$2"' _ "$rc" "$out"
  check "3.1 dry-run: no write request, no export, no bw process, no backup, no journal" bash -c '
    [ "$(wc -l <"$1")" = "$2" ] && [ ! -e "$3" ] && [ ! -e "$4" ]' _ "$FAKE/argv.log" "$MARK" "$ROOT/data/vault-backups" "$(JOURNALF)"
  # 3.3 backup failure: nothing changed
  mark; out=$(FAKE_BW_EXPORT_FAIL=1 A apply --yes 2>&1); rc=$?
  check "3.3 a failing export: exit 1, 'nothing was changed', zero writes" bash -c '[ "$1" = 1 ] && grep -q "backup failed: nothing was changed" <<<"$2"' _ "$rc" "$out"
  check "3.3 ...and no POST/PUT/DELETE reached the server, no half backup left" bash -c '[ "$1" = 0 ] && ! ls "$2"/vault-*.json >/dev/null 2>&1' _ "$(writes_since)" "$ROOT/data/vault-backups"
  # 3.2 + 3.4 full apply
  mark; out=$(A apply --yes 2>&1); rc=$?; echo "$out" >"$ROOT/apply-out.txt"
  check "3.4 apply exit 0, the summary counts the work" bash -c '[ "$1" = 0 ] && grep -q "applied: 6 moved, 4 to the trash, 0 folders renamed, 4 folders created, 3 empty folders deleted" <<<"$2"' _ "$rc" "$out"
  check "3.4 the vault ends in the expected state (folders, moves, soft trash, empty folders gone)" expected_state
  check "3.2 the export ran before the first write request" bash -c '
    e=$(grep -n "^bw export" "$1" | head -1 | cut -d: -f1); w=$(grep -nE "^bw-serve (POST|PUT|DELETE) /(object|restore|attachment)" "$1" | head -1 | cut -d: -f1); [ -n "$e" ] && [ "$e" -lt "$w" ]' _ "$FAKE/argv.log"
  check "3.4 trash is the soft trash (no ?permanent), items still exist" bash -c '! grep -q "permanent" "$1" && [ "$(jq "[.items[]|select(.id==\"i-02\")]|length" "$2")" = 1 ]' _ "$FAKE/argv.log" "$FAKE/vault.json"
  check "3.4 rbw was synced at the end and the audit file is gone (stale)" bash -c 'grep -q "^rbw sync" "$1" && [ ! -e "$2" ]' _ "$FAKE/argv.log" "$(AJ)"
  check "3.12 backup: 600 file in a 700 dir, encrypted, 23 items, no plaintext" bash -c '
    f=$(ls "$1"/vault-*.json | head -1); [ "$(stat -c %a "$f")" = 600 ] && [ "$(stat -c %a "$1")" = 700 ] && [ "$(jq .encrypted "$f")" = true ] \
    && [ "$(jq ".items|length" "$f")" = 23 ] && ! grep -q "PW-" "$f"' _ "$ROOT/data/vault-backups"
  check "3.12 journal: 600, header with the plan sha, one ok line per step" bash -c '
    [ "$(stat -c %a "$1")" = 600 ] && head -1 "$1" | grep -q "^# plan-sha256=[0-9a-f]\{64\}$" && grep -qP "\tbackup\t-\tok " "$1" && grep -qP "\tmove\ti-04\tok moved" "$1" && grep -qP "\ttrash\ti-02\tok trashed" "$1"' _ "$(JOURNALF)"
  check "3.12 sentinels: not in stdout, the journal, the backup, the argv log" no_sentinel "$ROOT/apply-out.txt" "$(JOURNALF)" "$ROOT"/data/vault-backups/vault-*.json "$FAKE/argv.log"
  # 3.5 idempotent
  mark; A apply --yes >"$ROOT/apply2.txt" 2>&1; rc=$?
  check "3.5 a second apply: exit 0 and zero write requests" bash -c '[ "$1" = 0 ] && [ "$2" = 0 ]' _ "$rc" "$(writes_since)"
  # 3.6 resume after a kill in the middle (the full run only: two applies with a slowed-down server)
  if ((! QUICK)); then
  fresh_plan; rm -rf "$ROOT/data/vault-backups"
  FAKE_BW_REQ_DELAY=0.3 python3 -I -B "$SCRIPTS/vault-org.py" apply --yes >"$ROOT/apply3.txt" 2>&1 & local pid=$!
  local i; for ((i = 0; i < 100; i++)); do [[ $(grep -c '^bw-serve PUT' "$FAKE/argv.log") -ge 3 ]] && break; sleep 0.1; done
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  check "3.6 the kill came in the middle (some moves done, the vault not finished)" not_finished
  out=$(A apply --yes 2>&1); rc=$?
  check "3.6 a plain re-run after the kill archives the journal and still finishes (idempotent)" bash -c '[ "$1" = 0 ]' _ "$rc"
  fresh_plan; rm -rf "$ROOT/data/vault-backups";   : >"$FAKE/argv.log"
  FAKE_BW_REQ_DELAY=0.3 python3 -I -B "$SCRIPTS/vault-org.py" apply --yes >"$ROOT/apply3.txt" 2>&1 & pid=$!
  for ((i = 0; i < 100; i++)); do [[ $(grep -c '^bw-serve PUT' "$FAKE/argv.log") -ge 3 ]] && break; sleep 0.1; done
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  out=$(A apply --yes --resume 2>&1); rc=$?
  check "3.6 --resume finishes: exit 0 and the expected state" bash -c '[ "$1" = 0 ]' _ "$rc"
  check "3.6 ...expected vault state" expected_state
  check "3.6 nothing was done twice: one export, no item PUT twice" bash -c '
    [ "$(grep -c "^bw export" "$1")" = 1 ] && [ -z "$(grep "^bw-serve PUT" "$1" | sort | uniq -d)" ]' _ "$FAKE/argv.log"
  check "3.6 --resume with another plan is refused (exit 4) unless --new-journal" bash -c '
    A() { python3 -I -B "$1" "${@:2}"; }; echo "# x" >>"$2"; sed -i "s/^i-20\t\(.*\)\tfolder:Home\t/i-20\t\1\tkeep\t/" "$2"; A "$3" apply --yes --resume >/dev/null 2>&1; [ $? = 4 ]' _ "$SCRIPTS/vault-org.py" "$(PLANF)" "$SCRIPTS/vault-org.py"
  fi
  # 3.7 / 3.8 a revision or a username that changed after the audit: the trash is skipped (full run only)
  if ((! QUICK)); then
  fresh_plan; rm -rf "$ROOT/data/vault-backups"
  jq '(.items[]|select(.id=="i-02")|.revisionDate)="2026-10-18T00:00:00.000Z"' "$FAKE/vault.json" >"$FAKE/v.tmp" && mv "$FAKE/v.tmp" "$FAKE/vault.json"
  out=$(A apply --yes 2>&1); rc=$?
  check "3.7 changed after the audit: exit 5, i-02 stays, the others are trashed" bash -c '
    [ "$1" = 5 ] && grep -q "i-02 Example Mail: skipped (changed after the audit)" <<<"$2"' _ "$rc" "$out"
  check "3.7 ...i-02 not in the trash, i-03 in the trash" bash -c '[ "$(jq -r ".items[]|select(.id==\"i-02\")|.deletedDate" "$1")" = null ] && [ "$(jq -r ".items[]|select(.id==\"i-03\")|.deletedDate" "$1")" != null ]' _ "$FAKE/vault.json"
  # 3.8 the username changed: no longer a duplicate
  fresh_plan; rm -rf "$ROOT/data/vault-backups"
  jq '(.items[]|select(.id=="i-03")|.login.username)="someone-else"' "$FAKE/vault.json" >"$FAKE/v.tmp" && mv "$FAKE/v.tmp" "$FAKE/vault.json"
  out=$(A apply --yes 2>&1); rc=$?
  check "3.8 a changed username: skipped as 'no longer a duplicate', exit 5" bash -c '[ "$1" = 5 ] && grep -q "i-03 Example Mail: skipped (no longer a duplicate)" <<<"$2"' _ "$rc" "$out"
  fresh_plan; rm -rf "$ROOT/data/vault-backups"
  jq '(.items[]|select(.id=="i-02")|.login.password)="PW-changed-later"' "$FAKE/vault.json" >"$FAKE/v.tmp" && mv "$FAKE/v.tmp" "$FAKE/vault.json"
  out=$(A apply --yes 2>&1); rc=$?
  check "3.8 a changed password of an 'identical' duplicate: skipped, never trashed" bash -c '[ "$1" = 5 ] && grep -q "i-02 Example Mail: skipped (no longer a duplicate" <<<"$2"' _ "$rc" "$out"
  fi
  # 3.9 / 3.10 / 3.11 refusals before anything happens
  fresh_plan; rm -rf "$ROOT/data/vault-backups"; mark
  variant d 's/^\(i-12\t[^\t]*\t[^\t]*\t\)keep/\1folder:Personal/'
  A apply --yes >/dev/null 2>"$ROOT/e9.txt"; rc=$?
  check "3.9 moving a tool-folder item: exit 4, no export, no write" bash -c '[ "$1" = 4 ] && [ "$2" = 0 ] && ! grep -q "^bw export" "$3"' _ "$rc" "$(writes_since)" "$FAKE/argv.log"
  variant d2 's/^\(@folder\tf-linux\tLinux\t\)keep/\1rename:Linux2/'
  A apply --yes >/dev/null 2>&1; check "3.9 renaming Linux: exit 4" test $? = 4
  variant e 's/^\(@folder\tf-old\tOld Stuff\t\)keep/\1rename:Mail/'
  A apply --yes >/dev/null 2>&1; check "3.10 a rename collision: exit 4" test $? = 4
  fresh_plan; rm -rf "$ROOT/data/vault-backups"; mark
  ln -sf "$(command -v bash)" "$ROOT/claude"
  "$ROOT/claude" -c "python3 -I -B '$SCRIPTS/vault-org.py' apply --yes; exit \$?" >"$ROOT/o11.txt" 2>"$ROOT/e11.txt"; rc=$?
  check "3.11 under a fake claude ancestor: exit 4, no export, no write" bash -c '[ "$1" = 4 ] && [ "$2" = 0 ] && ! grep -q "^bw export" "$3" && grep -q "refused under an agent" "$4"' _ "$rc" "$(writes_since)" "$FAKE/argv.log" "$ROOT/e11.txt"
  "$ROOT/claude" -c "python3 -I -B '$SCRIPTS/vault-org.py' apply --dry-run; exit \$?" >"$ROOT/o11b.txt" 2>&1; rc=$?
  check "3.11 ...the offline dry-run is allowed for an agent" test $rc = 0
  A apply >/dev/null 2>"$ROOT/e12.txt" </dev/null; rc=$?
  check "3.11 without --yes and without a terminal: exit 4" bash -c '[ "$1" = 4 ] && grep -q "no terminal" "$2"' _ "$rc" "$ROOT/e12.txt"
  ONLY_REST=1
}

want 1 && section1
want 2 && section2
want 3 && section3

echo
echo "passed $PASS, failed $FAILS"
exit $((FAILS > 0))
