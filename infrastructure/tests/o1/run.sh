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

echo "o1 tests: $fails failure(s)"
exit $((fails > 0))
