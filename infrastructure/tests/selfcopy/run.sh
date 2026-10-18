#!/usr/bin/env bash
# Test of the private-copy header of doctor.sh and apply-system.sh (the "immune to concurrent edits" block): the copy must not be
# left behind after Ctrl+C / SIGTERM (it was: the parent died before its rm), and as root the copy never goes to $TMPDIR.
# The header is cut out of the real files and run with a body that only sleeps, so nothing of doctor or apply-system runs.
#   run.sh
set -u
export PYTHONDONTWRITEBYTECODE=1   # python3 -I ignores PYTHON* variables (hence -B there); this covers the other interpreters: no __pycache__ in the repo
unset DOCTOR_SELF APPLY_SYSTEM_SELF   # doctor runs this test with DOCTOR_SELF exported, which would skip the copy under test
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/selfcopy-test.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
PASS=0 FAILS=0
check() { local name=$1; shift; if "$@"; then PASS=$((PASS + 1)); printf 'ok    %s\n' "$name"; else FAILS=$((FAILS + 1)); printf 'FAIL  %s\n' "$name"; fi; }

# header NAME PREAMBLE: the block from "# Immune to concurrent edits" to its closing `fi`, as a runnable script
make_script() { # FILE PREAMBLE
  local file=$1 pre=$2 src=$3
  {
    printf '#!/usr/bin/env bash\n%s\n' "$pre"
    awk '/^# Immune to concurrent edits/ {on=1} on {print} on && /^fi$/ {exit}' "$src"
    printf 'echo "body ran from $0" >>"$SELFCOPY_LOG"\nsleep "${SELFCOPY_SLEEP:-0}"\nexit 7\n'
  } >"$file"
  chmod +x "$file"
}
mkdir -p "$SCRATCH/s"
make_script "$SCRATCH/s/doctor.sh" 'set -u' "$REPO/doctor.sh"
make_script "$SCRATCH/s/apply-system.sh" 'set -euo pipefail' "$REPO/apply-system.sh"
check "the header was found in both scripts" bash -c '[ "$(grep -c "mktemp -d" "$1/doctor.sh")" = 1 ] && [ "$(grep -c "mktemp -d" "$1/apply-system.sh")" = 1 ]' _ "$SCRATCH/s"

# run SCRIPT SIGNAL: start it in its own process group, wait for the private copy, send the signal to the group (what the
# terminal does for Ctrl+C), print "rc=<returncode> leftovers=<n>"
runsig() {
  python3 -I -B - "$1" "$2" "$SCRATCH/tmp" "$SCRATCH/log" <<'PY'
import glob, os, signal, subprocess, sys, time
script, sig, tmp, log = sys.argv[1], getattr(signal, sys.argv[2]), sys.argv[3], sys.argv[4]
os.makedirs(tmp, exist_ok=True)
env = dict(os.environ, TMPDIR=tmp, SELFCOPY_LOG=log, SELFCOPY_SLEEP="30")
p = subprocess.Popen(["bash", script], env=env, start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(100):
    if glob.glob(tmp + "/*/*.sh") and os.path.exists(log):
        break
    time.sleep(0.05)
time.sleep(0.3)   # the wrapper is in its wait loop
os.killpg(p.pid, sig)
try:
    rc = p.wait(10)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL); rc = "hung"
time.sleep(0.2)
print(f"rc={rc} leftovers={len(os.listdir(tmp))} copy_was_used={os.path.exists(log)}")
PY
}
# runone SCRIPT SIGNAL: the signal goes to the WRAPPER process only (not the group): kill from outside, a closing terminal.
# Prints "rc=<returncode> secs=<n> leftovers=<n> copy_alive=<0|1>" (the copy's own pid is read from the log it writes)
runone() {
  python3 -I -B - "$1" "$2" "$SCRATCH/tmp" "$SCRATCH/log" <<'PY'
import glob, os, signal, subprocess, sys, time
script, sig, tmp, log = sys.argv[1], getattr(signal, sys.argv[2]), sys.argv[3], sys.argv[4]
os.makedirs(tmp, exist_ok=True)
env = dict(os.environ, TMPDIR=tmp, SELFCOPY_LOG=log, SELFCOPY_SLEEP="30")
p = subprocess.Popen(["bash", script], env=env, start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(100):
    if glob.glob(tmp + "/*/*.sh") and os.path.exists(log):
        break
    time.sleep(0.05)
time.sleep(0.3)   # the wrapper has assigned the copy's pid and is in its wait loop (under load the copy can write its log first)
kids = subprocess.run(["pgrep", "-P", str(p.pid)], capture_output=True, text=True).stdout.split()
t = time.time()
os.kill(p.pid, sig)
try:
    rc = p.wait(8)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL); rc = "hung"
secs = round(time.time() - t)
time.sleep(0.3)
alive = int(any(os.path.exists(f"/proc/{k}") and b"Z" != open(f"/proc/{k}/stat").read().split(")")[-1].split()[0].encode() for k in kids))
print(f"rc={rc} secs={secs} leftovers={len(os.listdir(tmp))} copy_alive={alive}")
PY
}
# runrace SCRIPT: a signal that arrives BEFORE the wrapper knows the copy's pid (between the fork and `_dpid=$!`). Deterministic: a DEBUG
# trap in $BASH_ENV sends SIGTERM to the wrapper just before it runs that assignment (the trap handler then runs first). The old
# wrapper stored the signal but could not forward it and waited for the copy (30 s). Prints "rc=<rc> secs=<n> leftovers=<n>".
runrace() {
  cat >"$SCRATCH/race.env" <<'RACE'
trap 'case "$BASH_COMMAND" in "_dpid=\$!"|"_apid=\$!") kill -TERM $$ ;; esac' DEBUG
RACE
  python3 -I -B - "$1" "$SCRATCH/tmp" "$SCRATCH/log" "$SCRATCH/race.env" <<'PY'
import os, signal, subprocess, sys, time
script, tmp, log, benv = sys.argv[1:5]
os.makedirs(tmp, exist_ok=True)
env = dict(os.environ, TMPDIR=tmp, SELFCOPY_LOG=log, SELFCOPY_SLEEP="30", BASH_ENV=benv)
t = time.time()
p = subprocess.Popen(["bash", script], env=env, start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    rc = p.wait(8)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL); rc = "hung"
time.sleep(0.3)
print(f"rc={rc} secs={round(time.time() - t)} leftovers={len(os.listdir(tmp))}")
PY
}
for s in doctor.sh apply-system.sh; do
  rm -rf "$SCRATCH/tmp" "$SCRATCH/log"
  out=$(runrace "$SCRATCH/s/$s")
  check "$s: a SIGTERM that arrives before the copy's pid is known is forwarded after all (old code: waited for the copy; got: $out)" bash -c 'grep -q "secs=[0-4] leftovers=0" <<<"$1" && grep -qE "rc=-15 " <<<"$1"' _ "$out"
done
for s in doctor.sh apply-system.sh; do
  for sig in SIGTERM SIGHUP; do   # (SIGINT alone: a bash copy waiting for a foreground child only exits after it; Ctrl+C reaches both, see below)
    rm -rf "$SCRATCH/tmp" "$SCRATCH/log"
    out=$(runone "$SCRATCH/s/$s" "$sig")
    check "$s: $sig sent to the wrapper alone is forwarded to the copy, ends the run at once, leaves no temp dir and re-raises" bash -c 'grep -q "secs=[0-4] leftovers=0 copy_alive=0" <<<"$1" && grep -qE "rc=-(1|2|15) " <<<"$1"' _ "$out"
  done
done
for s in doctor.sh apply-system.sh; do
  for sig in SIGINT SIGTERM; do
    rm -rf "$SCRATCH/tmp" "$SCRATCH/log"
    out=$(runsig "$SCRATCH/s/$s" "$sig")
    check "$s: $sig removes the private copy (no temp dir left) and the script dies by that signal" bash -c 'grep -q "leftovers=0 copy_was_used=True" <<<"$1" && grep -qE "rc=-(2|15)\b" <<<"$1"' _ "$out"
  done
  # a normal run: exit status of the copy is passed on, no leftover
  rm -rf "$SCRATCH/tmp" "$SCRATCH/log"; mkdir -p "$SCRATCH/tmp"
  TMPDIR="$SCRATCH/tmp" SELFCOPY_LOG="$SCRATCH/log" bash "$SCRATCH/s/$s"; rc=$?
  check "$s: a normal run runs the copy, passes its exit status on and leaves nothing behind" bash -c '[ "$1" = 7 ] && [ -z "$(ls -A "$2")" ] && grep -q "body ran from $2/" "$3"' _ "$rc" "$SCRATCH/tmp" "$SCRATCH/log"
  # as root (a fake `id` that says 0): TMPDIR is ignored, the copy goes to /tmp
  rm -rf "$SCRATCH/tmp" "$SCRATCH/fb"; mkdir -p "$SCRATCH/tmp" "$SCRATCH/fb"
  printf '#!/bin/sh\necho 0\n' >"$SCRATCH/fb/id"
  printf '#!/bin/sh\necho "$@" >>"%s/mktemp.log"\nexec /usr/bin/mktemp "$@"\n' "$SCRATCH" >"$SCRATCH/fb/mktemp"
  chmod +x "$SCRATCH/fb/id" "$SCRATCH/fb/mktemp"; rm -f "$SCRATCH/mktemp.log"
  PATH="$SCRATCH/fb:$PATH" TMPDIR="$SCRATCH/tmp" SELFCOPY_LOG="$SCRATCH/log" bash "$SCRATCH/s/$s"
  check "$s: as root (EUID 0) the copy is made in /tmp and TMPDIR is ignored" bash -c 'grep -q -- "^-d /tmp/" "$1" && ! grep -q "$2" "$1" && ! ls "$3" | grep -q .' _ "$SCRATCH/mktemp.log" "$SCRATCH/tmp" "$SCRATCH/tmp"
  printf '#!/bin/sh\necho 1000\n' >"$SCRATCH/fb/id"
  rm -f "$SCRATCH/mktemp.log"
  PATH="$SCRATCH/fb:$PATH" TMPDIR="$SCRATCH/tmp" SELFCOPY_LOG="$SCRATCH/log" bash "$SCRATCH/s/$s"
  check "$s: as a normal user the copy follows TMPDIR" bash -c 'grep -q -- "^-d $2/" "$1"' _ "$SCRATCH/mktemp.log" "$SCRATCH/tmp"
done
printf '\nselfcopy test: %d passed, %d failed\n' "$PASS" "$FAILS"
((FAILS == 0))
