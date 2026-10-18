#!/usr/bin/env bash
# Offline test of sysup (UPD1): fake sudo/checkupdates/yay/flatpak/npm in a temp PATH, a temp state dir and a fake pacman cache.
# Never touches the real system: nothing is installed, the real steps (repo, flatpak, npm, go, nvim ...) are never run.
#   infrastructure/tests/sysup/run.sh
set -u
unset DISPLAY WAYLAND_DISPLAY
# Only the project-environment cases below may activate mise. An inherited diff could undo the fake PATH.
for v in $(compgen -e | grep -E '^(__MISE_|MISE_ENV$)'); do unset "$v"; done
unset SYSUP_MISE SYSUP_KEEP_PROJECT_ENV SYSUP_INNER
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
SYSUP="$REPO/.local/bin/sysup"
UPDATES="$REPO/.config/waybar/scripts/updates.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/cache" "$T/pred"
for tool in fzf-menu ghostty notify-send hyprctl wl-copy pkill; do
  printf '#!/bin/sh\nexit 0\n' >"$T/bin/$tool"
done
fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
expect() { # name, condition command...
  local n=$1; shift
  if "$@" >/dev/null 2>&1; then pass "$n"; else fail "$n"; fi
}

cat >"$T/bin/sudo" <<'X'
#!/bin/sh
echo "[fake sudo] $* GOBIN=${GOBIN:-unset} PATH=$PATH" >>"$FAKE_LOG"
exit 0
X
cat >"$T/bin/checkupdates" <<'X'
#!/bin/sh
printf 'alpha 1.0-1 -> 1.1-1\nbeta 2:3.0-1 -> 2:3.1-1\n'
X
cat >"$T/bin/yay" <<'X'
#!/bin/sh
case "$*" in *-Qua*) printf 'aurpkg 1-1 -> 2-1\n' ;; *) echo "[fake yay] $*" >>"$FAKE_LOG" ;; esac
X
cat >"$T/bin/flatpak" <<'X'
#!/bin/sh
printf 'org.example.App\t1.2\n'
X
cat >"$T/bin/npm" <<'X'
#!/bin/sh
printf '{"codex":{"current":"1.0.0","latest":"1.1.0"}}'
X
chmod +x "$T/bin"/*
export FAKE_LOG="$T/fake.log"
: >"$FAKE_LOG"
# beta is already "downloaded" (a .sig alone must not count for alpha)
touch "$T/cache/beta-2:3.1-1-x86_64.pkg.tar.zst" "$T/cache/alpha-1.1-1-x86_64.pkg.tar.zst.sig"
printf '1700000000\n2\nok\n' >"$T/pred/state"
export XDG_STATE_HOME="$T/state" SYSUP_PKGCACHE="$T/cache" SYSUP_PRED="$T/pred" XDG_RUNTIME_DIR="$T/run" PATH="$T/bin:/usr/bin"
mkdir -p "$XDG_RUNTIME_DIR"
export SYSUP_TEST_HOME="$T/home"   # sysup takes HOME from the password database; this hook (scratch XDG_STATE_HOME only) replaces it

expect "steps list in order" bash -c "[ \"\$($SYSUP steps | tr '\n' ' ')\" = 'space news prune keyring repo flatpak rust npm pipx go devtools mise claude nvim zsh tmux report ' ]"
expect "dry run prints the plan and writes no log" bash -c "$SYSUP --dry-run | grep -q keyring && [ ! -e '$T/state/sysup/last.log' ]"

"$SYSUP" check --quiet
P="$T/state/sysup/pending.json"
expect "check writes pending.json" test -s "$P"
expect "repo count 2, aur 1, flatpak 1, npm 1" jq -e '(.repo|length)==2 and (.aur|length)==1 and (.flatpak|length)==1 and (.npm|length)==1' "$P"
expect "only the complete package counts as downloaded" jq -e '.downloaded==1 and (.repo[]|select(.name=="beta").downloaded) and (.repo[]|select(.name=="alpha").downloaded|not)' "$P"
expect "predownload state is read" jq -e '.predownload_active==true and .predownload_ts==1700000000' "$P"
expect "status prints the numbers" bash -c "$SYSUP status | grep -q 'repo     2 pending, 1 already downloaded'"

# waybar module: counts repo + aur + flatpak, tooltip with the download line and the hint line
J=$("$UPDATES")
expect "badge text counts 4" bash -c "jq -e '.text | endswith(\" 4\")' <<<'$J'"
expect "badge tooltip has the hint line" bash -c "jq -e '.tooltip | contains(\"L: install everything · M: check now · R: pending list\")' <<<'$J'"
expect "badge tooltip says what is downloaded" bash -c "jq -e '.tooltip | contains(\"Downloaded in the background: 1 of 2\")' <<<'$J'"

# a run with the safe steps only: logged, inhibited, summarised, nothing real executed
out=$("$SYSUP" --only space,prune,keyring,report --yes 2>&1)
rc=$?
expect "install run exits 0" test "$rc" = 0
expect "log file exists with the summary" grep -q 'summary' "$T/state/sysup/last.log"
expect "prune used paccache twice" bash -c "[ \$(grep -c 'paccache' '$FAKE_LOG') = 2 ]"
expect "keyring runs before any upgrade" bash -c "grep -q 'pacman -Sy --needed --noconfirm archlinux-keyring' '$FAKE_LOG' && ! grep -q 'fake yay' '$FAKE_LOG'"
expect "skipped steps are listed as skipped" bash -c "grep -q 'repo     skipped' <<<'$out'"

# USERS-SYNC: the shared dev-tool tree is skipped quietly while /srv/devtools does not exist
out=$(USR_DEVTOOLS_SHARED="$T/no-such-devtools" "$SYSUP" --only devtools --yes 2>&1)
expect "devtools step: no tree = skipped without a failure" bash -c "grep -q 'shared dev tools skipped' <<<'$out' && grep -q 'devtools *ok' <<<'$out'"

# a second run rotates the log
"$SYSUP" --only space --yes >/dev/null 2>&1
expect "the previous log is kept" bash -c "ls '$T'/state/sysup/[0-9]*.log >/dev/null 2>&1"

# low disk: refuses (df is faked by a function-free shim)
cat >"$T/bin/df" <<'X'
#!/bin/sh
printf 'Avail\n1048576\n'
X
chmod +x "$T/bin/df"
"$SYSUP" --only space --yes >/dev/null 2>&1; rc=$?
expect "refuses below 2 GiB" test "$rc" != 0
"$SYSUP" --only space --yes --force >/dev/null 2>&1; rc=$?
expect "--force continues" test "$rc" = 0

# mise step (DEV-b): runs after go, from $HOME (never from the directory sysup was started in), skipped without mise
cat >"$T/bin/mise" <<'X'
#!/bin/sh
echo "[fake mise] $PWD|$*" >>"$FAKE_LOG"
exit 0
X
chmod +x "$T/bin/mise"
mkdir -p "$T/home" "$T/proj"
: >"$FAKE_LOG"
(cd "$T/proj" && HOME="$T/home" "$SYSUP" --only mise --yes >/dev/null 2>&1); rc=$?
expect "mise step exits 0" test "$rc" = 0
expect "mise step: plugins update, upgrade, prune in order" bash -c "[ \"\$(grep 'fake mise' '$FAKE_LOG' | sed 's/.*|//' | tr '\n' ',')\" = 'plugins update,upgrade --yes,prune --yes,' ]"
expect "mise step runs from HOME, not the start directory" bash -c "grep 'fake mise' '$FAKE_LOG' | grep -q '$T/home|' && ! grep 'fake mise' '$FAKE_LOG' | grep -q '$T/proj'"
expect "mise is listed after go in the dry run" bash -c "$SYSUP --dry-run | tr -s ' \n' ' ' | grep -q 'go devtools mise claude'"
rm -f "$T/bin/mise"
# a PATH without /usr/bin (mise is installed there now): links to the few basics sysup needs, none to mise (L9)
mkdir -p "$T/nomise"
for t in bash env sh dirname basename date mktemp cat sed grep awk tr id readlink mkdir rm sort head tail printf cut ls tee df uname hostname stat find wc getent mv xargs sleep timeout flock jq pacman systemd-inhibit script; do
  [ -x "/usr/bin/$t" ] && ln -sf "/usr/bin/$t" "$T/nomise/$t"
done
out=$(HOME="$T/home" PATH="$T/bin:$T/nomise" "$SYSUP" --only mise --yes 2>&1); rc=$?
expect "mise step is skipped when mise is missing" bash -c "[ $rc = 0 ] && grep -q 'mise is not installed' <<<'$out'"

# FIX-DEVb2: started inside an activated project, sysup lets mise undo its own environment (`mise hook-env -s bash --force` from
# $HOME; the __MISE_DIFF format is never decoded) before any step runs. The fake mise (tests/sysup/fake-mise) reverses a state
# file of its own format, so nothing here depends on how real mise encodes its diff.
FAKEMISE="$HERE/fake-mise"
rm -f "$T/bin/mise"
mkdir -p "$T/bin2" "$T/projbin" "$T/real/gobin" "$T/gopath"
printf '#!/bin/sh\n' >"$T/real/gobin/tool"; chmod +x "$T/real/gobin/tool"
cat >"$T/bin2/go" <<'X'
#!/bin/sh
case "$1 $2" in
  "env GOBIN") printf '%s\n' "${GOBIN:-}" ;;
  "env GOPATH") printf '%s\n' "$GOPATH_FAKE" ;;
  "version -m") printf '\tpath\texample.com/x/cmd/tool\n\tmod\texample.com/x\tv1.0.0\n' ;;
  install*) echo "[go install] $2 GOBIN=${GOBIN:-unset} PATH=$PATH" >>"$FAKE_LOG" ;;
esac
X
cat >"$T/bin2/npm" <<'X'
#!/bin/sh
echo "[npm] $* PREFIX=${NPM_CONFIG_PREFIX:-unset} KEEPME=${KEEPME:-unset} PATH=$PATH" >>"$FAKE_LOG"
X
for t in go npm; do printf '#!/bin/sh\necho "PROJECT-%s ran" >>"%s/project-tool-ran"\n' "$t" "$T" >"$T/projbin/$t"; done
chmod +x "$T/bin2"/* "$T/projbin"/*
ln -s "$FAKEMISE" "$T/bin2/mise"   # the `mise` step finds it on PATH; hook-env is reached through SYSUP_MISE
ORIGPATH="$T/bin2:$PATH"
printf 'GOBIN=%s\nNPM_CONFIG_PREFIX\nPROJ_ONLY\nPATH=%s\n' "$T/real/gobin" "$ORIGPATH" >"$T/diff.state"
mkdir -p "$T/mise/installs/go/1.22/bin" "$T/mise/shims"
PROJ_UNSET=()     # `-u NAME` options for env, set for single cases
projrun() { # extra env assignments... (PROJ_UNSET = -u options) : sysup --only npm,go,mise from an "activated project"
  (cd "$T/proj" && env "${PROJ_UNSET[@]}" HOME="$T/home" GOPATH_FAKE="$T/gopath" GOBIN="$T/proj/.bin" NPM_CONFIG_PREFIX="$T/proj/.npm" PROJ_ONLY=1 KEEPME=mine \
    MISE_ENV=prod __MISE_SESSION=abc __MISE_DIFF="$T/diff.state" PATH="$T/projbin:$T/mise/installs/go/1.22/bin:$T/mise/shims:$ORIGPATH" \
    "$@" "$SYSUP" --only npm,go,mise --yes 2>&1)
}
: >"$FAKE_LOG"; rm -f "$T/project-tool-ran"
out=$(projrun SYSUP_MISE="$FAKEMISE"); rc=$?
expect "project env: the run succeeds" test "$rc" = 0
expect "project env: mise undid its environment, once, from \$HOME, as a forced bash hook-env" bash -c "[ \$(grep -c '^\[hook-env\]' '$FAKE_LOG') = 1 ] && grep -q '^\[hook-env\] $T/home|hook-env -s bash --force' '$FAKE_LOG'"
expect "project env: go install sees the original GOBIN, not the project's" bash -c "grep '^\[go install\]' '$FAKE_LOG' | grep -q 'GOBIN=$T/real/gobin '"
expect "project env: npm -g sees no NPM_CONFIG_PREFIX and keeps unrelated variables" bash -c "grep '^\[npm\] -g update' '$FAKE_LOG' | grep -q 'PREFIX=unset KEEPME=mine'"
expect "REVIEW-DEV-d #16: npm -g update runs with --ignore-scripts (the pinned install of gitlab-ci-local had it, the update did not)" grep -q '^\[npm\] -g update --ignore-scripts' "$FAKE_LOG"
expect "project env: the project's _.path entry is out of PATH for go and npm, and its go/npm never ran" bash -c "! grep -E '^\[(npm|go install)\]' '$FAKE_LOG' | grep -q '$T/projbin' && [ ! -e '$T/project-tool-ran' ]"
expect "project env: mise's install dirs and shims are out of PATH too" bash -c "! grep '^\[' '$FAKE_LOG' | grep -q 'mise/installs\|mise/shims'"
expect "project env: mise upgrade runs with __MISE_* gone and the project's GOBIN undone" bash -c "grep '^\[env\] upgrade' '$FAKE_LOG' | grep -q 'GOBIN=$T/real/gobin NPM_CONFIG_PREFIX=unset SESSION=unset'"
expect "project env: MISE_ENV is gone for the steps" bash -c "[ \$(grep -c 'MISE_ENV' '$FAKE_LOG') = 0 ]"

: >"$FAKE_LOG"; rm -f "$T/project-tool-ran"
projrun SYSUP_MISE="$FAKEMISE" FAKE_MISE_FAIL=1 >"$T/out.txt"; rc=$?
expect "mise cannot undo it: the run stops before any step (exit 1, nothing ran)" bash -c "[ $rc = 1 ] && ! grep -qE '^\[(npm|go install|env)\]' '$FAKE_LOG' && [ ! -e '$T/project-tool-ran' ] && grep -q 'could not undo' '$T/out.txt'"
: >"$FAKE_LOG"; rm -f "$T/project-tool-ran"
projrun SYSUP_MISE="$FAKEMISE" FAKE_MISE_FAIL=1 SYSUP_KEEP_PROJECT_ENV=1 >"$T/out.txt"; rc=$?
expect "... SYSUP_KEEP_PROJECT_ENV=1 goes on with a warning and the project environment as it is (the owner's decision)" bash -c "[ $rc = 0 ] && grep -q 'SYSUP_KEEP_PROJECT_ENV=1' '$T/out.txt' && [ -e '$T/project-tool-ran' ]"
if [[ -x /usr/bin/mise ]]; then
  echo "SKIP  the no-mise cases: a real /usr/bin/mise is installed (covered by G7)"
else
  : >"$FAKE_LOG"; rm -f "$T/project-tool-ran" "$T/bin2/mise"   # no mise on PATH either
  projrun >"$T/out.txt"; rc=$?
  expect "activated environment and no mise at all: stops (exit 1), nothing ran" bash -c "[ $rc = 1 ] && ! grep -qE '^\[(npm|go install)\]' '$FAKE_LOG' && [ ! -e '$T/project-tool-ran' ]"
  cp "$FAKEMISE" "$T/fake-mise-outside"
  : >"$FAKE_LOG"
  projrun SYSUP_MISE="$T/fake-mise-outside" >"$T/out.txt"; rc=$?
  expect "SYSUP_MISE outside infrastructure/tests/ is ignored (not a way to run another program)" bash -c "[ $rc = 1 ] && ! grep -q '^\[hook-env\]' '$FAKE_LOG'"
  ln -s "$FAKEMISE" "$T/bin2/mise"
fi
: >"$FAKE_LOG"
out=$(cd "$T/proj" && env HOME="$T/home" GOPATH_FAKE="$T/gopath" GOBIN="$T/real/gobin" SYSUP_MISE="$FAKEMISE" PATH="$ORIGPATH" "$SYSUP" --only go --yes 2>&1); rc=$?
expect "no mise activation in this shell: hook-env is not called and the owner's own GOBIN stays" bash -c "[ $rc = 0 ] && ! grep -q '^\[hook-env\]' '$FAKE_LOG' && grep '^\[go install\]' '$FAKE_LOG' | grep -q 'GOBIN=$T/real/gobin '"

# REVIEW-ENVS-FINAL #5: a project's [env] HOME must not steer the undo; MISE_EXPERIMENTAL=0 for hook-env; the undo runs before sudo -v;
# only /usr/bin/mise (never a mise found through PATH) does the undo
PWHOME=$(getent passwd "$(id -u)" | cut -d: -f6)
: >"$FAKE_LOG"; rm -f "$T/project-tool-ran"
PROJ_UNSET=(-u SYSUP_TEST_HOME)
out=$(projrun SYSUP_MISE="$FAKEMISE" HOME="$T/evilhome"); rc=$?
PROJ_UNSET=()
expect "5a: an [env] HOME of the project does not decide where hook-env runs (the passwd home does)" bash -c "[ $rc = 0 ] && grep -q '^\[hook-env\] $PWHOME|' '$FAKE_LOG' && ! grep -q 'evilhome' '$FAKE_LOG'"
expect "5c: hook-env runs with MISE_EXPERIMENTAL=0" grep -q '^\[hook-env-env\] EXP=0' "$FAKE_LOG"
expect "5b: sudo -v runs AFTER the project environment is undone (original GOBIN, no project PATH entry)" bash -c "grep '^\[fake sudo\] -v' '$FAKE_LOG' | head -1 | grep -q 'GOBIN=$T/real/gobin ' && ! grep '^\[fake sudo\] -v' '$FAKE_LOG' | head -1 | grep -q '$T/projbin'"
# REVIEW-DEV-d #11: a project's [env] sets BOTH XDG_STATE_HOME and SYSUP_TEST_HOME (a directory inside the project, or anywhere that is
# not a scratch root): the hook must not count, or the undo would run inside the project again (5a)
EVIL=$(mktemp -d "/run/user/$(id -u)/sysup-evil.XXXXXX")   # a directory of ours that is not below a scratch root
: >"$FAKE_LOG"; rm -f "$T/project-tool-ran"
PROJ_UNSET=()
out=$(projrun SYSUP_MISE="$FAKEMISE" SYSUP_TEST_HOME="$EVIL"); rc=$?
expect "11: SYSUP_TEST_HOME outside /tmp, /var/tmp and /dev/shm is ignored: hook-env runs in the passwd home, not in that directory" bash -c "[ $rc = 0 ] && grep -q '^\[hook-env\] $PWHOME|' '$FAKE_LOG' && ! grep -q '$EVIL' '$FAKE_LOG'"
rm -rf "$EVIL"
if [[ ! -x /usr/bin/mise ]]; then
  # a `mise` earlier on PATH than /usr/bin (a project's `_.path` entry) must not be run for the undo
  mkdir -p "$T/evilbin"; printf '#!/bin/sh\necho EVIL-MISE >>"%s/project-tool-ran"\n' "$T" >"$T/evilbin/mise"; chmod +x "$T/evilbin/mise"
  : >"$FAKE_LOG"; rm -f "$T/project-tool-ran"
  (cd "$T/proj" && env HOME="$T/home" GOBIN="$T/proj/.bin" __MISE_SESSION=abc __MISE_DIFF="$T/diff.state" PATH="$T/evilbin:$ORIGPATH" "$SYSUP" --only go --yes >"$T/out.txt" 2>&1); rc=$?
  expect "5c: a mise found through PATH is not run (no /usr/bin/mise: the run stops, the project's mise never executed)" bash -c "[ $rc = 1 ] && [ ! -e '$T/project-tool-ran' ]"
fi

echo "sysup tests: $fails failure(s)"
exit $((fails > 0))
