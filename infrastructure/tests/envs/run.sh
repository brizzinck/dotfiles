#!/usr/bin/env bash
# Test of `envs` (DEV-b) against the FAKE vault of tests/vault-browse/bin (rbw, bw, bw-serve.py, pinentry, wl-copy, notify-send)
# plus fake mise and logger in tests/envs/bin. Never touches the real vault, the real state or the owner's session.
#   infrastructure/tests/envs/run.sh [--quick] [--keep]     --quick skips the tmux TUI and the timing section (doctor runs it)
# After every section: no secret sentinel in any argv log, captured output, notification, state file, journald line or `ps`.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
ENVS="$REPO/.local/bin/envs"
QUICK=0 KEEP=0
for a in "$@"; do case $a in --quick) QUICK=1 ;; --keep) KEEP=1 ;; *) echo "usage: run.sh [--quick] [--keep]" >&2; exit 2 ;; esac; done

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
  (cd "${EDIR:-$PROJ}" && printf '%b' "$input" | script -qec "$(printf '%q ' "$ENVS" "$@")" /dev/null >"$CAP/$N.out" 2>"$CAP/$N.err"); RC=$?
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
ps -eo args >"$CAP/ps-run.txt"
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

printf '\nenvs test: %d passed, %d failed\n' "$PASS" "$FAILS"
exit $((FAILS > 0))
