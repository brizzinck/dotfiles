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
# shellcheck source=env.sh
. "$HERE/env.sh" >/dev/null || exit 1
T=${ENVS_TEST_ROOT:?}
CAP="$T/cap"; mkdir -p "$CAP"
PROJ="$T/proj"
PASS=0 FAILS=0 N=0
SECRETS=(SECRET-billing-dev-db SECRET-billing-dev-stripe SECRET-billing-dev-extra SECRET-billing-stage-db SECRET-billing-prod-db
  SECRET-billing-prod-stripe SECRET-other-dev-db SECRET-other-dev-stripe SECRET-work-login master-pw)
# values the tests write themselves (they must never show up either)
SECRETS+=(NEWVAL-set-1 NEWVAL-set-2 NEWVAL-all-3 NEWVAL-import-4 NEWVAL-import-5 NEWVAL-copy-6)
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
  rm -f "$FAKE_DIR"/{argv.log,rbw-view.json,rbw-locked,bw-unlocked,seq,notify.log,logger.log,mise.log,clip.txt,clip.args,clip.events,last-*}
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
check "TomlText line editor keeps comments and order, quoted keys are refused" python3 -I "$HERE/edit_test.py" "$ENVS"
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
check "dotenv parser: quotes, export, multi-line, inline comments, \${VAR}, bad lines reported without content" python3 -I "$HERE/dotenv_test.py" "$ENVS"

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

# ───────────── 16 timing (report; fails only above 150 ms)
section "16 timing"
if command -v hyperfine >/dev/null; then
  reset; bind_proj
  (cd "$PROJ" && hyperfine -N -w3 -r 25 --export-json "$T/hf.json" "true" "$ENVS run -- true" >/dev/null 2>&1)
  base=$(jq -r '.results[0]|(.median // .summary.time_wall_clock.median)*1000' "$T/hf.json"); runm=$(jq -r '.results[1]|(.median // .summary.time_wall_clock.median)*1000' "$T/hf.json")
  printf 'info  envs run -- true: median %.1f ms, true alone %.2f ms (gate: overhead <= 60 ms; fake rbw is bash+jq)\n' "$runm" "$base"
  check "envs run overhead is below 150 ms" bash -c "awk -v r=$runm 'BEGIN{exit !(r < 150)}'"
else
  echo "info  hyperfine is missing: timing skipped"
fi
fi

}

if [[ -z $ONLY ]]; then sections_1_14; fi
sections_15_16

printf '\nenvs test: %d passed, %d failed\n' "$PASS" "$FAILS"
exit $((FAILS > 0))
