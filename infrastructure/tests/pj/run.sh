#!/usr/bin/env bash
# shellcheck disable=SC2016  # check bodies are single-quoted on purpose: they run in their own bash -c
# Offline test of `pj` (.local/bin/pj): rows, session names, layouts + trust, Enter contexts (tmux client, plain terminal,
# Hyprland), term-* handling, kill. Everything runs against a private tmux server (-L), fake zoxide / hyprctl / hyprd / ghostty /
# notify-send / fzf-menu / nvim / claude / gh / glab / workmux from ./bin and a scratch HOME. The live tmux server, Hyprland
# and the owner's repos are never touched.
#
#   run.sh            full run (the modal fzf-menu test drives the real fzf-menu in a second private tmux server)
#   run.sh --quick    no modal UI test (used by doctor.sh)
#   run.sh --keep     keep the temp dirs (paths printed at the end)
#   run.sh --only N   run section N alone, in this process
# Every section builds its own fixture in its own temp dir and private tmux server (`setup`), so a run is one process per
# section started in parallel (about 2 s instead of the sum of all sections); the shards' output is printed in section order.
set -u
export PYTHONDONTWRITEBYTECODE=1
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
PJ="$REPO/.local/bin/pj"
BIN="$HERE/bin"
BIN_AI="$HERE/bin-ai"
BIN_GLAB="$HERE/bin-glab"
QUICK=0 KEEP=0 ONLY=""
while (($#)); do case $1 in --quick) QUICK=1 ;; --keep) KEEP=1 ;; --only) ONLY=${2:-}; shift ;; *) echo "usage: run.sh [--quick] [--keep] [--only N]" >&2; exit 2 ;; esac; shift; done
SECTIONS=(3 4 5 11 12 13 14 15 1 2 6 7 8 16 10)
((QUICK)) || SECTIONS=(9 "${SECTIONS[@]}")

command -v tmux >/dev/null && command -v script >/dev/null && command -v git >/dev/null || { echo "tmux/script/git missing: skipped"; exit 0; }

if [[ -z $ONLY ]]; then
  OUT=$(mktemp -d "${TMPDIR:-/tmp}/pj-shards.XXXXXX")
  for n in "${SECTIONS[@]}"; do
    "${BASH_SOURCE[0]}" --only "$n" $( ((QUICK)) && echo --quick ) $( ((KEEP)) && echo --keep ) >"$OUT/$n" 2>&1 &
  done
  wait
  passes=0 fails=0
  for n in $(printf '%s\n' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16); do
    if [[ $n == 9 ]] && ((QUICK)); then echo "-- 9. modal UI skipped (--quick)"; continue; fi
    [[ -f $OUT/$n ]] || continue
    grep -v '^pj: [0-9]* passed' "$OUT/$n"
    if last=$(grep '^pj: [0-9]* passed' "$OUT/$n"); then
      passes=$((passes + $(sed 's/^pj: \([0-9]*\) passed.*/\1/' <<<"$last")))
      fails=$((fails + $(sed 's/.* \([0-9]*\) failed.*/\1/' <<<"$last")))
    else
      echo "FAIL  section $n did not finish"; fails=$((fails + 1))
    fi
  done
  rm -rf "$OUT"
  echo "pj: $passes passed, $fails failed"
  [ "$fails" = 0 ]
  exit
fi

REAL_PATH=$PATH
REAL_HOME=$HOME
# Nothing here may reach the owner's desktop: no display, and the fake fzf-menu / ghostty / notify-send come first on PATH, so
# even a `"$PJ" ...` run without pjx cannot open the real float menu (a real ghostty window) or a real notification.
unset WAYLAND_DISPLAY DISPLAY
export PATH="$BIN:$PATH"
T=$(mktemp -d "${TMPDIR:-/tmp}/pj-test.XXXXXX")
SOCK="pj-test-$$"
UISOCK="pj-test-ui-$$"
ZSOCK="pj-test-zw-$$"
export TMUX_TMPDIR="$T/tmp"
mkdir -p "$TMUX_TMPDIR" "$T/home" "$T/state" "$T/cache" "$T/hypr"
SOCK_DIR="$TMUX_TMPDIR/tmux-$(id -u)"
unset TMUX TMUX_PANE HYPRLAND_INSTANCE_SIGNATURE HUB_TARGET
export HOME="$T/home" FAKE_DIR="$T" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export XDG_CONFIG_HOME="$REPO/.config" XDG_STATE_HOME="$T/xstate" XDG_CACHE_HOME="$T/xcache" XDG_RUNTIME_DIR="$T/run"
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
# no real forge CLI may write its config into the repo (XDG_CONFIG_HOME above is the repo's .config): the fakes come first on PATH, and these point the real ones away
export GLAB_CONFIG_DIR="$T/glab-config" GH_CONFIG_DIR="$T/gh-config"
export PJ_CONFIG="$T/config.toml" PJ_STATE_DIR="$T/state" PJ_CACHE_DIR="$T/cache"
export PJ_TMUX="tmux -L $SOCK -f $T/tmux.conf" PJ_ZOXIDE="$BIN/zoxide" PJ_HYPRCTL="$BIN/hyprctl" PJ_HYPRD="$BIN/hyprd"
export PJ_TERMINAL="$BIN/ghostty" PJ_NOTIFY="$BIN/notify-send" PJ_HYPR=0
export PJ_WALK_MS=60000                                # the walk budget must not make a loaded machine flaky (section 15 tests it)
export FAKE_PICKS="$T/picks"
# files that a `#(touch $PWNn)` in a tmux argument would create: set in the environment of the tmux server (section 11)
export PWN1="$T/pwn1" PWN2="$T/pwn2" PWN3="$T/pwn3" PWN4="$T/pwn4"
CLIENT_PIDS=()
cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null
  tmux -L "$UISOCK" kill-server 2>/dev/null
  tmux -L "$ZSOCK" kill-server 2>/dev/null
  for p in "${CLIENT_PIDS[@]}"; do kill "$p" 2>/dev/null; done
  pkill -f "tmux -L $SOCK" 2>/dev/null
  pkill -f "tmux -L $UISOCK" 2>/dev/null
  pkill -f "tmux -L $ZSOCK" 2>/dev/null
  rm -f "$SOCK_DIR/$SOCK" "$SOCK_DIR/$UISOCK" "$SOCK_DIR/$ZSOCK"
  if ((KEEP)); then echo "kept: $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT

fails=0 passes=0
pass() { printf 'PASS  %s\n' "$1"; passes=$((passes + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
expect() { local n=$1; shift; if "$@" >/dev/null 2>&1; then pass "$n"; else fail "$n"; fi; }
tm() { tmux -L "$SOCK" "$@"; }
mkdir -p "$T/pjbin" && ln -sf "$PJ" "$T/pjbin/pj"
MIN_PATH=$T/pjbin:/usr/bin:/bin                                # python3, git, tmux, bat; no claude (the real one lives elsewhere)
pjx() { PATH="$BIN:$MIN_PATH" "$PJ" "$@"; }           # no claude on PATH
pjai() { PATH="$BIN:$BIN_AI:$MIN_PATH" "$PJ" "$@"; }  # claude on PATH
wait_for() { local n=${2:-5} i; for ((i = 0; i < n * 20; i++)); do bash -c "$1" >/dev/null 2>&1 && return 0; sleep 0.05; done; return 1; }
sessions() { tm list-sessions -F '#{session_name}' 2>/dev/null | sort | tr '\n' ' '; }
has_session() { tm has-session -t "=$1" 2>/dev/null; }
# attach NAME [CMD]: a client the way SUPER+Return makes one (new-session -s NAME, not detached); sets LAST_PID (the `script` pid)
attach() {
  local name=$1; shift
  tail -f /dev/null | script -qfc "tmux -L $SOCK new-session -s $name $*" /dev/null >/dev/null 2>&1 &
  LAST_PID=$!; CLIENT_PIDS+=("$LAST_PID")
  wait_for "tmux -L $SOCK has-session -t =$name" 5
}
attach_to() { # NAME: a client of an existing session
  tail -f /dev/null | script -qfc "tmux -L $SOCK attach-session -t '=$1'" /dev/null >/dev/null 2>&1 &
  LAST_PID=$!; CLIENT_PIDS+=("$LAST_PID")
  wait_for "[ -n \"\$(tmux -L $SOCK list-clients -t =$1 -F x)\" ]" 5
}
client_of() { tm list-clients -t "=$1" -F '#{client_name}' | head -1; }
client_session() { tm list-clients -F '#{client_name} #{client_session}' | awk -v c="$1" '$1 == c { print $2 }'; }
mkgit() { git init -q -b main "$1" && git -C "$1" commit -q --allow-empty -m init; }
log() { cat "$T/log" 2>/dev/null; }
# settle SESSION: wait until its shells finished starting (no child process under any pane: pj counts a startup script as work)
settle() { wait_for "for p in \$(tmux -L $SOCK list-panes -s -t =$1 -F '#{pane_pid}'); do pgrep -P \$p >/dev/null && exit 1; done; exit 0" 5; }

setup() {  # the fixture every section starts from
mkdir -p "$T/job/beta/delta" "$T/misc/dirA" "$T/misc/with space" "$T/odd"
mkgit "$T/job/alpha"; mkgit "$T/job/beta/gamma"; mkgit "$T/job/beta/delta"; mkgit "$T/job/beta/delta/nested-sub"
git -C "$T/job/alpha" worktree add -q "$T/wt/alpha/feat" -b feat
# a second worktree whose directory is gone (prunable): must not be listed
git -C "$T/job/alpha" worktree add -q "$T/wt/alpha/gone" -b gone && rm -rf "$T/wt/alpha/gone"
printf 'roots = ["%s"]\ndepth = 4\nzoxide = 30\n' "$T/job" >"$PJ_CONFIG"
printf '  9.0 %s\n  8.0 %s\n  7.0 %s\n  6.0 %s\n  5.0 %s\n  4.0 %s\n' "$HOME" "$T/gone" "$T/job/alpha" "$T/misc/dirA" \
  "$T/misc/with space" "$T/job/beta/gamma" >"$T/zoxide.txt"
{ echo 'set -g default-shell /bin/sh'; echo 'set -g base-index 1'; grep -E '^set-hook -g session-created ' "$REPO/.config/tmux/tmux.conf"; } >"$T/tmux.conf"
mkdir -p "$T/anchorcwd"
PATH="$BIN:$BIN_AI:$REAL_PATH" tmux -L "$SOCK" -f "$T/tmux.conf" new-session -d -s anchor -c "$T/anchorcwd"
tm set-option -g -t =anchor: remain-on-exit off 2>/dev/null

}

sec1() {
# ───────────────────────────── 1. rows ─────────────────────────────
echo "-- 1. rows"
rows=$(pjx rows)
expect "rows: a repo under the root" bash -c 'printf "%s\n" "$1" | grep -q "^r:$2/job/alpha	"' _ "$rows" "$T"
expect "rows: nested repos are listed at depth" bash -c 'printf "%s\n" "$1" | grep -q "^r:$2/job/beta/gamma	"' _ "$rows" "$T"
expect "rows: a repo inside a repo is pruned" bash -c '! printf "%s\n" "$1" | grep -q "nested-sub"' _ "$rows" "$T"
expect "rows: the worktree row follows its repo" bash -c 'printf "%s\n" "$1" | grep -A1 "^r:$2/job/alpha	" | tail -1 | grep -q "^w:$2/wt/alpha/feat	.*alpha ⎇ feat"' _ "$rows" "$T"
expect "rows: a prunable worktree is skipped" bash -c '! printf "%s\n" "$1" | grep -q "alpha/gone"' _ "$rows" "$T"
expect "rows: branch of a repo" bash -c 'printf "%s\n" "$1" | grep "^r:$2/job/beta/gamma	" | grep -q "main"' _ "$rows" "$T"
expect "rows: zoxide dir with a space" bash -c 'printf "%s\n" "$1" | grep -q "^z:$2/misc/with space	"' _ "$rows" "$T"
expect "rows: zoxide skips HOME, missing dirs and listed repos" bash -c '! printf "%s\n" "$1" | grep -q "^z:$2	\|^z:$3/gone\|^z:$3/job/alpha	\|^z:$3/job/beta/gamma	"' _ "$rows" "$HOME" "$T"
expect "rows: every row has an id and a display column" bash -c 'printf "%s\n" "$1" | awk -F"\t" "NF != 2 { exit 1 }"' _ "$rows"
expect "rows --json parses" bash -c '"$1" rows --json | python3 -c "import json,sys; d=json.load(sys.stdin); assert d and \"id\" in d[0]"' _ "$PJ"
# sessions: the session row stands for its repo, its worktree rows stay behind it
pjx create "$T/job/alpha" >/dev/null
rows=$(pjx rows)
expect "rows: a repo with a session is folded into the session row" bash -c 'printf "%s\n" "$1" | grep -q "^s:alpha	" && ! printf "%s\n" "$1" | grep -q "^r:$2/job/alpha	"' _ "$rows" "$T"
expect "rows: worktree rows follow the session row" bash -c 'printf "%s\n" "$1" | grep -A1 "^s:alpha	" | tail -1 | grep -q "^w:$2/wt/alpha/feat	"' _ "$rows" "$T"
expect "rows: project sessions come before the repos" bash -c 'printf "%s\n" "$1" | awk -F"\t" "NR == 1 { exit \$1 !~ /^s:/ }"' _ "$rows"
# a busy detached term-* is a leftover that holds work: first row, with its command
attach term-busy "'exec sleep 300'"
tm set-option -t =term-busy: destroy-unattached off; tm detach-client -s term-busy
wait_for "tmux -L $SOCK list-clients -t =term-busy -F x | grep -q . ; test \$? != 0" 3
rows=$(pjx rows)
expect "rows: a detached term-* that runs something is the first row and names the command" bash -c 'printf "%s\n" "$1" | head -1 | grep -q "^s:term-busy	.*detached.*running: sleep"' _ "$rows"
tm kill-session -t =term-busy 2>/dev/null
# the speed guard (the real one is G1 on the real HOME)
best=999999; for _ in 1 2 3 4 5; do t0=$(date +%s%N); pjx rows >/dev/null; t1=$(date +%s%N); d=$(((t1 - t0) / 1000000)); ((d < best)) && best=$d; done
pybase=999999; for _ in 1 2 3; do t0=$(date +%s%N); python3 -I -c pass; t1=$(date +%s%N); d=$(((t1 - t0) / 1000000)); ((d < pybase)) && pybase=$d; done
expect "rows: the fastest of 5 runs on the fixture < 150 ms + 4x the python start (the sections run in parallel: not the mean, and slack for a busy machine)" test "$best" -lt $((150 + 4 * pybase))

}

sec2() {
# ───────────────────────────── 2. names ─────────────────────────────
echo "-- 2. names"
mkdir -p "$T/c1/proj" "$T/c2/proj" "$T/c3/proj" "$T/x/c2/proj" "$T/odd/12345" "$T/odd/term-x" "$T/odd/a b.c"
n1=$(pjx create "$T/c1/proj"); n2=$(pjx create "$T/c2/proj"); n3=$(pjx create "$T/c3/proj"); n4=$(pjx create "$T/x/c2/proj")
expect "names: basename" test "$n1" = proj
expect "names: a clash gets parent-base" test "$n2" = c2-proj
expect "names: another clash with another parent" test "$n3" = c3-proj
expect "names: the same parent again gets -2" test "$n4" = c2-proj-2
cnt=$(tm list-sessions | wc -l)
expect "names: reuse by @pj_path, no new session" bash -c 'test "$("$1" create "$2/c1/proj")" = proj' _ "$PJ" "$T"
expect "names: reuse did not add a session" test "$(tm list-sessions | wc -l)" = "$cnt"
expect "names: @pj_path is set" test "$(tm show-options -t =proj: -v @pj_path)" = "$T/c1/proj"
expect "names: digits only get a p- prefix" test "$(pjx create "$T/odd/12345")" = p-12345
expect "names: a term-* dir name gets a p- prefix" test "$(pjx create "$T/odd/term-x")" = p-term-x
expect "names: dot and space become _" test "$(pjx create "$T/odd/a b.c")" = a_b_c
expect "names: no created session matches the term-* hook" bash -c '! tmux -L "$1" list-sessions -F "#{session_name}" | grep -q "^term-[a-z]"' _ "$SOCK"
expect "names: a session of another path is not reused (a term-* of the same path is not either)" bash -c 'test "$("$1" create "$2/c2/proj")" = c2-proj' _ "$PJ" "$T"

}

sec3() {
# ───────────────────────────── 3. layout ─────────────────────────────
echo "-- 3. layout"
: >"$T/log"
mkgit "$T/lay1"
s=$(pjai create "$T/lay1")
wait_for 'grep -q "^nvim " "$FAKE_DIR/log"' 5
expect "layout: default windows code, sh, ai in order" test "$(tm list-windows -t "=$s:" -F '#{window_name}' | tr '\n' ' ')" = "code sh ai "
expect "layout: code is the selected window" test "$(tm list-windows -t "=$s:" -F '#{window_name} #{window_active}' | awk '$2 == 1 { print $1 }')" = code
expect "layout: nvim was typed into the shell of code (ran there)" grep -q "^nvim $T/lay1" "$T/log"
expect "layout: claude is typed into the ai window but not run" bash -c 'tmux -L "$1" capture-pane -p -t "=$2:ai" | grep -q claude && ! grep -q "^claude " "$FAKE_DIR/log"' _ "$SOCK" "$s"
# no claude on PATH: the ai window is a plain shell
mkgit "$T/lay2"
s2=$(pjx create "$T/lay2")
sleep 0.3
expect "layout: without claude the ai window is a plain shell" bash -c '! tmux -L "$1" capture-pane -p -t "=$2:ai" | grep -q claude' _ "$SOCK" "$s2"
# ai_autostart = true runs it
mkgit "$T/lay3"
printf 'ai_autostart = true\n' >"$T/config.auto"
s3=$(PJ_CONFIG="$T/config.auto" pjai create "$T/lay3")
expect "layout: ai_autostart = true runs claude" wait_for 'grep -q "^claude $FAKE_DIR/lay3" "$FAKE_DIR/log"' 5
# a plain directory: one window sh
mkdir -p "$T/plain"
sp=$(pjx create "$T/plain")
expect "layout: a non-repo directory has one window sh" test "$(tm list-windows -t "=$sp:" -F '#{window_name}' | tr '\n' ' ')" = "sh "
mkgit "$T/lay4"
out=$(pjx --dry-run create "$T/lay4")
expect "layout: --dry-run prints new-session / new-window / send-keys" bash -c 'printf "%s\n" "$1" | grep -q "new-session -d -s lay4" && printf "%s\n" "$1" | grep -q "new-window" && printf "%s\n" "$1" | grep -q "send-keys"' _ "$out"
expect "layout: --dry-run created no session" bash -c '! tmux -L "$1" has-session -t =lay4' _ "$SOCK"
expect "layout: pj layout names the state" bash -c '"$1" layout "$2/lay4" | head -1 | grep -q ": default"' _ "$PJ" "$T"

# .tmux-session.toml: untrusted -> default + prompt; trust -> used; changed -> untrusted again
mkgit "$T/tl1"; mkdir -p "$T/tl1/sub"
cat >"$T/tl1/.tmux-session.toml" <<'EOF'
name = "tlayout"
[[window]]
name = "main"
command = "echo main"
dir = "sub"
focus = true
[[window]]
name = "side"
command = "echo side"
[[window.pane]]
command = "echo pane2"
split = "right"
size = 40
EOF
expect "layout: pj layout says an untrusted file is not used" bash -c '"$1" layout "$2/tl1" | head -1 | grep -q "NOT trusted"' _ "$PJ" "$T"
: >"$T/log"
st=$(FAKE_PICK="Use the default" pjx create "$T/tl1")
expect "layout: untrusted + 'default' = default layout and the default name" bash -c 'test "$1" = tl1 && test "$(tmux -L "$2" list-windows -t =tl1: -F "#{window_name}" | tr "\n" " ")" = "code sh ai "' _ "$st" "$SOCK"
expect "layout: the trust prompt lists the commands in its header and offers the default first" bash -c 'grep -q "fzf-menu .*runs:" "$FAKE_DIR/log" && grep -q "echo pane2" "$FAKE_DIR/log" && grep -A4 "^fzf-menu" "$FAKE_DIR/log" | grep -m1 "row:" | grep -q "default"'
expect "layout: nothing is trusted yet" test ! -s "$T/state/trusted.tsv"
tm kill-session -t =tl1
st=$(FAKE_PICK="Trust this" pjx create "$T/tl1")
expect "layout: trusted file: its name, windows and panes" bash -c 'test "$1" = tlayout && test "$(tmux -L "$2" list-windows -t =tlayout: -F "#{window_name}" | tr "\n" " ")" = "main side " && test "$(tmux -L "$2" list-panes -t =tlayout:side | wc -l)" = 2' _ "$st" "$SOCK"
expect "layout: window dir is relative to the repo root" test "$(tm display-message -p -t '=tlayout:main' '#{pane_current_path}')" = "$T/tl1/sub"
expect "layout: focus = true selects that window" test "$(tm list-windows -t =tlayout: -F '#{window_name} #{window_active}' | awk '$2 == 1 { print $1 }')" = main
expect "layout: the extra pane is 40 percent wide" bash -c 'w=$(tmux -L "$1" display-message -p -t =tlayout:side "#{window_width}"); p=$(tmux -L "$1" list-panes -t =tlayout:side -F "#{pane_width}" | sort -n | head -1); test $((p * 100 / w)) -ge 35 -a $((p * 100 / w)) -le 45' _ "$SOCK"
expect "layout: the commands ran in their windows" wait_for 'tmux -L "'"$SOCK"'" capture-pane -p -t =tlayout:side | grep -q "pane2\|side"' 3
expect "layout: trusted.tsv holds path and sha256" bash -c 'grep -q "^$1/tl1	[0-9a-f]\{64\}$" "$2/state/trusted.tsv"' _ "$T" "$T"
expect "layout: state dir 0700, trusted.tsv 0600" bash -c 'test "$(stat -c %a "$1/state")" = 700 && test "$(stat -c %a "$1/state/trusted.tsv")" = 600' _ "$T"
expect "layout: pj layout says trusted" bash -c '"$1" layout "$2/tl1" | head -1 | grep -q "trusted" && ! "$1" layout "$2/tl1" | head -1 | grep -q "NOT"' _ "$PJ" "$T"
echo '# changed' >>"$T/tl1/.tmux-session.toml"
expect "layout: a changed file is untrusted again" bash -c '"$1" layout "$2/tl1" | head -1 | grep -q "NOT trusted"' _ "$PJ" "$T"
tm kill-session -t =tlayout
st=$(FAKE_PICK="Trust this" pjx create "$T/tl1" --default)
expect "layout: --default ignores the file (no prompt, default windows)" bash -c 'tmux -L "$1" list-windows -t =tl1: -F "#{window_name}" | tr "\n" " " | grep -q "^code sh ai $"' _ "$SOCK"
tm kill-session -t =tl1
# invalid files fail closed: nothing is created
bad() { # NAME BODY: a repo with an invalid layout file
  mkgit "$T/$1"; printf '%s\n' "$2" >"$T/$1/.tmux-session.toml"
}
bad inv1 $'bogus = 1\n[[window]]\nname = "a"'
bad inv2 $'[[window]]\nname = "wm-x"'
bad inv3 $'[[window]]\nname = "a"\ndir = "../.."'
{ for i in $(seq 1 13); do printf '[[window]]\nname = "w%s"\n' "$i"; done; } >"$T/inv4.toml"; mkgit "$T/inv4"; cp "$T/inv4.toml" "$T/inv4/.tmux-session.toml"
bad inv5 $'[[window]]\nname = "a"\ncommand = "x\\ny"'
bad inv6 $'[[window]]\nname = "a"\n[[window]]\nname = "a"'
for i in 1 2 3 4 5 6; do
  FAKE_PICK="Trust this" pjx create "$T/inv$i" >"$T/inv.out" 2>&1; rc=$?
  expect "layout: invalid file inv$i creates nothing and exits non-zero" bash -c 'test "$1" != 0 && ! tmux -L "$2" has-session -t =inv'"$i"'' _ "$rc" "$SOCK"
done
expect "layout: the error names the problem and the way out" bash -c 'FAKE_PICK=x "$1" create "$2/inv2" 2>&1 | grep -q "wm-\*.*Alt+Enter"' _ "$PJ" "$T"

}

sec4() {
# ───────────────────────────── 4. Enter contexts ─────────────────────────────
echo "-- 4. enter contexts"
mkdir -p "$T/c1/proj"
mkgit "$T/e1"; mkgit "$T/e2"
out=$(pjx --dry-run --client fakeclient "$T/e1")
expect "enter: --client prints switch-client for that client" bash -c 'printf "%s\n" "$1" | grep -q "switch-client -c fakeclient -t =e1"' _ "$out"
expect "enter: --dry-run switch created nothing" bash -c '! tmux -L "$1" has-session -t =e1' _ "$SOCK"
out=$(pjx --dry-run "$T/e1")
expect "enter: no tmux, no client = attach-session argv" bash -c 'printf "%s\n" "$1" | grep -q "attach-session -t =e1"' _ "$out"
# a real client: switch it
attach main1; CPID=$LAST_PID
cl=$(client_of main1)
expect "enter: the test client exists" test -n "$cl"
pjx --client "$cl" "$T/e1" >/dev/null
expect "enter: pj --client switches that client to the new session" wait_for "test \"\$(tmux -L $SOCK list-clients -F '#{client_name} #{client_session}' | awk -v c='$cl' '\$1 == c { print \$2 }')\" = e1" 3
expect "enter: pj NAME switches to a running session" bash -c '"$1" --client "$2" main1 && sleep 0.3 && test "$(tmux -L "$3" list-clients -F "#{client_name} #{client_session}" | awk -v c="$2" "\$1 == c { print \$2 }")" = main1' _ "$PJ" "$cl" "$SOCK"
expect "enter: pj NAME for an unknown name fails" bash -c '! "$1" --client "$2" no-such-session-xyz 2>/dev/null' _ "$PJ" "$cl"
# Hyprland: window pid = the `script` process that owns the tmux client
hypr_json() { # ADDRESS PID TITLE
  printf '[{"address":"%s","pid":%s,"title":"%s","class":"com.mitchellh.ghostty"},{"address":"0xbrowser","pid":1,"title":"Zen","class":"zen"}]\n' "$1" "$2" "$3" >"$T/hypr/clients.json"
}
hypr_json 0xaaa "$CPID" "main1:sh"
printf '{"address":"0xaaa","pid":%s,"class":"com.mitchellh.ghostty"}\n' "$CPID" >"$T/hypr/activewindow.json"
: >"$T/log"
HUB_TARGET= PJ_HYPR=1 pjx open "$T/e2" >/dev/null
expect "hypr (a): the focused terminal's client is switched" wait_for "test \"\$(tmux -L $SOCK list-clients -F '#{client_name} #{client_session}' | awk -v c='$cl' '\$1 == c { print \$2 }')\" = e2" 3
expect "hypr (a): no new window" bash -c '! grep -q "^ghostty" "$FAKE_DIR/log"'
# (b) the session is shown in another window: focus it
attach_to e1; BPID=$LAST_PID
hypr_json 0xaaa "$CPID" "e2:sh"
python3 - "$T/hypr/clients.json" "$BPID" <<'EOF'
import json, sys
f, pid = sys.argv[1], int(sys.argv[2])
d = json.load(open(f))
d.append({"address": "0xbbb", "pid": pid, "title": "e1:sh", "class": "com.mitchellh.ghostty"})
json.dump(d, open(f, "w"))
EOF
printf '{"address":"0xbrowser","pid":1,"class":"zen"}\n' >"$T/hypr/activewindow.json"
: >"$T/log"
HUB_TARGET= PJ_HYPR=1 pjx open "$T/e1" >/dev/null
expect "hypr (b): the window that shows the session is focused (target was a browser)" grep -q "^hyprd focuswindow address:0xbbb" "$T/log"
expect "hypr (b): no new terminal" bash -c '! grep -q "^ghostty" "$FAKE_DIR/log"'
# (c) the session is shown nowhere: a new ghostty attaches
: >"$T/log"
HUB_TARGET= PJ_HYPR=1 pjx open "$T/c1/proj" >/dev/null
expect "hypr (c): a new ghostty runs tmux attach-session for the session" grep -q "^ghostty -e tmux -L $SOCK -f $T/tmux.conf attach-session -t =proj" "$T/log"
# HUB_TARGET wins over the active window
: >"$T/log"
HUB_TARGET=address:0xaaa PJ_HYPR=1 pjx open "$T/c1/proj" >/dev/null
expect "hypr: HUB_TARGET wins over the active window (its client is switched)" wait_for "test \"\$(tmux -L $SOCK list-clients -F '#{client_name} #{client_session}' | awk -v c='$cl' '\$1 == c { print \$2 }')\" = proj" 3
expect "hypr: pj open --dry-run prints a plan and changes nothing" bash -c 'out=$(HUB_TARGET= PJ_HYPR=1 "$1" --dry-run open "$2/c1/proj" 2>&1); printf "%s\n" "$out" | grep -q "DRY"' _ "$PJ" "$T"
kill "$BPID" 2>/dev/null

}

sec5() {
# ───────────────────────────── 5. term-* ─────────────────────────────
echo "-- 5. term-*"
mkgit "$T/e1"; mkgit "$T/e2"; pjx create "$T/e1" >/dev/null
attach term-idle; TI=$LAST_PID
ci=$(client_of term-idle)
expect "term: the hook set destroy-unattached on" test "$(tm list-sessions -F '#{session_name} #{destroy-unattached}' | awk '$1 == "term-idle" { print $2 }')" = on
pjx --client "$ci" "$T/e2" >/dev/null
expect "term: idle term-*: switching away destroys it (nothing lost)" wait_for "! tmux -L $SOCK has-session -t =term-idle" 3
attach term-work; TW=$LAST_PID
cw=$(client_of term-work)
tm send-keys -t =term-work: 'sleep 300' Enter
expect "term: the pane runs sleep" wait_for "tmux -L $SOCK list-panes -t =term-work -F '#{pane_current_command}' | grep -q sleep" 5
out=$(pjx --client "$cw" "$T/e2")
expect "term: busy term-*: destroy-unattached turned off, the session survives the switch" bash -c 'sleep 0.4; tmux -L "$1" has-session -t =term-work && test "$(tmux -L "$1" list-sessions -F "#{session_name} #{destroy-unattached}" | awk "\$1 == \"term-work\" { print \$2 }")" = off' _ "$SOCK"
expect "term: the surviving term-* is the first row of the picker" bash -c '"$1" rows | head -1 | grep -q "^s:term-work	"' _ "$PJ"
# project sessions never get destroy-unattached and survive a detach
attach_to e1; EP=$LAST_PID
tm detach-client -s e1; sleep 0.3
expect "term: a pj project session keeps destroy-unattached off and survives detach" bash -c 'tmux -L "$1" has-session -t =e1 && test "$(tmux -L "$1" list-sessions -F "#{session_name} #{destroy-unattached}" | awk "\$1 == \"e1\" { print \$2 }")" = off' _ "$SOCK"
tm kill-session -t =term-work 2>/dev/null

}

sec6() {
# ───────────────────────────── 6. kill ─────────────────────────────
echo "-- 6. kill"
mkdir -p "$T/k1" "$T/k2" "$T/k3"
pjx create "$T/k1" >/dev/null; settle k1
: >"$T/log"
expect "kill: idle + detached = killed without a prompt" bash -c '"$1" kill k1 && ! tmux -L "$2" has-session -t =k1 && ! grep -q "^fzf-menu" "$FAKE_DIR/log"' _ "$PJ" "$SOCK"
pjx create "$T/k2" >/dev/null
tm send-keys -t =k2:sh 'sleep 300' Enter
wait_for "tmux -L $SOCK list-panes -s -t =k2 -F '#{pane_current_command}' | grep -q sleep" 5
FAKE_PICK="No" pjx kill k2 >/dev/null
expect "kill: busy = confirm, 'No' keeps the session" has_session k2
expect "kill: the confirm text says what runs" grep -q "running: sleep" "$T/log"
FAKE_PICK="Yes" pjx kill k2 >/dev/null
expect "kill: busy = confirm, 'Yes' kills" bash -c '! tmux -L "$1" has-session -t =k2' _ "$SOCK"
pjx create "$T/k3" >/dev/null
attach_to k3; KP=$LAST_PID
kc=$(client_of k3)
pjx kill k3 --force >/dev/null
expect "kill: --force skips the prompt" bash -c '! tmux -L "$1" has-session -t =k3' _ "$SOCK"
expect "kill: the attached client was moved to another session, not dropped" wait_for "test -n \"\$(tmux -L $SOCK list-clients -F '#{client_name}' | grep -F '$kc')\"" 3
expect "kill: an unknown session is reported" bash -c '"$1" kill nope-xyz | grep -q "no session"' _ "$PJ"
: >"$T/log"
mkgit "$T/k4"; pjx create "$T/k4" >/dev/null
tm new-window -d -t =k4: -n wm-job
FAKE_PICK="No" pjx kill k4 >/dev/null
expect "kill: wm-* windows trigger the confirm and the text says worktrees stay" grep -q "workmux windows: wm-job" "$T/log"
pjx kill k4 --force >/dev/null

}

sec7() {
# ───────────────────────────── 7. workmux ─────────────────────────────
echo "-- 7. workmux"
# the picker pieces are driven by the fake fzf-menu (FAKE_PICKS); a real client takes the switch
pjx create "$T/job/alpha" >/dev/null
attach wmain; WP=$LAST_PID
wcl=$(client_of wmain)
mkgit "$T/job/wmrepo"; git -C "$T/job/wmrepo" branch spare
: >"$T/log"; printf 'pick:wmrepo\nquery:feat-x\n' >"$FAKE_PICKS"
FZF_MENU_HERE=1 pjx --client "$wcl" open --task >/dev/null 2>&1
expect "workmux: w runs 'workmux add BRANCH --parent-session S -b' in the repo with the private server in TMUX" bash -c 'grep -q "^workmux add feat-x --parent-session wmrepo -b | cwd=$1/job/wmrepo | TMUX=.*/$2,[0-9]*,0$" "$FAKE_DIR/log"' _ "$T" "$SOCK"
expect "workmux: the project session was created for the repo" has_session wmrepo
expect "workmux: the new wm-* window is selected and the client follows" wait_for "test \"\$(tmux -L $SOCK display-message -p -t =wmrepo: '#{window_name}')\" = wm-feat-x -a \"\$(tmux -L $SOCK list-clients -F '#{client_name} #{client_session}' | awk -v c='$wcl' '\$1 == c { print \$2 }')\" = wmrepo" 3
expect "workmux: pj created no wm-* window itself (only the fake workmux did)" bash -c 'test "$(tmux -L "$1" list-windows -t =wmrepo: -F "#{window_name}" | grep -c "^wm-")" = 1' _ "$SOCK"
expect "workmux: the branch list holds branches without a worktree and not the checked-out one" bash -c 'grep -A6 "^fzf-menu .*-p branch" "$FAKE_DIR/log" | grep -q "row: spare" && ! grep -A6 "^fzf-menu .*-p branch" "$FAKE_DIR/log" | grep -q "row: main"' 
expect "workmux: the --task list holds repos only (no zoxide rows)" bash -c '! grep -A40 "^fzf-menu .*-p project" "$FAKE_DIR/log" | grep -q "row: z:"'
# a failing workmux is reported, nothing selected
: >"$T/log"; touch "$T/workmux.fail"; printf 'pick:wmrepo\nquery:feat-y\n' >"$FAKE_PICKS"
out=$(FZF_MENU_HERE=1 pjx --client "$wcl" open --task 2>&1)
expect "workmux: a failing workmux shows its last line (in the header of the reopened list)" grep -q "workmux add failed: workmux: boom" "$T/log"
expect "workmux: the log keeps the output (0600)" bash -c 'grep -q boom "$1/state/last.log" && test "$(stat -c %a "$1/state/last.log")" = 600' _ "$T"
rm -f "$T/workmux.fail"
# a bad branch name
printf 'pick:wmrepo\nquery:--evil\n' >"$FAKE_PICKS"; : >"$T/log"
FZF_MENU_HERE=1 pjx --client "$wcl" open --task >/dev/null 2>&1
expect "workmux: a branch name starting with - is refused (workmux not called)" bash -c '! grep -q "^workmux add" "$FAKE_DIR/log"'
# worktree row: an existing window is selected; else workmux open; missing workmux = wt-* window
tm new-window -d -t =alpha: -n wm-feat -c "$T/wt/alpha/feat"
: >"$T/log"; printf 'pick:alpha ⎇ feat\n' >"$FAKE_PICKS"
FZF_MENU_HERE=1 pjx --client "$wcl" >/dev/null 2>&1
expect "workmux: Enter on a worktree row selects the window that already works in it (no workmux call)" bash -c 'test "$(tmux -L "$1" display-message -p -t =alpha: "#{window_name}")" = wm-feat && ! grep -q "^workmux" "$FAKE_DIR/log"' _ "$SOCK"
tm kill-window -t =alpha:wm-feat
: >"$T/log"; printf 'pick:alpha ⎇ feat\n' >"$FAKE_PICKS"
FZF_MENU_HERE=1 pjx --client "$wcl" >/dev/null 2>&1
expect "workmux: without a window Enter runs 'workmux open HANDLE --parent-session S'" grep -q "^workmux open feat --parent-session alpha | cwd=$T/job/alpha" "$T/log"
expect "workmux: and selects the wm-feat window" test "$(tm display-message -p -t =alpha: '#{window_name}')" = wm-feat
tm kill-window -t =alpha:wm-feat
: >"$T/log"; printf 'pick:alpha ⎇ feat\n' >"$FAKE_PICKS"
FZF_MENU_HERE=1 PJ_WORKMUX=/nonexistent/workmux pjx --client "$wcl" >/dev/null 2>&1
expect "workmux: workmux missing -> a plain wt-feat window in the project session" test "$(tm display-message -p -t =alpha: '#{window_name}')" = wt-feat
expect "workmux: the fallback window works in the worktree" test "$(tm display-message -p -t '=alpha:wt-feat' '#{pane_current_path}')" = "$T/wt/alpha/feat"
expect "workmux: w is hidden without workmux (header)" bash -c 'printf "p\n" >"$1"; : >"$2/log"; FZF_MENU_HERE=1 FAKE_PICK= PJ_WORKMUX=/nonexistent/workmux PATH="$3" "$4" --here >/dev/null 2>&1; ! grep "^fzf-menu .*-p project" "$2/log" | grep -q "w task"' _ "$T/x" "$T" "$BIN:$MIN_PATH" "$PJ"
kill "$WP" 2>/dev/null

}

sec8() {
# ───────────────────────────── 8. clone ─────────────────────────────
echo "-- 8. clone"
cat >"$T/gh-user.json" <<'EOF2'
[{"nameWithOwner":"me/alpha-remote","description":"Alpha remote","isArchived":false,"pushedAt":"2026-10-02T00:00:00Z"},
 {"nameWithOwner":"me/cloned-one","description":"Already here","isArchived":false,"pushedAt":"2026-10-01T00:00:00Z"}]
EOF2
cat >"$T/gh-org.json" <<'EOF2'
[{"nameWithOwner":"orgone/tool","description":"An org tool","isArchived":true,"pushedAt":"2026-09-01T00:00:00Z"}]
EOF2
printf '[{"path_with_namespace":"grp/labrepo","description":"On gitlab","archived":false,"last_activity_at":"2026-10-03T00:00:00Z"}]\n' >"$T/glab.json"
mkgit "$T/job/cloned-one"; git -C "$T/job/cloned-one" remote add origin git@github.com:me/cloned-one.git
printf 'roots = ["%s"]\nclone_dir = "%s"\n' "$T/job" "$T/job" >"$T/config.clone"
export PJ_CONFIG="$T/config.clone"
attach cmain; CP=$LAST_PID
ccl=$(client_of cmain)
: >"$T/log"; rm -rf "$T/cache"/*
FAKE_PICK= FZF_MENU_HERE=1 pjx clone --here --client "$ccl" >/dev/null 2>&1
expect "clone: with no cache the picker opens at once and reloads in the background" bash -c 'grep -q "^fzf-menu .*-p clone .*start:reload(.*_remote-rows --refresh)" "$FAKE_DIR/log"'
out=$(pjx _remote-rows --refresh)
expect "clone: rows from gh (user and org) sorted by push date" bash -c 'printf "%s\n" "$1" | head -1 | grep -q "^c:gh:me/alpha-remote	gh .*me/alpha-remote  Alpha remote" && printf "%s\n" "$1" | grep -q "^c:gh:orgone/tool	.*\[archived\]"' _ "$out"
expect "clone: an origin found in .git/config marks [cloned]" bash -c 'printf "%s\n" "$1" | grep "me/cloned-one" | grep -q "\[cloned\]"' _ "$out"
expect "clone: the cache is 0600 in a 0700 dir" bash -c 'test "$(stat -c %a "$1/cache/remote.json")" = 600 && test "$(stat -c %a "$1/cache")" = 700' _ "$T"
: >"$T/log"; printf 'pick:alpha-remote\npick:dest\n' >"$FAKE_PICKS"
FZF_MENU_HERE=1 pjx clone --here --client "$ccl" >/dev/null 2>&1
expect "clone: a fresh cache means no gh list call and no reload bind" bash -c '! grep -q "^gh repo list" "$FAKE_DIR/log" && ! grep -q "start:reload" "$FAKE_DIR/log"'
expect "clone: the destination prompt starts at clone_dir/name" grep -q -- "--query=$T/job/alpha-remote" "$T/log"
expect "clone: runs gh repo clone OWNER/NAME DEST" grep -q "^gh repo clone me/alpha-remote $T/job/alpha-remote" "$T/log"
expect "clone: the clone is opened like Enter (session, client switched)" wait_for "test \"\$(tmux -L $SOCK list-clients -F '#{client_name} #{client_session}' | awk -v c='$ccl' '\$1 == c { print \$2 }')\" = alpha-remote" 3
expect "clone: the new repo got the default layout" test "$(tm list-windows -t =alpha-remote: -F '#{window_name}' | tr '\n' ' ')" = "code sh ai "
: >"$T/log"; printf 'pick:cloned-one\n' >"$FAKE_PICKS"
FZF_MENU_HERE=1 pjx clone --here --client "$ccl" >/dev/null 2>&1
expect "clone: an already cloned repo is opened instead of cloned" bash -c '! grep -q "^gh repo clone" "$FAKE_DIR/log"' 
expect "clone: ...and its session exists" has_session cloned-one
: >"$T/log"; printf 'pick:orgone/tool\nquery:%s\n' "$T/job/alpha" >"$FAKE_PICKS"
out=$(FZF_MENU_HERE=1 pjx clone --here --client "$ccl" 2>&1)
expect "clone: an existing non-empty destination is refused" bash -c 'printf "%s\n" "$1" | grep -q "exists and is not empty" && ! grep -q "^gh repo clone" "$FAKE_DIR/log"' _ "$out"
touch "$T/gh.loggedout"
out=$(pjx _remote-rows --refresh | head -1)
expect "clone: not logged in = one row that says gh auth login" bash -c 'printf "%s\n" "$1" | grep -q "^login	gh: not logged in, run gh auth login"' _ "$out"
rm -f "$T/gh.loggedout"
# a failing clone is reported
: >"$T/log"; printf 'pick:alpha-remote\nquery:%s\n' "$T/job/never/x" >"$FAKE_PICKS"
mkdir -p "$T/job/never"
cat >"$T/bin-fail-gh" <<'EOF2'
#!/usr/bin/env bash
case "$1 $2" in "repo clone") echo "fatal: could not read from remote" >&2; exit 1 ;; esac
exit 0
EOF2
chmod +x "$T/bin-fail-gh"
rm -rf "$T/job/alpha-remote"; tm kill-session -t =alpha-remote
out=$(FZF_MENU_HERE=1 PJ_GH="$T/bin-fail-gh" pjx clone --here --client "$ccl" 2>&1)
expect "clone: a failing clone is reported (the tool's own output stays visible in the terminal)" bash -c 'printf "%s\n" "$1" | grep -q "fatal: could not read from remote" && printf "%s\n" "$1" | grep -q "clone failed"' _ "$out"
# glab rows when glab exists and is logged in
rm -rf "$T/cache"/*
out=$(PATH="$BIN_GLAB:$BIN:$MIN_PATH" "$PJ" _remote-rows --refresh)
expect "clone: glab rows join when glab is installed and logged in" bash -c 'printf "%s\n" "$1" | grep -q "^c:glab:grp/labrepo	glab .*On gitlab"' _ "$out"
expect "clone: gh and glab missing = a login row, the c key is hidden" bash -c 'PJ_GH=/nonexistent/gh PJ_GLAB=/nonexistent/glab FZF_MENU_HERE=1 FAKE_PICK= PATH="$1:$2" "$3" --here >/dev/null 2>&1; ! grep "^fzf-menu .*-p project" "$4/log" | tail -1 | grep -q "c clone"' _ "$BIN" "$MIN_PATH" "$PJ" "$T"
# L8: glab pages its list (-P 100 -p N, until a short page); a subgroup project is matched by its whole path
python3 -I -c 'import json; print(json.dumps([{"path_with_namespace": f"grp/sub/repo{i}", "description": "", "archived": False, "last_activity_at": f"2026-01-01T00:00:{i % 60:02d}Z"} for i in range(230)]))' >"$T/glab.json"
mkgit "$T/job/repo7"; git -C "$T/job/repo7" remote add origin https://gitlab.com/grp/sub/repo7.git
mkgit "$T/job/repo8"; git -C "$T/job/repo8" remote add origin git@gitlab.com:grp/sub/repo8.git
rm -rf "$T/cache"/*; : >"$T/log"
out=$(PATH="$BIN_GLAB:$BIN:$MIN_PATH" "$PJ" _remote-rows --refresh)
expect "L8: all 230 glab projects are listed (3 pages of 100)" bash -c 'test "$(printf "%s\n" "$1" | grep -c "^c:glab:")" = 230 && test "$(grep -c "^glab repo list" "$FAKE_DIR/log")" = 3 && grep "^glab repo list" "$FAKE_DIR/log" | head -1 | grep -q -- "-P 100 -p 1"' _ "$out"
expect "L8: a subgroup project (grp/sub/repo7, https and ssh origin) is marked [cloned]" bash -c 'printf "%s\n" "$1" | grep "grp/sub/repo7 " | grep -q "\[cloned\]" && printf "%s\n" "$1" | grep "grp/sub/repo8 " | grep -q "\[cloned\]" && ! printf "%s\n" "$1" | grep "grp/sub/repo9 " | grep -q "\[cloned\]"' _ "$out"
export PJ_CONFIG="$T/config.toml"
kill "$CP" 2>/dev/null

}

sec9() {
# ───────────────────────────── 9. modal UI ─────────────────────────────
if ((QUICK)); then
  echo "-- 9. modal UI skipped (--quick)"
else
  echo "-- 9. modal UI"
  for n in ui1 ui2; do mkdir -p "$T/$n"; tm new-session -d -s "$n" -c "$T/$n"; done
  mkdir -p "$T/uibin"
  ln -sf "$BIN/zoxide" "$T/uibin/zoxide"; ln -sf "$BIN/nvim" "$T/uibin/nvim"
  UI=(tmux -L "$UISOCK" -f /dev/null)
  uik() { local x; for x in "$@"; do "${UI[@]}" send-keys -t u "$x"; sleep 0.15; done; }
  uilit() { "${UI[@]}" send-keys -t u -l "$1"; sleep 0.15; }
  uiscreen() { "${UI[@]}" capture-pane -p -J -t u 2>/dev/null; }
  uiwait() { local i; for ((i = 0; i < ${2:-6} * 20; i++)); do uiscreen | grep -Eq "$1" && return 0; sleep 0.05; done; return 1; }
  env_cmd="env -u TMUX HOME='$HOME' XDG_CONFIG_HOME='$XDG_CONFIG_HOME' XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR' TMUX_TMPDIR='$TMUX_TMPDIR' FAKE_DIR='$T' PATH='$T/uibin:$REPO/.local/bin:$REAL_PATH' PJ_CONFIG='$PJ_CONFIG' PJ_STATE_DIR='$PJ_STATE_DIR' PJ_TMUX='$PJ_TMUX' PJ_ZOXIDE='$PJ_ZOXIDE' PJ_HYPR=0 FZF_MENU_NO_SERVER=1 FZF_MENU_HERE=1"
  "${UI[@]}" new-session -d -s u -x 150 -y 40 "bash --noprofile --norc -c \"$env_cmd '$PJ' --here; echo EXIT[\\\$?]; sleep 30\""
  expect "ui: the picker opens with the session rows" uiwait 'ui1' 15
  before=$(sessions)
  uilit "ui"; sleep 0.3
  uik Escape; sleep 0.2
  uik j; sleep 0.2
  uilit d
  expect "ui: NORMAL d kills the selected idle session and the list reopens" wait_for "test \$(tmux -L $SOCK list-sessions -F '#{session_name}' | grep -c '^ui[12]\$') = 1" 8
  uiwait 'project' 5 >/dev/null
  uik Escape; sleep 0.2
  uilit в
  expect "ui: the ua twin of d (в) works" wait_for "test \$(tmux -L $SOCK list-sessions -F '#{session_name}' | grep -c '^ui[12]\$') = 0" 8
  uiwait 'project' 5 >/dev/null
  uik Escape; sleep 0.2; uilit q
  expect "ui: Esc q quits with exit 0" uiwait 'EXIT\[0\]' 6
  expect "ui: nothing but the killed sessions changed" bash -c '! tmux -L "$1" has-session -t =ui1 2>/dev/null && ! tmux -L "$1" has-session -t =ui2 2>/dev/null' _ "$SOCK"
fi

}

sec10() {
# ───────────────────────────── 10. check ─────────────────────────────
echo "-- 10. check"
expect "check: the tmux.conf of the fixture has the session-created hook" grep -q session-created "$T/tmux.conf"
mkdir -p "$T/emptyrepo"
out=$(PJ_REPO="$T/emptyrepo" pjx check); rc=$?
expect "check: config line and repo notice, exit 0" bash -c 'test "$1" = 0 && printf "%s\n" "$2" | grep -q "^PASS  pj: config" && printf "%s\n" "$2" | grep -q "^INFO  pj: repo files not found"' _ "$rc" "$out"
out=$(pjx check); rc=$?
expect "check: on this repo every key wire is PASS (SUPER+P, prefix F, no sessionizer.sh, cli profile)" bash -c 'test "$1" = 0 && for w in "SUPER+P runs pj open" "prefix F opens pj" "sessionizer.sh is gone" "cli profile lists"; do printf "%s\n" "$2" | grep -q "^PASS  pj: .*$w" || exit 1; done' _ "$rc" "$out"
printf 'roots = "nope"\n' >"$T/bad.toml"
out=$(PJ_CONFIG="$T/bad.toml" PJ_REPO="$T/emptyrepo" pjx check); rc=$?
expect "check: a broken config is FAIL and exit 1" bash -c 'test "$1" = 1 && printf "%s\n" "$2" | grep -q "^FAIL  pj: config does not parse"' _ "$rc" "$out"
# L11: the doctor pj-trust line prints one number for an empty trusted.tsv (`grep -c . f || echo 0` printed it twice)
mkdir -p "$T/dstate/pj"; chmod 700 "$T/dstate/pj"; : >"$T/dstate/pj/trusted.tsv"; chmod 600 "$T/dstate/pj/trusted.tsv"
blk=$(sed -n '/^  pj_dir=/,/^else$/p' "$REPO/doctor.sh" | sed '$d')
out=$(XDG_STATE_HOME="$T/dstate" bash -c 'info() { echo "INFO $*"; }; bad() { echo "BAD $*"; }; ok() { echo "OK $*"; }; '"$blk")
expect "L11: doctor pj-trust on an empty trusted.tsv says 0 once" bash -c 'printf "%s\n" "$1" | grep -qx "INFO pj-trust 0 trusted file(s) .*" && test "$(printf "%s\n" "$1" | wc -l)" = 1' _ "$out"
printf 'roots = ["/nonexistent-pj-root"]\n' >"$T/missing.toml"
out=$(PJ_CONFIG="$T/missing.toml" PJ_REPO="$T/emptyrepo" pjx check)
expect "check: a missing root is INFO" bash -c 'printf "%s\n" "$1" | grep -q "^INFO  pj: root /nonexistent-pj-root does not exist"' _ "$out"

}

# ───────────────────────────── 11. hostile names ─────────────────────────────
sec11() {
echo "-- 11. hostile names (#, \$, ;, .)"
mkdir -p "$T/h"
# H1: tmux format-expands -s, -c and -n: a directory called x#(touch $PWN1) must not run a shell command, here or in any window
d1="$T/h/x#(touch\${IFS}\$PWN1)"          # no space: pj turns spaces of a session name into _
mkgit "$d1"
n1=$(pjx create "$d1")
expect "H1: a #() directory gets a session whose name has no #" bash -c 'test -n "$1" && [[ $1 != *"#"* ]] && tmux -L "$2" has-session -t "=$1"' _ "$n1" "$SOCK"
expect "H1: session_path and every pane path are the directory itself" bash -c 'test "$(tmux -L "$1" display-message -p -t "=$2:" "#{session_path}")" = "$3" && test "$(tmux -L "$1" list-panes -s -t "=$2" -F "#{pane_current_path}" | sort -u)" = "$3"' _ "$SOCK" "$n1" "$d1"
expect "H1: @pj_path is the directory and the next create reuses the session" bash -c 'test "$(tmux -L "$1" show-options -v -t "=$2:" @pj_path)" = "$3" && test "$("$4" create "$3")" = "$2"' _ "$SOCK" "$n1" "$d1" "$PJ"
# H1: a trusted layout with a #() dir and an extra pane (new-window -c and split-window -c)
mkgit "$T/job/lh4"; mkdir -p "$T/job/lh4/sub#(touch \$PWN4)"
cat >"$T/job/lh4/.tmux-session.toml" <<'EOF'
[[window]]
name = "one"
dir = "sub#(touch $PWN4)"
command = "echo typed-ok"
[[window.pane]]
command = "echo pane-ok"
split = "below"
EOF
FAKE_PICK="Trust this" pjx create "$T/job/lh4" >/dev/null
expect "H1: a layout window dir with #() reaches new-window and split-window literally" bash -c 'test "$(tmux -L "$1" list-panes -t "=lh4:one" -F "#{pane_current_path}" | sort -u)" = "$2/job/lh4/sub#(touch \$PWN4)"' _ "$SOCK" "$T"
expect "H1: send-keys never expands formats (the typed command ran)" wait_for 'tmux -L "'"$SOCK"'" capture-pane -p -t =lh4:one | grep -q "^typed-ok"' 3
# H1: a worktree directory with #() gets a plain wt-* window without a job
mkgit "$T/job/wr"; git -C "$T/job/wr" worktree add -q "$T/h/wtree#(touch \$PWN3)" -b hostbr3
attach hmain; hcl=$(client_of hmain)
printf 'pick:wr ⎇ hostbr3\n' >"$FAKE_PICKS"
FZF_MENU_HERE=1 PJ_WORKMUX=/nonexistent/workmux pjx --client "$hcl" >/dev/null 2>&1
expect "H1: the wt-* window of a #() worktree works in that directory" wait_for 'test "$(tmux -L "'"$SOCK"'" list-windows -t =wr: -F "#{window_name}#{pane_current_path}" | grep "^wt-")" = "wt-wtree_(touch_\$PWN3)$(printf "%s" "'"$T"'/h/wtree#(touch \$PWN3)")"' 3
# M1: `=$1` is the session ID $1 for tmux: names that start with $ (or @ % ! { ~ -) get a p- prefix and are addressed by id
tm new-session -d -s second -c "$T"
sid=$(tm display-message -p -t '=second:' '#{session_id}')
mkdir -p "$T/h/$sid"
n2=$(pjx create "$T/h/$sid")
expect "M1: a directory named like a session id gets a p- name" test "$n2" = "p-$sid"
expect "M1: @pj_path is on that session, not on the session with that id" bash -c 'test "$(tmux -L "$1" show-options -v -t "=$2:" @pj_path)" = "$3" && test -z "$(tmux -L "$1" show-options -v -t "=second:" @pj_path)"' _ "$SOCK" "$n2" "$T/h/$sid"
pjx kill "$n2" --force >/dev/null
expect "M1: killing it keeps the session with that id" bash -c 'tmux -L "$1" list-sessions -F "#{session_name}" | grep -qx second && ! tmux -L "$1" list-sessions -F "#{session_name}" | grep -qxF "$2"' _ "$SOCK" "$n2"
tm new-session -d -s third -c "$T"
tid=$(tm display-message -p -t '=third:' '#{session_id}')
tm new-session -d -s "$tid" -c "$T"           # a session whose NAME is the id of `third`
pjx kill "$tid" --force >/dev/null
expect "M1: pj kill '\$N' kills the session named \$N, not the one with that id" bash -c 'tmux -L "$1" list-sessions -F "#{session_name}" | grep -qx third && ! tmux -L "$1" list-sessions -F "#{session_name}" | grep -qxF "$2"' _ "$SOCK" "$tid"
out=$(pjx kill "$tid" --force)
expect "M1: pj kill '\$N' with no such name does not hit the session with that id" bash -c 'printf "%s\n" "$1" | grep -q "no session" && tmux -L "$2" list-sessions -F "#{session_name}" | grep -qx third' _ "$out" "$SOCK"
# L2: a window name with a dot (`-t =S:=a.1` is window a, pane 1) is refused; L2: a chain that fails half way takes its session with it
mkgit "$T/job/ld"
printf '[[window]]\nname = "a.1"\n[[window.pane]]\ncommand = "echo x"\n' >"$T/job/ld/.tmux-session.toml"
out=$(FAKE_PICK="Trust this" pjx create "$T/job/ld" 2>&1); rc=$?
expect "L2: a window name with a dot is refused (nothing created)" bash -c 'test "$1" != 0 && printf "%s\n" "$2" | grep -q "A-Za-z0-9_-" && ! tmux -L "$3" list-sessions -F "#{session_name}" | grep -qx ld' _ "$rc" "$out" "$SOCK"
mkgit "$T/job/lh5"
printf '[[window]]\nname = "main"\n[[window.pane]]\ncommand = "echo x"\n' >"$T/job/lh5/.tmux-session.toml"
# a tmux that fails at run time half way: the split-window of the chain gets a window that does not exist
cat >"$T/failsplit" <<EOF2
#!/bin/sh
n=\$#; i=0
while [ \$i -lt \$n ]; do a=\$1; shift; case \$a in *:=main) a=\${a%=main}=nowin ;; esac; set -- "\$@" "\$a"; i=\$((i + 1)); done
exec tmux -L $SOCK -f $T/tmux.conf "\$@"
EOF2
chmod +x "$T/failsplit"
out=$(FAKE_PICK="Trust this" PJ_TMUX="$T/failsplit" pjx create "$T/job/lh5" 2>&1); rc=$?
expect "L2: a failing chain exits non-zero and leaves no half-built session" bash -c 'test "$1" != 0 && printf "%s\n" "$2" | grep -q "nowin" && ! tmux -L "$3" list-sessions -F "#{session_name}" | grep -qx lh5' _ "$rc" "$out" "$SOCK"
expect "L2: the next create builds the whole session (no reuse of a stump)" bash -c 'FAKE_PICK="Trust this" "$1" create "$2/job/lh5" >/dev/null && test "$(tmux -L "$3" list-panes -t =lh5:main | wc -l)" = 2' _ "$PJ" "$T" "$SOCK"
# L3: tmux ends a command at an argument that ends with ';'
mkdir -p "$T/h/semi;"
n3=$(pjx create "$T/h/semi;" 2>&1)
expect "L3: a directory ending in ; gets a session with that name, path and @pj_path" bash -c 'tmux -L "$1" list-sessions -F "#{session_name}|#{session_path}|#{@pj_path}" | grep -qxF "semi;|$2/h/semi;|$2/h/semi;"' _ "$SOCK" "$T"
mkgit "$T/job/lh6"
printf '[[window]]\nname = "main"\ncommand = "echo ok-semi;"\n' >"$T/job/lh6/.tmux-session.toml"
FAKE_PICK="Trust this" pjx create "$T/job/lh6" >/dev/null
expect "L3: a trusted command ending in ; is typed with its ;" wait_for 'tmux -L "'"$SOCK"'" capture-pane -p -t =lh6:main | grep -q "echo ok-semi;$"' 3
# L6: pj's messages (names, the last line of workmux output) are shown literally by tmux, not format-expanded
touch "$T/workmux.fail"
printf 'pick:wr ⎇ hostbr3\n' >"$FAKE_PICKS"
tm kill-window -t '=wr:wt-wtree_(touch_$PWN3)' 2>/dev/null
WORKMUX_FAIL_TEXT='boom #{session_name} #(touch $PWN2)' FZF_MENU_HERE=1 pjx --client "$hcl" >/dev/null 2>&1
rm -f "$T/workmux.fail"
expect "L6: a message with #{session_name} is displayed as typed" bash -c 'tmux -L "$1" show-messages -t "$2" | grep -qF "boom #{session_name} #(touch \$PWN2)"' _ "$SOCK" "$hcl"
sleep 0.3
for f in 1 2 3 4; do expect "no tmux job ran for PWN$f" bash -c 'test ! -e "$1/pwn$2"' _ "$T" "$f"; done
}

# ───────────────────────────── 12. pj inside a term-* pane, background jobs ─────────────────────────────
sec12() {
echo "-- 12. pj inside a term-* pane, background and stopped jobs"
mkgit "$T/job/m2dir"
# M2: Ctrl+X p / `pj` typed in a SUPER+Return terminal (what the zsh widget runs: `pj --here`, plain `tmux` and $TMUX of the
# pane): pj is the foreground job of that pane and must not count as work
attach term-self; cself=$(client_of term-self)
printf 'pick:job/m2dir\n' >"$FAKE_PICKS"
tm send-keys -t =term-self: "PATH='$BIN:$MIN_PATH' PJ_TMUX= $PJ --here" Enter
expect "M2: pj run in an idle term-* pane switches the client" wait_for "test \"\$(tmux -L $SOCK list-clients -F '#{client_name} #{client_session}' | awk -v c='$cself' '\$1 == c { print \$2 }')\" = m2dir" 5
expect "M2: ...and the idle term-* session is gone (it did not leak as a detached leftover)" wait_for "! tmux -L $SOCK has-session -t =term-self" 3
# the same with a background job: the session must stay (destroy-unattached off), the message names the job
mkgit "$T/job/m2dir2"
attach term-bg; cbg=$(client_of term-bg)
tm send-keys -t =term-bg: 'sleep 305 &' Enter
expect "L1: the shell of term-bg has a background job" wait_for "pgrep -f '^sleep 305$'" 5
tm send-keys -t =term-bg: "PJ_TMUX= $PJ --client '$cbg' '$T/job/m2dir2' 2>$T/m2.err" Enter
expect "L1: a term-* with a background job survives the switch away (destroy-unattached off)" bash -c 'sleep 0.5; tmux -L "$1" has-session -t =term-bg && test "$(tmux -L "$1" list-sessions -F "#{session_name} #{destroy-unattached}" | awk "\$1 == \"term-bg\" { print \$2 }")" = off' _ "$SOCK"
expect "L1: the picker shows it first, with the job" bash -c '"$1" rows | head -1 | grep -q "^s:term-bg	.*running: sleep"' _ "$PJ"
# a stopped job (Ctrl+Z) counts too
attach term-stop; cstop=$(client_of term-stop)
tm send-keys -t =term-stop: 'sleep 306' Enter
wait_for "tmux -L $SOCK list-panes -t =term-stop -F '#{pane_current_command}' | grep -q sleep" 5
tm send-keys -t =term-stop: C-z
expect "L1: the shell of term-stop is back at its prompt with a stopped job" wait_for "tmux -L $SOCK list-panes -t =term-stop -F '#{pane_current_command}' | grep -qx sh" 5
mkgit "$T/job/m2dir3"
pjx --client "$cstop" "$T/job/m2dir3" >/dev/null 2>&1
expect "L1: a term-* with a stopped job survives the switch away" bash -c 'sleep 0.4; tmux -L "$1" has-session -t =term-stop' _ "$SOCK"
# a process that forked away from the shell (what wl-copy does to keep the clipboard) is not a job of the terminal
attach term-orph; corph=$(client_of term-orph)
tm send-keys -t =term-orph: '(sleep 308 &)' Enter
expect "L1: the shell of term-orph has an orphaned process on its terminal" wait_for "pgrep -f '^sleep 308\$'" 5
settle term-orph
mkgit "$T/job/m2dir4"
pjx --client "$corph" "$T/job/m2dir4" >/dev/null 2>&1
expect "L1: ...which does not keep the idle term-* alive when the client leaves" wait_for "! tmux -L $SOCK has-session -t =term-orph" 3
pkill -KILL -f '^sleep 308$' 2>/dev/null
# kill: a detached project session whose shell has a background job asks first
mkgit "$T/job/kb"; pjx create "$T/job/kb" >/dev/null
tm send-keys -t '=kb:sh' 'sleep 307 &' Enter
wait_for "pgrep -f '^sleep 307$'" 5
: >"$T/log"
FAKE_PICK="No" pjx kill kb >/dev/null
expect "L1: pj kill asks when a background job runs" bash -c 'grep -q "running: sleep" "$FAKE_DIR/log" && tmux -L "$1" has-session -t =kb' _ "$SOCK"
FAKE_PICK="Yes" pjx kill kb >/dev/null
expect "L1: ...and kills it on Yes" bash -c '! tmux -L "$1" has-session -t =kb' _ "$SOCK"
pkill -KILL -f '^sleep 30[5-8]$' 2>/dev/null     # the jobs of the shells above outlive their terminals (orphans)
}

# ───────────────────────────── 13. workmux and .workmux.yaml trust, branch picker ─────────────────────────────
sec13() {
echo "-- 13. workmux: .workmux.yaml trust, branch picker"
attach wtmain; wtcl=$(client_of wtmain)
mkgit "$T/job/wmt"
printf 'post_create: touch %s/hook-ran\n' "$T" >"$T/job/wmt/.workmux.yaml"
wmt_key="$T/job/wmt/.workmux.yaml"
# w with an untrusted .workmux.yaml: asks first; "no" = workmux is not run, no session, no hook
printf 'pick:wmt\npick:Do not run\n' >"$FAKE_PICKS"; : >"$T/log"
FZF_MENU_HERE=1 pjx --client "$wtcl" open --task >/dev/null 2>&1
expect "M3: w on a repo with an untrusted .workmux.yaml asks, and the prompt shows the file" bash -c 'grep -q "fzf-menu .*-p workmux" "$FAKE_DIR/log" && grep -q "post_create: touch" "$FAKE_DIR/log"'
expect "M3: answering no: workmux is not run, its hook did not run, no session was made" bash -c '! grep -q "^workmux" "$FAKE_DIR/log" && test ! -e "$1/hook-ran" && ! tmux -L "$2" has-session -t =wmt' _ "$T" "$SOCK"
expect "M3: ...and the picker says why (header of the reopened list)" grep -q "not trusted, workmux was not run" "$T/log"
# yes: the hook runs, the key <repo>/.workmux.yaml is stored with the sha256
: >"$T/log"; printf 'pick:wmt\npick:Trust this version\nquery:feat-t\n' >"$FAKE_PICKS"
FZF_MENU_HERE=1 pjx --client "$wtcl" open --task >/dev/null 2>&1
expect "M3: after trusting, workmux add runs and its post_create hook runs" bash -c 'grep -q "^workmux add feat-t " "$FAKE_DIR/log" && test -e "$1/hook-ran"' _ "$T"
expect "M3: trusted.tsv holds <repo>/.workmux.yaml with the sha256 (0600)" bash -c 'grep -q "^$1	[0-9a-f]\{64\}$" "$2/state/trusted.tsv" && test "$(stat -c %a "$2/state/trusted.tsv")" = 600' _ "$wmt_key" "$T"
rm -f "$T/hook-ran"; : >"$T/log"; printf 'pick:wmt\nquery:feat-u\n' >"$FAKE_PICKS"
FZF_MENU_HERE=1 pjx --client "$wtcl" open --task >/dev/null 2>&1
expect "M3: a trusted file is not asked about again" bash -c '! grep -q "fzf-menu .*-p workmux" "$FAKE_DIR/log" && grep -q "^workmux add feat-u " "$FAKE_DIR/log"'
# a changed file is untrusted again
echo 'post_create: touch '"$T"'/hook-changed' >"$T/job/wmt/.workmux.yaml"; rm -f "$T/hook-ran"
: >"$T/log"; printf 'pick:wmt\npick:Do not run\n' >"$FAKE_PICKS"
FZF_MENU_HERE=1 pjx --client "$wtcl" open --task >/dev/null 2>&1
expect "M3: a changed .workmux.yaml asks again and is not run" bash -c 'grep -q "fzf-menu .*-p workmux" "$FAKE_DIR/log" && ! grep -q "^workmux" "$FAKE_DIR/log" && test ! -e "$1/hook-changed"' _ "$T"
# Enter on a worktree row runs `workmux open`, which reads the same file: untrusted = a plain wt-* window instead
git -C "$T/job/wmt" worktree add -q "$T/wt/wmt/f1" -b f1
tm kill-session -t =wmt 2>/dev/null
: >"$T/log"; printf 'pick:wmt ⎇ f1\npick:Do not run\n' >"$FAKE_PICKS"
FZF_MENU_HERE=1 pjx --client "$wtcl" >/dev/null 2>&1
expect "M3: Enter on a worktree with an untrusted .workmux.yaml: no workmux, a plain wt-f1 window" bash -c '! grep -q "^workmux" "$FAKE_DIR/log" && test ! -e "$1/hook-changed" && tmux -L "$2" list-windows -t =wmt: -F "#{window_name}" | grep -qx wt-f1' _ "$T" "$SOCK"
# t / pj trust covers the file too; --dry-run asks nothing and writes nothing (L13)
mkgit "$T/job/wmd"; printf 'post_create: true\n' >"$T/job/wmd/.workmux.yaml"
printf '[[window]]\nname = "x"\n' >"$T/job/wmd/.tmux-session.toml"
before=$(cat "$T/state/trusted.tsv" 2>/dev/null)
out=$(FAKE_PICK="Trust this" pjx --dry-run trust "$T/job/wmd" 2>&1)
expect "L13: pj --dry-run trust writes nothing and says what it would ask" bash -c 'test "$(cat "$1/state/trusted.tsv" 2>/dev/null)" = "$2" && printf "%s\n" "$3" | grep -q "would ask" && printf "%s\n" "$3" | grep -q "workmux.yaml"' _ "$T" "$before" "$out"
out=$(FAKE_PICK="Trust this" pjx trust "$T/job/wmd" 2>&1)
expect "M3: pj trust DIR trusts the layout file and the .workmux.yaml" bash -c 'grep -q "^$1/job/wmd	" "$1/state/trusted.tsv" && grep -q "^$1/job/wmd/.workmux.yaml	" "$1/state/trusted.tsv"' _ "$T"
expect "M3: the preview says whether .workmux.yaml is trusted" bash -c '"$1" _preview "r:$2/job/wmd" | grep -q "workmux: .workmux.yaml trusted" && "$1" _preview "r:$2/job/wmt" | grep -q "workmux: .workmux.yaml NOT trusted"' _ "$PJ" "$T"
# L10: the branch is picked BEFORE the session is made: a cancel leaves nothing; Alt+Enter uses the typed name as it is
mkgit "$T/job/wmc"; git -C "$T/job/wmc" branch spare
: >"$T/log"; printf 'pick:wmc\n\n' >"$FAKE_PICKS"
FZF_MENU_HERE=1 pjx --client "$wtcl" open --task >/dev/null 2>&1
expect "L10: cancelling the branch picker leaves no project session behind" bash -c '! tmux -L "$1" has-session -t =wmc && ! grep -q "^workmux" "$FAKE_DIR/log"' _ "$SOCK"
: >"$T/log"; printf 'pick:wmc\nqt:spa:alt-enter:spare\n' >"$FAKE_PICKS"
FZF_MENU_HERE=1 pjx --client "$wtcl" open --task >/dev/null 2>&1
expect "L10: Alt+Enter on a typed name uses it, not the fuzzy match (spa, not spare)" grep -q "^workmux add spa --parent-session wmc -b" "$T/log"
tm kill-window -t '=wmc:wm-spa' 2>/dev/null
: >"$T/log"; printf 'pick:wmc\nqt:spa::spare\n' >"$FAKE_PICKS"
FZF_MENU_HERE=1 pjx --client "$wtcl" open --task >/dev/null 2>&1
expect "L10: plain Enter still picks the highlighted branch" grep -q "^workmux add spare --parent-session wmc -b" "$T/log"
expect "L10: the branch picker offers Alt+Enter in its header" grep -q "Alt+Enter: use the typed name" "$T/log"
# a branch with a slash: the real workmux 0.1.276 names the window after its last part (feat/x -> wm-x)
: >"$T/log"; printf 'pick:wmc\nquery:feat/x\n' >"$FAKE_PICKS"
FZF_MENU_HERE=1 pjx --client "$wtcl" open --task >/dev/null 2>&1
expect "L12: feat/x creates wm-x and the client follows" wait_for "test \"\$(tmux -L $SOCK display-message -p -t =wmc: '#{window_name}')\" = wm-x" 3
}

# ───────────────────────────── 14. layout file: read once, shown whole, zsh as the shell ─────────────────────────────
sec14() {
echo "-- 14. layout file: one read, what is shown is what runs; zsh as default-shell"
# L5: a symlink is not followed, a FIFO is not read, a big file is refused (the sha256 and the parse use the same bytes)
mkgit "$T/lf1"; printf '[[window]]\nname = "a"\n' >"$T/lf1-real.toml"; ln -s "$T/lf1-real.toml" "$T/lf1/.tmux-session.toml"
out=$(pjx layout "$T/lf1" 2>&1 | head -1)
expect "L5: a symlinked .tmux-session.toml is invalid (not followed)" bash -c 'printf "%s\n" "$1" | grep -q "invalid.*symlink"' _ "$out"
mkgit "$T/lf2"; mkfifo "$T/lf2/.tmux-session.toml"
out=$(timeout 5 "$PJ" layout "$T/lf2" 2>&1 | head -1)
expect "L5: a FIFO as .tmux-session.toml is invalid and does not hang" bash -c 'printf "%s\n" "$1" | grep -q "invalid.*not a regular file"' _ "$out"
mkgit "$T/lf3"; { printf '[[window]]\nname = "a"\n# '; head -c 70000 /dev/zero | tr '\0' x; echo; } >"$T/lf3/.tmux-session.toml"
out=$(pjx layout "$T/lf3" 2>&1 | head -1)
expect "L5: a file over 64 KiB is refused" bash -c 'printf "%s\n" "$1" | grep -q "invalid.*larger than 64 KiB"' _ "$out"
# L4: the trust prompt shows every command whole: long lines wrap, invisible characters are spelled out, long or space-hidden commands are refused
mkgit "$T/lf4"
long="echo $(printf 'word%.0s ' $(seq 1 30))END"
printf '[[window]]\nname = "a"\ncommand = "%s"\n' "$long" >"$T/lf4/.tmux-session.toml"
: >"$T/log"; FAKE_PICK= pjx create "$T/lf4" >/dev/null 2>&1
expect "L4: a long command is wrapped in the prompt header (no line over 110 characters, the tail END is shown)" bash -c 'awk "/^fzf-menu .*-p layout/ { on = 1 } on && /^  row:/ { on = 0 } on { sub(/ --preview=.*/, \"\"); if (length(\$0) > 110) bad = 1; n++ } END { exit bad || n < 3 }" "$FAKE_DIR/log" && grep -q "END" "$FAKE_DIR/log"'
mkgit "$T/lf5"
printf '[[window]]\nname = "a"\ncommand = "echo safe\xe2\x80\xae evil"\n' >"$T/lf5/.tmux-session.toml"
: >"$T/log"; FAKE_PICK= pjx create "$T/lf5" >/dev/null 2>&1
expect "L4: a right-to-left override in a command is shown as <U+202E>" grep -q "<U+202E>" "$T/log"
out=$(FAKE_PICK= pjx trust "$T/lf5" 2>&1)
expect "L4: pj trust prints it spelled out too" bash -c 'printf "%s\n" "$1" | grep -q "runs: echo safe<U+202E> evil"' _ "$out"
mkgit "$T/lf6"; printf '[[window]]\nname = "a"\ncommand = "echo %s"\n' "$(printf 'x%.0s' $(seq 1 250))" >"$T/lf6/.tmux-session.toml"
out=$(pjx layout "$T/lf6" 2>&1 | head -1)
expect "L4: a command over 200 characters is refused" bash -c 'printf "%s\n" "$1" | grep -q "invalid.*200 characters"' _ "$out"
mkgit "$T/lf7"; printf '[[window]]\nname = "a"\ncommand = "nvim            ; touch evil"\n' >"$T/lf7/.tmux-session.toml"
out=$(pjx layout "$T/lf7" 2>&1 | head -1)
expect "L4: a command that hides text behind a run of spaces is refused" bash -c 'printf "%s\n" "$1" | grep -q "invalid.*spaces"' _ "$out"
# L12: keys typed before the shell has drawn its prompt (zsh reads them after its startup files)
if command -v zsh >/dev/null; then
  printf '#!/bin/sh\nexec zsh -f "$@"\n' >"$T/zshf"; chmod +x "$T/zshf"
  mkgit "$T/lz"; printf '[[window]]\nname = "z"\ncommand = "print -r -- zsh-sees-$((6*7))"\n[[window.pane]]\ncommand = "print -r -- pane-sees-$((7*7))"\n' >"$T/lz/.tmux-session.toml"
  tm set -g default-shell "$T/zshf"
  FAKE_PICK="Trust this" pjx create "$T/lz" >/dev/null
  expect "L12: zsh as default-shell: the typed command ran after the prompt came up (output, not only the typed text)" wait_for 'tmux -L "'"$SOCK"'" capture-pane -p -t =lz:z.0 | grep -q "^zsh-sees-42"' 8
  expect "L12: ...and so did the command of the extra pane" wait_for 'tmux -L "'"$SOCK"'" capture-pane -p -t =lz:z.1 | grep -q "^pane-sees-49"' 8
  tm set -g default-shell /bin/sh
fi
}

# ───────────────────────────── 15. rows: worktree cap, scratch worktrees, walk budget ─────────────────────────────
sec15() {
echo "-- 15. rows: worktree cap, scratch worktrees in the temp dir, walk budget"
# L7: per repo the newest 3 worktrees (HEAD mtime of .git/worktrees/N) and one "+N worktrees" row
mkgit "$T/job/capr"
for i in 1 2 3 4 5; do git -C "$T/job/capr" worktree add -q "$T/wt/capr/w$i" -b "w$i"; touch -d "2020-01-0$i" "$T/job/capr/.git/worktrees/w$i/HEAD"; done
rows=$(pjx rows)
expect "L7: only the newest 3 worktrees of a repo are listed (w5 w4 w3 in that order)" bash -c 'printf "%s\n" "$1" | grep "^w:$2/wt/capr/" | cut -f1 | tr "\n" " " | grep -qx "w:$2/wt/capr/w5 w:$2/wt/capr/w4 w:$2/wt/capr/w3 "' _ "$rows" "$T"
expect "L7: a +2 worktrees row follows them" bash -c 'printf "%s\n" "$1" | grep -A4 "^r:$2/job/capr	" | grep -q "^m:$2/job/capr	.*+2 worktrees"' _ "$rows" "$T"
expect "L7: a repo with 3 worktrees or fewer has no such row" bash -c '! printf "%s\n" "$1" | grep "^m:" | grep -vq "capr"' _ "$rows"
# Enter on that row shows them all (the picker reopens with the repo expanded)
: >"$T/log"; printf 'pick:+2 worktrees\n' >"$FAKE_PICKS"
FZF_MENU_HERE=1 pjx --here >/dev/null 2>&1
expect "L7: Enter on the +N row reopens the list with all 5 worktrees and no +N row" bash -c 'awk "/^fzf-menu .*-p project/ { n++ } n == 2 && /^  row: w:.*capr\\/w[0-9]/ { w++ } n == 2 && /^  row: m:/ { m++ } END { exit !(w == 5 && !m) }" "$FAKE_DIR/log"' _
# L7: a worktree in the temp dir of a repo that lives elsewhere is an agent's scratch checkout: not listed
mkdir -p "$T/scratch"; git -C "$T/job/capr" worktree add -q "$T/scratch/agent-wt" -b agentbr
touch -d "2030-01-01" "$T/job/capr/.git/worktrees/agent-wt/HEAD" 2>/dev/null
rows=$(TMPDIR="$T/scratch" pjx rows)
expect "L7: a worktree under \$TMPDIR of a repo outside it is skipped" bash -c '! printf "%s\n" "$1" | grep -q "agent-wt"' _ "$rows"
rows=$(pjx rows)
expect "L7: ...but listed when the repo lives in the temp dir itself (the default of this fixture)" bash -c 'printf "%s\n" "$1" | grep -q "agent-wt"' _ "$rows"
expect "L7: the scratch worktree's branch still counts as used (the branch picker does not offer it)" bash -c 'printf "pick:capr\nquery:zzz\n" >"$1/picks"; : >"$1/log"; TMPDIR="$1/scratch" FZF_MENU_HERE=1 "$2" open --task >/dev/null 2>&1; ! grep -A12 "^fzf-menu .*-p branch" "$1/log" | grep -q "row: agentbr"' _ "$T" "$PJ"
# L9: the walk has a budget; a cut walk is completed from the last complete one (~/.cache/pj/repos.txt)
rm -rf "$T/cache"; full=$(pjx rows)
expect "L9: a complete walk writes ~/.cache/pj/repos.txt (0600, dir 0700)" bash -c 'test "$(stat -c %a "$1/cache/repos.txt")" = 600 && test "$(stat -c %a "$1/cache")" = 700 && grep -q "job/alpha" "$1/cache/repos.txt"' _ "$T"
cut=$(PJ_WALK_ENTRIES=3 pjx rows)
expect "L9: a walk that runs out of budget lists the same repos (from the cache)" test "$cut" = "$full"
mkgit "$T/job/newrepo"; rm -rf "$T/job/beta/gamma"
cut=$(PJ_WALK_ENTRIES=3 pjx rows)
expect "L9: a cut walk drops a repo that is gone and does not find a new one until the next complete walk" bash -c '! printf "%s\n" "$1" | grep -q "beta/gamma	" && ! printf "%s\n" "$1" | grep -q "job/newrepo	" && printf "%s\n" "$1" | grep -q "job/alpha	"' _ "$cut"
full=$(pjx rows)
expect "L9: a complete walk finds it and refreshes the cache" bash -c 'printf "%s\n" "$1" | grep -q "job/newrepo	" && grep -q "job/newrepo" "$2/cache/repos.txt" && ! grep -q "beta/gamma" "$2/cache/repos.txt"' _ "$full" "$T"
}

# ───────────────────────────── 16. zsh widget ─────────────────────────────
sec16() {
echo "-- 16. zsh widget (Ctrl+X p, NORMAL gp, and their ua/ru twins) in a real interactive zsh"
if ! command -v zsh >/dev/null; then echo "SKIP  zsh missing"; return; fi
mkdir -p "$T/zw/bin" "$T/zw/zd"
printf '#!/bin/sh\nprintf "pj %%s tty=%%s\\n" "$*" "$([ -t 0 ] && echo yes || echo no)" >>"$FAKE_DIR/zlog"\n' >"$T/zw/bin/pj"; chmod +x "$T/zw/bin/pj"
cat >"$T/zw/zd/.zshrc" <<EOF
export PATH=$T/zw/bin:$REAL_PATH
bindkey -v; KEYTIMEOUT=1
PROMPT='ready%# '
source $XDG_CONFIG_HOME/layout/layout-keys.sh 2>/dev/null
source $XDG_CONFIG_HOME/zsh/layout-keys.zsh
source $XDG_CONFIG_HOME/zsh/vi-mode.zsh
EOF
ZW=(tmux -L "$ZSOCK" -f /dev/null)
"${ZW[@]}" new-session -d -s w -x 100 -y 20 "env ZDOTDIR=$T/zw/zd FAKE_DIR=$T zsh -i; sleep 20"
zscreen() { "${ZW[@]}" capture-pane -p -t w; }
zcount() { grep -c "^pj --here tty=yes$" "$T/zlog" 2>/dev/null; }
zwait() { local i; for ((i = 0; i < 100; i++)); do [ "$(zcount)" = "$1" ] && return 0; sleep 0.05; done; return 1; }
expect "zsh: the interactive shell came up with the widget file sourced" wait_for "tmux -L $ZSOCK capture-pane -p -t w | grep -q 'ready%'" 5
"${ZW[@]}" send-keys C-x p
expect "zsh: Ctrl+X p runs 'pj --here' with the terminal as stdin" zwait 1
"${ZW[@]}" send-keys Escape; sleep 0.15; "${ZW[@]}" send-keys g p
expect "zsh: NORMAL gp runs it" zwait 2
"${ZW[@]}" send-keys i; sleep 0.1                # back to INSERT (the widget leaves the shell in NORMAL)
"${ZW[@]}" send-keys C-x з
expect "zsh: the ua/ru twin of Ctrl+X p (Ctrl+X з) runs it" zwait 3
"${ZW[@]}" send-keys Escape; sleep 0.15; "${ZW[@]}" send-keys п з
expect "zsh: the twin of gp (п з) runs it" zwait 4
"${ZW[@]}" send-keys i; sleep 0.1; "${ZW[@]}" send-keys -l 'echo alive-$((20+22))'; "${ZW[@]}" send-keys Enter
expect "zsh: the shell is back at its prompt after the widget (it works on)" wait_for "tmux -L $ZSOCK capture-pane -p -t w | grep -q '^alive-42'" 5
}

# ───────────────────────────── run ─────────────────────────────
setup
sec"$ONLY"
echo "pj: $passes passed, $fails failed"
[ "$fails" = 0 ]
