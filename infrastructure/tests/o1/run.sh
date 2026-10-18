#!/usr/bin/env bash
# shellcheck disable=SC2016
# Offline tests of the O1 desktop pieces with fake hyprctl / notify-send / playerctl / pw-dump / ffmpeg-free paths:
# lid.sh panel + mirror + recover, cursor-zoom, brightness, audio-picker --next, restart.sh, lock-screen, media.sh,
# transcode (a real ffmpeg run on a generated picture), ytdl URL check, hub install rows. The live session is never touched.
#   infrastructure/tests/o1/run.sh
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
SC="$REPO/.config/hypr/scripts"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/run" "$T/home"
fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
expect() { local n=$1; shift; if "$@" >/dev/null 2>&1; then pass "$n"; else fail "$n"; fi; }
logs() { cat "$T/log" 2>/dev/null; }

# ── fakes ──
cat >"$T/bin/hyprctl" <<'X'
#!/bin/sh
echo "hyprctl $*" >>"$FAKE_LOG"
case "$1 $2" in
  "monitors -j") cat "$FAKE_MONITORS" ;;
  "monitors all") cat "$FAKE_MONITORS" ;;
  "getoption cursor:zoom_factor") echo '{"option":"cursor:zoom_factor","float":'"${FAKE_ZOOM:-1}"',"set":false}' ;;
  "devices -j") echo '{"mice":[{"name":"fake-touchpad"},{"name":"fake-mouse"}]}' ;;
esac
exit 0
X
cat >"$T/bin/notify-send" <<'X'
#!/bin/sh
echo "notify $*" >>"$FAKE_LOG"
case "$*" in *" -A "*) [ -n "${FAKE_ACTION:-}" ] && echo "$FAKE_ACTION" ;; esac
exit 0
X
cat >"$T/bin/satty" <<'X'
#!/bin/sh
echo "satty $*" >>"$FAKE_LOG"
X
cat >"$T/bin/mpv" <<'X'
#!/bin/sh
echo "mpv $*" >>"$FAKE_LOG"
X
cat >"$T/bin/ghostty" <<'X'
#!/bin/sh
echo "ghostty $*" >>"$FAKE_LOG"
X
cat >"$T/bin/hyprshot" <<'X'
#!/bin/sh
echo "hyprshot $*" >>"$FAKE_LOG"
out=""; name=""
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift ;; -f) name=$2; shift ;; esac; shift; done
[ -n "$out" ] && [ -n "$name" ] && printf 'png' >"$out/$name"
X
cat >"$T/bin/playerctl" <<'X'
#!/bin/sh
echo "playerctl $*" >>"$FAKE_LOG"
case "$1" in
  --follow) printf 'Playing|||ytmdesktop|||Some Artist|||A Song|||An Album\nPaused|||ytmdesktop|||Some Artist|||A Song|||An Album\n' ;;
esac
X
cat >"$T/bin/hyprlock" <<'X'
#!/bin/sh
echo "hyprlock" >>"$FAKE_LOG"
X
cat >"$T/bin/pidof" <<'X'
#!/bin/sh
exit 1
X
cat >"$T/bin/wl-paste" <<'X'
#!/bin/sh
printf '%s' "${FAKE_CLIP:-}"
X
cat >"$T/bin/wl-copy" <<'X'
#!/bin/sh
cat >/dev/null
X
chmod +x "$T/bin"/*
export FAKE_LOG="$T/log" XDG_RUNTIME_DIR="$T/run" HOME="$T/home" PATH="$T/bin:$PATH" FAKE_MONITORS="$T/monitors.json"
mkdir -p "$HOME/.config/hypr"
cp "$REPO/.config/hypr/monitors.lua" "$HOME/.config/hypr/monitors.lua"
LID="$SC/lid.sh"
two='[{"name":"eDP-1","disabled":false,"mirrorOf":"none"},{"name":"HDMI-A-1","disabled":false,"mirrorOf":"none"}]'
one='[{"name":"eDP-1","disabled":false,"mirrorOf":"none"}]'
off_panel='[{"name":"eDP-1","disabled":true,"mirrorOf":"none"},{"name":"HDMI-A-1","disabled":false,"mirrorOf":"none"}]'
mirrored='[{"name":"eDP-1","disabled":false,"mirrorOf":"none"},{"name":"HDMI-A-1","disabled":false,"mirrorOf":"1"}]'
reset() { : >"$T/log"; }

# ── D6 displays ──
echo "$one" >"$T/monitors.json"; reset
"$LID" panel off
expect "panel off is refused with no external monitor" bash -c "! grep -q 'disabled = true' '$T/log' && grep -q 'Laptop panel stays on' '$T/log'"
reset; "$LID" mirror toggle
expect "mirror is refused with no external monitor" bash -c "! grep -q mirror= '$T/log' && grep -q 'Mirroring needs a second monitor' '$T/log'"
echo "$two" >"$T/monitors.json"; reset
"$LID" panel off
expect "panel off with an external monitor disables eDP-1" grep -q 'hl.monitor({ output = "eDP-1", disabled = true })' "$T/log"
echo "$off_panel" >"$T/monitors.json"; reset
"$LID" panel toggle
expect "panel toggle brings it back from monitors.lua" grep -q 'hl.monitor(m)' "$T/log"
echo "$one" >"$T/monitors.json"; reset
# panel disabled AND no external monitor left (the monitor.removed hook): recover
printf '%s' '[{"name":"eDP-1","disabled":true,"mirrorOf":"none"}]' >"$T/monitors.json"; reset
"$LID" recover
expect "recover re-enables the panel when nothing else is left" grep -q 'hl.monitor(m)' "$T/log"
echo "$off_panel" >"$T/monitors.json"; reset; "$LID" recover
expect "recover does nothing while the external monitor is there" bash -c "! grep -q 'hl.monitor' '$T/log'"
echo "$two" >"$T/monitors.json"; reset
"$LID" mirror on
expect "mirror on: the external monitor mirrors eDP-1" grep -q 'output = "HDMI-A-1", mode = "preferred", position = "auto", scale = 1, mirror = "eDP-1"' "$T/log"
echo "$mirrored" >"$T/monitors.json"; reset
"$LID" mirror toggle
expect "mirror off re-applies the monitors.lua rule for the output" bash -c "grep -q 'hl.monitor(r)' '$T/log' && grep -q 'HDMI-A-1' '$T/log'"

# ── D6 zoom ──
export FAKE_ZOOM=1; reset; "$SC/cursor-zoom.sh" in
expect "zoom in steps +0.5" grep -q 'zoom_factor = 1.50' "$T/log"
export FAKE_ZOOM=8; reset; "$SC/cursor-zoom.sh" in
expect "zoom stops at 8" grep -q 'zoom_factor = 8.00' "$T/log"
export FAKE_ZOOM=1; reset; "$SC/cursor-zoom.sh" out
expect "zoom out never goes below 1" grep -q 'zoom_factor = 1.00' "$T/log"
export FAKE_ZOOM=3; reset; "$SC/cursor-zoom.sh" reset
expect "zoom reset" grep -q 'zoom_factor = 1 ' "$T/log"

# ── D10a brightness (panel path, dry run: commands only) ──
echo '[{"name":"eDP-1","focused":true}]' >"$T/monitors.json"
expect "brightness 1 percent step" bash -c "[ \"\$('$SC/brightness.sh' up --step 1 --dry-run)\" = 'panel eDP-1: swayosd-client --brightness +1 || brightnessctl set +1%' ]"
expect "brightness default step keeps raise" bash -c "'$SC/brightness.sh' up --dry-run | grep -q -- '--brightness raise'"
expect "brightness max" bash -c "'$SC/brightness.sh' max --dry-run | grep -q 'brightnessctl set 100%'"
expect "brightness min is 1 percent, not 0" bash -c "'$SC/brightness.sh' min --dry-run | grep -q 'brightnessctl set 1%'"

# ── restart.sh ──
reset
"$SC/restart.sh" trackpad --yes
expect "restart trackpad toggles the device off then on" bash -c "grep -n 'enabled = false' '$T/log' | head -1 | grep -q . && [ \$(grep -c '^hyprctl eval .*fake-touchpad' '$T/log') = 2 ]"
expect "restart audio lists pipewire, pipewire-pulse and wireplumber" bash -c "'$SC/restart.sh' audio --dry-run | grep -q 'systemctl --user restart pipewire pipewire-pulse wireplumber'"
expect "restart wifi: off, on" bash -c "'$SC/restart.sh' wifi --dry-run | tr '\n' ' ' | grep -q 'radio wifi off.*radio wifi on'"

# ── lock-screen: layout reset first, then hyprlock ──
reset; "$REPO/.local/bin/lock-screen"
expect "lock resets the layout to us before locking" bash -c "grep -n 'switchxkblayout all 0' '$T/log' | head -1 | cut -d: -f1 | grep -q 1 && grep -q '^hyprlock' '$T/log'"

# ── media module ──
out=$("$REPO/.config/waybar/scripts/media.sh" --follow 2>/dev/null | head -n 2)
line1=$(sed -n 1p <<<"$out"); line2=$(sed -n 2p <<<"$out")
expect "media: Playing shows artist - title" bash -c "jq -e '.class == \"normal\" and (.text | contains(\"Some Artist - A Song\"))' <<<'$line1'"
expect "media: tooltip ends with the hint line" bash -c "jq -e '.tooltip | endswith(\"L: play/pause · M: next · R: menu · Scroll: next/previous\")' <<<'$line1'"
expect "media: Paused hides the module" jq -e '.text == ""' <<<"$line2"

# ── ytdl: only a single http(s) URL is accepted ──
FAKE_CLIP='not a url' "$SC/ytdl.sh" >/dev/null 2>&1; rc=$?
expect "ytdl refuses text" test "$rc" != 0
expect "ytdl dry run names yt-dlp and the folder" bash -c "FAKE_CLIP='https://example.org/v?x=1' '$SC/ytdl.sh' --dry-run | grep -q 'yt-dlp -P .*Videos/downloads https://example.org/v?x=1'"

# ── transcode: a real ffmpeg run ──
if command -v ffmpeg >/dev/null 2>&1; then
  mkdir -p "$T/media"
  ffmpeg -loglevel error -y -f lavfi -i testsrc=size=2000x1000 -frames:v 1 "$T/media/p.png"
  "$SC/transcode.sh" "$T/media/p.png" jpg 1080 >/dev/null 2>&1
  expect "transcode writes NAME-1080.jpg next to the source, 1080 px wide" bash -c "[ \"\$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 '$T/media/p-1080.jpg')\" = 1080 ]"
  expect "transcode never overwrites" bash -c "'$SC/transcode.sh' '$T/media/p.png' jpg 1080 >/dev/null 2>&1; [ -f '$T/media/p-1080-2.jpg' ]"
  expect "transcode rejects a bad size" bash -c "! '$SC/transcode.sh' '$T/media/p.png' jpg huge >/dev/null 2>&1"
else
  echo "ffmpeg missing: transcode test skipped"
fi

# ── hub: a missing tool with a hint is an install row, without a hint it stays hidden ──
HUBDIR=$(mktemp -d)
mkdir -p "$HUBDIR/actions.d"
cp "$REPO/.config/hub/hub" "$HUBDIR/hub"; cp "$REPO/.config/hub/groups.tsv" "$HUBDIR/"
printf 'nope-tool\tfake-pkg\n' >"$HUBDIR/install-hints.tsv"
printf 'r1\tUpdate\tRow with hint\t-\trun\tnope-tool --x\t-\t-\t-\n' >"$HUBDIR/actions.tsv"
printf 'r2\tUpdate\tRow without hint\t-\trun\tnope-other\t-\t-\t-\n' >>"$HUBDIR/actions.tsv"
printf 'r3\tFix\tPlain row\t-\trun\ttrue\t-\t-\t-\n' >>"$HUBDIR/actions.tsv"
json=$(PATH="$T/bin:$PATH" XDG_RUNTIME_DIR="$T/run" "$HUBDIR/hub" --json 2>/dev/null | jq -c '[.[] | select(.id | test("^r[0-9]$")) | {id, available, install}]')
rm -rf "$HUBDIR"
expect "hub json: installable row is listed with its package" bash -c "jq -e 'any(.[]; .id == \"r1\" and .available == false and .install == \"fake-pkg\")' <<<'$json'"
expect "hub json: a missing tool without a hint is hidden" bash -c "jq -e 'all(.[]; .id != \"r2\")' <<<'$json'"
expect "hub json: an available row" bash -c "jq -e 'any(.[]; .id == \"r3\" and .available == true)' <<<'$json'"

# ── D3 capture endings ──
export HOME="$T/home"
mkdir -p "$HOME/pics/screenshots"
reset; "$SC/shot.sh" region
expect "shot.sh silences hyprshot and names the file" grep -q 'hyprshot -m region -o .*pics/screenshots -f .*_hyprshot.png --silent' "$T/log"
f=$(ls "$HOME/pics/screenshots"/*_hyprshot.png | head -1)
reset; FAKE_ACTION=default bash -c ". '$SC/capture-lib.sh'; SHOTS='$HOME/pics/screenshots'; cap_shot_worker '$f'"
expect "screenshot toast: default action opens satty on the file" grep -q "satty -f $f" "$T/log"
reset; FAKE_ACTION=folder bash -c ". '$SC/capture-lib.sh'; cap_shot_worker '$f'"
expect "screenshot toast: folder action opens yazi" grep -q "ghostty --class=float.tui -e yazi $f" "$T/log"
reset; FAKE_ACTION="" bash -c ". '$SC/capture-lib.sh'; cap_shot_worker '$f'"
expect "screenshot toast: no click does nothing" bash -c "! grep -q -e '^satty' -e '^ghostty' '$T/log'"
reset; "$SC/freeze-shot.sh" save --dry-run >/dev/null
expect "freeze-shot has an image mode for OCR and QR" bash -c "'$SC/freeze-shot.sh' image /tmp/x.png --dry-run | grep -q 'grim -g .* /tmp/x.png'"
expect "OCR region selects on the frozen screen" bash -c "grep -q 'freeze-shot.sh\" image' '$SC/capture.sh'"

if command -v ffmpeg >/dev/null 2>&1; then
  v="$T/media/rec.mp4"
  ffmpeg -loglevel error -y -f lavfi -i testsrc=size=640x360:rate=30:duration=3 -f lavfi -i "sine=frequency=440:duration=3" \
    -f lavfi -i "sine=frequency=220:duration=3" -map 0:v -map 1:a -map 2:a -c:v libx264 -c:a aac "$v"
  before=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$v")
  bash -c ". '$SC/capture-lib.sh'; cap_process_recording '$v'"
  after=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$v")
  expect "processing trims the start (shorter than the raw file)" awk -v a="$after" -v b="$before" 'BEGIN { exit !(a < b) }'
  expect "processing keeps both audio tracks at 48 kHz" bash -c "[ \"\$(ffprobe -v error -select_streams a -show_entries stream=sample_rate -of csv=p=0 '$v' | tr '\n' ' ')\" = '48000 48000 ' ]"
  expect "processing leaves no temp file" bash -c "! ls '$T'/media/*.processing.mp4"
  printf 'not a video' >"$T/media/bad.mp4"
  expect "a broken file stays as it is (raw kept)" bash -c ". '$SC/capture-lib.sh'; ! cap_process_recording '$T/media/bad.mp4'; [ \"\$(cat '$T/media/bad.mp4')\" = 'not a video' ]"
  reset; FAKE_ACTION=default bash -c ". '$SC/capture-lib.sh'; cap_recording_worker '$v'"
  expect "recording toast: thumbnail, play action starts mpv" bash -c "grep -q 'notify .* -i .*capture-thumbs/rec.png' '$T/log' && grep -q \"mpv $v\" '$T/log' || { sleep 0.5; grep -q \"mpv $v\" '$T/log'; }"
  expect "recording toast: the thumbnail exists" test -s "$T/run/capture-thumbs/rec.png"
else
  echo "ffmpeg missing: recording tests skipped"
fi

# ── D4 reminders ──
cat >"$T/bin/systemd-run" <<'X'
#!/bin/sh
echo "systemd-run $*" >>"$FAKE_LOG"
X
cat >"$T/bin/systemctl" <<'X'
#!/bin/sh
echo "systemctl $*" >>"$FAKE_LOG"
case "$*" in
  *list-timers*) echo "[{\"unit\":\"reminder-1-2.timer\",\"next\":$(( ($(date +%s) + 600) * 1000000 ))},{\"unit\":\"reminder-3-4.timer\",\"next\":$(( ($(date +%s) + 7200) * 1000000 ))}]" ;;
esac
X
chmod +x "$T/bin/systemd-run" "$T/bin/systemctl"
mkdir -p "$T/run/systemd/transient"
printf '[Unit]\nDescription=reminder: tea\n' >"$T/run/systemd/transient/reminder-1-2.service"
printf '[Unit]\nDescription=reminder: standup\n' >"$T/run/systemd/transient/reminder-3-4.service"
R="$SC/reminder.sh"
expect "reminder preview: minutes" test "$("$R" --parse '25 tea')" = "in 25m: tea"
expect "reminder preview: h and m" test "$("$R" --parse '1h30 call')" = "in 1h30m: call"
expect "reminder preview: seconds" test "$("$R" --parse '90s x')" = "in 90s: x"
expect "reminder preview: a bad time" bash -c "'$R' --parse 'tea 25' | grep -q 'time first'"
reset; "$R" set 25 tea >/dev/null
expect "reminder set: one transient timer 1500 s ahead" grep -q -e '--on-active=1500s' -e 'on-active=1500s' "$T/log"
expect "reminder set: message and critical urgency in the service command" bash -c "grep 'systemd-run' '$T/log' | grep -q 'notify-send -u critical -a reminder' && grep 'systemd-run' '$T/log' | grep -q ' tea '"
reset; "$R" set nonsense >/dev/null 2>&1; rc=$?
expect "reminder set: a bad time creates nothing" bash -c "[ $rc != 0 ] && ! grep -q '^systemd-run' '$T/log'"
w=$("$R" waybar)
expect "reminder waybar: next one and the count" bash -c "jq -e '.text | test(\"10m \\\\+1\")' <<<'$w'"
expect "reminder waybar: tooltip lists both with the hint line" bash -c "jq -e '.tooltip | contains(\"tea\") and contains(\"standup\") and endswith(\"L: list · M: new · R: clear all\")' <<<'$w'"
reset; "$R" clear --yes >/dev/null
expect "reminder clear stops every timer and service" bash -c "grep -c 'systemctl --user stop reminder-' '$T/log' | grep -q '^2$'"

# ── idle dim: never save a dimmed value ──
cat >"$T/bin/brightnessctl" <<'X'
#!/bin/sh
# fake: raw value in $FAKE_BL, max 496000, exponent 4 for -e4 set 25%
max=496000
cur=$(cat "$FAKE_BL")
case "$*" in
  "-m") echo "amdgpu_bl1,backlight,$cur,0%,$max" ;;
  "-e4 set 25%") echo $((max / 256)) >"$FAKE_BL" ;;
  "set "*) echo "${2}" >"$FAKE_BL" ;;
esac
X
chmod +x "$T/bin/brightnessctl"
export FAKE_BL="$T/bl" DIM_NO_WATCH=1
DIM="$SC/dim.sh"
echo 248000 >"$FAKE_BL"; rm -f "$T/run/dim-saved"
"$DIM" dim
expect "dim saves the real value and dims" bash -c "[ \"\$(cut -d' ' -f1 '$T/run/dim-saved')\" = 248000 ] && [ \"\$(cat '$FAKE_BL')\" = 1937 ]"
"$DIM" dim
expect "a second dim without a resume does not save the dimmed value" bash -c "[ \"\$(cut -d' ' -f1 '$T/run/dim-saved')\" = 248000 ]"
"$DIM" restore
expect "restore brings the saved value back and clears the state" bash -c "[ \"\$(cat '$FAKE_BL')\" = 248000 ] && [ ! -e '$T/run/dim-saved' ]"
"$DIM" restore
expect "restore without a dim is a no-op" bash -c "[ \"\$(cat '$FAKE_BL')\" = 248000 ]"
echo 1937 >"$FAKE_BL"; "$DIM" dim
expect "an already dark panel is neither dimmed nor remembered" bash -c "[ ! -e '$T/run/dim-saved' ]"
echo "1937 496000" >"$T/run/dim-saved"; "$DIM" restore
expect "a corrupt saved value falls back to 50 percent" bash -c "[ \"\$(cat '$FAKE_BL')\" = 248000 ]"
expect "hypridle uses dim.sh for dim and resume" bash -c "grep -q 'dim.sh dim' '$REPO/.config/hypr/hypridle.conf' && grep -q 'dim.sh restore' '$REPO/.config/hypr/hypridle.conf'"
expect "a key press restores through the hyprland.lua event" grep -q 'input.keyboard.key' "$REPO/.config/hypr/hyprland.lua"
expect "watchdog leaves hypridle alone after idle off" bash -c "touch '$T/run/idle-off'; : >'$T/log'; PATH='$T/bin:'\"\$PATH\" '$DIM' watchdog; ! grep -q hypridle '$T/log'"

# ── D2 crash watcher ──
CW="$SC/crash-watch.sh"
export CRASH_WATCH_SYNC=1
rec() { printf '{"COREDUMP_COMM":"%s","COREDUMP_PID":"4242","COREDUMP_EXE":"/usr/bin/%s","COREDUMP_SIGNAL_NAME":"SIGSEGV"}' "$1" "$1"; }
reset; rm -rf "$T/run/crash-watch-last"; mkdir -p "$T/run/crash-watch-last"
"$CW" --event "$(rec foo)"
expect "crash toast names the program, signal and pid" bash -c "grep -q 'foo crashed (SIGSEGV)' '$T/log' && grep -q 'pid 4242' '$T/log'"
expect "crash toast offers details, ask Claude and mute" bash -c "grep 'notify' '$T/log' | grep -q 'default=Details' && grep 'notify' '$T/log' | grep -q 'claude=Ask Claude' && grep 'notify' '$T/log' | grep -q 'mute=Mute foo'"
reset; "$CW" --event "$(rec foo)"
expect "at most one toast per program per 60 s" bash -c "! grep -q 'foo crashed' '$T/log'"
reset; "$CW" --event "$(rec bar)"
expect "another program still gets its toast" grep -q 'bar crashed' "$T/log"
reset; "$CW" --event "$(rec waybar)"
expect "waybar is skipped (its watchdog reports it)" bash -c "! grep -q 'waybar crashed' '$T/log'"
reset; FAKE_ACTION=default "$CW" --event "$(rec baz)"
expect "details click: coredumpctl info in a floating terminal" grep -q 'ghostty --class=float.tui --title=crash: baz -e bash -c coredumpctl info' "$T/log"
reset; FAKE_ACTION=claude "$CW" --event "$(rec qux)"
expect "ask Claude: a normal claude session, no auto-approve flag" bash -c "grep -q 'ghostty --title=crash: qux -e claude A program of mine crashed: qux' '$T/log' && ! grep -q -e '--dangerously' -e 'permission-mode' -e 'auto' '$T/log'"
reset; FAKE_ACTION=mute "$CW" --event "$(rec noisy)"
expect "mute action adds the program to the mute list" grep -qx noisy "$HOME/.local/state/crash-watch/muted"
rm -f "$T/run/crash-watch-last"/*; reset; "$CW" --event "$(rec noisy)"
expect "a muted program never raises a toast" bash -c "! grep -q 'noisy crashed' '$T/log'"
"$CW" unmute noisy; rm -f "$T/run/crash-watch-last"/*; reset; "$CW" --event "$(rec noisy)"
expect "unmute brings it back" grep -q 'noisy crashed' "$T/log"
unset CRASH_WATCH_SYNC

# ── D1 dictation (fake voxtype, fake systemctl; independent of whether the voxtype package is installed) ──
DC="$SC/dictation.sh"
export DICTATION_NO_DOWNLOAD=1 VOXTYPE_MODEL_DIR="$T/models"
mkdir -p "$T/run/voxtype" "$T/models" "$HOME/.config/voxtype"
cat >"$T/bin/systemctl" <<'X'
#!/bin/sh
echo "systemctl $*" >>"$FAKE_LOG"
case "$*" in
  *"show voxtype.service -p NRestarts"*) echo "${FAKE_NRESTARTS:-0}" ;;
  *"is-active"*) exit 3 ;;
esac
exit 0
X
chmod +x "$T/bin/systemctl"
export VOXTYPE_BIN="$T/none"  # an explicit "not installed": the real /usr/bin/voxtype of this machine is never looked at
reset; "$DC" toggle
expect "without voxtype the key only says how to install it" bash -c "grep -q 'Dictation needs voxtype' '$T/log' && grep -q 'apply-system.sh --only install' '$T/log'"
cat >"$T/bin/voxtype" <<'X'
#!/bin/sh
echo "voxtype $*" >>"$FAKE_LOG"
X
chmod +x "$T/bin/voxtype"
export VOXTYPE_BIN="$T/bin/voxtype"
reset; "$DC" toggle
expect "model missing: no recording, a notification" bash -c "grep -q 'the model is missing' '$T/log' && ! grep -q '^voxtype record' '$T/log'"
printf 'x' >"$T/models/ggml-small.bin"
echo idle >"$T/run/voxtype/state"; reset; "$DC" toggle
expect "toggle while idle starts recording" grep -q '^voxtype record start' "$T/log"
echo recording >"$T/run/voxtype/state"; reset; "$DC" toggle
expect "toggle while recording stops it" grep -q '^voxtype record stop' "$T/log"
echo recording >"$T/run/voxtype/state"; reset; "$DC" start
expect "F9 press while already recording does nothing" bash -c "! grep -q '^voxtype record' '$T/log'"
echo idle >"$T/run/voxtype/state"; reset; "$DC" stop
expect "F9 release while idle does nothing" bash -c "! grep -q '^voxtype record' '$T/log'"
expect "status reads the daemon state file" bash -c "echo transcribing >'$T/run/voxtype/state'; [ \"\$('$DC' status)\" = transcribing ]"
echo idle >"$T/run/voxtype/state"
cp "$REPO/.config/voxtype/config.toml" "$HOME/.config/voxtype/config.toml"
expect "the tracked config defaults to ru" grep -q '^language = "ru"' "$HOME/.config/voxtype/config.toml"
rm -rf "$HOME/.local/state/dictation"
"$DC" run --dry-run >/dev/null
expect "no state file: the runtime config is Russian and the model small" bash -c "grep -q '^language = \"ru\"' '$T/run/voxtype/config.toml' && grep -q '^model = \"small\"' '$T/run/voxtype/config.toml'"
reset; "$DC" lang uk >/dev/null
expect "the language choice is stored" test "$(cat "$HOME/.local/state/dictation/lang")" = uk
"$DC" run --dry-run >/dev/null
expect "the runtime config carries the language, the tracked file stays ru" bash -c "grep -q '^language = \"uk\"' '$T/run/voxtype/config.toml' && grep -q '^language = \"ru\"' '$HOME/.config/voxtype/config.toml'"
expect "the daemon is restarted without waiting" grep -q '^systemctl --user try-restart --no-block voxtype.service' "$T/log"
expect "a bad language is refused" bash -c "! '$DC' lang klingon >/dev/null 2>&1"
expect "auto cannot be mixed into a list" bash -c "! '$DC' lang en,auto >/dev/null 2>&1"
"$DC" lang en,ru,uk >/dev/null
expect "a comma list is accepted and reaches the daemon config" bash -c "'$DC' run --dry-run >/dev/null; grep -q '^language = \"en,ru,uk\"' '$T/run/voxtype/config.toml'"
"$DC" lang auto >/dev/null
expect "auto is accepted" test "$(cat "$HOME/.local/state/dictation/lang")" = auto
# SUPER+ALT+SHIFT+D: ru > uk > en > ru, one replacing notification
echo idle >"$T/run/voxtype/state"
"$DC" lang ru >/dev/null
for want in uk en ru; do
  reset; "$DC" cycle
  expect "cycle -> $want (stored)" test "$(cat "$HOME/.local/state/dictation/lang")" = "$want"
done
expect "cycle: one notification with the language and the stack tag" bash -c "[ \$(grep -c '^notify' '$T/log') = 1 ] && grep -q 'x-dunst-stack-tag:dictation' '$T/log' && grep -q 'Dictation: RU' '$T/log'"
"$DC" lang en,ru,uk >/dev/null; "$DC" cycle
expect "cycle from a list or auto starts at ru" test "$(cat "$HOME/.local/state/dictation/lang")" = ru
echo recording >"$T/run/voxtype/state"; reset; "$DC" cycle
expect "cycle while recording changes nothing and says so" bash -c "[ \"\$(cat '$HOME/.local/state/dictation/lang')\" = ru ] && grep -q 'Dictation is busy' '$T/log'"
echo idle >"$T/run/voxtype/state"
# waybar: always the language and the state
"$DC" lang uk >/dev/null
out=$(timeout 3 "$DC" --follow 2>/dev/null | head -n 1)
expect "waybar follow: idle shows the language, dim, tooltip with model, backend and the hint line" bash -c "jq -e '.class == \"dim\" and (.text | endswith(\"UK\")) and (.tooltip | contains(\"Language: UK\") and contains(\"Model: small\") and contains(\"Backend:\") and endswith(\"L: dictate · M: next language · R: menu\"))' <<<'$out'"
echo recording >"$T/run/voxtype/state"
out=$(timeout 3 "$DC" --follow 2>/dev/null | head -n 1)
expect "waybar follow: recording is critical and still shows the language" bash -c "jq -e '.class == \"critical\" and (.text | contains(\"UK\")) and (.tooltip | endswith(\"L: dictate · M: next language · R: menu\"))' <<<'$out'"
echo transcribing >"$T/run/voxtype/state"
out=$(timeout 3 "$DC" --follow 2>/dev/null | head -n 1)
expect "waybar follow: transcribing is warning" bash -c "jq -e '.class == \"warning\" and (.text | contains(\"UK\"))' <<<'$out'"
out=$(VOXTYPE_BIN="$T/none" timeout 3 "$DC" --follow 2>/dev/null | head -n 1)
expect "waybar follow: hidden without voxtype" bash -c "jq -e '.text == \"\"' <<<'$out'"
echo idle >"$T/run/voxtype/state"
# models
reset; "$DC" model large-v3-turbo --dry-run >/dev/null
expect "model NAME without the file would download it from the whisper.cpp repository" bash -c "'$DC' model large-v3-turbo --dry-run | grep -q 'ggml-large-v3-turbo.bin'"
printf 'x' >"$T/models/ggml-large-v3-turbo.bin"; reset
"$DC" model large-v3-turbo >/dev/null
expect "model NAME selects an installed model and restarts the daemon" bash -c "[ \"\$(cat '$HOME/.local/state/dictation/model')\" = large-v3-turbo ] && grep -q 'try-restart --no-block' '$T/log'"
"$DC" run --dry-run >/dev/null
expect "the runtime config carries the chosen model" grep -q '^model = "large-v3-turbo"' "$T/run/voxtype/config.toml"
expect "a bad model name is refused" bash -c "! '$DC' model '../x' >/dev/null 2>&1"
"$DC" model small >/dev/null

# ── D1b backend: Vulkan when a real GPU works, else the best CPU build by the CPU flags ──
unset VOXTYPE_BIN
LIB="$T/lib"; mkdir -p "$LIB"
cat >"$LIB/voxtype-vulkan" <<'X'
#!/bin/sh
echo "voxtype-vulkan $*" >>"$FAKE_LOG"
case "$*" in
  *daemon*) echo "env PIPEWIRE_PROPS=${PIPEWIRE_PROPS:-unset}" >>"$FAKE_LOG" ;;
  *transcribe*)
    echo probe >>"$FAKE_PROBES"
    echo "whisper_init_with_params_no_state: use gpu    = 1"
    if [ "${FAKE_GPU:-ok}" = ok ]; then
      echo "ggml_vulkan: Found 1 Vulkan devices:"
      echo "ggml_vulkan: 0 = Fake GPU 9000 (FAKE) (radv) | uma: 1 | fp16: 1 | warp size: 64"
      echo "whisper_backend_init_gpu: using Vulkan0 backend"
    elif [ "$FAKE_GPU" = soft ]; then
      echo "ggml_vulkan: 0 = llvmpipe (LLVM 21.1.0, 256 bits) (llvmpipe) | uma: 0 | fp16: 0"
      echo "whisper_backend_init_gpu: using Vulkan0 backend"
    else
      echo "whisper_backend_init_gpu: no GPU found"
    fi ;;
esac
X
for v in avx512 avx2 baseline; do printf '#!/bin/sh\necho "voxtype-%s $*" >>"$FAKE_LOG"\n' "$v" >"$LIB/voxtype-$v"; done
chmod +x "$LIB"/voxtype-*
export VOXTYPE_LIBDIR="$LIB" FAKE_PROBES="$T/probes"
cpu512="$T/cpu512"; echo 'flags : fpu sse2 avx avx2 fma avx512f avx512dq avx512cd avx512bw avx512vl' >"$cpu512"
cpu2="$T/cpu2"; echo 'flags : fpu sse2 avx avx2 fma' >"$cpu2"
cpu0="$T/cpu0"; echo 'flags : fpu sse2' >"$cpu0"
bk() { rm -rf "$HOME/.local/state/dictation/backend" "$T/probes"; DICTATION_CPUINFO=$1 "$DC" backend --path; }
expect "a working Vulkan device wins over any CPU build" test "$(FAKE_GPU=ok bk "$cpu512")" = "$LIB/voxtype-vulkan"
expect "the GPU name is cached for the tooltip" grep -q '^device=Fake GPU 9000 (FAKE)$' "$HOME/.local/state/dictation/backend"
rm -f "$T/probes"; "$DC" backend --path >/dev/null; "$DC" backend --path >/dev/null
expect "the probe result is cached: no second probe" test ! -e "$T/probes"
"$DC" backend --probe >/dev/null
expect "backend --probe probes again" test "$(wc -l <"$T/probes")" = 1
expect "no Vulkan device: avx512 on an avx512 CPU" test "$(FAKE_GPU=none bk "$cpu512")" = "$LIB/voxtype-avx512"
expect "a software Vulkan device (llvmpipe) does not count" test "$(FAKE_GPU=soft bk "$cpu512")" = "$LIB/voxtype-avx512"
expect "no Vulkan device: avx2 without avx512" test "$(FAKE_GPU=none bk "$cpu2")" = "$LIB/voxtype-avx2"
expect "no Vulkan device: the baseline build on an old CPU" test "$(FAKE_GPU=none bk "$cpu0")" = "$LIB/voxtype-baseline"
mv "$LIB/voxtype-avx512" "$LIB/voxtype-avx512.off"
expect "an avx512 CPU without the avx512 build falls back to avx2" test "$(FAKE_GPU=none bk "$cpu512")" = "$LIB/voxtype-avx2"
mv "$LIB/voxtype-avx512.off" "$LIB/voxtype-avx512"
mv "$T/models/ggml-small.bin" "$T/models/ggml-small.off"; rm -f "$T/models/ggml-large-v3-turbo.bin"
expect "no model yet: the probe is skipped, a CPU build is used" test "$(FAKE_GPU=ok bk "$cpu512")" = "$LIB/voxtype-avx512"
expect "...and that decision is not cached" test ! -e "$HOME/.local/state/dictation/backend"
mv "$T/models/ggml-small.off" "$T/models/ggml-small.bin"
# the daemon runs the variant directly: no PATH hack
rm -rf "$HOME/.local/state/dictation/backend"
out=$(FAKE_GPU=ok DICTATION_CPUINFO=$cpu512 "$DC" run --dry-run)
export RUN_OUT="$out"
expect "run execs the variant binary directly" bash -c "grep -q '^exec $LIB/voxtype-vulkan -c $T/run/voxtype/config.toml daemon' <<<\"\$RUN_OUT\""
expect "run keeps the Whisper stream on the raw microphone (PIPEWIRE_PROPS node.dont-move, AUDIO2)" bash -c "grep -qF \"export PIPEWIRE_PROPS='{ node.dont-move = true }'\" <<<\"\$RUN_OUT\""
reset; FAKE_GPU=ok DICTATION_CPUINFO=$cpu512 "$DC" run
expect "run (for real) starts the daemon from that binary" grep -q "^voxtype-vulkan -c $T/run/voxtype/config.toml daemon" "$T/log"
expect "the real daemon process gets PIPEWIRE_PROPS node.dont-move in its environment" grep -qF "env PIPEWIRE_PROPS={ node.dont-move = true }" "$T/log"
# a Vulkan daemon that crash-loops (systemd restarted it twice) is demoted to the CPU build
reset; FAKE_NRESTARTS=2 FAKE_GPU=ok DICTATION_CPUINFO=$cpu512 "$DC" run
expect "two automatic restarts demote Vulkan to the CPU build" grep -q "^voxtype-avx512 -c $T/run/voxtype/config.toml daemon" "$T/log"
expect "the demotion is cached with its reason" grep -q 'crash-looped' "$HOME/.local/state/dictation/backend"
reset; DICTATION_CPUINFO=$cpu512 "$DC" run
expect "a demoted backend stays demoted until the probe is repeated" grep -q "^voxtype-avx512 -c" "$T/log"
# no variant directory at all: the package binary on PATH
rm -rf "$HOME/.local/state/dictation/backend"
out=$(VOXTYPE_LIBDIR="$T/nolib" "$DC" backend 2>&1)
expect "without /usr/lib/voxtype variants the package binary is used" bash -c "grep -q 'backend: CPU (package default)' <<<'$out'"
rm -rf "$HOME/.local/state/dictation/backend"
unset VOXTYPE_LIBDIR FAKE_PROBES
rm -f "$T/bin/voxtype" "$T/bin/systemctl" "$T/run/voxtype/state"
unset DICTATION_NO_DOWNLOAD VOXTYPE_MODEL_DIR VOXTYPE_BIN

echo "o1 tests: $fails failure(s)"
exit $((fails > 0))
