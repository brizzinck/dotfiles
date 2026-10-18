#!/usr/bin/env bash
# Test of the dev launchers (DEV-d): db, api, ci, forge, `envs run -g` as the launchers use it, and the shared theme/render checks.
# Everything runs against the FAKE vault (tests/vault-browse/bin rbw/bw), fake tools of tests/dev/bin (lazysql, posting, hurl, act,
# gitlab-ci-local, gh-dash, glab-tui, glab, gh, docker, hyprctl, ssh) and fake fzf-menu / ghostty / notify-send / wl-copy:
# WAYLAND_DISPLAY, DISPLAY and HYPRLAND_INSTANCE_SIGNATURE are unset, so no test can open a window or notify on the owner's
# session. Never touches the real vault, state or docker (the docker fake answers from a JSON file).
#   infrastructure/tests/dev/run.sh [--quick] [--keep] [--only=N]      --quick skips the private-tmux menu sections (doctor runs it)
# After every section: no secret sentinel in any fake's log, captured output, the repo dir, the state dir, finished run dirs, or
# a `ps` snapshot taken while a fake sleeps.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
ENVS="$REPO/.local/bin/envs" DB="$REPO/.local/bin/db"
QUICK=0 KEEP=0 ONLY=""
for a in "$@"; do case $a in --quick) QUICK=1 ;; --keep) KEEP=1 ;; --only=*) ONLY=${a#--only=} ;; *) echo "usage: run.sh [--quick] [--keep] [--only=N]" >&2; exit 2 ;; esac; done

ENVS_TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dev-test.XXXXXX")
export ENVS_TEST_ROOT
# shellcheck source=../envs/env.sh
. "$HERE/../envs/env.sh" >/dev/null || exit 1
unset WAYLAND_DISPLAY DISPLAY HYPRLAND_INSTANCE_SIGNATURE CLAUDECODE
export DEVTOOLS_NO_LAYOUT=1
export ENVS_TOOL_PATH="$HERE/bin:$HERE/bin-menu:$ENVS_TOOL_PATH"
export PATH="$HERE/bin:$HERE/bin-menu:$PATH"
T=${ENVS_TEST_ROOT:?}
printf '%s' "$FAKE_DIR" >"$XDG_RUNTIME_DIR/devtools-fake-dir"   # for fakes whose launcher scrubs the environment (posting)
CAP="$T/cap"; mkdir -p "$CAP"
PROJ="$T/proj"
PASS=0 FAILS=0 N=0
SECRETS=(SECRET-db-pass-dev SECRET-url-pw SECRET-url-query SECRET-api-token SECRET-npm-token SECRET-user "SECRET-p@ss:w/rd#?%"
  "SECRET-p%40ss%3Aw%2Frd%23%3F%25" SECRET-db-pass-prod SECRET-gitlab-token SECRET-gitlab-host SECRET-gh-token SECRET-openai-env
  SECRET-api-token-stage SECRET-api-token-prod SECRET-global-td-pw)
export OPENAI_API_KEY=SECRET-openai-env
SOCK="devtest-$$"

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
  [[ -n ${HTTP_PID:-} ]] && kill "$HTTP_PID" 2>/dev/null
  if ((KEEP)); then echo "kept: $T"; else rm -rf "${T:?}"; fi
}
trap cleanup EXIT

ok() { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
bad() { FAILS=$((FAILS + 1)); printf 'FAIL  %s\n' "$1"; [[ -n ${2:-} ]] && printf '      %s\n' "$2"; return 0; }
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
sha() { printf %s "$1" | sha256sum | cut -c1-16; }
section() { printf '\n== %s\n' "$1"; }
devlog() { cat "${FAKE_DIR:?}/dev.log" 2>/dev/null; }

# fresh vault, state, logs and project (a git repo with .envs.toml, bound to Env/devproj)
reset() {
  stop_bw
  rm -rf "${XDG_STATE_HOME:?}"/* "${XDG_RUNTIME_DIR:?}/envs" "${XDG_RUNTIME_DIR:?}/devtools" "${XDG_RUNTIME_DIR:?}"/vault/* "${CAP:?}"/* "${PROJ:?}"
  cp "$HERE/fixtures/vault.json" "${FAKE_DIR:?}/vault.json"
  sed "s|@ROOT@|$PROJ|g" "$HERE/fixtures/docker.json" >"${FAKE_DIR:?}/docker.json"
  local f
  for f in argv.log rbw-view.json rbw-locked bw-unlocked seq notify.log logger.log mise.log clip.txt clip.args clip.events clip.last dev.log \
      lazysql.config menu.in; do rm -f "${FAKE_DIR:?}/$f"; done
  mkdir -p "$PROJ" "$XDG_STATE_HOME/theme"
  rm -rf "${ENVS_GLOBAL_DIR:?}"; mkdir -p -m 700 "$ENVS_GLOBAL_DIR"
  cp "$REPO/.config/envs/global.toml" "$ENVS_GLOBAL_DIR/global.toml"; chmod 644 "$ENVS_GLOBAL_DIR/global.toml"
  (cd "$PROJ" && git init -q . && cat >.envs.toml <<'TOML'
project = "devproj"
environments = ["dev", "stage", "prod"]
default = "dev"
protected = ["prod"]

[secrets]
DB_PASSWORD = "MariaDB password of the app user"
DB_USER = "database user"
DB_URL = "whole URL of the reporting database"
API_TOKEN = ""
NPM_TOKEN = ""

[db.main]
driver = "mariadb"
docker = "mariadb"
database = "app"
user = "app"
password = "DB_PASSWORD"

[db.pg]
driver = "postgres"
host = "127.0.0.1"
port = 5432
database = "appdb"
user = "svc"
password = "DB_PASSWORD"
envs = ["dev", "stage"]

[db.full]
driver = "postgres"
url = "DB_URL"

[db.lite]
driver = "sqlite"
path = "var/app.sqlite"
TOML
  mkdir -p var && : >var/app.sqlite
  git add -A >/dev/null 2>&1 && git commit -qm init >/dev/null 2>&1)
  (cd "$PROJ" && "$ENVS" bind --yes >/dev/null 2>&1)
}

RC=0 OUT="" ERR=""
d() { # args: run `db` in the project (EDIR overrides); output in $CAP, status in RC
  N=$((N + 1))
  (cd "${EDIR:-$PROJ}" && "$DB" "$@" >"$CAP/$N.out" 2>"$CAP/$N.err" </dev/null); RC=$?
  OUT="$CAP/$N.out" ERR="$CAP/$N.err"
}
dtty() { # INPUT args: through a pty
  local input=$1; shift
  N=$((N + 1))
  (cd "${EDIR:-$PROJ}" && printf '%b' "$input" | script -qec "$(printf '%q ' "$DB" "$@")" /dev/null >"$CAP/$N.out" 2>"$CAP/$N.err"); RC=$?
  OUT="$CAP/$N.out" ERR="$CAP/$N.err"
}

scan() { # label: no sentinel in any place a leak could go
  local label=$1 s hit="" f
  local files=("$CAP"/* "$FAKE_DIR/dev.log" "$FAKE_DIR/argv.log" "$FAKE_DIR/notify.log" "$FAKE_DIR/logger.log" "$FAKE_DIR/lazysql.config"
    "$FAKE_DIR/menu.in" "$XDG_STATE_HOME"/envs/* "$XDG_RUNTIME_DIR"/envs/*)
  while IFS= read -r f; do files+=("$f"); done < <(find "$PROJ" "$XDG_RUNTIME_DIR/devtools" -type f ! -path '*/.git/*' 2>/dev/null)
  for s in "${SECRETS[@]}"; do
    for f in "${files[@]}"; do
      [[ -f $f ]] && grep -aqF -- "$s" "$f" && hit="$hit $s@$(basename "$f")"
    done
  done
  if [[ -z $hit ]]; then ok "no secret in any log, output, repo file, state or run dir ($label)"; else bad "SECRET LEAK ($label)" "$hit"; fi
}
ps_has() { ps -eo args | grep -aF -- "$1" | grep -qv "grep -aF"; }

# set_db SNIPPET: replace the [db.*] part of the project's .envs.toml by SNIPPET (the head with [secrets] is kept)
set_db() {
  python3 - "$PROJ/.envs.toml" "$1" <<'PY'
import sys
p, extra = sys.argv[1], sys.argv[2]
t = open(p).read()
head = t.split("\n[db.", 1)[0].rstrip("\n") + "\n"
open(p, "w").write(head + "\n" + extra + "\n")
PY
}

sections_1() {
section "1 [db.*] validation"
reset
d check
check "1: the fixture project validates" bash -c "[ $RC = 0 ]"
d list
check "1: db list shows the connections without any vault or docker access" bash -c "[ $RC = 0 ] && grep -q '^main ' '$OUT' && grep -q 'docker:mariadb' '$OUT' && grep -q '^lite' '$OUT' && [ ! -e '$FAKE_DIR/argv.log' ] && ! grep -q '^docker' '$FAKE_DIR/dev.log'"
d list --json
check "1: db list --json holds names only (secret NAMES, no value)" bash -c "jq -e '(.[]|select(.name==\"main\").secrets==[\"DB_PASSWORD\"])' '$OUT'"
bad_case() { # label snippet expected-substring
  set_db "$2"
  d check
  check "1: $1" bash -c "[ $RC = 1 ] && grep -qF -- '$3' '$OUT' '$ERR'"
}
bad_case "unknown driver" $'[db.x]\ndriver = "oracle"\nhost = "h"' "driver must be one of"
bad_case "no location" $'[db.x]\ndriver = "mysql"\ndatabase = "a"' "exactly one of docker"
bad_case "two locations" $'[db.x]\ndriver = "mysql"\nhost = "h"\ndocker = "svc"' "exactly one of docker"
bad_case "literal password refused (not a declared name)" $'[db.x]\ndriver = "mysql"\nhost = "h"\npassword = "hunter2"' "password must name a secret declared in [secrets]"
bad_case "password naming an undeclared secret" $'[db.x]\ndriver = "mysql"\nhost = "h"\npassword = "NOT_DECLARED"' "password must name a secret declared"
bad_case "url naming an undeclared secret" $'[db.x]\ndriver = "postgres"\nurl = "NOPE"' "url must name a secret declared"
bad_case "host injection (; and space)" $'[db.x]\ndriver = "mysql"\nhost = "h; touch /tmp/x"' "host must be a host name"
bad_case "host injection (newline)" $'[db.x]\ndriver = "mysql"\nhost = "h\\nx"' "host must be a host name"
bad_case "port out of range" $'[db.x]\ndriver = "mysql"\nhost = "h"\nport = 70000' "port must be a number from 1 to 65535"
bad_case "port as a string" $'[db.x]\ndriver = "mysql"\nhost = "h"\nport = "3306"' "port must be a number"
bad_case "database with a quote" $'[db.x]\ndriver = "mysql"\nhost = "h"\ndatabase = "a\\"b"' "database must match"
bad_case "user with a space" $'[db.x]\ndriver = "mysql"\nhost = "h"\nuser = "a b"' "user must match"
bad_case "tunnel injection" $'[db.x]\ndriver = "mysql"\nhost = "h"\ntunnel = "b -o ProxyCommand=x"' "tunnel must match"
bad_case "tunnel without host" $'[db.x]\ndriver = "mysql"\ndocker = "svc"\ntunnel = "bastion"' "tunnel needs"
bad_case "docker name injection" $'[db.x]\ndriver = "mysql"\ncontainer = "a;b"' "container must match"
bad_case "sqlite path escaping the root" $'[db.x]\ndriver = "sqlite"\npath = "../outside.db"' "path leaves the project root"
bad_case "sqlite absolute path" $'[db.x]\ndriver = "sqlite"\npath = "/etc/passwd"' "path must be relative"
bad_case "connection name with a slash" $'[db."a/b"]\ndriver = "mysql"\nhost = "h"' "connection name must match"
bad_case "unknown key" $'[db.x]\ndriver = "mysql"\nhost = "h"\nshell = "sh"' "unknown key"
bad_case "envs naming a missing environment" $'[db.x]\ndriver = "mysql"\nhost = "h"\nenvs = ["qa"]' "which is not an environment of this project"
bad_case "url together with parts" $'[db.x]\ndriver = "postgres"\nurl = "DB_URL"\nuser = "a"' "the parts (user, password, database)"
bad_case "read_only as a string" $'[db.x]\ndriver = "mysql"\nhost = "h"\nread_only = "yes"' "read_only must be true or false"
mkdir -p "$PROJ/var"; ln -sfn /etc "$PROJ/var/link"
set_db $'[db.x]\ndriver = "sqlite"\npath = "var/link/passwd"'
d check
check "1: a sqlite path through a symlink that leaves the root is refused" bash -c "[ $RC = 1 ] && grep -q 'path leaves the project root' '$OUT'"
set_db $'[db.ok]\ndriver = "mysql"\nhost = "::1"\nport = 3306\nuser = "u"\npassword = "DB_PASSWORD"\ndatabase = "d"'
d check
check "1: an IPv6 literal host is fine" test $RC = 0
d check --all
check "1: db check --all covers the bound projects and the global scope" bash -c "[ $RC = 0 ] && grep -q 'global' '$OUT' && grep -q devproj '$OUT'"
scan "section 1"
}

sections_2_3() {
section "2+3 URL building and docker resolution (functions of db, fake docker)"
reset
if out=$(python3 -I -B "$HERE/urltest.py" "$DB" "$PROJ" 2>&1); then ok "2+3: urltest.py ($(grep -c '^ok' <<<"$out") cases)"; else bad "2+3: urltest.py" "$(grep -m3 '^FAIL' <<<"$out")"; fi
printf '%s\n' "$out" | grep -E '^(ok|FAIL)' | sed -n 's/^FAIL/FAIL/p' | head -5
# end to end: a container whose published port is ClickHouse's HTTP port (ch-ui) is refused with an explanation
python3 -I -B "$HERE/pingserver.py" "$T/ping.port" & HTTP_PID=$!
for _ in $(seq 50); do [[ -s $T/ping.port ]] && break; sleep 0.1; done
python3 - "$FAKE_DIR/docker.json" "$(cat "$T/ping.port")" <<'PY'
import json, sys
p, port = sys.argv[1], sys.argv[2]
d = json.load(open(p)); d["ports"]["td-clickhouse:9000"] = "127.0.0.1:" + port; json.dump(d, open(p, "w"))
PY
set_db $'[db.ch]\ndriver = "clickhouse"\ncontainer = "td-clickhouse"\ndatabase = "default"\nuser = "default"\npassword = "DB_PASSWORD"'
d open ch
check "3: db open on a ClickHouse HTTP port: exit 1, says native protocol / HTTP / ch-ui, lazysql never started" bash -c "[ $RC = 1 ] && grep -q 'native protocol' '$ERR' && grep -q 'HTTP port' '$ERR' && ! grep -q '^lazysql' '$FAKE_DIR/dev.log'"
d open nosuch
check "3: db open of an unknown connection names the known ones" bash -c "[ $RC = 1 ] && grep -q 'no connection' '$ERR'"
check "3: only read-only docker queries were made (ps, port): no start, run, compose, exec, inspect of Env" bash -c "! grep -E '^docker (start|run|stop|rm|compose|exec|create|kill|restart|inspect)' '$FAKE_DIR/dev.log' && grep -q '^docker ps' '$FAKE_DIR/dev.log'"
check "3: docker ps asks for explicit label fields (never .Config.Env)" bash -c "! grep -q 'Config.Env' '$FAKE_DIR/dev.log' && ! grep -q INSPECT-ENV '$FAKE_DIR/dev.log'"
kill "$HTTP_PID" 2>/dev/null; HTTP_PID=""
scan "section 2+3"
}

sections_4() {
section "4 db open end to end (real envs run, fake vault, fake lazysql)"
reset
mkdir -p "$XDG_STATE_HOME/theme/current"; cp "$REPO/themes/generated/black/lazysql.toml" "$XDG_STATE_HOME/theme/current/lazysql.toml"
mkdir -p "$XDG_RUNTIME_DIR/devtools/db-99999999/x"; : >"$XDG_RUNTIME_DIR/devtools/db-99999999/config.toml"
d open main
CFG="$FAKE_DIR/lazysql.config"
RUNDIR=$(sed -n 's/^lazysql config-mode=[0-9]* dir-mode=[0-9]* dir=//p' "$FAKE_DIR/dev.log" | tail -1)
check "4: db open main exits 0 and starts lazysql with -config PATH --no-telemetry only" bash -c "[ $RC = 0 ] && grep -qE '^lazysql -config $XDG_RUNTIME_DIR/devtools/db-[0-9]+/config.toml --no-telemetry\$' '$FAKE_DIR/dev.log'"
check "4: the config holds the placeholder URL, the printf command and no secret" bash -c "grep -qF 'URL = \"mysql://app:\${pw}@127.0.0.1:32768/app\"' '$CFG' && grep -qF 'printf %s \\\"\$DB_PW\\\"' '$CFG' && grep -q 'Provider = \"mysql\"' '$CFG'"
check "4: ephemeral port 32768 came from docker port, not from a file" grep -q '^docker port devproj-mariadb-1 3306/tcp' "$FAKE_DIR/dev.log"
check "4: config file 0600, run dir 0700, cwd of lazysql = the run dir (no repo .lazysql.toml can load)" bash -c "grep -q 'config-mode=600 dir-mode=700' '$FAKE_DIR/dev.log' && grep -q \"^lazysql cwd=$RUNDIR\$\" '$FAKE_DIR/dev.log'"
check "4: DB_PW is the percent-encoded password (hash compared, value never written)" grep -q "DB_PW=$(sha SECRET-db-pass-dev) " "$FAKE_DIR/dev.log"
check "4: lazysql's environment holds DB_PW but none of the declared secret names" bash -c "n=\$(grep '^lazysql names' '$FAKE_DIR/dev.log'); grep -qw DB_PW <<<\"\$n\" && ! grep -qwE 'DB_PASSWORD|DB_URL|DB_USER|API_TOKEN|NPM_TOKEN' <<<\"\$n\""
check "4: telemetry, update check and tracking are switched off, SQL_EDITOR is nvim" grep -q 'telemetry=1 update=1 dnt=1 sql_editor=nvim' "$FAKE_DIR/dev.log"
check "4: the theme block of the active variant is appended" grep -q '^\[theme.Colors\]' "$CFG"
check "4: run dirs of dead pids are removed at start" bash -c "[ ! -e '$XDG_RUNTIME_DIR/devtools/db-99999999' ]"
scan "4 main"

d open main -e stage
check "4: stage password with every URL-significant character: DB_PW is its percent-encoding" grep -q "DB_PW=$(sha "$(python3 -c 'import urllib.parse as u; print(u.quote("SECRET-p@ss:w/rd#?%", safe=""), end="")')") " "$FAKE_DIR/dev.log"
d open pg -e prod
check "4: a connection whose envs list lacks the environment is refused (exit 1)" bash -c "[ $RC = 1 ] && grep -q 'not in prod' '$ERR'"
d open main -e prod
check "4: protected env without --prod and without a terminal: envs refuses (exit 4)" test $RC = 4
: >"$FAKE_DIR/dev.log"
d open main -e prod --prod
check "4: --prod opens it READ-ONLY (protected environments default to ro)" bash -c "[ $RC = 0 ] && grep -q 'ReadOnly = true' '$FAKE_DIR/lazysql.config'"
d open main -e prod --prod --rw
check "4: --rw needs a typed rw on a terminal: without one nothing opens (exit 4)" test $RC = 4
d open main --ro
check "4: --ro forces read-only in dev" grep -q 'ReadOnly = true' "$FAKE_DIR/lazysql.config"
d open main
check "4: dev default is writable" grep -q 'ReadOnly = false' "$FAKE_DIR/lazysql.config"
d open full
check "4: a url secret: template with the pw and q placeholders, DB_PW and DB_QUERY hashes match, no secret in the config" bash -c "grep -qF 'URL = \"postgres://svc:\${pw}@dbhost:5432/appdb?\${q}\"' '$FAKE_DIR/lazysql.config' && grep -q \"DB_PW=$(sha SECRET-url-pw) \" '$FAKE_DIR/dev.log' && grep -q \"DB_QUERY=$(sha 'sslmode=require&application_name=SECRET-url-query')\" '$FAKE_DIR/dev.log'"
: >"$FAKE_DIR/argv.log"; : >"$FAKE_DIR/dev.log"
d open lite
check "4: sqlite needs no secret: no rbw call, URL = the absolute path inside the project" bash -c "[ $RC = 0 ] && ! grep -q '^rbw' '$FAKE_DIR/argv.log' && grep -qF 'URL = \"$PROJ/var/app.sqlite\"' '$FAKE_DIR/lazysql.config' && grep -q 'Provider = \"sqlite3\"' '$FAKE_DIR/lazysql.config'"
# a missing secret: DB_PASSWORD gone from dev
jq '(.items[]|select(.id=="d-dev").fields) |= map(select(.name != "DB_PASSWORD"))' "$FAKE_DIR/vault.json" >"$T/v.json" && mv "$T/v.json" "$FAKE_DIR/vault.json"
rm -f "$FAKE_DIR/rbw-view.json"
d open main
check "4: a secret that is not set in the environment: message with the envs set command, exit 1" bash -c "[ $RC = 1 ] && grep -q 'envs set DB_PASSWORD' '$ERR'"
cp "$HERE/fixtures/vault.json" "$FAKE_DIR/vault.json"; rm -f "$FAKE_DIR/rbw-view.json"
# ps snapshot while lazysql lives
(cd "$PROJ" && FAKE_SLEEP=3 "$DB" open main >"$CAP/ps.out" 2>"$CAP/ps.err" </dev/null) & BGPID=$!
LZLINE=""
for _ in $(seq 50); do
  LZLINE=$(ps -eo args | grep -aE 'lazysql -config [^ ]+ --no-telemetry$' | grep -v 'grep' | head -1)
  [[ -n $LZLINE ]] && break
  sleep 0.1
done
hit=""; for s in "${SECRETS[@]}"; do ps_has "$s" && hit="$hit $s"; done
check "4: while lazysql runs no secret is in any process's argv (ps -eo args)" test -z "$hit"
check "4: ... and the lazysql process itself shows only -config and --no-telemetry" test -n "$LZLINE"
wait "$BGPID" 2>/dev/null
scan "4"
}

sections_5() {
section "5 agents get names only"
reset
CLAUDECODE=1 d open main
check "5: CLAUDECODE=1: db open is refused (exit 4) and lazysql never starts" bash -c "[ $RC = 4 ] && ! grep -q '^lazysql' '$FAKE_DIR/dev.log'"
CLAUDECODE=1 d open lite
check "5: ... also for a connection without secrets" test $RC = 4
CLAUDECODE=1 d cli main
check "5: db cli is refused for an agent" test $RC = 4
CLAUDECODE=1 d
check "5: the menu is refused for an agent" test $RC = 4
CLAUDECODE=1 d list
check "5: db list still works for an agent" test $RC = 0
CLAUDECODE=1 d check
check "5: db check still works for an agent" test $RC = 0
cp /bin/sh "$T/claude"
(cd "$PROJ" && "$T/claude" -c "\"$DB\" open main; exit \$?" >"$CAP/ag.out" 2>"$CAP/ag.err"); rc=$?
check "5: an ancestor process named claude is refused as well" test $rc = 4
scan "5"
}

sections_6() {
section "6 docker autodiscovery rows and db cli"
reset
set_db $'[db.main]\ndriver = "mariadb"\ndocker = "mariadb"\ndatabase = "app"\nuser = "app"\npassword = "DB_PASSWORD"\n\n[db.pgd]\ndriver = "postgres"\ndocker = "pg"\ndatabase = "appdb"\nuser = "svc"\npassword = "DB_PASSWORD"'
d
M="$FAKE_DIR/menu.in"
check "6: the menu lists configured connections with their resolved docker port / state" bash -c "grep -q 'main  *mariadb .*docker:mariadb -> 127.0.0.1:32768' '$M' && grep -q 'pgd  *postgres .*docker:pg -> stopped' '$M'"
check "6: running DB containers without a configuration are rows too (td-clickhouse, other-mariadb-1); nginx is not" bash -c "grep -q 'td-clickhouse' '$M' && grep -q 'other-mariadb-1' '$M' && ! grep -q nginx '$M' && ! grep -q 'devproj-mariadb-1' '$M'"
check "6: the menu opens through fzf-menu with NORMAL keys in FZF_MENU_NORMAL_BINDS-style --expect for Alt keys" bash -c "grep -q 'fzf-menu .*--expect=alt-r,alt-e,alt-c,alt-a' '$FAKE_DIR/dev.log'"
check "6: the menu needs no vault" bash -c "[ ! -s '$FAKE_DIR/argv.log' ] || ! grep -q '^rbw' '$FAKE_DIR/argv.log'"
ID=$(awk -F'\t' '/^d:/ {print $1; exit}' "$M")
d _preview "$ID"
check "6: the preview of a docker row says no configuration and never shows a password" bash -c "grep -q 'no configuration' '$OUT'"
ID=$(awk -F'\t' '/^c:/ {print $1; exit}' "$M")
d _preview "$ID"
check "6: the preview of a connection lists fields and secret NAMES, the run command, no value" bash -c "grep -q 'password .*secret DB_PASSWORD' '$OUT' && grep -q 'envs run -e dev' '$OUT' && ! grep -q SECRET '$OUT'"
: >"$FAKE_DIR/dev.log"
d cli main
check "6: db cli main -> docker exec -it <container> sh -c <script>; the script reads MARIADB_ROOT_PASSWORD INSIDE the container, no value in argv" bash -c "grep -q '^docker exec -it devproj-mariadb-1 sh -c ' '$FAKE_DIR/dev.log' && grep -qF 'MARIADB_ROOT_PASSWORD' '$FAKE_DIR/dev.log' && grep -qF 'exec mariadb -uroot' '$FAKE_DIR/dev.log'"
d cli docker:td-clickhouse
check "6: an autodiscovered ClickHouse container gets clickhouse-client (password via the prompt, never argv)" bash -c "grep -q '^docker exec -it td-clickhouse sh -c .*clickhouse-client' '$FAKE_DIR/dev.log' && grep -qF -- '--ask-password' '$FAKE_DIR/dev.log'"
d cli docker:other-mariadb-1
check "6: an autodiscovered MariaDB container gets the mariadb client" grep -q '^docker exec -it other-mariadb-1 sh -c ' "$FAKE_DIR/dev.log"
d cli docker:plain-nginx
check "6: a non-database container is refused" test $RC = 1
d cli pgd
check "6: a stopped container has no client (exit 1)" test $RC = 1
d cli lite
check "6: db cli needs a docker / container connection" test $RC = 1
check "6: no vault access for any cli call" bash -c "[ ! -s '$FAKE_DIR/argv.log' ] || ! grep -q '^rbw' '$FAKE_DIR/argv.log'"
scan "6"
}

sections_11_12() {
section "11 keyboard layout switch, 12 render check"
reset
: >"$FAKE_DIR/dev.log"
HYPRLAND_INSTANCE_SIGNATURE=test DEVTOOLS_NO_LAYOUT=0 d open lite
check "11: starting the TUI switches the keyboard to us (hyprctl switchxkblayout all 0) exactly once" bash -c "[ \$(grep -c '^hyprctl switchxkblayout all 0\$' '$FAKE_DIR/dev.log') = 1 ]"
: >"$FAKE_DIR/dev.log"
HYPRLAND_INSTANCE_SIGNATURE=test DEVTOOLS_NO_LAYOUT=1 d open lite
check "11: DEVTOOLS_NO_LAYOUT=1 skips it" bash -c "! grep -q '^hyprctl' '$FAKE_DIR/dev.log'"
: >"$FAKE_DIR/dev.log"
d open lite
check "11: without a Hyprland instance nothing is called" bash -c "! grep -q '^hyprctl' '$FAKE_DIR/dev.log'"
if PYTHONPYCACHEPREFIX=/tmp/pycache python3 -B "$REPO/themes/palette/render.py" --check >"$CAP/render.out" 2>&1; then ok "12: render.py --check is clean"; else bad "12: render.py --check" "$(head -3 "$CAP/render.out")"; fi
check "12: the four new outputs exist for both variants" bash -c "for v in black night; do for f in lazysql.toml posting.yaml gh-dash-theme.yml glab-tui.toml; do [ -s '$REPO/themes/generated/'\$v/\$f ] || exit 1; done; done"
check "12: the generated lazysql theme parses and uses only documented keys" python3 -I -B -c "
import tomllib,sys
d=tomllib.load(open('$REPO/themes/generated/black/lazysql.toml','rb'))
keys={'PrimitiveBackground','ContrastBackground','MoreContrastBackground','Border','Title','Graphics','PrimaryText','SecondaryText','TertiaryText','InverseText','ContrastSecondaryText','SidebarTitleBorder','Error','ReadOnly','TableChange','TableInsert','TableDelete','TableMarked','EditorSelection','EditorStatusBarBackground','EditorStatusBarText','AutocompleteBackground','AutocompleteText','AutocompleteSelected','AutocompleteDescription','AutocompleteSeparator','SQLKeyword','SQLString','SQLNumber','SQLComment','SQLFunction','SQLOperator','SQLType','SQLBoolean','SQLParameter','JSONKey','JSONString','JSONBoolean','JSONNull','JSONNumber'}
sys.exit(0 if set(d['theme']['Colors'])<=keys else 1)"
}

sections_7() {
section "7 global connections (global.local.toml), db add"
reset
printf '[secrets]\nTD_PW = "password of the td ClickHouse"\n\n[db.td]\ndriver = "clickhouse"\ncontainer = "td-clickhouse"\nuser = "default"\npassword = "TD_PW"\n\n[db.tdnopw]\ndriver = "clickhouse"\ncontainer = "td-clickhouse"\nuser = "default"\n' >"$ENVS_GLOBAL_DIR/global.local.toml"
chmod 600 "$ENVS_GLOBAL_DIR/global.local.toml"
EDIR="$T"
d list --global
check "7: db list --global shows the global connections" bash -c "[ $RC = 0 ] && grep -q '^td ' '$OUT' && grep -q 'global' '$OUT'"
d open td -g
check "7: a global connection with a secret: envs run -g, DB_PW hash matches, native port 19000 from docker port" bash -c "[ $RC = 0 ] && grep -q \"DB_PW=$(sha SECRET-global-td-pw) \" '$FAKE_DIR/dev.log' && grep -qF 'URL = \"clickhouse://default:\${pw}@127.0.0.1:19000/\"' '$FAKE_DIR/lazysql.config'"
: >"$FAKE_DIR/argv.log"
d open tdnopw -g
check "7: a global connection without a secret needs no vault" bash -c "[ $RC = 0 ] && ! grep -q '^rbw' '$FAKE_DIR/argv.log' && grep -qF 'URL = \"clickhouse://default@127.0.0.1:19000/\"' '$FAKE_DIR/lazysql.config'"
EDIR="$PROJ"
d open td
check "7: from inside a project the global connection is found by name too (project first)" test $RC = 0
chmod 666 "$ENVS_GLOBAL_DIR/global.local.toml"
EDIR="$T" d open td -g
check "7: a group/other-writable global.local.toml is refused (exit 4)" test $RC = 4
chmod 600 "$ENVS_GLOBAL_DIR/global.local.toml"
EDIR="$PROJ"
# db add (flags, no terminal)
d add pgnew --driver postgres --host 127.0.0.1 --port 5433 --database shop --user shopuser --password-secret SHOP_PW --envs dev,stage --read-only
check "7: db add writes [db.pgnew] and declares the new secret name (no value)" bash -c "[ $RC = 0 ] && grep -q '^\\[db.pgnew\\]' '$PROJ/.envs.toml' && grep -q '^SHOP_PW = ' '$PROJ/.envs.toml' && grep -q 'envs set SHOP_PW' '$OUT'"
d check
check "7: ... and the file still validates; the line editor kept the earlier tables" bash -c "[ $RC = 0 ] && grep -q '^\\[db.main\\]' '$PROJ/.envs.toml' && grep -q 'read_only = true' '$PROJ/.envs.toml'"
d add pgnew --driver postgres --host h
check "7: db add of an existing name is refused" test $RC = 1
d add bad --driver postgres --host 'h;x' --password-secret DB_PASSWORD
check "7: db add validates like db check (host injection refused, nothing written)" bash -c "[ $RC = 2 ] && ! grep -q '^\\[db.bad\\]' '$PROJ/.envs.toml'"
d add gl --global --driver mysql --host db.internal --user ro --password-secret GL_PW
check "7: db add --global declares in global.local.toml (0600), never in the dotfiles global.toml" bash -c "[ $RC = 0 ] && grep -q '^\\[db.gl\\]' '$ENVS_GLOBAL_DIR/global.local.toml' && ! grep -q GL_PW '$ENVS_GLOBAL_DIR/global.toml' && [ \$(stat -c %a '$ENVS_GLOBAL_DIR/global.local.toml') = 600 ]"
CLAUDECODE=1 d add agentconn --driver mysql --host h
check "7: an agent cannot add a connection" test $RC = 4
scan "7"
}

sections_8() {
section "8 api: posting with a scrubbed environment, hurl with HURL_SECRET"
reset
mkdir -p "$PROJ/api/env" "$PROJ/api/tests"
printf 'BASE_URL=http://localhost:8080\nPLAIN_ONE="two words"\n' >"$PROJ/api/env/base.env"
printf '# dev vars\nBASE_URL=http://localhost:9090\nAPI_TOKEN=${API_TOKEN}\nEXTRA=${SOMETHING}\n' >"$PROJ/api/env/dev.env"
printf 'GET {{BASE_URL}}/h\nHTTP 200\n' >"$PROJ/api/tests/health.hurl"; mkdir -p "$PROJ/api/tests/sub"; : >"$PROJ/api/tests/sub/b.hurl"
cat >>"$PROJ/.envs.toml" <<'TOML'

[api]
collection = "api"
env_dir = "api/env"
tests = "api/tests"
TOML
mkdir -p "$PROJ/api"
a() { # args: run `api` in the project (EDIR overrides)
  N=$((N + 1))
  (cd "${EDIR:-$PROJ}" && "$API" "$@" >"$CAP/$N.out" 2>"$CAP/$N.err" </dev/null); RC=$?
  OUT="$CAP/$N.out" ERR="$CAP/$N.err"
}
API="$REPO/.local/bin/api"
a
L=$(devlog)
check "8: api starts posting: --collection <abs api dir> and --env for base.env, dev.env and the tmpfs secrets.env" bash -c "[ $RC = 0 ] && grep -qF -- 'posting --collection $PROJ/api --env $PROJ/api/env/base.env --env $PROJ/api/env/dev.env --env $XDG_RUNTIME_DIR/devtools/api-' '$FAKE_DIR/dev.log'"
check "8: the env files that do not exist are not passed (no stage.env)" bash -c "! grep -q 'stage.env' '$FAKE_DIR/dev.log'"
check "8: secrets.env holds NAME=\${NAME} lines for the declared secrets that were injected, no value" bash -c "grep -qxF 'API_TOKEN=\${API_TOKEN}' '$FAKE_DIR/posting.env.3' && ! grep -q SECRET '$FAKE_DIR/posting.env.3'"
check "8: posting's environment is scrubbed: no OPENAI_API_KEY (exported by the parent shell), none of the test harness variables, but the declared secret" bash -c "n=\$(grep '^posting env-names' '$FAKE_DIR/dev.log'); ! grep -qw OPENAI_API_KEY <<<\"\$n\" && ! grep -qw FAKE_DIR <<<\"\$n\" && grep -qw API_TOKEN <<<\"\$n\" && grep -qw HOME <<<\"\$n\" && grep -qw TERM <<<\"\$n\""
check "8: the secret value reaches posting (hash), PATH is the fixed safe one, EDITOR=nvim" bash -c "grep -q 'API_TOKEN=$(sha SECRET-api-token) ' '$FAKE_DIR/dev.log' && grep -q 'editor=nvim path=/usr/bin:/usr/local/bin:' '$FAKE_DIR/dev.log'"
check "8: posting runs in the tmpfs run directory (no repo .env is ever its cwd)" grep -q "^posting cwd=$XDG_RUNTIME_DIR/devtools/api-" "$FAKE_DIR/dev.log"
scan "8 posting"
: >"$FAKE_DIR/dev.log"
a -e stage
check "8: -e stage picks stage.env if it exists (it does not): base.env only" bash -c "[ $RC = 0 ] && grep -qF -- '--env $PROJ/api/env/base.env' '$FAKE_DIR/dev.log' && ! grep -qF 'dev.env' '$FAKE_DIR/dev.log'"
: >"$FAKE_DIR/dev.log"
a -e prod
check "8: a protected environment without --prod and without a terminal is refused by envs (exit 4)" test $RC = 4
# outside a project: the scratch collection, no vault
: >"$FAKE_DIR/dev.log"; : >"$FAKE_DIR/argv.log"
EDIR="$T" a
check "8: outside a project: posting on ~/.local/share/posting/default, no secret, no rbw call" bash -c "[ $RC = 0 ] && grep -qE '^posting --collection .*/.local/share/posting/default\$' '$FAKE_DIR/dev.log' && ! grep -q '^rbw' '$FAKE_DIR/argv.log'"
EDIR="$PROJ"
# api test
: >"$FAKE_DIR/dev.log"
a test
check "8: api test: hurl --test --color --variables-file <run dir> --glob <tests>/**/*.hurl" bash -c "[ $RC = 0 ] && grep -qE '^hurl --test --color --variables-file $XDG_RUNTIME_DIR/devtools/api-[0-9]+/vars.env --file-root $PROJ --glob $PROJ/api/tests/\\*\\*/\\*.hurl\$' '$FAKE_DIR/dev.log'"
check "8: HURL_SECRET_API_TOKEN carries the value (hash), the plain API_TOKEN is gone, the parent's OPENAI key is not a hurl secret" bash -c "grep -q 'HURL_SECRET_API_TOKEN=$(sha SECRET-api-token) ' '$FAKE_DIR/dev.log' && grep -q 'plain-API_TOKEN= ' '$FAKE_DIR/dev.log'"
check "8: the variables file has the plain lines only: no comment, no \${...} reference, no secret name" bash -c "grep -qx 'BASE_URL=http://localhost:8080' '$FAKE_DIR/hurl.vars' && grep -qx 'PLAIN_ONE=\"two words\"' '$FAKE_DIR/hurl.vars' && grep -qx 'BASE_URL=http://localhost:9090' '$FAKE_DIR/hurl.vars' && ! grep -qE 'API_TOKEN|EXTRA|^#' '$FAKE_DIR/hurl.vars'"
check "8: hurl's cwd is the run dir (no repo .hurlrc)" grep -q "^hurl cwd=$XDG_RUNTIME_DIR/devtools/api-" "$FAKE_DIR/dev.log"
: >"$FAKE_DIR/dev.log"
a test --report api/tests/health.hurl
check "8: api test FILES --report: the file, --report-html <tests>/report, no --glob" bash -c "grep -qF -- '--report-html $PROJ/api/tests/report' '$FAKE_DIR/dev.log' && grep -qF '$PROJ/api/tests/health.hurl' '$FAKE_DIR/dev.log' && ! grep -qF -- '--glob' '$FAKE_DIR/dev.log'"
a test nothere.hurl
check "8: a file that does not exist is a usage error" test $RC = 2
FAKE_HURL_RC=3 a test
check "8: hurl's exit status is api test's (exec)" test $RC = 3
scan "8 hurl"
# agents
CLAUDECODE=1 a
CLAUDECODE=1 a test
check "8: api and api test are refused for an agent (exit 4)" test $RC = 4
# init / check
rm -rf "$PROJ/api"; printf 'node_modules\n' >"$PROJ/.gitignore"
a init
check "8: api init creates the skeleton: base.env, <env>.env for each environment, health.hurl, health.posting.yaml" bash -c "[ $RC = 0 ] && grep -qx 'BASE_URL=http://localhost:8080' '$PROJ/api/env/base.env' && [ -f '$PROJ/api/env/dev.env' ] && [ -f '$PROJ/api/env/prod.env' ] && grep -q 'HTTP 200' '$PROJ/api/tests/health.hurl' && grep -q 'url: \${BASE_URL}/health' '$PROJ/api/health.posting.yaml'"
check "8: ... env files hold a comment per declared secret, never a value" bash -c "grep -q '# secret API_TOKEN' '$PROJ/api/env/dev.env' && ! grep -q SECRET '$PROJ/api/env/dev.env'"
check "8: ... and .gitignore gets api/tests/report/" grep -qx 'api/tests/report/' "$PROJ/.gitignore"
a init
check "8: api init refuses to overwrite (exit 1, nothing changed)" test $RC = 1
a check
check "8: api check passes on the skeleton" test $RC = 0
printf 'API_TOKEN=SECRET-api-token\nOTHER=1\n' >>"$PROJ/api/env/stage.env"
a check
check "8: api check flags a committed literal for a declared secret name" bash -c "[ $RC = 1 ] && grep -q 'secret value committed' '$OUT'"
printf 'API_TOKEN=${API_TOKEN}\n' >"$PROJ/api/env/stage.env"; : >"$PROJ/api/.env"
a check
check "8: api check flags a .env file inside api/" bash -c "[ $RC = 1 ] && grep -q 'a .env file inside' '$OUT'"
sed -i '/^\[api\]/,$d' "$PROJ/.envs.toml"; printf '[api]\ncollection = "../out"\n' >>"$PROJ/.envs.toml"
a check
check "8: an [api] path that leaves the project is refused" bash -c "[ $RC = 1 ] && grep -q 'leaves the project root' '$ERR'"
scan "8"
}

sections_9() {
section "9 ci: act and gitlab-ci-local, secrets from envs, hostile-repo hardening"
reset
CI="$REPO/.local/bin/ci"
c() { N=$((N + 1)); (cd "${EDIR:-$PROJ}" && "$CI" "$@" >"$CAP/$N.out" 2>"$CAP/$N.err" </dev/null); RC=$?; OUT="$CAP/$N.out" ERR="$CAP/$N.err"; }
gh_flow() { mkdir -p "$PROJ/.github/workflows"; printf 'name: CI\non: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n' >"$PROJ/.github/workflows/ci.yml"; }
gl_flow() { printf 'build-shell:\n  script:\n    - echo hi\n' >"$PROJ/.gitlab-ci.yml"; }
printf -- '-P ubuntu-latest=catthehacker/ubuntu:act-latest\n' >"$T/actrc"; export DEVTOOLS_ACTRC="$T/actrc"
c list
check "9: no workflow and no .gitlab-ci.yml: exit 1 with a message" bash -c "[ $RC = 1 ] && grep -q 'no .github/workflows' '$ERR'"
gh_flow
c list --json
check "9: detection: a GitHub workflow -> act; the job table of act -l is parsed (job, workflow, file, events)" bash -c "[ $RC = 0 ] && jq -e '.system==\"act\" and (.jobs|length)==2 and .jobs[0].job==\"build\" and .jobs[0].file==\"ci.yml\" and .jobs[0].events==\"push,pull_request\"' '$OUT'"
rm -rf "$PROJ/.github"; gl_flow
c list --json
check "9: detection: .gitlab-ci.yml -> gitlab-ci-local; the --list-csv rows are parsed" bash -c "[ $RC = 0 ] && jq -e '.system==\"gcl\" and .jobs[0].job==\"build-shell\" and .jobs[1].stage==\"test\"' '$OUT'"
gh_flow
c list
check "9: both present and no terminal: asks for --system (exit 2)" bash -c "[ $RC = 2 ] && grep -q -- '--system' '$ERR'"
c list --system act --json
check "9: --system act picks act" bash -c "jq -e '.system==\"act\"' '$OUT'"
rm -rf "$PROJ/.gitlab-ci.yml"

# act: argv, empty files, secrets by name
cat >>"$PROJ/.envs.toml" <<'TOML'

[ci]
secrets = ["NPM_TOKEN"]
TOML
mkdir -p "$T/images"; python3 - "$FAKE_DIR/docker.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["images"] = ["catthehacker/ubuntu:act-latest"]; json.dump(d, open(p, "w"))
PY
: >"$FAKE_DIR/dev.log"
c run --system act
RUNL=$(grep '^act ' "$FAKE_DIR/dev.log" | head -1)
check "9: act run: -C <repo>, empty --env-file/--secret-file/--var-file/--input-file in the run dir, explicit cache paths, --pull=false, push event" bash -c "[ $RC = 0 ] && grep -qE '^act -C $PROJ --env-file $XDG_RUNTIME_DIR/devtools/ci-[0-9]+/none.env --secret-file [^ ]+none.secrets --var-file [^ ]+none.vars --input-file [^ ]+none.input --action-cache-path [^ ]+/act --cache-server-path [^ ]+/act/cache --artifact-server-path [^ ]+/act/artifacts --pull=false push -s NPM_TOKEN\$' '$FAKE_DIR/dev.log'"
check "9: the four files are empty and 0600 (a repo .env / .secrets / .vars / .input is never read)" bash -c "[ \$(grep -c -E '^act --(env|secret|var|input)-file-size=0 mode=600\$' '$FAKE_DIR/dev.log') = 4 ]"
check "9: act's cwd is the run dir, not the repository (a repo .actrc is never read)" grep -q "^act cwd=$XDG_RUNTIME_DIR/devtools/ci-" "$FAKE_DIR/dev.log"
check "9: -s NPM_TOKEN has no value on argv; the value is in act's environment (hash)" bash -c "grep -q 'NPM_TOKEN=$(sha SECRET-npm-token) ' '$FAKE_DIR/dev.log' && ! grep -q 'SECRET' '$FAKE_DIR/dev.log'"
check "9: only the declared [ci] secret is injected, not DB_PASSWORD or API_TOKEN" bash -c "grep '^act hashes' '$FAKE_DIR/dev.log' | grep -q 'names=NPM_TOKEN OPENAI_API_KEY \$'"
check "9: run dir removed when the run ends" bash -c "! ls '$XDG_RUNTIME_DIR'/devtools/ci-[0-9]* >/dev/null 2>&1"
check "9: the log of the run is on tmpfs, 0600" bash -c "[ \$(stat -c %a '$XDG_RUNTIME_DIR/devtools/ci-last.log') = 600 ] && grep -q 'fake run' '$XDG_RUNTIME_DIR/devtools/ci-last.log'"
: >"$FAKE_DIR/dev.log"
c run build --system act --event pull_request --dry-run
check "9: a job, another event and --dry-run: -j build, pull_request, -n" bash -c "grep -qE '^act .* pull_request -j build -s NPM_TOKEN -n\$' '$FAKE_DIR/dev.log'"
c run -- --system act
check "9: a job name starting with a dash is refused (exit 2)" test $RC = 2
c run 'build;rm' --system act
check "9: a job name with shell characters is refused" test $RC = 2
FAKE_ACT_RC=7 c run --system act
check "9: the tool's exit status is ci run's" test $RC = 7
# the first-run image confirmation
python3 - "$FAKE_DIR/docker.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["images"] = []; json.dump(d, open(p, "w"))
PY
: >"$FAKE_DIR/dev.log"
c run --system act
check "9: no act image on the machine and no terminal: nothing runs (the pull of 1-2 GB needs a yes)" bash -c "[ $RC = 1 ] && grep -q 'about 1-2 GB' '$ERR' && ! grep -q '^act -C' '$FAKE_DIR/dev.log'"
c run --system act --yes
check "9: --yes accepts it" test $RC = 0
# github_token
python3 - "$PROJ/.envs.toml" <<'PY'
import sys
p = sys.argv[1]; t = open(p).read().replace('secrets = ["NPM_TOKEN"]', 'secrets = []\ngithub_token = true'); open(p, "w").write(t)
PY
: >"$FAKE_DIR/dev.log"; : >"$FAKE_DIR/argv.log"
c run --system act --yes
check "9: github_token = true: the fake gh gives GITHUB_TOKEN to act's environment, -s GITHUB_TOKEN, no vault" bash -c "[ $RC = 0 ] && grep -q 'GITHUB_TOKEN=$(sha SECRET-gh-token)' '$FAKE_DIR/dev.log' && grep -q ' -s GITHUB_TOKEN' '$FAKE_DIR/dev.log' && ! grep -q '^rbw' '$FAKE_DIR/argv.log'"
CLAUDECODE=1 c run --system act --yes
check "9: an agent is refused when the run needs a token (exit 4)" test $RC = 4
python3 - "$PROJ/.envs.toml" <<'PY'
import sys
p = sys.argv[1]; t = open(p).read().replace('secrets = []\ngithub_token = true', 'secrets = []'); open(p, "w").write(t)
PY
: >"$FAKE_DIR/argv.log"
CLAUDECODE=1 c run --system act --yes
check "9: without secrets or token an agent may run CI (it can run act itself); no vault" bash -c "[ $RC = 0 ] && ! grep -q '^rbw' '$FAKE_DIR/argv.log'"
python3 - "$PROJ/.envs.toml" <<'PY'
import sys
p = sys.argv[1]; t = open(p).read().replace('secrets = []', 'secrets = ["NPM_TOKEN"]'); open(p, "w").write(t)
PY
scan "9 act"

# gitlab-ci-local
rm -rf "$PROJ/.github"; gl_flow
: >"$FAKE_DIR/dev.log"
c run --system gcl -e stage
check "9: gcl run: --cwd <relative path to the repo>, --variables-file in the run dir, --timestamps" bash -c "[ $RC = 0 ] && grep -qE '^gcl --cwd (\\.\\./)+[^ ]+ --variables-file $XDG_RUNTIME_DIR/devtools/ci-[0-9]+/variables.yml --timestamps\$' '$FAKE_DIR/dev.log'"
check "9: variables.yml is 0600 in a 0700 dir; the value with a quote and a newline round-trips through the escaping" bash -c "grep -q 'variables-mode=600 dir-mode=700' '$FAKE_DIR/dev.log' && grep -q 'NPM_TOKEN-sha=$(sha $'SECRET-npm"q\nline2') lines=2' '$FAKE_DIR/dev.log'"
check "9: ... one key only: the escaped value cannot add a variable" bash -c "[ \$(grep -c '^[A-Za-z_]*:' '$FAKE_DIR/gcl.variables') = 1 ]"
check "9: the plain NPM_TOKEN is not in gitlab-ci-local's environment" bash -c "grep '^gcl names=' '$FAKE_DIR/dev.log' | grep -qv 'NPM_TOKEN'"
check "9: the variables file is gone after a successful run" bash -c "! ls '$XDG_RUNTIME_DIR'/devtools/ci-[0-9]* >/dev/null 2>&1"
FAKE_GCL_RC=3 c run --system gcl
check "9: after a failing run: exit status 3 and the file is gone" bash -c "[ $RC = 3 ] && ! ls '$XDG_RUNTIME_DIR'/devtools/ci-[0-9]* >/dev/null 2>&1"
# SIGINT while the job runs
: >"$FAKE_DIR/dev.log"
(cd "$PROJ" && FAKE_SLEEP=20 "$CI" run --system gcl >"$CAP/int.out" 2>"$CAP/int.err" </dev/null) & BG=$!
for _ in $(seq 60); do grep -q '^gcl variables-mode' "$FAKE_DIR/dev.log" 2>/dev/null && break; sleep 0.1; done
RUNPID=$(pgrep -f "ci _run --root $PROJ" | head -1)
ls "$XDG_RUNTIME_DIR"/devtools/ci-[0-9]*/variables.yml >/dev/null 2>&1 && ok "9: while the run lives the variables file exists (tmpfs)" || bad "9: variables file during the run"
kill -INT "$RUNPID" 2>/dev/null
wait "$BG"; RCI=$?
check "9: SIGINT to the wrapper: it stops (exit 130) and the secrets file is removed" bash -c "[ $RCI = 130 ] && ! ls '$XDG_RUNTIME_DIR'/devtools/ci-[0-9]*/variables.yml >/dev/null 2>&1"
(cd "$PROJ" && FAKE_SLEEP=20 "$CI" run --system gcl >"$CAP/term.out" 2>"$CAP/term.err" </dev/null) & BG=$!
for _ in $(seq 60); do pgrep -f "ci _run --root $PROJ" >/dev/null && ls "$XDG_RUNTIME_DIR"/devtools/ci-[0-9]*/variables.yml >/dev/null 2>&1 && break; sleep 0.1; done
RUNPID=$(pgrep -f "ci _run --root $PROJ" | head -1); sleep 0.5
kill -TERM "$RUNPID" 2>/dev/null; wait "$BG"; RCT=$?
check "9: SIGTERM the same (exit 143, file removed)" bash -c "[ $RCT = 143 ] && ! ls '$XDG_RUNTIME_DIR'/devtools/ci-[0-9]*/variables.yml >/dev/null 2>&1"
# a repo .gitlab-ci-local-env
printf 'VOLUME=/:/host\n' >"$PROJ/.gitlab-ci-local-env"; : >"$FAKE_DIR/dev.log"
c run --system gcl
check "9: a repo .gitlab-ci-local-env (CLI defaults such as volumes) stops the run without a terminal (exit 4), gitlab-ci-local never starts" bash -c "[ $RC = 4 ] && grep -q 'VOLUME' '$ERR' && ! grep -q '^gcl --cwd' '$FAKE_DIR/dev.log'"
c run --system gcl --trust-env-file
check "9: --trust-env-file confirms it" test $RC = 0
rm -f "$PROJ/.gitlab-ci-local-env"
c run --system gcl --container-mode build-shell
check "9: container mode: --no-shell-executor-no-image and the job name" grep -q -- '--no-shell-executor-no-image build-shell' "$FAKE_DIR/dev.log"
c run --system gcl --dry-run
check "9: dry run of gcl is --preview" grep -q -- '--preview' "$FAKE_DIR/dev.log"
# the menu
gh_flow; : >"$FAKE_DIR/dev.log"
c --system gcl
check "9: the menu (gcl) lists the jobs and warns that image-less jobs run on this machine" bash -c "grep -q 'build-shell' '$FAKE_DIR/menu.in' && grep -q 'run ON THIS MACHINE' '$FAKE_DIR/dev.log'"
c --system act
check "9: the menu (act) lists build and test with workflow and events" bash -c "grep -q 'build  *CI  *push,pull_request' '$FAKE_DIR/menu.in'"
CLAUDECODE=1 c --system act
check "9: the menu is refused for an agent" test $RC = 4
scan "9"
}

sections_10() {
section "10 forge: gh-dash with a merged config, glab-tui through envs run -g, the zsh glab function"
reset
FORGE="$REPO/.local/bin/forge"
f() { N=$((N + 1)); (cd "${EDIR:-$PROJ}" && "$FORGE" "$@" >"$CAP/$N.out" 2>"$CAP/$N.err" </dev/null); RC=$?; OUT="$CAP/$N.out" ERR="$CAP/$N.err"; }
if python3 -I -B - "$FORGE" <<'PY'
import importlib.machinery, importlib.util, sys
l = importlib.machinery.SourceFileLoader("forge_mod", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("forge_mod", l)); l.exec_module(m)
cases = {"git@github.com:o/r.git": ("github.com", "o/r"), "ssh://git@gitlab.example.com:2222/grp/sub/proj.git": ("gitlab.example.com", "grp/sub/proj"),
         "https://user@github.com/o/r": ("github.com", "o/r"), "https://gitlab.example.com:8443/grp/proj.git/": ("gitlab.example.com", "grp/proj"),
         "git@GitHub.com:o/r": ("github.com", "o/r"), "": (None, None), "nonsense": (None, None)}
bad = [(u, m.parse_remote(u), want) for u, want in cases.items() if m.parse_remote(u) != want]
print(bad)
sys.exit(1 if bad else 0)
PY
then ok "10: remote parsing: scp-like and ssh:// and https forms, port, .git, user, case"; else bad "10: remote parsing"; fi
mkdir -p "$XDG_STATE_HOME/theme/current"; cp "$REPO/themes/generated/black/gh-dash-theme.yml" "$XDG_STATE_HOME/theme/current/gh-dash-theme.yml"
(cd "$PROJ" && git remote add origin git@github.com:owner/repo.git)
: >"$FAKE_DIR/dev.log"; : >"$FAKE_DIR/argv.log"
f
check "10: a github.com remote -> gh-dash --config <run dir>/gh-dash.yml; cwd = the run dir (no repo .gh-dash.yml); no vault" bash -c "[ $RC = 0 ] && grep -qE '^gh-dash --config $XDG_RUNTIME_DIR/devtools/forge-[0-9]+/gh-dash.yml\$' '$FAKE_DIR/dev.log' && grep -q \"^gh-dash cwd=$XDG_RUNTIME_DIR/devtools/forge-\" '$FAKE_DIR/dev.log' && ! grep -q '^rbw' '$FAKE_DIR/argv.log' && grep -q 'config-mode=600' '$FAKE_DIR/dev.log'"
check "10: the config is base.yml + the theme: exactly one top-level theme: key, the sections of base.yml, the palette colours" bash -c "[ \$(grep -c '^theme:' '$FAKE_DIR/gh-dash.config') = 1 ] && grep -q '^prSections:' '$FAKE_DIR/gh-dash.config' && grep -q 'selected: \"#' '$FAKE_DIR/gh-dash.config'"
check "10: the real base.yml has no top-level theme: key" bash -c "! grep -q '^theme:' '$REPO/.config/gh-dash/base.yml'"
mkdir -p "$T/xdgc/gh-dash"; printf 'theme:\n  ui: {}\n' >"$T/xdgc/gh-dash/base.yml"
XDG_CONFIG_HOME="$T/xdgc" f
check "10: a base.yml with its own theme: key is refused (the launcher would produce two)" bash -c "[ $RC = 1 ] && grep -q 'must not hold a top-level' '$ERR'"
CLAUDECODE=1 f
check "10: forge is refused for an agent (exit 4)" test $RC = 4
# gitlab
(cd "$PROJ" && git remote set-url origin git@gitlab.example.com:grp/proj.git)
printf '[secrets]\nTD_PW = ""\n' >"$ENVS_GLOBAL_DIR/global.local.toml"; chmod 600 "$ENVS_GLOBAL_DIR/global.local.toml"
: >"$FAKE_DIR/dev.log"
f
check "10: a non-github remote -> glab-tui through envs run -g: GITLAB_TOKEN and GITLAB_HOST arrive (hashes), cwd = the repository" bash -c "[ $RC = 0 ] && grep -q 'GITLAB_TOKEN=$(sha SECRET-gitlab-token) GITLAB_HOST=$(sha SECRET-gitlab-host.example) ' '$FAKE_DIR/dev.log' && grep -q \"^glab-tui cwd=$PROJ\$\" '$FAKE_DIR/dev.log'"
check "10: no other global secret (TD_PW) and no project secret reaches glab-tui; the parent's OPENAI key is the user's own environment" bash -c "grep '^glab-tui hashes' '$FAKE_DIR/dev.log' | grep -q 'names=GITLAB_HOST GITLAB_TOKEN OPENAI_API_KEY \$'"
f gitlab --root "$PROJ"
check "10: forge gitlab --root works from anywhere" test $RC = 0
CLAUDECODE=1 f gitlab
check "10: the gitlab path is refused for an agent (exit 4)" test $RC = 4
jq '(.items[]|select(.id=="g-def").fields) |= map(select(.name != "GITLAB_HOST"))' "$FAKE_DIR/vault.json" >"$T/v.json" && mv "$T/v.json" "$FAKE_DIR/vault.json"; rm -f "$FAKE_DIR/rbw-view.json"
f
check "10: GITLAB_HOST missing in Env/global: envs says to use envs set NAME -g (exit 1), glab-tui never starts" bash -c "[ $RC = 1 ] && grep -q 'envs set NAME -g' '$ERR'"
cp "$HERE/fixtures/vault.json" "$FAKE_DIR/vault.json"; rm -f "$FAKE_DIR/rbw-view.json" "$ENVS_GLOBAL_DIR/global.local.toml"
(cd "$PROJ" && git remote remove origin)
f
check "10: no remote and no terminal: asks for github|gitlab (exit 2)" bash -c "[ $RC = 2 ] && grep -q 'forge github' '$ERR'"
f check
check "10: forge check reports the tools and the remote without any vault" bash -c "[ $RC = 0 ] && grep -q 'gh-dash' '$OUT' && grep -q 'remote' '$OUT'"
# the zsh function: glab with the token from Bitwarden (Env/global) through envs run -g
blk=$(sed -n '/^# The absolute path of envs/,/^fi$/p' "$REPO/.zshrc")
gfn=$(grep -E '^glab\(\)' "$REPO/.zshrc")
check "10: .zshrc defines glab() through \$_ENVS_BIN run -g, with the comment" bash -c "grep -B2 -E '^glab\\(\\)' '$REPO/.zshrc' | grep -q '^# glab with the GitLab token' && grep -qE '^glab\\(\\) \\{ \\\$_ENVS_BIN run -g -- glab \"\\\$@\" \\}' '$REPO/.zshrc'"
: >"$FAKE_DIR/dev.log"
(cd "$T" && zsh -f -c "$blk; $gfn; glab ci view" >"$CAP/zg.out" 2>"$CAP/zg.err" </dev/null); rc=$?
check "10: glab ci view in zsh runs the (fake) glab with GITLAB_TOKEN from Env/global, no glab config involved" bash -c "[ $rc = 0 ] && grep -q '^glab ci view\$' '$FAKE_DIR/dev.log' && grep -q 'GITLAB_TOKEN=$(sha SECRET-gitlab-token) ' '$FAKE_DIR/dev.log'"
check "10: .zshrc exports the lazysql privacy switches for hand runs" bash -c "grep -q 'LAZYSQL_NO_TELEMETRY=1' '$REPO/.zshrc' && grep -q 'LAZYSQL_NO_UPDATE_CHECK=1' '$REPO/.zshrc'"
scan "10"
}

sections_13u() {
section "13u user-tools.sh (pinned user-level installs), packages"
UT="$REPO/infrastructure/dev/user-tools.sh"
mkdir -p "$T/ut/bin" "$T/ut/gobin" "$T/ut/home"
cat >"$T/ut/bin/go" <<'EOS'
#!/bin/sh
case "$1 $2" in
  "env GOBIN") echo "$UT_GOBIN" ;;
  "version -m") [ -n "$UT_GO_VERSION" ] && printf '\tpath\tx/y\n\tmod\tgithub.com/x/y\t%s\n' "$UT_GO_VERSION" ;;
esac
EOS
printf '#!/bin/sh\n[ "$1" = list ] && { [ -n "$UT_PIPX_JSON" ] && echo "$UT_PIPX_JSON" || echo "{}"; }\n' >"$T/ut/bin/pipx"
printf '#!/bin/sh\n[ "$1" = ls ] && { [ -n "$UT_NPM_JSON" ] && echo "$UT_NPM_JSON" || echo "{}"; }\n' >"$T/ut/bin/npm"
printf '#!/bin/sh\n[ "$1 $2" = "install --list" ] && printf "%%b" "${UT_CARGO_LIST:-}"\n' >"$T/ut/bin/cargo"
chmod +x "$T/ut/bin"/*
run_ut() { PATH="$T/ut/bin:/usr/bin:/bin" HOME="$T/ut/home" UT_GOBIN="$T/ut/gobin" "$@"; }
out=$(run_ut "$UT" --dry-run 2>&1)
check "13u: nothing installed: every pinned tool is planned with its exact version (go: module@tag, pipx ==, npm @, cargo --locked --version)" bash -c "grep -qF 'would run: go install github.com/jorgerojas26/lazysql@v0.7.0' <<<'$out' && grep -qF 'would run: go install github.com/dlvhdr/gh-dash/v4@v4.26.2' <<<'$out' && grep -qF 'would run: pipx install posting==2.11.1' <<<'$out' && grep -qF 'would run: npm install -g --ignore-scripts gitlab-ci-local@4.76.1' <<<'$out' && grep -qF 'would run: cargo install --locked --version 0.9.3 glab-tui-crate' <<<'$out'"
check "13u: --dry-run changes nothing (no gobin file, no config copy)" bash -c "[ -z \"\$(ls -A '$T/ut/gobin')\" ] && [ ! -e '$T/ut/home/.config' ]"
touch "$T/ut/gobin/lazysql" "$T/ut/gobin/gh-dash"; chmod +x "$T/ut/gobin"/*
out=$(UT_GO_VERSION=v9.0.0 UT_PIPX_JSON='{"venvs":{"posting":{"metadata":{"main_package":{"package_version":"2.12.0"}}}}}' UT_NPM_JSON='{"dependencies":{"gitlab-ci-local":{"version":"4.76.1"}}}' UT_CARGO_LIST='glab-tui-crate v0.9.3:\n    glab-tui\n' run_ut "$UT" --dry-run 2>&1)
check "13u: installed versions at or above the pin are skipped (sysup may be ahead of the pins)" bash -c "! grep -q 'would run' <<<'$out' && grep -q 'posting 2.12.0 present' <<<'$out' && grep -q 'glab-tui 0.9.3 present' <<<'$out'"
out=$(UT_GO_VERSION=v0.6.0 run_ut "$UT" --dry-run --only lazysql 2>&1)
check "13u: an older version is upgraded to the pin; --only limits the steps" bash -c "grep -qF 'would run: go install github.com/jorgerojas26/lazysql@v0.7.0' <<<'$out' && ! grep -q posting <<<'$out'"
out=$(run_ut "$UT" --dry-run --only glab-tui 2>&1)
check "13u: the glab-tui config is copied once when missing (planned in dry run)" grep -q 'would copy' <<<"$out"
check "13u: the pins are the documented floor (CLAUDE.md names them)" bash -c "grep -q 'v0.7.0' '$UT' && grep -q 'v4.26.2' '$UT' && grep -q '2.11.1' '$UT'"
check "13u: bash -n clean for the install scripts" bash -c "bash -n '$UT' && bash -n '$REPO/install.sh' && bash -n '$REPO/apply-system.sh'"
check "13u: apply-system.sh and install.sh list hurl act glab python-pipx (in sync)" bash -c "grep -q 'hurl act glab python-pipx' '$REPO/apply-system.sh' && grep -q 'hurl act glab python-pipx' '$REPO/install.sh'"
check "13u: install-hints.tsv offers hurl, act and glab" bash -c "grep -q '^hurl	hurl' '$REPO/.config/hub/install-hints.tsv' && grep -q '^act	act' '$REPO/.config/hub/install-hints.tsv' && grep -q '^glab	glab' '$REPO/.config/hub/install-hints.tsv'"
}

tmux_menu_section() { # full runs only: the real fzf-menu modal in a private tmux server
section "13+14 db menu and ci job picker (private tmux server, real fzf-menu --here)"
reset
tm() { tmux -L "$SOCK" "$@"; }
screen_raw() { tm capture-pane -p -J -t t 2>/dev/null; }
scr_has() { screen_raw | grep -aqE -- "$1"; }
wait_scr() { local i max=$(( ${2:-8} * 5 )); for ((i = 0; i < max; i++)); do scr_has "$1" && return 0; sleep 0.2; done; return 1; }
key() { tm send-keys -t t "$@"; sleep "${KDELAY:-0.4}"; }
leaks() { local out s; out=$(screen_raw); for s in "${SECRETS[@]}"; do grep -aqF -- "$s" <<<"$out" && echo "$s"; done; }
: >"$T/screen-leaks.log"
export FZF_MENU_NO_SERVER=1
NOMENU_PATH=${PATH/"$HERE/bin-menu:"/} NOMENU_TOOLS=${ENVS_TOOL_PATH/"$HERE/bin-menu:"/}
tm new-session -d -s t -x 150 -y 40 "bash --noprofile --norc -c 'cd $PROJ && PATH=$NOMENU_PATH ENVS_TOOL_PATH=$NOMENU_TOOLS $DB; echo EXIT[\$?]; sleep 60'"
check "13: the db menu opens with the connections of the project (resolved docker port) and the container without a config" wait_scr 'main +mariadb .*docker:mariadb -> 127.0.0.1:32768' 12
leaks >>"$T/screen-leaks.log"
check "13: the docker-only rows are listed: other-mariadb-1 and td-clickhouse" bash -c "s=\$(tmux -L $SOCK capture-pane -p -J -t t); grep -q 'other-mariadb-1' <<<\"\$s\" && grep -q 'td-clickhouse' <<<\"\$s\""
check "13: the preview names the secret but shows no value" wait_scr 'password +secret DB_PASSWORD' 6
KDELAY=0.9 key Escape
KDELAY=0.9 key r
check "13: r toggles read-only for the row: [ro] appears (the menu restarts after an action)" wait_scr 'main +\[ro\] +mariadb' 6
KDELAY=0.9 key Escape
KDELAY=0.9 key r
check "13: r again turns it off" bash -c "! tmux -L $SOCK capture-pane -p -J -t t | grep -q 'main .*\[ro\]'"
KDELAY=0.9 key Escape
tm send-keys -t t -l к; sleep 1.2
check "13: the Cyrillic twin of r works" wait_scr 'main +\[ro\] +mariadb' 6
KDELAY=0.9 key Escape
tm send-keys -t t -l к; sleep 1.2
KDELAY=0.9 key Escape
: >"$FAKE_DIR/dev.log"
KDELAY=0.9 key '?'
check "13: ? shows the help" wait_scr 'db menu keys' 6
key Enter
KDELAY=0.9 key Escape
KDELAY=1.5 key o
check "13: o opens the connection: the (fake) lazysql was started from the menu with the placeholder config" bash -c "grep -q '^lazysql -config' '$FAKE_DIR/dev.log' && grep -qF 'URL = \"mysql://app:\${pw}@127.0.0.1:32768/app\"' '$FAKE_DIR/lazysql.config'"
check "13: ... and the menu is back afterwards" wait_scr 'main +mariadb' 8
leaks >>"$T/screen-leaks.log"
check "13: no secret was ever on the screen" bash -c "[ ! -s '$T/screen-leaks.log' ]"
KDELAY=0.6 key Escape
KDELAY=0.9 key Escape
wait_scr 'EXIT\[0\]' 6 || { key q; }
check "13: Esc quits with status 0" scr_has 'EXIT\[0\]'
tm kill-server 2>/dev/null
# 14: the ci job picker
gh_flow14() { mkdir -p "$PROJ/.github/workflows"; printf 'name: CI\non: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n' >"$PROJ/.github/workflows/ci.yml"; }
gh_flow14; printf -- '-P ubuntu-latest=catthehacker/ubuntu:act-latest\n' >"$T/actrc"
python3 - "$FAKE_DIR/docker.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["images"] = ["catthehacker/ubuntu:act-latest"]; json.dump(d, open(p, "w"))
PY
: >"$FAKE_DIR/dev.log"
tm new-session -d -s t -x 150 -y 40 "bash --noprofile --norc -c 'cd $PROJ && PATH=$NOMENU_PATH ENVS_TOOL_PATH=$NOMENU_TOOLS DEVTOOLS_ACTRC=$T/actrc $REPO/.local/bin/ci --system act; echo EXIT[\$?]; sleep 60'"
check "14: the ci job picker lists the jobs of act -l (build, test) with workflow and events" wait_scr 'build +CI +push,pull_request' 12
KDELAY=1.5 key Escape
KDELAY=2 key a
check "14: a runs everything: act ran with the push event and no -j" bash -c "grep -qE '^act -C .* --pull=false push\$' '$FAKE_DIR/dev.log'"
check "14: the output waits for Enter, then the picker is back" wait_scr 'Enter' 6
key Enter
check "14: back in the picker" wait_scr 'build +CI' 8
KDELAY=0.9 key Escape
KDELAY=0.9 key Escape
wait_scr 'EXIT\[0\]' 6 || key q
check "14: Esc quits with status 0" scr_has 'EXIT\[0\]'
tm kill-server 2>/dev/null
}

timing_section() { # reported; fails only above the bounds
section "16 timing (db list < 150 ms, db menu first frame < 800 ms with fakes, tmux start included)"
reset
if command -v hyperfine >/dev/null; then
  (cd "$PROJ" && hyperfine -N -w3 -r 20 --export-json "$T/hf.json" "$DB list" >/dev/null 2>&1)
  med=$(jq -r '.results[0]|(.median // .summary.time_wall_clock.median)*1000' "$T/hf.json")
  printf 'info  db list: median %.1f ms (reported; the check below fails above 150 ms)\n' "$med"
  check "16: db list is below 150 ms" bash -c "awk -v r=$med 'BEGIN{exit !(r < 150)}'"
else
  echo "info  hyperfine is missing: db list timing skipped"
fi
local NOMENU_PATH=${PATH/"$HERE/bin-menu:"/} NOMENU_TOOLS=${ENVS_TOOL_PATH/"$HERE/bin-menu:"/} t0 t1 i ms
export FZF_MENU_NO_SERVER=1
t0=$(date +%s%N)
tmux -L "$SOCK" new-session -d -s t -x 150 -y 40 "bash --noprofile --norc -c 'cd $PROJ && PATH=$NOMENU_PATH ENVS_TOOL_PATH=$NOMENU_TOOLS $DB; sleep 20'"
for ((i = 0; i < 200; i++)); do
  tmux -L "$SOCK" capture-pane -p -t t 2>/dev/null | grep -aq 'main  *mariadb' && break
  sleep 0.02
done
t1=$(date +%s%N); ms=$(((t1 - t0) / 1000000))
tmux -L "$SOCK" kill-server 2>/dev/null
printf 'info  db menu first frame: %d ms (includes the tmux start and the polling; fails above 800 ms)\n' "$ms"
check "16: the db menu draws its first frame within 800 ms" test "$ms" -lt 800
}

run_section() { [[ -z $ONLY || $ONLY == "$1" ]] && "$2"; }
run_section 1 sections_1
run_section 2 sections_2_3
run_section 4 sections_4
run_section 5 sections_5
run_section 6 sections_6
run_section 7 sections_7
run_section 8 sections_8
run_section 9 sections_9
run_section 10 sections_10
run_section 13u sections_13u
((QUICK)) || run_section 13 tmux_menu_section
((QUICK)) || run_section 16 timing_section
((QUICK)) && { [[ -z $ONLY ]] && printf '\n(--quick: the private-tmux menu sections 13 and 14 are skipped)\n'; }
run_section 11 sections_11_12

printf '\ndev test: %d passed, %d failed\n' "$PASS" "$FAILS"
exit $((FAILS > 0))
