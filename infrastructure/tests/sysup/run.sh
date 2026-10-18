#!/usr/bin/env bash
# Offline test of sysup (UPD1): fake sudo/checkupdates/yay/flatpak/npm in a temp PATH, a temp state dir and a fake pacman cache.
# Never touches the real system: nothing is installed, the real steps (repo, flatpak, npm, go, nvim ...) are never run.
#   infrastructure/tests/sysup/run.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
SYSUP="$REPO/.local/bin/sysup"
UPDATES="$REPO/.config/waybar/scripts/updates.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/cache" "$T/pred"
fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
expect() { # name, condition command...
  local n=$1; shift
  if "$@" >/dev/null 2>&1; then pass "$n"; else fail "$n"; fi
}

cat >"$T/bin/sudo" <<'X'
#!/bin/sh
echo "[fake sudo] $*" >>"$FAKE_LOG"
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
export XDG_STATE_HOME="$T/state" SYSUP_PKGCACHE="$T/cache" SYSUP_PRED="$T/pred" XDG_RUNTIME_DIR="$T/run" PATH="$T/bin:$PATH"
mkdir -p "$XDG_RUNTIME_DIR"

expect "steps list in order" bash -c "[ \"\$($SYSUP steps | tr '\n' ' ')\" = 'space news prune keyring repo flatpak rust npm pipx go mise claude nvim zsh tmux report ' ]"
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
expect "mise is listed after go in the dry run" bash -c "$SYSUP --dry-run | tr -s ' \n' ' ' | grep -q 'go mise claude'"
rm -f "$T/bin/mise"
out=$(HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" "$SYSUP" --only mise --yes 2>&1); rc=$?
expect "mise step is skipped when mise is missing" bash -c "[ $rc = 0 ] && grep -q 'mise is not installed' <<<'$out'"

# FIX-DEVb: started inside an activated project, sysup runs with the project's PATH entries, [env] and __MISE_* gone
cat >"$T/bin/mise" <<'X'
#!/bin/sh
echo "[env] GOBIN=${GOBIN:-unset} KEEPME=${KEEPME:-unset} PROJ_ONLY=${PROJ_ONLY:-unset} MISE_ENV=${MISE_ENV:-unset} SESSION=${__MISE_SESSION:-unset} PATH=$PATH" >>"$FAKE_LOG"
exit 0
X
chmod +x "$T/bin/mise"
mkdir -p "$T/mise/installs/go/1.22/bin" "$T/mise/shims"
DIFF=$(python3 -I -B - <<'PY'
import base64, json, zlib
d = {"original": {"GOBIN": "/home/real/go/bin"}, "additions": {"GOBIN": "/proj/.bin", "PROJ_ONLY": "1"}, "deletions": {}}
print(base64.urlsafe_b64encode(zlib.compress(json.dumps(d).encode())).decode().rstrip("="))
PY
)
: >"$FAKE_LOG"
(cd "$T/proj" && HOME="$T/home" KEEPME=mine GOBIN=/proj/.bin PROJ_ONLY=1 MISE_ENV=prod __MISE_SESSION=abc __MISE_DIFF="$DIFF" \
  PATH="$T/mise/installs/go/1.22/bin:$T/mise/shims:$PATH" "$SYSUP" --only mise --yes >/dev/null 2>&1); rc=$?
expect "project env: the mise install dirs and shims are out of PATH" bash -c "[ $rc = 0 ] && grep -q '^\[env\]' '$FAKE_LOG' && ! grep '^\[env\]' '$FAKE_LOG' | grep -q 'mise/installs\|mise/shims'"
expect "project env: the [env] the project added is undone (GOBIN back to the original, PROJ_ONLY unset), other variables stay" bash -c "grep '^\[env\]' '$FAKE_LOG' | grep -q 'GOBIN=/home/real/go/bin KEEPME=mine PROJ_ONLY=unset'"
expect "project env: MISE_ENV and __MISE_* are gone" bash -c "grep '^\[env\]' '$FAKE_LOG' | grep -q 'MISE_ENV=unset SESSION=unset'"
expect "project env: PATH entries outside the project stay" bash -c "grep '^\[env\]' '$FAKE_LOG' | grep -q 'PATH=.*/usr/bin'"
: >"$FAKE_LOG"
(cd "$T/proj" && HOME="$T/home" GOBIN=/proj/.bin __MISE_DIFF="not-a-diff" "$SYSUP" --only mise --yes >/dev/null 2>&1); rc=$?
expect "project env: an unreadable __MISE_DIFF is skipped, the run still works" bash -c "[ $rc = 0 ] && grep -q '^\[env\]' '$FAKE_LOG'"

echo "sysup tests: $fails failure(s)"
exit $((fails > 0))
