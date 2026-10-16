#!/usr/bin/env bash
# Waybar custom/recording: critical pill with the elapsed time while gpu-screen-recorder runs, nothing otherwise.
#   recording.sh --follow   continuous mode (one bash per bar, no process spawns while idle): checks every second with
#                           builtins only, prints one JSON line per second while recording and one empty line when it ends
#   recording.sh            print the current state once
# rec-toggle.sh writes "$XDG_RUNTIME_DIR/rec-pid" (pid + start epoch) and leaves "$XDG_RUNTIME_DIR/rec-mic" behind when the
# microphone is part of the recording. A recording started some other way is found with pgrep every 5 s (the kernel
# truncates the process name to 15 chars) and shows REC without a timer.
set -u

RT="${XDG_RUNTIME_DIR:-/tmp}"
PIDF="$RT/rec-pid"
MICF="$RT/rec-mic"
G_REC='󰑊'
G_MIC='󰍬'
EMPTY='{"text":""}'

# state -> sets pid, start; returns 0 while a recording runs. $1 = 1 allows the (spawning) pgrep fallback
probe() {
  pid="" start=""
  if [[ -r $PIDF ]]; then
    read -r pid start <"$PIDF" || true
    if [[ $pid =~ ^[0-9]+$ && -d /proc/$pid ]]; then return 0; fi
    pid="" start=""
  fi
  if (($1)) && pgrep -x gpu-screen-reco >/dev/null 2>&1; then pid=0; return 0; fi
  return 1
}

render() {
  local now el text="$G_REC REC" tip="Recording the screen" mic=""
  [[ -e $MICF ]] && { mic=" $G_MIC"; tip="Recording system sound and microphone"; }
  if [[ $start =~ ^[0-9]+$ ]]; then
    printf -v now '%(%s)T' -1
    el=$((now - start))
    if ((el >= 3600)); then printf -v text '%s %d:%02d:%02d%s' "$G_REC" $((el / 3600)) $((el % 3600 / 60)) $((el % 60)) "$mic"
    else printf -v text '%s %02d:%02d%s' "$G_REC" $((el / 60)) $((el % 60)) "$mic"; fi
  else
    text="$text$mic"
  fi
  printf '{"text":"%s","class":"critical","tooltip":"%s\\n\\nL: stop · R: capture menu"}\n' "$text" "$tip"
}

# sleep without spawning a process: read with a timeout on a pipe that never delivers
exec {TICKFD}<> <(:)
tick() { read -r -t "${1:-1}" -u "$TICKFD" || true; }

if [[ ${1:-} == --follow ]]; then
  was=0 n=0
  while :; do
    # the pgrep fallback runs only every 5th idle second
    if probe $((n % 5 == 0)); then render; was=1
    elif ((was)); then echo "$EMPTY"; was=0
    elif ((n == 0)); then echo "$EMPTY"
    fi
    n=$((n + 1))
    tick 1
  done
fi

if probe 1; then render; else echo "$EMPTY"; fi
