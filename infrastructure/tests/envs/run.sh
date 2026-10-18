#!/usr/bin/env bash
# Test of `envs` (DEV-b) against the FAKE vault of tests/vault-browse/bin (rbw, bw, bw-serve.py, pinentry, wl-copy, notify-send)
# plus fake mise and logger in tests/envs/bin. Never touches the real vault, the real state or the owner's session.
#   infrastructure/tests/envs/run.sh [--quick] [--keep] [--only=15]   --quick skips the tmux TUI and the timing section (doctor runs it);
#                                                                     --only=15 runs just the TUI section (development)
# After every section: no secret sentinel in any argv log, captured output, notification, state file, journald line or `ps`.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
ENVS="$REPO/.local/bin/envs"
QUICK=0 KEEP=0
ONLY=""
for a in "$@"; do case $a in --quick) QUICK=1 ;; --keep) KEEP=1 ;; --only=*) ONLY=${a#--only=} ;; *) echo "usage: run.sh [--quick] [--keep] [--only=15]" >&2; exit 2 ;; esac; done

ENVS_TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/envs-test.XXXXXX")
# the bw-serve unix socket lives under it (`<root>/run/vault/bw.sock`, 108 bytes at most): a long TMPDIR would break every vault write
((${#ENVS_TEST_ROOT} > 70)) && { rmdir "$ENVS_TEST_ROOT"; ENVS_TEST_ROOT=$(mktemp -d /tmp/envs-test.XXXXXX); }
# shellcheck source=env.sh
. "$HERE/env.sh" >/dev/null || exit 1
T=${ENVS_TEST_ROOT:?}
CAP="$T/cap"; mkdir -p "$CAP"
PROJ="$T/proj"
PASS=0 FAILS=0 N=0
SECRETS=(SECRET-billing-dev-db SECRET-billing-dev-stripe SECRET-billing-dev-extra SECRET-billing-stage-db SECRET-billing-prod-db
  SECRET-billing-prod-stripe SECRET-other-dev-db SECRET-other-dev-stripe SECRET-work-login master-pw)
# values the tests write themselves (they must never show up either)
SECRETS+=(SECRET-global-gitlab SECRET-global-extra NEWVAL-set-1 NEWVAL-set-2 NEWVAL-all-3 NEWVAL-import-4 NEWVAL-import-5 NEWVAL-copy-6)
# BW-ORG C6: the managed-user section (values of the owner, of td, of yc and of the shared folder)
SECRETS+=(SECRET-td-db SECRET-td-token SECRET-shared-db SECRET-shared-only SECRET-yc-db SECRET-owner-demo SECRET-td-gitlab NEWVAL-for-td NEWVAL-shared)
SOCK="envstest-$$"

stop_bw() {
  local pid
  pid=$(cat "$XDG_RUNTIME_DIR/vault/bw-serve.pid" 2>/dev/null)
  if [[ -n $pid ]] && grep -aq 'vault-bw.py' "/proc/$pid/cmdline" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    for _ in $(seq 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
  fi
}
cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK"
  stop_bw
  if ((KEEP)); then echo "kept: $T"; else rm -rf "${T:?}"; fi
}
trap cleanup EXIT

ok() { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
bad() { FAILS=$((FAILS + 1)); printf 'FAIL  %s\n' "$1"; [[ -n ${2:-} ]] && printf '      %s\n' "$2"; return 0; }
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }

# fresh vault, state, logs and project; the bw server of the last case is stopped
reset() {
  stop_bw
  rm -rf "${XDG_STATE_HOME:?}"/* "${XDG_RUNTIME_DIR:?}/envs" "${XDG_RUNTIME_DIR:?}"/vault/* "${CAP:?}"/* "${PROJ:?}" "${T:?}/wt"
  cp "$HERE/fixture.json" "$FAKE_DIR/vault.json"
  rm -f "$FAKE_DIR"/{argv.log,rbw-view.json,rbw-locked,bw-unlocked,seq,notify.log,logger.log,mise.log,clip.txt,clip.args,clip.events,fail-delete,last-*}
  rm -f "${T:?}/.mise.toml"
  mkdir -p "$PROJ"
  (cd "$PROJ" && git init -q . && cat >.envs.toml <<'T'
project = "billing"
environments = ["dev", "stage", "prod"]
default = "dev"
protected = ["prod"]

[secrets]
DATABASE_URL = "Postgres DSN of the API"
STRIPE_SECRET_KEY = ""
T
  printf '[tools]\n' >.mise.toml)
}
bind_proj() { (cd "$PROJ" && "$ENVS" bind --yes >/dev/null 2>&1); }

# run envs in the project: stdout / stderr captured in $CAP, status in RC
RC=0 OUT="" ERR=""
e() { # args...
  N=$((N + 1))
  (cd "${EDIR:-$PROJ}" && "$ENVS" "$@" >"$CAP/$N.out" 2>"$CAP/$N.err" </dev/null); RC=$?
  OUT="$CAP/$N.out" ERR="$CAP/$N.err"
}
etty() { # INPUT args...: run through a pty (script), INPUT is typed
  local input=$1; shift
  N=$((N + 1))
  (cd "${EDIR:-$PROJ}" && { sleep "${ETTY_DELAY:-0}"; if [[ -n ${ETTY_DELAY:-} ]]; then   # a hidden prompt flushes pending input: one line at a time
      while IFS= read -r l; do printf '%s\n' "$l"; sleep 0.5; done < <(printf '%b' "$input"); else printf '%b' "$input"; fi; } | script -qec "$(printf '%q ' "$ENVS" "$@")" /dev/null >"$CAP/$N.out" 2>"$CAP/$N.err"); RC=$?
  OUT="$CAP/$N.out" ERR="$CAP/$N.err"
}
epipe() { # INPUT args...: INPUT on stdin (no terminal)
  local input=$1; shift
  N=$((N + 1))
  (cd "${EDIR:-$PROJ}" && printf '%s' "$input" | "$ENVS" "$@" >"$CAP/$N.out" 2>"$CAP/$N.err"); RC=$?
  OUT="$CAP/$N.out" ERR="$CAP/$N.err"
}
vault_field() { jq -r --arg i "$1" --arg n "$2" '.items[]|select(.id==$i)|.fields[]?|select(.name==$n)|.value' "$FAKE_DIR/vault.json"; }
sha() { printf %s "$1" | sha256sum | cut -c1-64; }

scan() { # label: no sentinel in any place a leak could go
  local label=$1 s hit="" f
  local files=("$CAP"/* "$FAKE_DIR/argv.log" "$FAKE_DIR/notify.log" "$FAKE_DIR/logger.log" "$FAKE_DIR/mise.log"
    "$XDG_STATE_HOME"/envs/* "$XDG_RUNTIME_DIR"/envs/* "$XDG_RUNTIME_DIR"/vault/bw-serve.log)
  for s in "${SECRETS[@]}"; do
    for f in "${files[@]}"; do
      [[ -f $f ]] && grep -aqF -- "$s" "$f" && hit="$hit $s@$(basename "$f")"
    done
  done
  if [[ -z $hit ]]; then ok "no secret in argv logs, output, notifications, state, journald line ($label)"; else bad "SECRET LEAK ($label)" "$hit"; fi
}

section() { printf '\n== %s\n' "$1"; }

sections_1_14() {
# ───────────── 1 parse / validate .envs.toml and the line editor
section "1 .envs.toml: validation and the line editor"
reset
e status
check "good file: status ok, names listed" bash -c "[ $RC = 0 ] && grep -q 'names    DATABASE_URL, STRIPE_SECRET_KEY' '$OUT' && grep -q 'binding  unbound' '$OUT'"
bad_cfg() { # name, shell edit of the file, expected message
  reset
  (cd "$PROJ" && eval "$2")
  e status
  if grep -qF -- "$3" "$OUT"; then ok "rejected: $1"; else bad "rejected: $1" "$(head -c 300 "$OUT")"; fi
}
bad_cfg "bad project name" "sed -i 's/billing/Bad_Name/' .envs.toml" "project must match"
bad_cfg "duplicate environment" "sed -i 's/\"stage\"/\"dev\"/' .envs.toml" "environments must be unique"
bad_cfg "default not in the list" "sed -i 's/default = \"dev\"/default = \"qa\"/' .envs.toml" "default must be one of"
bad_cfg "bad environment name" "sed -i 's/\"stage\"/\"Stage 1\"/' .envs.toml" "must match ^[a-z]"
bad_cfg "protected not an environment" "sed -i 's/\\[\"prod\"\\]/[\"live\"]/' .envs.toml" "protected environment 'live'"
bad_cfg "reserved secret name PATH" "echo 'PATH = \"\"' >>.envs.toml" "'PATH' is a reserved name"
bad_cfg "reserved prefix MISE_" "echo 'MISE_FOO = \"\"' >>.envs.toml" "'MISE_FOO' is a reserved name"
bad_cfg "reserved prefix ENVS_" "echo 'ENVS_X = \"\"' >>.envs.toml" "'ENVS_X' is a reserved name"
bad_cfg "invalid variable name" "echo '\"1X\" = \"\"' >>.envs.toml" "'1X' is not a valid variable name"
bad_cfg "quoted key with a dash" "echo '\"A-B\" = \"\"' >>.envs.toml" "'A-B' is not a valid variable name"
bad_cfg "unknown top-level key" "sed -i '1i colour = \"red\"' .envs.toml" "unknown key 'colour'"
bad_cfg "secret that is also a mise [env] key" "printf '[env]\nDATABASE_URL = \"x\"\n' >.mise.toml" "also a key of mise [env]"
bad_cfg "per-env mise file conflict" "printf '[env]\nSTRIPE_SECRET_KEY = \"x\"\n' >.mise.stage.toml" ".mise.stage.toml"
reset
check "TomlText line editor keeps comments and order, quoted keys are refused" python3 -I -B "$HERE/edit_test.py" "$ENVS"
scan "section 1"

# ───────────── 3 run
section "3 run: the child sees exactly the declared secrets"
reset; bind_proj
e run -- sh -c 'printf %s "$DATABASE_URL" | sha256sum | cut -c1-64'
check "DATABASE_URL of Env/billing/dev reaches the child (sha256 inside the child)" bash -c "[ $RC = 0 ] && [ \"\$(cat '$OUT')\" = '$(sha SECRET-billing-dev-db)' ]"
check "the decoy item (Env/other, dev) is not the one used" bash -c "[ \"\$(cat '$OUT')\" != '$(sha SECRET-other-dev-db)' ]"
e run -- sh -c 'env | grep -F SECRET- | cut -d= -f1 | sort | tr "\n" " "'
check "exactly the declared names are injected (the undeclared EXTRA_FIELD is not)" bash -c "[ \"\$(cat '$OUT')\" = 'DATABASE_URL STRIPE_SECRET_KEY ' ]"
e run -- sh -c 'echo "$ENVS_PROJECT $ENVS_ENV $MISE_ENV"'
check "ENVS_PROJECT, ENVS_ENV and MISE_ENV are set" grep -qx 'billing dev dev' "$OUT"
check "mise exec was used, its argv holds no value" grep -q '|exec -- sh -c' "$FAKE_DIR/mise.log"
: >"$FAKE_DIR/mise.log"
e run --no-mise -- sh -c 'echo "[${MISE_ENV:-}] $ENVS_ENV"'
check "--no-mise: the command runs directly, no MISE_ENV" bash -c "grep -qx '\[\] dev' '$OUT' && ! grep -q 'exec' '$FAKE_DIR/mise.log'"
e run -e stage --allow-missing -- sh -c 'printf "%s|%s" "$DATABASE_URL" "${STRIPE_SECRET_KEY:-none}" | sha256sum | cut -c1-64'
check "-e stage reads the stage item" bash -c "[ \"\$(cat '$OUT')\" = '$(sha 'SECRET-billing-stage-db|none')' ]"
e run -e nosuch -- true
check "unknown environment: usage error" test $RC = 2
e run true
check "run without -- is a usage error" test $RC = 2
e run -- sh -c 'exit 7'
check "the exit status of the command is kept (exec)" test $RC = 7
# a process that stays alive: the values are not in any argv
( cd "$PROJ" && "$ENVS" run -- sleep 2 >/dev/null 2>&1 ) &
SLP=$!
sleep 0.8
descendants() { # pids below the given one (the test shell): a ps of the whole machine would include unrelated command lines
  local p kids=$1 all=""
  while [[ -n $kids ]]; do all="$all $kids"; kids=$(for p in $kids; do pgrep -P "$p"; done | tr '\n' ' '); done
  echo "$all"
}
ps -o args= -p "$(descendants $$ | tr -s ' ' ',' | sed 's/^,//;s/,$//')" >"$CAP/ps-run.txt" 2>/dev/null
wait $SLP
check "ps while the child sleeps lists it and holds no value" bash -c "grep -q 'sleep 2' '$CAP/ps-run.txt'"
scan "section 3"

# ───────────── 4 missing names
section "4 missing declared names"
reset; bind_proj
e run -e stage -- true
check "missing STRIPE_SECRET_KEY: refused, names the fix" bash -c "[ $RC = 1 ] && grep -q 'STRIPE_SECRET_KEY' '$ERR' && grep -q 'envs set NAME -e stage' '$ERR'"
e run -e stage --allow-missing -- true
check "--allow-missing runs anyway" test $RC = 0
scan "section 4"

# ───────────── 5 locked rbw
section "5 locked vault"
reset; bind_proj
touch "$FAKE_DIR/rbw-locked"
e run -- true
check "locked, no terminal: exit 3 with the hint" bash -c "[ $RC = 3 ] && grep -q 'vault is locked' '$ERR'"
etty '' run -- sh -c 'printf %s "$DATABASE_URL" | sha256sum | cut -c1-64'
check "locked, terminal: rbw unlock through the fake pinentry, then the command runs" bash -c "[ $RC = 0 ] && grep -q '$(sha SECRET-billing-dev-db)' '$OUT' && [ ! -f '$FAKE_DIR/rbw-locked' ]"
scan "section 5"

# ───────────── 6 protected environments
section "6 protected environments (prod)"
reset; bind_proj
e use prod
check "use prod without --prod (no terminal): refused, exit 4" bash -c "[ $RC = 4 ] && [ ! -s '$XDG_STATE_HOME/envs/active.tsv' ]"
e use prod --for 9h --prod
check "--for above 8h is a usage error" test $RC = 2
e use prod --prod
check "use prod --prod: one line, kind p, expires in about an hour" bash -c "[ $RC = 0 ] && awk -F'\t' -v now=\$(date +%s) '\$2==\"prod\" && \$4==\"p\" && \$3>now+3500 && \$3<=now+3601 {f=1} END{exit !f}' '$XDG_STATE_HOME/envs/active.tsv'"
e status
check "status shows prod as active and protected" bash -c "grep -q 'env      prod' '$OUT' && grep -q 'protected' '$OUT'"
e run -- true
check "run in the active prod without --prod (no terminal): refused" test $RC = 4
e run --prod -- true
check "run --prod works" test $RC = 0
check "journald line: project, env, command, count; no values" grep -q 'run project=billing env=prod cmd=true vars=2' "$FAKE_DIR/logger.log"
# an expired selection counts as the default
sed -i -E 's/\t[0-9]+\tp$/\t1\tp/' "$XDG_STATE_HOME/envs/active.tsv"
e status
check "expired selection: the default environment is back" grep -q 'env      dev (default)' "$OUT"
e run -e prod -- true
check "run -e prod without --prod (no terminal): refused" test $RC = 4
e use prod --prod; e use dev
check "use <default> clears the selection" bash -c "[ $RC = 0 ] && [ ! -s '$XDG_STATE_HOME/envs/active.tsv' ]"
e use stage
check "a non-protected selection needs no confirmation and does not expire" bash -c "[ $RC = 0 ] && awk -F'\t' '\$2==\"stage\" && \$3==0 && \$4==\"-\" {f=1} END{exit !f}' '$XDG_STATE_HOME/envs/active.tsv'"
etty 'prod\n' use prod
check "on a terminal: typing the environment name confirms" bash -c "[ $RC = 0 ] && grep -q prod '$XDG_STATE_HOME/envs/active.tsv'"
etty 'n\n' run -e prod -- true
check "run in prod on a terminal asks [y/N]; n refuses" test $RC = 4
etty 'y\n' run -e prod -- true
check "run in prod on a terminal: y runs" test $RC = 0
scan "section 6"

# ───────────── 7 agent refusal
section "7 agents never get values"
reset; bind_proj
cp /bin/sh "$T/claude"
(cd "$PROJ" && "$T/claude" -c "\"$ENVS\" run -- true; exit \$?" >"$CAP/ag1.out" 2>"$CAP/ag1.err"); rc=$?
check "run under a process called claude: refused, exit 4" bash -c "[ $rc = 4 ] && grep -q 'refused inside an agent' '$CAP/ag1.err'"
(cd "$PROJ" && CLAUDECODE=1 "$ENVS" run -- true >"$CAP/ag2.out" 2>"$CAP/ag2.err"); rc=$?
check "run with CLAUDECODE=1: refused" test $rc = 4
for c in "set X --stdin" "use stage" "bind" "init"; do
  # shellcheck disable=SC2086
  (cd "$PROJ" && CLAUDECODE=1 "$ENVS" $c >"$CAP/ag3.out" 2>"$CAP/ag3.err" </dev/null); rc=$?
  check "$c refused for an agent" test $rc = 4
done
(cd "$PROJ" && CLAUDECODE=1 "$ENVS" status >"$CAP/ag4.out" 2>&1); rc=$?
check "status (names only) still works for an agent" bash -c "[ $rc = 0 ] && grep -q 'DATABASE_URL' '$CAP/ag4.out'"
(cd "$PROJ" && "$T/claude" -c "\"$ENVS\" check; exit \$?" >"$CAP/ag5.out" 2>&1); rc=$?
check "check still works for an agent" bash -c "[ $rc = 0 ] && grep -q 'binding' '$CAP/ag5.out'"
scan "section 7"

# ───────────── 8 binding
section "8 binding to Env/<project>"
reset
e run -- true
check "unbound (no terminal): refused, exit 4, names the fix" bash -c "[ $RC = 4 ] && grep -q 'envs bind' '$ERR'"
e bind --yes
check "bind --yes (test hook) writes bindings.tsv and trusts mise" bash -c "[ $RC = 0 ] && grep -q 'billing' '$XDG_STATE_HOME/envs/bindings.tsv' && grep -q '|trust' '$FAKE_DIR/mise.log'"
e run -- true
check "bound: runs" test $RC = 0
sed -i 's/^project = "billing"/project = "other"/' "$PROJ/.envs.toml"
e run -- true
check "a changed project name for a bound root is refused" bash -c "[ $RC = 4 ] && grep -q 'project name changed' '$ERR'"
sed -i 's/^project = "other"/project = "billing"/' "$PROJ/.envs.toml"
(cd "$PROJ" && git add -A >/dev/null 2>&1 && git commit -qm init && git worktree add -q "$T/wt" -b wt >/dev/null 2>&1)
EDIR="$T/wt" e run -- true
check "a worktree of the same repo shares the binding" test $RC = 0
EDIR=""
etty 'n\n' run -e dev -- true
check "bound root on a terminal runs without asking" test $RC = 0
reset
etty 'y\n' run -- true
check "unbound on a terminal: asks 'Bind ...? [y/N]', y binds and runs" bash -c "[ $RC = 0 ] && grep -q billing '$XDG_STATE_HOME/envs/bindings.tsv' && grep -q 'Bind' '$OUT'"
scan "section 8"

# ───────────── 9 prompt marker
section "9 envs.zsh prompt marker"
reset; bind_proj
ZS="$REPO/.config/zsh/envs.zsh"
zsh_marker() { (cd "${1:-$PROJ}" && XDG_STATE_HOME="$XDG_STATE_HOME" zsh -f -c "source '$ZS'; print -r -- \"[\$_ENVS_PROMPT]\"" 2>&1); }
M=$(zsh_marker)
check "default environment: no marker" test "$M" = '[]'
e use stage
M=$(zsh_marker)
check "stage: yellow [stage]" test "$M" = '[%F{3}[stage]%f ]'
e use prod --prod
M=$(zsh_marker)
check "prod: bold red [prod]" test "$M" = '[%F{1}%B[prod]%b%f ]'
sed -i -E 's/\t[0-9]+\tp$/\t1\tp/' "$XDG_STATE_HOME/envs/active.tsv"
M=$(zsh_marker)
check "expired selection: no marker" test "$M" = '[]'
e use prod --prod
M=$(zsh_marker "$T")
check "another directory: no marker" test "$M" = '[]'
mkdir -p "$PROJ/sub/dir"
M=$(zsh_marker "$PROJ/sub/dir")
check "a subdirectory of the project shows the marker" test "$M" = '[%F{1}%B[prod]%b%f ]'
check "no secret in the environment of a shell that sourced it" bash -c "! (cd '$PROJ' && zsh -f -c \"source '$ZS'; env\") | grep -q 'SECRET'"
scan "section 9"

# ───────────── 2 dotenv parser
section "2 .env parser"
check "dotenv parser: quotes, export, multi-line, inline comments, \${VAR}, bad lines reported without content" python3 -I -B "$HERE/dotenv_test.py" "$ENVS"

# ───────────── 10 set / unset / rename / plain
section "10 set, unset, rename, plain variables"
reset; bind_proj
epipe $'NEWVAL-set-1\n' set DATABASE_URL -e stage --stdin
check "set --stdin writes a hidden field into the stage item" bash -c "[ $RC = 0 ] && [ \"\$(jq -r '.items[]|select(.id==\"e-stage\")|.fields[]|select(.name==\"DATABASE_URL\")|.type' '$FAKE_DIR/vault.json')\" = 1 ]"
check "the value landed in the item (read from the fake vault file)" test "$(vault_field e-stage DATABASE_URL)" = NEWVAL-set-1
check "rbw sees it after the sync that follows a write" bash -c "rbw get --raw e-stage | jq -e '.fields[]|select(.value==\"NEWVAL-set-1\")'"
epipe $'NEWVAL-set-2\n' set STRIPE_SECRET_KEY --stdin
check "without -e the default environment (dev) is written" test "$(vault_field e-dev STRIPE_SECRET_KEY)" = NEWVAL-set-2
e set DATABASE_URL=oops -e stage
check "a NAME=value argument is refused (history and ps would see it)" bash -c "[ $RC = 2 ] && grep -q 'values never go on the command line' '$ERR'"
e set DATABASE_URL oops
check "a value after the name is refused" test $RC = 2
e set 1BAD --stdin
check "invalid variable name refused" test $RC = 2
e set PATH --stdin
check "reserved name refused" test $RC = 2
epipe $'NEWVAL-all-3\n' set NEW_TOKEN --all --stdin --description "a token"
check "--all writes every environment item incl. prod and declares the name with its description" bash -c "[ $RC = 0 ] && for i in e-dev e-stage e-prod; do [ \"\$(jq -r --arg i \$i '.items[]|select(.id==\$i)|.fields[]|select(.name==\"NEW_TOKEN\")|.value' '$FAKE_DIR/vault.json')\" = NEWVAL-all-3 ] || exit 1; done; grep -q 'NEW_TOKEN = \"a token\"' '$PROJ/.envs.toml'"
ETTY_DELAY=0.7 etty $'NEWVAL-set-1\nNEWVAL-set-1\n' set DATABASE_URL -e stage
check "hidden prompt, asked twice" bash -c "[ $RC = 0 ] && [ \"\$(jq -r '.items[]|select(.id==\"e-stage\")|.fields[]|select(.name==\"DATABASE_URL\")|.value' '$FAKE_DIR/vault.json')\" = NEWVAL-set-1 ]"
ETTY_DELAY=0.7 etty $'NEWVAL-set-1\nNEWVAL-set-2\n' set DATABASE_URL -e stage
check "the two entries differ: nothing is written" bash -c "[ $RC = 1 ] && [ \"\$(jq -r '.items[]|select(.id==\"e-stage\")|.fields[]|select(.name==\"DATABASE_URL\")|.value' '$FAKE_DIR/vault.json')\" = NEWVAL-set-1 ]"
e unset NEW_TOKEN -e stage
check "unset -e removes it from that environment only" bash -c "[ $RC = 0 ] && [ -z \"\$(jq -r '.items[]|select(.id==\"e-stage\")|.fields[]?|select(.name==\"NEW_TOKEN\")|.value' '$FAKE_DIR/vault.json')\" ] && [ -n \"\$(jq -r '.items[]|select(.id==\"e-dev\")|.fields[]?|select(.name==\"NEW_TOKEN\")|.value' '$FAKE_DIR/vault.json')\" ]"
e unset NEW_TOKEN --all --undeclare
check "unset --all --undeclare removes it everywhere and from .envs.toml" bash -c "[ $RC = 0 ] && ! grep -q NEW_TOKEN '$PROJ/.envs.toml' && ! grep -q NEW_TOKEN '$FAKE_DIR/vault.json'"
e rename STRIPE_SECRET_KEY STRIPE_KEY
check "rename: the field in every item, the declaration (with its description line kept)" bash -c "[ $RC = 0 ] && grep -q '^STRIPE_KEY = ' '$PROJ/.envs.toml' && ! grep -q STRIPE_SECRET_KEY '$PROJ/.envs.toml' && [ \"\$(jq -r '[.items[]|select(.folderId==\"f-billing\")|.fields[]?|select(.name==\"STRIPE_SECRET_KEY\")]|length' '$FAKE_DIR/vault.json')\" = 0 ] && [ \"\$(jq -r '.items[]|select(.id==\"o-dev\")|.fields[]|select(.name==\"STRIPE_SECRET_KEY\")|.value' '$FAKE_DIR/vault.json')\" = SECRET-other-dev-stripe ] && grep -q 'DATABASE_URL = \"Postgres DSN of the API\"' '$PROJ/.envs.toml'"
e rename DATABASE_URL STRIPE_KEY
check "rename onto an existing name is refused" test $RC = 1
e status
check "status after the rename lists the new name" bash -c "grep -q 'names    DATABASE_URL, STRIPE_KEY' '$OUT'"
epipe $'plain-value\n' set LOG_LEVEL --plain --stdin
check "--plain goes to .mise.toml [env] and keeps the other tables" bash -c "[ $RC = 0 ] && grep -q '^LOG_LEVEL = \"plain-value\"' '$PROJ/.mise.toml' && grep -q '^\[tools\]' '$PROJ/.mise.toml' && grep -q '^\[env\]' '$PROJ/.mise.toml'"
epipe $'stage-value\n' set LOG_LEVEL --plain --stdin -e stage
check "--plain -e stage goes to .mise.stage.toml" grep -q '^LOG_LEVEL = "stage-value"' "$PROJ/.mise.stage.toml"
epipe $'x\n' set DATABASE_URL --plain --stdin
check "a declared secret cannot also be set as plain" test $RC = 1
epipe $'x\n' set LOG_LEVEL --stdin
check "a plain variable cannot be set as a secret" test $RC = 1
e rename LOG_LEVEL APP_LOG_LEVEL
check "rename of a plain variable renames it in the mise files" bash -c "[ $RC = 0 ] && grep -q '^APP_LOG_LEVEL = ' '$PROJ/.mise.toml' && grep -q '^APP_LOG_LEVEL = ' '$PROJ/.mise.stage.toml'"
e unset APP_LOG_LEVEL -e stage
check "unset of a plain variable removes it from the file of that environment" bash -c "[ $RC = 0 ] && ! grep -q APP_LOG_LEVEL '$PROJ/.mise.stage.toml' && grep -q APP_LOG_LEVEL '$PROJ/.mise.toml'"
scan "section 10"

# ───────────── 11 copy, diff, check
section "11 copy, diff, check"
reset; bind_proj
e copy dev stage
check "copy: only names missing in the destination" bash -c "[ $RC = 0 ] && [ \"\$(jq -r '.items[]|select(.id==\"e-stage\")|.fields[]|select(.name==\"STRIPE_SECRET_KEY\")|.value' '$FAKE_DIR/vault.json')\" = SECRET-billing-dev-stripe ] && [ \"\$(jq -r '.items[]|select(.id==\"e-stage\")|.fields[]|select(.name==\"DATABASE_URL\")|.value' '$FAKE_DIR/vault.json')\" = SECRET-billing-stage-db ] && grep -q 'kept' '$OUT'"
e diff dev stage
check "diff: differs for DATABASE_URL, same for STRIPE_SECRET_KEY, no values printed" bash -c "grep -q 'DATABASE_URL *differs' '$OUT' && grep -q 'STRIPE_SECRET_KEY *same' '$OUT'"
e copy dev stage --overwrite
check "copy --overwrite replaces" bash -c "[ \"\$(jq -r '.items[]|select(.id==\"e-stage\")|.fields[]|select(.name==\"DATABASE_URL\")|.value' '$FAKE_DIR/vault.json')\" = SECRET-billing-dev-db ]"
e diff dev stage
check "diff after the copy: same" bash -c "grep -q 'DATABASE_URL *same' '$OUT'"
e copy dev prod
check "copy into prod without --prod (no terminal): refused" test $RC = 4
e copy dev prod --prod --overwrite
check "copy into prod with --prod works" test $RC = 0
e diff
check "diff with no arguments lists every pair" bash -c "grep -q '^dev vs stage' '$OUT' && grep -q '^dev vs prod' '$OUT' && grep -q '^stage vs prod' '$OUT'"
reset; bind_proj
e check
check "check: set/missing per environment, undeclared fields named, no values" bash -c "grep -q 'stage: 1 set, missing: STRIPE_SECRET_KEY' '$OUT' && grep -q 'dev: undeclared fields (never injected): EXTRA_FIELD' '$OUT' && grep -q 'binding: bound' '$OUT'"
printf 'NEWVAL-import-4\n' >"$PROJ/.env.local"
e check
check "an untracked env file gets the import hint" grep -q '.env.local is a plain env file' "$OUT"
printf 'KEY=NEWVAL-import-5\n' >"$PROJ/.env"
(cd "$PROJ" && git add .env >/dev/null 2>&1)
e check
check "a tracked .env is an error (exit 1) that says to rotate" bash -c "[ $RC = 1 ] && grep -q '.env is tracked in git' '$OUT'"
e check --all
check "check --all lists the bound root" grep -q "$PROJ" "$OUT"
touch "$FAKE_DIR/rbw-locked"
e check
check "a locked vault is reported, not unlocked by check" grep -q 'vault locked' "$OUT"
scan "section 11"

# ───────────── 12 import
section "12 import"
reset; bind_proj
write_env() {
  cat >"$PROJ/.env" <<'ENV'
# comment
export DATABASE_URL="postgres://u:NEWVAL-import-4@db/app"
STRIPE_SECRET_KEY='NEWVAL-import-5'
LOG_LEVEL=debug # inline
MULTI="line1
line2"
BAD LINE WITH SECRET-work-login
ESC="a\tb\"c\\d"
REF=${HOME}/x
ENV
}
write_env
e import .env -e stage --secrets DATABASE_URL,STRIPE_SECRET_KEY --plain LOG_LEVEL,MULTI,ESC,REF --keep
check "import: new secret written, the already-set one skipped without --overwrite" bash -c "[ $RC = 0 ] && [ \"\$(jq -r '.items[]|select(.id==\"e-stage\")|.fields[]|select(.name==\"STRIPE_SECRET_KEY\")|.value' '$FAKE_DIR/vault.json')\" = NEWVAL-import-5 ] && [ \"\$(jq -r '.items[]|select(.id==\"e-stage\")|.fields[]|select(.name==\"DATABASE_URL\")|.value' '$FAKE_DIR/vault.json')\" = SECRET-billing-stage-db ] && grep -q 'skipped (already set): DATABASE_URL' '$OUT'"
check "plain variables go to .mise.stage.toml with exact values (inline comment cut, escapes, multi-line, \${VAR} literal)" python3 - "$PROJ/.mise.stage.toml" <<'PY'
import sys, tomllib
e = tomllib.load(open(sys.argv[1], "rb"))["env"]
assert e["LOG_LEVEL"] == "debug" and e["MULTI"] == "line1\nline2" and e["ESC"] == 'a\tb"c\\d' and e["REF"] == "${HOME}/x", e
PY
check "the bad line is reported by number, its content never" bash -c "grep -q 'line 7: not KEY=value' '$ERR' && ! grep -q 'WITH SECRET' '$ERR' '$OUT'"
check "the \${VAR} warning" grep -q 'REF: contains' "$ERR"
check "--keep leaves the file" test -f "$PROJ/.env"
check "new secret names are declared in .envs.toml" bash -c "grep -q '^STRIPE_SECRET_KEY' '$PROJ/.envs.toml'"
e import .env -e stage --secrets DATABASE_URL --overwrite --keep
check "--overwrite replaces the existing field" test "$(vault_field e-stage DATABASE_URL)" = "postgres://u:NEWVAL-import-4@db/app"
e import .env --plain LOG_LEVEL --keep
check "without -e: the default environment (dev) -> .mise.toml" bash -c "[ $RC = 0 ] && grep -q '^LOG_LEVEL = \"debug\"' '$PROJ/.mise.toml'"
e import .env --keep
check "no terminal and no --secrets/--plain: usage error" test $RC = 2
e import .env -e stage --secrets STRIPE_SECRET_KEY
check "no terminal, no --keep: the file is kept with a message" bash -c "[ $RC = 0 ] && test -f '$PROJ/.env' && grep -q 'kept' '$OUT'"
etty 'y\n' import .env -e stage --secrets STRIPE_SECRET_KEY --overwrite
check "terminal: 'Shred .env now? [Y/n]' y shreds the untracked file" bash -c "[ $RC = 0 ] && [ ! -e '$PROJ/.env' ]"
write_env
(cd "$PROJ" && git add .env >/dev/null 2>&1 && git commit -qm env >/dev/null 2>&1)
e import .env -e stage --secrets STRIPE_SECRET_KEY --overwrite
check "a file tracked by git is kept with the rotate warning" bash -c "[ $RC = 0 ] && test -f '$PROJ/.env' && grep -q 'tracked in git' '$OUT'"
scan "section 12"

# ───────────── 13 export-example
section "13 export-example"
reset; bind_proj
printf '[env]\nLOG_LEVEL = "debug"\n' >"$PROJ/.mise.toml"
e export-example
check "names only: secrets with their description, plain names under 'set by mise'" bash -c "[ $RC = 0 ] && head -1 '$PROJ/.env.example' | grep -q '^# generated by envs export-example' && grep -qx 'DATABASE_URL=' '$PROJ/.env.example' && grep -qx '# Postgres DSN of the API' '$PROJ/.env.example' && grep -qx 'LOG_LEVEL=' '$PROJ/.env.example' && ! grep -q 'debug' '$PROJ/.env.example'"
e export-example
check "a file written by envs is overwritten" test $RC = 0
printf 'MINE=1\n' >"$PROJ/.env.example"
e export-example
check "a foreign .env.example is refused" bash -c "[ $RC = 1 ] && grep -q 'MINE=1' '$PROJ/.env.example'"
e export-example --force -o "$T/ex.env"
check "-o and --force" test -s "$T/ex.env"
e copy-value DATABASE_URL
check "copy-value: wl-copy --sensitive got it, nothing printed" bash -c "[ $RC = 0 ] && [ \"\$(cat '$FAKE_DIR/clip.txt')\" = SECRET-billing-dev-db ] && grep -q 'wl-copy --sensitive' '$FAKE_DIR/argv.log' && ! grep -q SECRET '$OUT' '$ERR'"
scan "section 13"

# ───────────── 14 env / project management
section "14 environments and projects"
reset; bind_proj
e env new qa
check "env new: an empty item in the folder and the list entry" bash -c "[ $RC = 0 ] && [ \"\$(jq -r '[.items[]|select(.name==\"qa\" and .folderId==\"f-billing\")]|length' '$FAKE_DIR/vault.json')\" = 1 ] && grep -q '\"qa\"' '$PROJ/.envs.toml'"
printf '[env]\nQA_ONLY = "1"\n' >"$PROJ/.mise.qa.toml"
e env rename qa test
check "env rename: item, list, per-environment mise file" bash -c "[ $RC = 0 ] && [ \"\$(jq -r '[.items[]|select(.name==\"test\" and .folderId==\"f-billing\")]|length' '$FAKE_DIR/vault.json')\" = 1 ] && grep -q '\"test\"' '$PROJ/.envs.toml' && [ -f '$PROJ/.mise.test.toml' ] && [ ! -e '$PROJ/.mise.qa.toml' ]"
etty 'wrong\n' env delete test
check "env delete: a wrong confirmation changes nothing" bash -c "[ $RC != 0 ] && [ \"\$(jq -r '[.items[]|select(.name==\"test\" and .deletedDate==null)]|length' '$FAKE_DIR/vault.json')\" = 1 ]"
etty 'test\n' env delete test
check "env delete: typed name -> the item is in the trash, the list entry is gone" bash -c "[ $RC = 0 ] && [ \"\$(jq -r '[.items[]|select(.name==\"test\" and .deletedDate!=null)]|length' '$FAKE_DIR/vault.json')\" = 1 ] && ! grep -q '\"test\"' '$PROJ/.envs.toml'"
e env delete dev
check "the default environment cannot be deleted" test $RC = 1
e project rename billing2
check "project rename: folder renamed through PUT /object/folder, .envs.toml and the binding follow" bash -c "[ $RC = 0 ] && grep -q '^bw-serve PUT /object/folder/f-billing' '$FAKE_DIR/argv.log' && [ \"\$(jq -r '.folders[]|select(.id==\"f-billing\")|.name' '$FAKE_DIR/vault.json')\" = Env/billing2 ] && grep -q '^project = \"billing2\"' '$PROJ/.envs.toml' && grep -q billing2 '$XDG_STATE_HOME/envs/bindings.tsv'"
e status
check "status after the rename: bound, vault items found under the new folder" bash -c "grep -q 'binding  bound' '$OUT' && grep -q 'dev: 2 set' '$OUT'"
etty 'billing2\n' project delete
check "project delete: items in the trash, folder gone (DELETE /object/folder), binding removed" bash -c "[ $RC = 0 ] && grep -q '^bw-serve DELETE /object/folder/f-billing' '$FAKE_DIR/argv.log' && [ \"\$(jq -r '[.items[]|select(.folderId==\"f-billing\" and .deletedDate==null)]|length' '$FAKE_DIR/vault.json')\" = 0 ] && [ \"\$(jq -r '[.folders[]|select(.id==\"f-billing\")]|length' '$FAKE_DIR/vault.json')\" = 0 ] && ! grep -q billing2 '$XDG_STATE_HOME/envs/bindings.tsv'"
e project delete
check "project delete without a terminal is refused" test $RC != 0
scan "section 14"

}


pycheck() { # name, script, args...: a python harness; its output is shown when it fails
  local n=$1 out; shift
  out=$(python3 -I -B "$@" 2>&1); local rc=$?
  if ((rc == 0)); then ok "$n"; else bad "$n" "$out"; fi
}

sections_17() {
# ───────────── 17 FIX-DEVb: the attacks of the review (REVIEW-DEV-b.md), each reproduced; all of these fail on the old code
section "17 FIX-DEVb: review attacks"
cp /bin/sh "$T/claude"

# finding 1: `_preview` was a value oracle for anything that wrote the reveal flag
reset
mkdir -p "$XDG_RUNTIME_DIR/envs"; chmod 700 "$XDG_RUNTIME_DIR/envs"
FUT=$(( $(date +%s) + 600 ))
printf 'billing\tprod\tDATABASE_URL\t%s' "$FUT" >"$XDG_RUNTIME_DIR/envs/reveal"
(cd / && CLAUDECODE=1 "$ENVS" _preview vars billing - prod DATABASE_URL >"$CAP/pv1.out" 2>"$CAP/pv1.err"); rc=$?
check "1: _preview under an agent is refused (exit 4), nothing printed" bash -c "[ $rc = 4 ] && [ ! -s '$CAP/pv1.out' ]"
(cd / && "$ENVS" _preview vars billing - prod DATABASE_URL >"$CAP/pv2.out" 2>&1)
check "1: the old fixed-name reveal flag is not honoured by anyone (masked)" bash -c "! grep -q SECRET '$CAP/pv2.out' && grep -q '••••' '$CAP/pv2.out'"
FLAG="$XDG_RUNTIME_DIR/envs/reveal-4242-0123456789ab"
printf 'billing\tdev\tDATABASE_URL\t%s' "$FUT" >"$FLAG"
(cd / && ENVS_REVEAL_FILE="$FLAG" "$ENVS" _preview vars billing "$PROJ" dev DATABASE_URL >"$CAP/pv3.out" 2>&1)
check "1: this run's flag does not reveal for a checkout that is not bound" bash -c "! grep -q SECRET '$CAP/pv3.out' && grep -q '••••' '$CAP/pv3.out'"
(cd / && ENVS_REVEAL_FILE="$FLAG" "$ENVS" _preview vars billing - dev DATABASE_URL >"$CAP/pv3b.out" 2>&1)
check "1: ... nor without a checkout at all (project named on the command line)" bash -c "! grep -q SECRET '$CAP/pv3b.out'"
bind_proj
pycheck "1: control + FIX-DEVb2 #3: a bound checkout and the flag of an ancestor TUI reveal; no other process does (reveal_test.py)" "$HERE/reveal_test.py" "$ENVS" "$PROJ" "$T/revealwork"
printf 'billing\tdev\tDATABASE_URL\t%s' "$FUT" >"$T/reveal-1-0123456789ab"
(cd / && ENVS_REVEAL_FILE="$T/reveal-1-0123456789ab" "$ENVS" _preview vars billing "$PROJ" dev DATABASE_URL >"$CAP/pv4.out" 2>&1)
check "1: a flag outside the runtime directory is ignored" bash -c "! grep -q SECRET '$CAP/pv4.out'"
scan "17.1"

# finding 2: a forged .git file borrowed another checkout's binding
reset; bind_proj
(cd "$PROJ" && git add -A >/dev/null 2>&1 && git commit -qm init >/dev/null 2>&1 && git worktree add -q "$T/wt" -b wt >/dev/null 2>&1)
ZIP="$T/downloaded-zip"; mkdir -p "$ZIP"; cp "$PROJ/.envs.toml" "$PROJ/.mise.toml" "$ZIP/"
printf 'gitdir: %s/.git\n' "$PROJ" >"$ZIP/.git"
EDIR="$ZIP" e status
check "2: a .git FILE pointing at a bound clone's .git directory does not borrow its binding" grep -q 'binding  unbound' "$OUT"
EDIR="$ZIP" e run -- true
check "2: ... and envs run there is refused without a prompt (exit 4)" test $RC = 4
printf 'gitdir: %s/.git/worktrees/wt\n' "$PROJ" >"$ZIP/.git"
EDIR="$ZIP" e status
check "2: a .git file pointing at a real worktree gitdir without its back-link is refused too" grep -q 'binding  unbound' "$OUT"
rm -f "$ZIP/.git"; ln -s "$PROJ/.git" "$ZIP/.git"
EDIR="$ZIP" e status
check "2: a .git symlink to a bound clone does not borrow the binding" grep -q 'binding  unbound' "$OUT"
EDIR="$T/wt" e run -- true
check "2: a real linked worktree still shares the binding" test $RC = 0
EDIR=""
scan "17.2"

# finding 13: one binding per repository AND directory (monorepo)
reset; bind_proj
mkdir -p "$PROJ/apps/api"
printf 'project = "api"\nenvironments = ["dev"]\ndefault = "dev"\n' >"$PROJ/apps/api/.envs.toml"
EDIR="$PROJ/apps/api" e run -- true
check "13: a second project in a subdirectory of a bound repository starts unbound" test $RC = 4
EDIR="$PROJ/apps/api" e bind --yes
e run -- true
check "13: binding it leaves the root's own binding alone (no flip to 'changed')" test $RC = 0
EDIR="$PROJ/apps/api" e run -- true
check "13: ... and both stay bound" test $RC = 0
check "13: two rows in bindings.tsv" bash -c "[ \$(wc -l <'$XDG_STATE_HOME/envs/bindings.tsv') = 2 ]"
EDIR=""
e check --all
check "13: check --all lists both roots" bash -c "grep -q '$PROJ\$' '$OUT' && grep -q '$PROJ/apps/api' '$OUT'"

# finding 12: a tab or newline in the checkout path forges state rows
reset
TABDIR="$T/pro"$'\t'"j"
mkdir -p "$TABDIR"; cp "$PROJ/.envs.toml" "$TABDIR/"
EDIR="$TABDIR" e bind --yes
check "12: a root with a tab in its path is refused, no row written" bash -c "[ $RC != 0 ] && [ ! -s '$XDG_STATE_HOME/envs/bindings.tsv' ] && grep -q 'control character' '$ERR'"
NLDIR="$T/pro"$'\n'"k"
mkdir -p "$NLDIR"; cp "$PROJ/.envs.toml" "$NLDIR/"
EDIR="$NLDIR" e bind --yes
check "12: and one with a newline" bash -c "[ $RC != 0 ] && [ ! -s '$XDG_STATE_HOME/envs/bindings.tsv' ]"
EDIR=""
rm -rf "$TABDIR" "$NLDIR"

# finding 3: the test hooks cannot switch the agent check off, and cannot reach the real vault
reset; bind_proj
mkdir -p "$T/fakebin"
printf '#!/bin/sh\necho called >>"%s/rbw-called"\nexit 0\n' "$T" >"$T/fakebin/rbw"; chmod +x "$T/fakebin/rbw"
rm -f "$T/rbw-called"
(cd "$PROJ" && "$T/claude" -c "ENVS_TOOL_PATH='$T/fakebin' ENVS_TEST_ROOT_PID=\$\$ ENVS_TEST_YES=1 RBW_BIN='$T/fakebin/rbw' \"$ENVS\" run -- true; exit \$?" >"$CAP/h1.out" 2>"$CAP/h1.err"); rc=$?
check "3: under an agent, hooks + a rbw outside tests/ are refused (exit 4) and the fake rbw is never called" bash -c "[ $rc = 4 ] && [ ! -e '$T/rbw-called' ] && grep -q 'refused inside an agent' '$CAP/h1.err'"
rm -f "$XDG_STATE_HOME/envs/bindings.tsv"
(cd "$PROJ" && ENVS_TOOL_PATH="$T/fakebin" ENVS_TEST_YES=1 "$ENVS" bind >"$CAP/h2.out" 2>"$CAP/h2.err" </dev/null); rc=$?
check "3: ENVS_TEST_YES with a tool directory outside tests/ binds nothing" bash -c "[ $rc = 4 ] && [ ! -s '$XDG_STATE_HOME/envs/bindings.tsv' ]"
pycheck "3: test mode needs a tool dir below tests/ and isolated state; tool() never leaves it for the vault tools" "$HERE/hardening_test.py" "$ENVS" "$REPO"
scan "17.3"

# finding 4: absolute interpreter, user PATH only for the command, tools not shadowed through PATH
reset; bind_proj
check "4: the shebang is the absolute /usr/bin/python3 -I" test "$(head -1 "$ENVS")" = '#!/usr/bin/python3 -I'
mkdir -p "$T/pybin" "$T/evilbin" "$T/fakehome/.local/bin"
printf '#!/bin/sh\necho "No module named tomllib" >&2\necho used >>"%s/python-used"\nexit 99\n' "$T" >"$T/pybin/python3"; chmod +x "$T/pybin/python3"
rm -f "$T/python-used"
(cd "$PROJ" && PATH="$T/pybin:$PATH" "$ENVS" run -- sh -c 'printf %s "$PATH"' >"$CAP/py.out" 2>"$CAP/py.err"); rc=$?
check "4: a python3 first in PATH (a project pinning Python 3.10) neither runs nor breaks envs" bash -c "[ $rc = 0 ] && [ ! -e '$T/python-used' ]"
check "4: the command still gets the user's PATH unchanged" test "$(cat "$CAP/py.out")" = "$T/pybin:$PATH"
printf '#!/bin/sh\necho EVIL >>"%s/evil-ran"\n' "$T" >"$T/evilbin/envs"
printf '#!/bin/sh\necho "REAL $*" >>"%s/real-ran"\n' "$T" >"$T/fakehome/.local/bin/envs"
chmod +x "$T/evilbin/envs" "$T/fakehome/.local/bin/envs"
rm -f "$T/evil-ran" "$T/real-ran"
# the functions of .zshrc with the startup line replaced by one that follows the fake $HOME (the real line takes the home from
# the password database; it has its own case below)
fn=$(printf 'typeset -g _ENVS_BIN=$HOME/.local/bin/envs\n'; grep -E '^(envs\(\)|er\(\)|ere\(\)|ert\(\))' "$REPO/.zshrc")
HOME="$T/fakehome" PATH="$T/evilbin:$PATH" zsh -f -c "$fn; er true; ere stage true; ert test; envs run true" >/dev/null 2>&1
check "4: er / ere / ert / a typed envs call ~/.local/bin/envs, never an envs found through PATH" bash -c "[ ! -e '$T/evil-ran' ] && [ \$(wc -l <'$T/real-ran') = 4 ]"
# FIX-DEVb2 #6: a project's mise [env] changes HOME (and PATH) AFTER the shell started: the functions keep the path of startup
mkdir -p "$T/evilhome/.local/bin"
printf '#!/bin/sh\necho EVILHOME >>"%s/evil-ran"\n' "$T" >"$T/evilhome/.local/bin/envs"; chmod +x "$T/evilhome/.local/bin/envs"
rm -f "$T/evil-ran" "$T/real-ran"
HOME="$T/fakehome" zsh -f -c "$fn; HOME='$T/evilhome'; PATH='$T/evilbin':\$PATH; envs run true; er true; ere stage true; ert test" >/dev/null 2>&1
check "19.6: HOME and PATH changed after startup (a project's [env]) do not redirect envs, er, ere, ert" bash -c "[ ! -e '$T/evil-ran' ] && [ \$(wc -l <'$T/real-ran') = 4 ]"
# REVIEW-ENVS-FINAL #7 (FINAL re-check): the real startup block: home from passwd (not $HOME), readonly, an imported _ENVS_BIN is dropped, re-sourcing is fine
blk=$(sed -n '/^# The absolute path of envs/,/^fi$/p' "$REPO/.zshrc")
pwhome=$(getent passwd "$(id -u)" | cut -d: -f6)
got=$(HOME=/nonexistent-evil _ENVS_BIN=/evil/envs zsh -f -c "$blk; $blk; print -r -- \$_ENVS_BIN; _ENVS_BIN=x" 2>&1)
check "17.7: _ENVS_BIN is the passwd home's envs (not \$HOME, not an imported value) and readonly, also when sourced twice" bash -c "[ \"\$(head -1 <<<'$got')\" = '$pwhome/.local/bin/envs' ] && grep -q 'read-only variable' <<<'$got'"
printf '#!/bin/sh\necho evil >>"%s/wlcopy-evil"\ncat >/dev/null\n' "$T" >"$T/evilbin/wl-copy"; chmod +x "$T/evilbin/wl-copy"
rm -f "$T/wlcopy-evil"
rm -f "$FAKE_DIR/clip.last"
(cd "$PROJ" && PATH="$T/evilbin:$PATH" "$ENVS" copy-value DATABASE_URL >"$CAP/wl.out" 2>"$CAP/wl.err"); rc=$?
for _ in $(seq 30); do [[ -s $FAKE_DIR/clip.last ]] && break; sleep 0.1; done   # the fake wl-copy runs on its own, like the real one
check "4: copy-value hands the secret to the real wl-copy path, not to a wl-copy first in PATH" bash -c "[ $rc = 0 ] && [ ! -e '$T/wlcopy-evil' ] && [ \"\$(cat '$FAKE_DIR/clip.last')\" = SECRET-billing-dev-db ]"
scan "17.4"

# finding 5: the fzf API key (TUI section), and the documented limits
rm -f "$T/evade.out"
(cd "$PROJ" && "$T/claude" -c "setsid -f sh -c 'cd \"$PROJ\" && \"$ENVS\" run -- sh -c \"echo ran\" >\"$T/evade.out\" 2>&1' </dev/null >/dev/null 2>&1; exit 0")
for _ in $(seq 50); do [[ -s $T/evade.out ]] && break; sleep 0.1; done
check "5: KNOWN LIMIT (documented): a process that detaches from the agent (setsid -f) is not recognised as one" grep -qx ran "$T/evade.out"
cat >"$T/evade2.sh" <<EOS
#!/bin/sh
cd "$PROJ"
printf 'y\n' | script -qec '"$ENVS" run -e prod -- true' /dev/null >"$T/evade2.out" 2>&1
echo "rc=\$?" >>"$T/evade2.out"
EOS
rm -f "$T/evade2.out"
(cd "$PROJ" && "$T/claude" -c "setsid -f sh '$T/evade2.sh' </dev/null >/dev/null 2>&1; exit 0")
for _ in $(seq 60); do grep -q "rc=" "$T/evade2.out" 2>/dev/null && break; sleep 0.1; done
check "5: KNOWN LIMIT (documented): a pty answers the [y/N] of a protected run (the prompt stops accidents, not a determined process)" grep -q "rc=0" "$T/evade2.out"
scan "17.5"

# finding 6: mise trust is its own question, never implied
reset
etty 'y\nn\n' bind
check "6: bind asks the trust question separately; n = bound but mise stays untrusted" bash -c "[ $RC = 0 ] && grep -q billing '$XDG_STATE_HOME/envs/bindings.tsv' && ! grep -q '|trust' '$FAKE_DIR/mise.log' && grep -q 'Trust the mise config' '$OUT' && grep -q '.mise.toml' '$OUT'"
reset
etty 'y\ny\n' bind
check "6: y to both questions trusts" bash -c "[ $RC = 0 ] && grep -q '|trust' '$FAKE_DIR/mise.log'"
: >"$FAKE_DIR/mise.log"
e bind --yes
check "6: bind on an already bound checkout never re-trusts" bash -c "[ $RC = 0 ] && grep -q 'already bound' '$OUT' && ! grep -q '|trust' '$FAKE_DIR/mise.log'"
reset
etty 'y\n' run -- true
check "6: the first-run binding question (envs run) does not trust mise either" bash -c "[ $RC = 0 ] && grep -q billing '$XDG_STATE_HOME/envs/bindings.tsv' && ! grep -q '|trust' '$FAKE_DIR/mise.log'"
e trust
check "6: envs trust without a terminal does not trust (exit 4)" bash -c "[ $RC = 4 ] && ! grep -q '|trust' '$FAKE_DIR/mise.log'"
(cd "$PROJ" && CLAUDECODE=1 "$ENVS" trust >/dev/null 2>&1 </dev/null); rc=$?
check "6: envs trust is refused for an agent" test $rc = 4
etty 'y\n' trust
check "6: envs trust on a terminal lists the file and trusts after y" bash -c "[ $RC = 0 ] && grep -q '|trust' '$FAKE_DIR/mise.log' && grep -q '.mise.toml' '$OUT'"
reset
NEW="$T/newproj"; rm -rf "$NEW"; mkdir -p "$NEW"; (cd "$NEW" && git init -q . && printf '[tools]\n' >.mise.toml)
EDIR="$NEW" e init --project newp
check "6: init without a terminal binds but does not trust a mise config that is already there; it says how" bash -c "[ $RC = 0 ] && grep -q newp '$XDG_STATE_HOME/envs/bindings.tsv' && ! grep -q '|trust' '$FAKE_DIR/mise.log' && grep -q 'envs trust' '$OUT'"
rm -rf "$NEW"; mkdir -p "$NEW"; (cd "$NEW" && git init -q . && printf '[tools]\n' >.mise.toml)
EDIR="$NEW" etty 'y\nn\n' init --project newp2
check "6: init on a terminal asks; n = not trusted" bash -c "[ $RC = 0 ] && ! grep -q '|trust' '$FAKE_DIR/mise.log' && grep -q 'Trust the mise config' '$OUT'"
EDIR=""; rm -rf "$NEW"
scan "17.6"

# finding 8 and the TUI pieces
reset; bind_proj
( . "$HERE/env.sh" >/dev/null 2>&1; : ) 2>/dev/null
pycheck "8/9: preview command quoting (spaces, \$(...), backticks in a checkout path) and the protected reveal" "$HERE/tui_test.py" "$ENVS" "$T/tuiwork"

# finding 9: prod gate gaps
reset; bind_proj
e copy prod dev
check "9: copy FROM prod without --prod (no terminal) is refused, dev untouched" bash -c "[ $RC = 4 ] && [ \"\$(jq -r '.items[]|select(.id==\"e-dev\")|.fields[]|select(.name==\"DATABASE_URL\")|.value' '$FAKE_DIR/vault.json')\" = SECRET-billing-dev-db ]"
e copy prod dev --prod --overwrite
check "9: copy from prod with --prod works and leaves a journald line" bash -c "[ $RC = 0 ] && grep -q 'copy from project=billing env=prod' '$FAKE_DIR/logger.log'"
reset; bind_proj
ETTY_DELAY=0.4 etty 'y\nwrong\n' convert STRIPE_SECRET_KEY
check "9: secret -> plain with a prod value: a wrong typed name stops it, nothing was written or removed" bash -c "[ $RC != 0 ] && [ ! -e '$PROJ/.mise.prod.toml' ] && [ \"\$(jq -r '.items[]|select(.id==\"e-prod\")|.fields[]|select(.name==\"STRIPE_SECRET_KEY\")|.value' '$FAKE_DIR/vault.json')\" = SECRET-billing-prod-stripe ] && grep -q '^STRIPE_SECRET_KEY' '$PROJ/.envs.toml'"
e convert STRIPE_SECRET_KEY
check "9: ... and without a terminal it is refused" test $RC != 0
(cd "$PROJ" && CLAUDECODE=1 "$ENVS" convert STRIPE_SECRET_KEY --prod >/dev/null 2>&1 </dev/null); rc=$?
check "9: convert is refused for an agent" test $rc = 4
ETTY_DELAY=0.4 etty 'y\nprod\n' convert STRIPE_SECRET_KEY
check "9: typing prod lets the conversion through and it is logged" bash -c "[ $RC = 0 ] && grep -q 'STRIPE_SECRET_KEY' '$PROJ/.mise.prod.toml' && grep -q 'convert project=billing env=prod name=STRIPE_SECRET_KEY' '$FAKE_DIR/logger.log'"
rm -f "$PROJ/.mise.prod.toml" "$PROJ/.mise.dev.toml"
reset; bind_proj
e env rename prod live
check "9: renaming prod keeps it protected under the new name" bash -c "[ $RC = 0 ] && grep -q 'protected = \[\"live\"\]' '$PROJ/.envs.toml'"
e status --json
check "9: ... status lists live as protected" jq -e '.protected | index("live")' "$OUT"
reset
sed -i 's/default = "dev"/default = "prod"/' "$PROJ/.envs.toml"
e status
check "9: a protected default environment is a problem" grep -q 'is protected' "$OUT"
reset
sed -i 's/protected = \["prod"\]/protected = ["prod", "stage"]/; s/default = "dev"/default = "stage"/' "$PROJ/.envs.toml"
e status
check "9: ... also when protected = [...] names it" grep -q 'default .stage. is protected' "$OUT"
scan "17.9"

# finding 11: import never follows a symlink
reset; bind_proj
printf 'X_TOKEN=NEWVAL-import-4\n' >"$T/outside.env"
ln -s "$T/outside.env" "$PROJ/.env"
e import -e stage --secrets X_TOKEN
check "11: a symlinked .env is not even found" test $RC = 1
e import .env -e stage --secrets X_TOKEN
check "11: naming the symlink is refused" bash -c "[ $RC = 1 ] && grep -q 'symbolic link' '$ERR'"
etty 'y\n' import .env -e stage --secrets X_TOKEN
check "11: on a terminal too (no Shred prompt is reached)" test $RC = 1
e import "$T/outside.env" -e stage --secrets X_TOKEN
check "11: a file outside the project root is refused" test $RC = 1
check "11: the link target is intact and nothing reached the vault" bash -c "[ \"\$(cat '$T/outside.env')\" = 'X_TOKEN=NEWVAL-import-4' ] && ! grep -q NEWVAL-import-4 '$FAKE_DIR/vault.json'"
rm -f "$PROJ/.env" "$T/outside.env"

# finding 14: project delete stops at the first failed item delete
reset; bind_proj
echo e-stage >"$FAKE_DIR/fail-delete"
etty 'billing\n' project delete
check "14: a failing item delete stops project delete before the folder and the other items" bash -c "[ $RC = 1 ] && [ \"\$(jq -r '[.folders[]|select(.id==\"f-billing\")]|length' '$FAKE_DIR/vault.json')\" = 1 ] && [ \"\$(jq -r '.items[]|select(.id==\"e-prod\")|.deletedDate' '$FAKE_DIR/vault.json')\" = null ] && grep -q billing '$XDG_STATE_HOME/envs/bindings.tsv'"
rm -f "$FAKE_DIR/fail-delete"
etty 'billing\n' project delete
check "14: run again once it works: everything goes" bash -c "[ $RC = 0 ] && [ \"\$(jq -r '[.folders[]|select(.id==\"f-billing\")]|length' '$FAKE_DIR/vault.json')\" = 0 ]"

# finding 15: reserved names
bad_cfg2() { reset; (cd "$PROJ" && eval "$2"); e status; if grep -qF -- "$3" "$OUT"; then ok "15: rejected: $1"; else bad "15: rejected: $1" "$(head -c 200 "$OUT")"; fi; }
bad_cfg2 "LD_ prefix" "echo 'LD_DEBUG = \"\"' >>.envs.toml" "'LD_DEBUG' is a reserved name"
bad_cfg2 "BASH_ENV" "echo 'BASH_ENV = \"\"' >>.envs.toml" "'BASH_ENV' is a reserved name"
bad_cfg2 "NODE_PATH" "echo 'NODE_PATH = \"\"' >>.envs.toml" "'NODE_PATH' is a reserved name"
bad_cfg2 "GLIBC_TUNABLES" "echo 'GLIBC_TUNABLES = \"\"' >>.envs.toml" "'GLIBC_TUNABLES' is a reserved name"
bad_cfg2 "GIT_DIR" "echo 'GIT_DIR = \"\"' >>.envs.toml" "'GIT_DIR' is a reserved name"

# finding 16: mise logging and overrides
reset; bind_proj
(cd "$PROJ" && MISE_LOG_FILE="$T/mise-trace.log" MISE_DEBUG=1 MISE_TRACE=1 MISE_LOG_LEVEL=trace "$ENVS" run -- sh -c 'echo "${MISE_LOG_FILE:-unset} ${MISE_DEBUG:-unset} ${MISE_TRACE:-unset} $MISE_LOG_LEVEL"' >"$CAP/ml.out" 2>"$CAP/ml.err")
check "16: mise gets no log file, no debug/trace switch, and level warn" grep -qx 'unset unset unset warn' "$CAP/ml.out"
printf '[env]\nDATABASE_URL = "from-parent"\n' >"$T/.mise.toml"
e run -- true
check "16: a mise [env] above the project that sets a declared secret is reported on stderr" grep -q "DATABASE_URL is also set by mise \[env\] in $T/.mise.toml" "$ERR"
e check
check "16: ... and by check" grep -q "DATABASE_URL is also set by mise \[env\]" "$OUT"
rm -f "$T/.mise.toml"
scan "17.16"

# finding 18 (info): interpreter run agents, the set message
reset; bind_proj
cp /bin/sh "$T/node"
(cd "$PROJ" && "$T/node" -c "\"$ENVS\" run -- true; exit \$?" /opt/lib/node_modules/@openai/codex/bin/codex.js >/dev/null 2>"$CAP/nd.err" </dev/null); rc=$?
check "18: node running .../@openai/codex/... is recognised as an agent" bash -c "[ $rc = 4 ] && grep -q 'refused inside an agent' '$CAP/nd.err'"
(cd "$PROJ" && "$T/node" -c "\"$ENVS\" run -- true; exit \$?" /usr/lib/gemini-cli/bundle/gemini.js >/dev/null 2>&1 </dev/null); rc=$?
check "18: ... and gemini-cli" test $rc = 4
e set DATABASE_URL=oops
check "18: the value-on-the-command-line message tells to rotate it and clean the history" grep -q 'rotate it' "$ERR"
rm -f "$T/node"
}

sections_18() {
# ───────────── 18 mise.zsh: install on cd
section "18 mise.zsh install-on-cd (fake mise)"
reset
MZ="$REPO/.config/zsh/mise.zsh"
mkdir -p "$T/legacy" "$T/tomlproj" "$T/zhome"
printf 'node 22\n' >"$T/legacy/.tool-versions"
printf '[tools]\nnode = "22"\n' >"$T/tomlproj/.mise.toml"
mz() { # dir -> stdout+stderr of a zsh that cd'ed into it (mise log in $FAKE_DIR/mise.log)
  : >"$FAKE_DIR/mise.log"; printf 'node 22.1.0\n' >"$T/missing.txt"; rm -rf "$T/zrun"
  (cd "$T" && DF_MISE_MODE=activate HOME="$T/zhome" XDG_RUNTIME_DIR="$T/zrun" XDG_CACHE_HOME="$T/zcache" XDG_DATA_HOME="$T/zdata" \
    FAKE_MISE_MISSING="$T/missing.txt" zsh -f -c "source '$MZ'; cd '$1'; sleep 1" 2>&1)
}
out=$(mz "$T/tomlproj")
check "7: a trusted mise.toml with missing tools starts the background install (control)" grep -q '|install' "$FAKE_DIR/mise.log"
out=$(mz "$T/legacy")
check "7: a .tool-versions alone does not start an install, it prints a hint" bash -c "! grep -q '|install' '$FAKE_DIR/mise.log' && grep -q 'not installed automatically' <<<'$out'"
cat >"$T/legacy/.nvmrc" <<<'22'
rm "$T/legacy/.tool-versions"
out=$(mz "$T/legacy")
check "7: same for .nvmrc" bash -c "! grep -q '|install' '$FAKE_DIR/mise.log' && grep -q 'not installed automatically' <<<'$out'"
check "7: the global mise config disables the asdf and vfox plugin backends" grep -q '^disable_backends = \["asdf", "vfox"\]' "$REPO/.config/mise/config.toml"
}

sections_19() {
# ───────────── 19 FIX-DEVb2: the open findings of REVIEW-FIXDEVb-5.md, each reproduced; all of these fail on the old code
section "19 FIX-DEVb2: review attacks"

# #1 (HIGH): a forged linked worktree (own commondir + back-link) borrowed a bound clone's binding
reset; bind_proj
JOB="$T/job"; rm -rf "$JOB"; mkdir -p "$JOB/downloaded/fakegit"
cp "$PROJ/.envs.toml" "$PROJ/.mise.toml" "$JOB/downloaded/"
printf 'gitdir: fakegit\n' >"$JOB/downloaded/.git"
printf '%s\n' "$PROJ/.git" >"$JOB/downloaded/fakegit/commondir"
printf '../.git\n' >"$JOB/downloaded/fakegit/gitdir"
EDIR="$JOB/downloaded" e status
check "19.1: a .git file with its own commondir and back-link (the reviewer's fakegit) does not borrow the binding" grep -q 'binding  unbound' "$OUT"
EDIR="$JOB/downloaded" e run -- sh -c 'echo $DATABASE_URL'
check "19.1: ... envs run there is refused without a prompt and prints no secret (exit 4)" bash -c "[ $RC = 4 ] && ! grep -q SECRET '$OUT'"
rm -rf "$JOB/downloaded/fakegit"; mkdir -p "$JOB/downloaded/fakegit2/x"
printf 'gitdir: fakegit2/x\n' >"$JOB/downloaded/.git"
printf '../..\n' >"$JOB/downloaded/fakegit2/x/commondir"
printf '../../../.git\n' >"$JOB/downloaded/fakegit2/x/gitdir"
EDIR="$JOB/downloaded" e status
check "19.1: a gitdir that merely sits two levels below its own common dir (not in .../worktrees/) is refused" grep -q 'binding  unbound' "$OUT"
(cd "$PROJ" && git add -A >/dev/null 2>&1 && git commit -qm init >/dev/null 2>&1 && git worktree add -q "$T/wt" -b wt >/dev/null 2>&1)
EDIR="$T/wt" e run -- true
check "19.1: control: a real linked worktree (gitdir in <common>/worktrees/) still shares the binding" test $RC = 0
EDIR=""; rm -rf "$JOB"
scan "19.1"

# #4: auto-install of legacy tool files must not run with the secrets in the environment
reset; bind_proj
(cd "$PROJ" && MISE_AUTO_INSTALL=1 MISE_NOT_FOUND_AUTO_INSTALL=1 "$ENVS" run -- sh -c 'echo "${MISE_AUTO_INSTALL:-unset}/${MISE_NOT_FOUND_AUTO_INSTALL:-unset}"' >"$CAP/ai.out" 2>"$CAP/ai.err"); rc=$?
check "19.4: mise exec runs with auto-install and not-found auto-install off, whatever the shell had" bash -c "[ $rc = 0 ] && [ \"\$(cat '$CAP/ai.out')\" = 0/0 ]"
(cd "$PROJ" && "$ENVS" run --no-mise -- sh -c 'echo "${MISE_AUTO_INSTALL:-unset}"' >"$CAP/ai2.out" 2>/dev/null)
check "19.4: --no-mise leaves the environment alone" test "$(cat "$CAP/ai2.out")" = unset
# REVIEW-ENVS-FINAL #6: exec and task-run auto-install switches (ert runs `mise run` inside envs run)
(cd "$PROJ" && MISE_EXEC_AUTO_INSTALL=1 MISE_TASK_RUN_AUTO_INSTALL=1 "$ENVS" run -- sh -c 'echo "${MISE_EXEC_AUTO_INSTALL:-unset}/${MISE_TASK_RUN_AUTO_INSTALL:-unset}"' >"$CAP/ai3.out" 2>/dev/null)
check "19.4: MISE_EXEC_AUTO_INSTALL and MISE_TASK_RUN_AUTO_INSTALL are 0 for the mise child too" test "$(cat "$CAP/ai3.out")" = 0/0

# #5: a hard-linked .env is never imported or shredded
reset; bind_proj
printf 'X_TOKEN=NEWVAL-import-4\n' >"$T/outside.env"
ln "$T/outside.env" "$PROJ/.env"
e import .env -e stage --secrets X_TOKEN
check "19.5: a .env with a second hard link is refused without a terminal" bash -c "[ $RC = 1 ] && grep -q 'hard link' '$ERR'"
etty 'y\n' import .env -e stage --secrets X_TOKEN
check "19.5: and on a terminal (no Shred prompt is reached)" test $RC = 1
check "19.5: the other name of the file is intact and nothing reached the vault" bash -c "[ \"\$(cat '$T/outside.env')\" = 'X_TOKEN=NEWVAL-import-4' ] && ! grep -q NEWVAL-import-4 '$FAKE_DIR/vault.json'"
rm -f "$PROJ/.env" "$T/outside.env"
printf 'X_TOKEN=NEWVAL-import-5\n' >"$PROJ/.env"
etty 'y\ny\n' import .env -e stage --secrets X_TOKEN
check "19.5: control: a plain single-link .env is still imported" bash -c "[ $RC = 0 ] && grep -q NEWVAL-import-5 '$FAKE_DIR/vault.json'"
scan "19.5"

# REVIEW-ENVS-FINAL #2/#3: a different repository that lands on a bound path is not the bound one (root commit stored in bindings.tsv)
reset; bind_proj
(cd "$PROJ" && git add -A >/dev/null 2>&1 && git commit -qm one >/dev/null 2>&1)
e run -- true
ID1=$(awk -F'\t' '{print $4}' "$XDG_STATE_HOME/envs/bindings.tsv")
check "19.8: the first use of a binding without identity records the root commit (column 4)" bash -c "[ $RC = 0 ] && [[ '$ID1' =~ ^[0-9a-f]{40}$ ]]"
rm -rf "$PROJ/.git"
(cd "$PROJ" && git init -q . && echo second >other.txt && git add -A >/dev/null 2>&1 && git commit -qm two >/dev/null 2>&1)
e run -- sh -c 'echo $DATABASE_URL'
check "19.8: another repository at the bound path is refused (exit 4, no secret, names envs bind)" bash -c "[ $RC = 4 ] && ! grep -q SECRET '$OUT' && grep -q 'not the one that was bound' '$ERR' && grep -q 'envs bind' '$ERR'"
e status
check "19.8: status says moved" grep -q 'binding  moved' "$OUT"
etty 'billing\n' bind
check "19.8: envs bind (typed project name) accepts the new repository" bash -c "[ $RC = 0 ] && ! grep -q '$ID1' '$XDG_STATE_HOME/envs/bindings.tsv'"
e run -- true
check "19.8: and it runs again" test $RC = 0
scan "19.8"

# REVIEW-ENVS-FINAL #4: Env/<project> already bound elsewhere: loud, typed project name, never inline in `envs run`
reset; bind_proj
CL="$T/clone2"; rm -rf "$CL"; mkdir -p "$CL"; cp "$PROJ/.envs.toml" "$PROJ/.mise.toml" "$CL/"; (cd "$CL" && git init -q .)
EDIR="$CL" e run -- sh -c 'echo $DATABASE_URL'
check "19.9: envs run in a second checkout of a bound project name: exit 4, says where it is bound, no inline prompt" bash -c "[ $RC = 4 ] && ! grep -q SECRET '$OUT' && grep -q 'already bound to' '$ERR' && grep -q 'envs bind' '$ERR'"
EDIR="$CL" ENVS_TEST_YES=1 e run -- true
check "19.9: even the test hook that says yes does not bind it inline" test $RC = 4
EDIR="$CL" etty 'y\n' bind
check "19.9: envs bind: y is not enough (the warning names the other path, exit 4, nothing bound)" bash -c "[ $RC = 4 ] && grep -qa 'already bound to' '$ERR' '$OUT' && [ \$(wc -l <'$XDG_STATE_HOME/envs/bindings.tsv') = 1 ]"
EDIR="$CL" etty 'billing\n' bind
check "19.9: ... typing the project name binds it" bash -c "[ $RC = 0 ] && [ \$(wc -l <'$XDG_STATE_HOME/envs/bindings.tsv') = 2 ]"
rm -rf "$CL"
EDIR=""
scan "19.9"

# REVIEW-DEV-d #12: a shallow clone's root commits are its shallow boundary: they change after `git fetch --unshallow`, but it is the
# same repository and stays bound (the stored commit still exists)
reset
(cd "$PROJ" && git add -A >/dev/null 2>&1 && git commit -qm one >/dev/null 2>&1 && echo 2 >f2 && git add f2 && git commit -qm two >/dev/null 2>&1 && echo 3 >f3 && git add f3 && git commit -qm three >/dev/null 2>&1)
SH="$T/shallow"; ORIGIN="$T/origin"; rm -rf "$SH" "$ORIGIN"; mv "$PROJ" "$ORIGIN"; git clone -q --depth 1 "file://$ORIGIN" "$SH" >/dev/null 2>&1
PROJ_KEEP=$PROJ; PROJ=$SH
bind_proj
e run -- true
check "19.10: a bound SHALLOW clone runs" test $RC = 0
(cd "$SH" && git fetch -q --unshallow >/dev/null 2>&1)
e run -- true
check "19.10: after git fetch --unshallow the same repository is still bound (exit 0; it was refused as moved, exit 4, before)" bash -c "[ $RC = 0 ] && ! grep -q 'not the one that was bound' '$ERR'"
PROJ=$PROJ_KEEP; rm -rf "$ORIGIN" "$SH"
scan "19.10"

# REVIEW-DEV-d #13: the same repository moved (~/job/billing -> ~/work/billing): the old row is gone, a plain y rebinds, the old row is replaced
reset
(cd "$PROJ" && git add -A >/dev/null 2>&1 && git commit -qm init >/dev/null 2>&1)
bind_proj
MV="$T/moved"; rm -rf "$MV"; mv "$PROJ" "$MV"
EDIR="$MV" etty 'y\n' bind
check "19.11: a moved repository (old root gone, same root commit): y is enough, no typed project name" bash -c "[ $RC = 0 ] && ! grep -qa 'already bound to' '$ERR' '$OUT'"
check "19.11: ... and the old row is replaced, not kept (one binding)" bash -c "[ \$(wc -l <'$XDG_STATE_HOME/envs/bindings.tsv') = 1 ] && grep -q 'moved' '$XDG_STATE_HOME/envs/bindings.tsv'"
rm -rf "$MV"; mkdir -p "$PROJ"
(cd "$PROJ" && git init -q . && printf 'project = "billing"\nenvironments = ["dev"]\ndefault = "dev"\n[secrets]\nX = ""\n' >.envs.toml; echo other >o && git add -A >/dev/null 2>&1 && git commit -qm other >/dev/null 2>&1)
etty 'y\n' bind
check "19.11: a DIFFERENT repository with the same project name while the old root is gone still needs the typed name, and the note says (gone)" bash -c "[ $RC = 4 ] && grep -qa '(gone)' '$ERR' '$OUT'"
scan "19.11"
}

sections_20() {
# ───────────── 20 DEV-d C1: global scope (envs run -g), ENVS_SECRETS, [db]/[api]/[ci] tables
section "20 DEV-d: global scope, ENVS_SECRETS, extra tables"
reset; bind_proj
GD="$T/gdir"; GD_DEFAULT=$ENVS_GLOBAL_DIR; rm -rf "$GD" "$T/nowhere"; mkdir -p "$GD" "$T/nowhere"; chmod 700 "$GD"
cp "$REPO/.config/envs/global.toml" "$GD/global.toml"; chmod 644 "$GD/global.toml"
export ENVS_GLOBAL_DIR="$GD"
EDIR="$T/nowhere"
epipe 'SECRET-global-gitlab' set GITLAB_TOKEN -g --stdin
check "20.1: set NAME -g --stdin writes the Secure Note default in Env/global (no project, no binding)" bash -c "[ $RC = 0 ] && [ \"\$(jq -r '.items[]|select(.name==\"default\")|.fields[]|select(.name==\"GITLAB_TOKEN\")|.value' '$FAKE_DIR/vault.json')\" = SECRET-global-gitlab ]"
check "20.1: ... and the folder is Env/global" bash -c "jq -e '.folders[]|select(.name==\"Env/global\")' '$FAKE_DIR/vault.json'"
e run -g --allow-missing -- sh -c 'printf "%s" "$GITLAB_TOKEN" | sha256sum | cut -c1-64; echo "names=$ENVS_SECRETS project=$ENVS_PROJECT env=$ENVS_ENV host=${GITLAB_HOST:-unset}"'
check "20.2: run -g (outside any project, no bind prompt) injects the global secret; ENVS_SECRETS lists names only" bash -c "[ $RC = 0 ] && head -1 '$OUT' | grep -qx $(sha SECRET-global-gitlab) && grep -q 'names=GITLAB_TOKEN project=global env=default host=unset' '$OUT'"
e run -g -- true
check "20.2: a declared global name that is missing stops the run (exit 1) unless --allow-missing" bash -c "[ $RC = 1 ] && grep -q GITLAB_HOST '$ERR'"
CLAUDECODE=1 e run -g --allow-missing -- true
check "20.3: run -g is refused for an agent (exit 4)" test $RC = 4
EDIR="$PROJ" e run -- sh -c 'echo "names=$ENVS_SECRETS"'
check "20.4: a project run exports ENVS_SECRETS too (declared names that were injected, in order)" grep -q 'names=DATABASE_URL STRIPE_SECRET_KEY' "$OUT"
EDIR="$T/nowhere"
printf '[secrets]\nEXTRA_ONE = "second token"\n\n[db.td]\ndriver = "clickhouse"\nhost = "127.0.0.1"\n' >"$GD/global.local.toml"; chmod 600 "$GD/global.local.toml"
e status -g --json
check "20.5: global.local.toml is merged over global.toml (secrets of both, binding n/a)" bash -c "jq -e '.project==\"global\" and (.names|index(\"GITLAB_TOKEN\")) and (.names|index(\"EXTRA_ONE\")) and (.problems|length)==0' '$OUT'"
printf '[secrets]\nGITLAB_TOKEN = "again"\n' >"$GD/global.local.toml"
e status -g
check "20.5: a name declared in both files is an error" grep -q 'declared in global.toml and in global.local.toml' "$OUT"
printf '[secrets]\nEXTRA_ONE = ""\n' >"$GD/global.local.toml"; chmod 666 "$GD/global.local.toml"
e run -g --allow-missing -- true
check "20.6: a group/other-writable global.local.toml is refused (exit 4)" bash -c "[ $RC = 4 ] && grep -q 'writable by group or others' '$ERR'"
chmod 600 "$GD/global.local.toml"
chmod 666 "$GD/global.toml"; e run -g --allow-missing -- true; rc1=$RC; chmod 644 "$GD/global.toml"
check "20.6: ... and so is a writable global.toml" test $rc1 = 4
epipe 'SECRET-global-extra' set NEWGLOBAL -g --stdin --description "added by test"
check "20.7: set of an undeclared name declares it in global.local.toml, never in global.toml" bash -c "[ $RC = 0 ] && grep -q '^NEWGLOBAL = \"added by test\"' '$GD/global.local.toml' && ! grep -q NEWGLOBAL '$GD/global.toml'"
rm -f "$GD/global.local.toml"
epipe 'x' set ANOTHER -g --stdin
check "20.7: global.local.toml is created 0600" bash -c "[ $RC = 0 ] && [ \"\$(stat -c %a '$GD/global.local.toml')\" = 600 ]"
e set X -g --plain --stdin
check "20.7: --plain does not exist for the global scope" test $RC = 2
rm -f "$GD/global.local.toml"
cp "$PROJ/.envs.toml" "$T/envs.toml.bak"
printf '\n[db.main]\ndriver = "mariadb"\ndocker = "mariadb"\npassword = "DATABASE_URL"\n\n[api]\ncollection = "api"\n\n[ci]\nsecrets = []\n' >>"$PROJ/.envs.toml"
EDIR="$PROJ" e check
check "20.8: [db.NAME], [api] and [ci] tables in .envs.toml are accepted (their fields are the launchers' business)" bash -c "[ $RC = 0 ] && ! grep -q 'unknown key' '$OUT' '$ERR'"
EDIR="$PROJ" epipe 'NEWVAL-set-1' set DATABASE_URL -e dev --stdin
check "20.8: the line editor still edits [secrets] with tables after it" bash -c "[ $RC = 0 ] && grep -q '^\[db.main\]' '$PROJ/.envs.toml' && grep -c '^DATABASE_URL' '$PROJ/.envs.toml' | grep -qx 1"
printf '\n[bogus]\nx = 1\n' >>"$PROJ/.envs.toml"
EDIR="$PROJ" e check
check "20.8: an unknown table is still an error" grep -q "unknown key 'bogus'" "$OUT"
cp "$T/envs.toml.bak" "$PROJ/.envs.toml"
EDIR=""
export ENVS_GLOBAL_DIR=$GD_DEFAULT
scan "20"
}

sections_15_16() {
if ((QUICK)); then
  printf '\n(--quick: the tmux TUI section and the timing section are skipped)\n'
else
# ───────────── 15 TUI in a private tmux server
section "15 TUI (private tmux server)"
reset; bind_proj
tm() { tmux -L "$SOCK" "$@"; }
screen_raw() { tm capture-pane -p -J -t t 2>/dev/null; }
screen_masked() { # the screen with every secret checked: a sentinel on it is a leak (except while a reveal is expected)
  local out s
  out=$(screen_raw)
  for s in "${SECRETS[@]}"; do grep -aqF -- "$s" <<<"$out" && echo "$s" >>"$T/leaks.log"; done
  printf '%s\n' "$out"
}
scr_has() { screen_raw | grep -aqE -- "$1"; }
wait_scr() { local i max=$(( ${2:-8} * 5 )); for ((i = 0; i < max; i++)); do scr_has "$1" && return 0; sleep 0.2; done; return 1; }
key() { tm send-keys -t t "$@"; sleep "${KDELAY:-0.35}"; }
: >"$T/leaks.log"
tm new-session -d -s t -x 150 -y 40 "bash --noprofile --norc -c '. $HERE/env.sh >/dev/null; cd $PROJ; $ENVS; echo EXIT[\$?]; sleep 60'"
check "starts inside a project on its environments" wait_scr 'billing.*rbw unlocked' 12
screen_masked >/dev/null
check "the environment rows: dev, stage, prod (protected marked)" bash -c "s=\$(tmux -L $SOCK capture-pane -p -J -t t); grep -q 'dev' <<<\"\$s\" && grep -q 'stage' <<<\"\$s\" && grep -q 'prod .*protected' <<<\"\$s\""
check "preview of an environment shows names masked (no value)" wait_scr 'DATABASE_URL +••••••••' 6
key Enter
check "Enter opens the variables of dev: secrets set, the undeclared field flagged" wait_scr 'DATABASE_URL +secret set' 8
check "variables: the undeclared EXTRA_FIELD is listed as extra" scr_has 'EXTRA_FIELD +secret extra'
screen_masked >/dev/null
SOCKF=$(ls "$XDG_RUNTIME_DIR"/envs/fzf-*.sock 2>/dev/null | head -1)
code_nokey=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 --unix-socket "$SOCKF" -X POST http://localhost -d 'refresh-preview' 2>/dev/null)
check "5: the TUI's fzf listener refuses a POST without the run's API key (was: any process of this user could drive it)" bash -c "[ -S '$SOCKF' ] && [ '$code_nokey' != 200 ] && [ '$code_nokey' != 000 ]"
FZFKEY=""
for pid in $(pgrep -f -- "--listen=$SOCKF"); do
  FZFKEY=$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^FZF_API_KEY=//p'); [[ -n $FZFKEY ]] && break
done
code_key=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 -H "x-api-key: $FZFKEY" --unix-socket "$SOCKF" -X POST http://localhost -d 'refresh-preview' 2>/dev/null)
check "5: ... and accepts the key (the reveal ticker sends it; the key itself is only in the environment of that fzf)" bash -c "[ -n '$FZFKEY' ] && [ '$code_key' = 200 ]"
key Escape
KDELAY=0.9 key v
check "v reveals the value of the current row in the preview" wait_scr 'SECRET-billing-dev-db' 8
key C-j
sleep 0.8
check "moving the cursor hides it again (the screen shows no sentinel)" bash -c "! tmux -L $SOCK capture-pane -p -J -t t | grep -aq SECRET-billing-dev-db"
: >"$FAKE_DIR/clip.txt"; : >"$FAKE_DIR/clip.events"
key Escape
KDELAY=1.2 key y
check "y copies the value through wl-copy --sensitive" bash -c "grep -q 'copy --sensitive' '$FAKE_DIR/clip.events' && [ \"\$(cat '$FAKE_DIR/clip.txt')\" = SECRET-billing-dev-stripe ]"
: >"$FAKE_DIR/clip.txt"; : >"$FAKE_DIR/clip.events"
key Escape
tm send-keys -t t -l н; sleep 1.4
check "the Cyrillic twin of y works too" bash -c "grep -q 'copy --sensitive' '$FAKE_DIR/clip.events' && [ \"\$(cat '$FAKE_DIR/clip.txt')\" = SECRET-billing-dev-stripe ]"
wait_scr 'DATABASE_URL +secret set' 5
key Escape; key Escape
check "Esc in NORMAL goes up one level (back to the environments)" wait_scr 'prod .*protected' 8
key C-j; key C-j
key Escape
KDELAY=0.9 key u
check "u on prod asks for the typed name" wait_scr 'Type prod to confirm' 8
tm send-keys -t t "no" Enter; sleep 0.8
key Enter
check "a wrong confirmation does not select prod" bash -c "[ ! -s '$XDG_STATE_HOME/envs/active.tsv' ]"
wait_scr 'prod .*protected' 8
key Escape
KDELAY=0.9 key u
wait_scr 'Type prod to confirm' 8
tm send-keys -t t "prod" Enter; sleep 1
key Enter
check "typing prod selects it (kind p, expires)" bash -c "awk -F'\t' '\$2==\"prod\" && \$4==\"p\" {f=1} END{exit !f}' '$XDG_STATE_HOME/envs/active.tsv'"
(cd "$PROJ" && "$ENVS" use dev >/dev/null 2>&1)
wait_scr 'prod .*protected' 8
key C-k; key C-k
key Enter
wait_scr 'DATABASE_URL +secret set' 8
key Escape
KDELAY=0.9 key a
check "a asks for a name" wait_scr 'New variable name' 8
tm send-keys -t t "NEW_VAR" Enter; sleep 1.2
tm send-keys -t t "Enter"; sleep 1.5
check "the add flow reaches the hidden value prompt" wait_scr 'Value of NEW_VAR \(hidden\)' 12
tm send-keys -t t "NEWVAL-copy-6" Enter; sleep 0.7
tm send-keys -t t "NEWVAL-copy-6" Enter; sleep 3
check "the new secret is in the dev item and declared" bash -c "[ \"\$(jq -r '.items[]|select(.id==\"e-dev\")|.fields[]|select(.name==\"NEW_VAR\")|.value' '$FAKE_DIR/vault.json')\" = NEWVAL-copy-6 ] && grep -q '^NEW_VAR' '$PROJ/.envs.toml'"
screen_masked >/dev/null
check "no secret was ever on the screen while the list was masked" bash -c "[ ! -s '$T/leaks.log' ]"
tm send-keys -t t Escape; sleep 0.4; tm send-keys -t t Escape; sleep 0.5; tm send-keys -t t Escape; sleep 0.4; tm send-keys -t t Escape; sleep 0.4
tm send-keys -t t Escape; sleep 0.4
wait_scr 'EXIT\[0\]' 8 || { tm send-keys -t t Escape; sleep 0.5; tm send-keys -t t q; wait_scr 'EXIT\[0\]' 6; }
check "Esc at the top level quits with status 0" scr_has 'EXIT\[0\]'
tm kill-server 2>/dev/null
check "the TUI refuses to start under an agent" bash -c "cd '$PROJ' && CLAUDECODE=1 '$ENVS' </dev/null >/dev/null 2>&1; [ \$? = 4 ]"
check "the TUI without a terminal says so" bash -c "cd '$PROJ' && '$ENVS' </dev/null >/dev/null 2>&1; [ \$? = 2 ]"
scan "section 15"

# ───────────── 16 timing (reported; fails only above 150 ms, the bash+jq fakes put the median at about 60 to 65 ms)
section "16 timing"
if command -v hyperfine >/dev/null; then
  reset; bind_proj
  (cd "$PROJ" && hyperfine -N -w3 -r 25 --export-json "$T/hf.json" "true" "$ENVS run -- true" >/dev/null 2>&1)
  base=$(jq -r '.results[0]|(.median // .summary.time_wall_clock.median)*1000' "$T/hf.json"); runm=$(jq -r '.results[1]|(.median // .summary.time_wall_clock.median)*1000' "$T/hf.json")
  printf 'info  envs run -- true: median %.1f ms, true alone %.2f ms (reported; the check below fails above 150 ms; fake rbw is bash+jq)\n' "$runm" "$base"
  check "envs run overhead is below 150 ms" bash -c "awk -v r=$runm 'BEGIN{exit !(r < 150)}'"
else
  echo "info  hyperfine is missing: timing skipped"
fi
fi

}


sections_21() {
# ───────────── 21 BW-ORG C6: a managed user reads Users/<u>/Env and Shared/Env through the vault-share broker
section "21 BW-ORG: managed backend (td) through the broker, owner --for / --shared"
reset
VS="$REPO/infrastructure/tests/vault-share"
VSCR="$T/vs"; rm -rf "$VSCR"; mkdir -p "$VSCR/run" "$VSCR/etc" "$VSCR/rt"; chmod 755 "$VSCR/run" "$VSCR/etc"; chmod 700 "$VSCR/rt"
printf 'td\tShared/**\ntd\tUsers/td/**\nyc\tShared/**\nyc\tUsers/yc/**\n' >"$VSCR/etc/scopes.tsv"; chmod 644 "$VSCR/etc/scopes.tsv"
echo td >"$VSCR/peer"
# the vault: the owner's Env/demo, td's own, the shared one and a yc decoy (invented values)
jq '.folders += [{"id":"f-users","name":"Users"},{"id":"f-utd","name":"Users/td"},{"id":"f-utde","name":"Users/td/Env"},{"id":"f-utdd","name":"Users/td/Env/demo"},
    {"id":"f-uyc","name":"Users/yc"},{"id":"f-uyce","name":"Users/yc/Env"},{"id":"f-uycd","name":"Users/yc/Env/demo"},
    {"id":"f-sh","name":"Shared"},{"id":"f-she","name":"Shared/Env"},{"id":"f-shd","name":"Shared/Env/demo"},{"id":"f-utdg","name":"Users/td/Env/global"},
    {"id":"f-od","name":"Env/demo"}]
  | .items += [
    {"id":"td-dev","type":2,"name":"dev","folderId":"f-utdd","notes":null,"secureNote":{"type":0},"login":null,"fields":[{"name":"DATABASE_URL","value":"SECRET-td-db","type":1},{"name":"TOKEN","value":"SECRET-td-token","type":1}],"attachments":[],"passwordHistory":[],"deletedDate":null},
    {"id":"sh-dev","type":2,"name":"dev","folderId":"f-shd","notes":null,"secureNote":{"type":0},"login":null,"fields":[{"name":"DATABASE_URL","value":"SECRET-shared-db","type":1},{"name":"SHARED_ONLY","value":"SECRET-shared-only","type":1}],"attachments":[],"passwordHistory":[],"deletedDate":null},
    {"id":"yc-dev","type":2,"name":"dev","folderId":"f-uycd","notes":null,"secureNote":{"type":0},"login":null,"fields":[{"name":"DATABASE_URL","value":"SECRET-yc-db","type":1}],"attachments":[],"passwordHistory":[],"deletedDate":null},
    {"id":"ow-dev","type":2,"name":"dev","folderId":"f-od","notes":null,"secureNote":{"type":0},"login":null,"fields":[{"name":"DATABASE_URL","value":"SECRET-owner-demo","type":1}],"attachments":[],"passwordHistory":[],"deletedDate":null},
    {"id":"td-glob","type":2,"name":"default","folderId":"f-utdg","notes":null,"secureNote":{"type":0},"login":null,"fields":[{"name":"GITLAB_TOKEN","value":"SECRET-td-gitlab","type":1}],"attachments":[],"passwordHistory":[],"deletedDate":null}]' \
  "$FAKE_DIR/vault.json" >"$FAKE_DIR/v.tmp" && mv "$FAKE_DIR/v.tmp" "$FAKE_DIR/vault.json"
DEMO="$T/demo"; rm -rf "$DEMO"; mkdir -p "$DEMO"
(cd "$DEMO" && git init -q . && cat >.envs.toml <<'TOML'
project = "demo"
environments = ["dev", "stage", "prod"]
default = "dev"
protected = ["prod"]

[secrets]
DATABASE_URL = ""
TOKEN = ""
SHARED_ONLY = ""
TOML
)
GD2="$T/gdir2"; rm -rf "$GD2"; mkdir -p "$GD2"; chmod 700 "$GD2"; cp "$REPO/.config/envs/global.toml" "$GD2/global.toml"; chmod 644 "$GD2/global.toml"
# the broker: a child process in verified test mode, its rbw is the fake one, td's envs gets a poison rbw
BENV=(env VAULT_SHARE_TEST_DIR="$VS" VAULT_SHARE_SCRATCH="$VSCR" VAULT_SHARE_SOCK="$VSCR/run/sock" VAULT_SHARE_SCOPES="$VSCR/etc/scopes.tsv"
  VAULT_SHARE_RUNTIME="$VSCR/rt" VAULT_SHARE_TEST_PEER_FILE="$VSCR/peer" RBW_BIN="$REPO/infrastructure/tests/vault-browse/bin/rbw")
"${BENV[@]}" python3 -I -B "$REPO/.config/hypr/scripts/vault-share.py" serve 2>"$T/broker.err" &
BROKER=$!
for _ in $(seq 50); do [[ -S $VSCR/run/sock ]] && break; sleep 0.1; done
check "21.0 the broker is up (test mode, fake rbw)" test -S "$VSCR/run/sock"
export VAULT_SHARE_TEST_DIR="$VS" VAULT_SHARE_SCRATCH="$VSCR" VAULT_SHARE_SOCK="$VSCR/run/sock" VAULT_SHARE_SCOPES="$VSCR/etc/scopes.tsv" \
  VAULT_SHARE_RUNTIME="$VSCR/rt-client" VAULT_SHARE_TEST_PEER_FILE="$VSCR/peer"
rm -f "$FAKE_DIR/poison.log"
asTD() { ENVS_TEST_MANAGED_USER=td RBW_BIN="$HERE/bin/rbw-poison" BW_BIN=/nonexistent-bw ENVS_GLOBAL_DIR="$GD2" "$@"; }
EDIR="$DEMO"
(cd "$DEMO" && asTD "$ENVS" bind --yes >/dev/null 2>&1)
N=$((N + 1)); (cd "$DEMO" && asTD "$ENVS" run -- sh -c 'for v in DATABASE_URL TOKEN SHARED_ONLY; do printf "%s=%s\n" "$v" "$(printf %s "${!v}" | sha256sum | cut -c1-64)"; done; echo "names=$ENVS_SECRETS"' >"$CAP/$N.out" 2>"$CAP/$N.err" </dev/null); RC=$?; OUT="$CAP/$N.out"; ERR="$CAP/$N.err"
check "21.1 envs run as td injects its own value (DATABASE_URL, TOKEN) and the shared one (SHARED_ONLY)" bash -c "[ $RC = 0 ] && grep -qx 'DATABASE_URL=$(sha SECRET-td-db)' '$OUT' && grep -qx 'TOKEN=$(sha SECRET-td-token)' '$OUT' && grep -qx 'SHARED_ONLY=$(sha SECRET-shared-only)' '$OUT'" 
check "21.1 ...td's own value wins over the shared one, and nothing of the owner's Env/demo or yc's folder arrives" bash -c "! grep -q '$(sha SECRET-shared-db)\|$(sha SECRET-owner-demo)\|$(sha SECRET-yc-db)' '$OUT'"
check "21.1 ...td's envs never called rbw (the poison rbw was never run)" test ! -e "$FAKE_DIR/poison.log"
check "21.1 ...and the broker's journal has the lines (list, get) without a value or a name" bash -c "grep -q 'op=list user=td' '$T/broker.err' && grep -q 'op=get user=td' '$T/broker.err' && ! grep -q 'SECRET-' '$T/broker.err'"
# 21.2 locked
touch "$FAKE_DIR/rbw-locked"
N=$((N + 1)); (cd "$DEMO" && asTD "$ENVS" run -- true >"$CAP/$N.out" 2>"$CAP/$N.err" </dev/null); RC=$?; OUT="$CAP/$N.out"; ERR="$CAP/$N.err"
check "21.2 a locked vault: exit 3 with the broker's message, no prompt" bash -c "[ $RC = 3 ] && grep -q \"owner's vault is locked\" '$ERR'"
rm -f "$FAKE_DIR/rbw-locked"
# 21.3 writes are refused
for c in "set X --stdin" "unset TOKEN -e dev" "rename TOKEN TOKEN2" "copy dev stage" "env new qa" "project rename other" "import" "convert TOKEN"; do
  N=$((N + 1)); (cd "$DEMO" && asTD "$ENVS" $c >"$CAP/$N.out" 2>"$CAP/$N.err" </dev/null); RC=$?
  check "21.3 '$c' as td: exit 4 and the owner's command is named" bash -c "[ $RC = 4 ] && grep -q 'envs set NAME --for td' '$CAP/$N.err'"
done
# 21.4 the owner writes into td's and the shared folder
EDIR="$DEMO"
epipe 'NEWVAL-for-td' set NEW_FOR_TD -e dev --for td --stdin
check "21.4 owner: set NAME --for td writes into Users/td/Env/demo (no binding needed)" bash -c "[ $RC = 0 ] && [ \"\$(jq -r '.items[]|select(.id==\"td-dev\")|.fields[]|select(.name==\"NEW_FOR_TD\")|.value' '$FAKE_DIR/vault.json')\" = NEWVAL-for-td ]"
check "21.4 ...and the owner's own Env/demo item is untouched" bash -c "[ \"\$(jq -r '.items[]|select(.id==\"ow-dev\")|.fields|length' '$FAKE_DIR/vault.json')\" = 1 ]"
epipe 'NEWVAL-shared' set NEW_SHARED -e stage --shared --stdin
check "21.4 owner: --shared creates the item in Shared/Env/demo" bash -c "[ $RC = 0 ] && jq -e '.folders[]|select(.name==\"Shared/Env/demo\")' '$FAKE_DIR/vault.json' >/dev/null && [ \"\$(jq -r '[.items[]|select(.name==\"stage\" and .folderId==\"f-shd\")|.fields[]|select(.name==\"NEW_SHARED\")|.value]|first' '$FAKE_DIR/vault.json')\" = NEWVAL-shared ]"
(cd "$DEMO" && printf 'x' | "$ENVS" set Y -e dev --for nobody --stdin >/dev/null 2>"$CAP/for.err"); rc=$?
check "21.4 --for with a user that is not an interactive managed user: exit 2" bash -c "[ $rc = 2 ] && grep -q 'not an interactive managed user' '$CAP/for.err'"
(cd "$DEMO" && printf 'x' | "$ENVS" set Y -e dev --for td --shared --stdin >/dev/null 2>&1); rc=$?
check "21.4 --for and --shared together: exit 2" test $rc = 2
e status --for td --json
check "21.4 owner: status --for td reads Users/td/Env/demo (dev has the item, stage has none there)" bash -c "jq -e '.env.dev.item == true and .env.stage.item == false' '$OUT'"
(cd "$DEMO" && asTD "$ENVS" set X --for td --stdin </dev/null >/dev/null 2>&1); rc=$?
check "21.4 a managed user cannot use --for either (exit 4)" test $rc = 4
# 21.5 shadowed names
N=$((N + 1)); (cd "$DEMO" && asTD "$ENVS" check >"$CAP/$N.out" 2>"$CAP/$N.err" </dev/null); RC=$?; OUT="$CAP/$N.out"
check "21.5 check as td reports the name set in both folders (names only)" bash -c "grep -q 'set in both Users/td/Env and Shared/Env' '$OUT' && grep -q 'DATABASE_URL' '$OUT'"
N=$((N + 1)); (cd "$DEMO" && asTD "$ENVS" status --json >"$CAP/$N.out" 2>"$CAP/$N.err" </dev/null); RC=$?; OUT="$CAP/$N.out"
check "21.5 status --json: the shadowed list, vault unlocked, nothing else leaks" bash -c "jq -e '.vault==\"unlocked\" and (.env.dev.shadowed|index(\"DATABASE_URL\")) and (.env.dev.set|index(\"TOKEN\")) and (.env.dev.set|index(\"SHARED_ONLY\"))' '$OUT' >/dev/null"
# 21.6 global scope
N=$((N + 1)); (cd "$T/nowhere" 2>/dev/null || mkdir -p "$T/nowhere"; cd "$T/nowhere" && asTD "$ENVS" run -g --allow-missing -- sh -c 'printf "%s" "$GITLAB_TOKEN" | sha256sum | cut -c1-64' >"$CAP/$N.out" 2>"$CAP/$N.err" </dev/null); RC=$?; OUT="$CAP/$N.out"
check "21.6 run -g as td reads Users/td/Env/global" bash -c "[ $RC = 0 ] && grep -qx $(sha SECRET-td-gitlab) '$OUT'"
check "21.6 ...and still no rbw call by td" test ! -e "$FAKE_DIR/poison.log"
# an agent as td is still refused
N=$((N + 1)); (cd "$DEMO" && CLAUDECODE=1 asTD "$ENVS" run -- true >"$CAP/$N.out" 2>"$CAP/$N.err" </dev/null); RC=$?
check "21.7 envs run is refused for an agent (exit 4) even as a managed user" test $RC = 4
# 21.8 timing
if command -v python3 >/dev/null; then
  t0=$(date +%s%N)
  for _ in 1 2 3 4 5 6 7 8; do (cd "$DEMO" && asTD "$ENVS" run -- true >/dev/null 2>&1 </dev/null); done
  ms=$(( ($(date +%s%N) - t0) / 8000000 ))
  printf 'info  envs run -- true as td through the broker: mean %d ms (reported; fails above 300 ms; fake rbw is bash+jq)\n' "$ms"
  check "21.8 envs run as td is below 300 ms" test "$ms" -lt 300
fi
kill "$BROKER" 2>/dev/null; wait "$BROKER" 2>/dev/null
unset VAULT_SHARE_TEST_DIR VAULT_SHARE_SCRATCH VAULT_SHARE_SOCK VAULT_SHARE_SCOPES VAULT_SHARE_RUNTIME VAULT_SHARE_TEST_PEER_FILE
EDIR=""
scan "21"
}

if [[ -z $ONLY ]]; then sections_1_14; sections_17; sections_18; sections_19; sections_20; sections_21; fi
[[ $ONLY == 19 ]] && sections_19
[[ $ONLY == 20 ]] && sections_20
[[ $ONLY == 21 ]] && sections_21
sections_15_16

printf '\nenvs test: %d passed, %d failed\n' "$PASS" "$FAILS"
exit $((FAILS > 0))
