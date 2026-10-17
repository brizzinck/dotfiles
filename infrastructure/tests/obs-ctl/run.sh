#!/usr/bin/env bash
# shellcheck disable=SC2016
# Offline test of .local/bin/obs-ctl against a fake obs-cmd (./bin): argv, the websocket URL handed over in the environment
# (never on argv), parsing of scene/input lists, the stream guard and the unreachable-OBS message. OBS is never contacted.
#   run.sh   (used by doctor.sh)
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
OC="$REPO/.local/bin/obs-ctl"
FAKE=$(mktemp -d "${TMPDIR:-/tmp}/obs-ctl-test.XXXXXX")
trap 'rm -rf "$FAKE"' EXIT
export FAKE_DIR="$FAKE" OBS_CMD_BIN="$HERE/bin/obs-cmd" OBS_CTL_ASSUME_RUNNING=1 OBS_CTL_MENU="$HERE/bin/pick" OBS_CONFIG_DIR="$FAKE/obs-studio"
export PATH="$HERE/bin:$PATH" XDG_CONFIG_HOME="$FAKE/config"
unset OBS_WEBSOCKET_URL
mkdir -p "$FAKE/obs-studio/plugin_config/obs-websocket" "$FAKE/obs-studio/basic/profiles/P" "$FAKE/config"
printf '{"server_enabled": true, "server_port": 4466, "server_password": "s3cretpw"}' >"$FAKE/obs-studio/plugin_config/obs-websocket/config.json"
PASS=0 FAILS=0
check() { # check NAME CMD...
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); else FAILS=$((FAILS + 1)); echo "FAIL: $name"; fi
}
reset() { : >"$FAKE/argv.log"; : >"$FAKE/url.log"; : >"$FAKE/notify.log"; rm -f "$FAKE/down" "$FAKE/rec" "$FAKE/paused"; unset FAKE_PICK; }

reset; "$OC" record
check "record -> recording toggle" grep -qx 'recording toggle' "$FAKE/argv.log"
check "URL from the obs-websocket config, in the environment only" grep -qx 'obsws://localhost:4466/s3cretpw' "$FAKE/url.log"
check "password never on argv" bash -c '! grep -q s3cretpw "$1"' _ "$FAKE/argv.log"
check "notification shows obs-cmd's message" grep -q 'Recording toggled successfully' "$FAKE/notify.log"
check "notification has no password" bash -c '! grep -q s3cretpw "$1"' _ "$FAKE/notify.log"

reset; OBS_WEBSOCKET_URL=obsws://h:1/envpw "$OC" record-pause
check "env URL wins" grep -qx 'obsws://h:1/envpw' "$FAKE/url.log"
check "record-pause -> recording toggle-pause" grep -qx 'recording toggle-pause' "$FAKE/argv.log"
mkdir -p "$FAKE/config/obs-cmd"; echo 'obsws://filehost:9/filepw' >"$FAKE/config/obs-cmd/url"
reset; "$OC" replay-save
check "url file beats the OBS config" grep -qx 'obsws://filehost:9/filepw' "$FAKE/url.log"
check "replay-save" grep -qx 'replay save' "$FAKE/argv.log"
rm -rf "$FAKE/config/obs-cmd"

reset; check "scenes parsed (headers, bullets, quotes, numbering)" bash -c '[ "$("$1" scenes | paste -sd,)" = "Game,Just Chatting,Desk" ]' _ "$OC"
reset; check "inputs parsed" bash -c '[ "$("$1" inputs | paste -sd,)" = "Mic/Aux,Desktop Audio" ]' _ "$OC"
reset; FAKE_PICK="Just Chatting" "$OC" scene
check "scene picker -> scene switch NAME" grep -qx 'scene switch Just Chatting' "$FAKE/argv.log"
reset; FAKE_PICK="Game  (current)" "$OC" scene
check "current marker stripped" grep -qx 'scene switch Game' "$FAKE/argv.log"
reset; "$OC" scene
check "cancelled scene picker switches nothing" bash -c '! grep -q "scene switch" "$1"' _ "$FAKE/argv.log"
reset; FAKE_PICK="Mic/Aux" "$OC" mute
check "mute picker -> input mute NAME toggle" grep -qx 'input mute Mic/Aux toggle' "$FAKE/argv.log"
reset; "$OC" mute "Desktop Audio"
check "mute NAME" grep -qx 'input mute Desktop Audio toggle' "$FAKE/argv.log"

reset; "$OC" stream
check "stream refused without a key" bash -c '! grep -q streaming "$1"' _ "$FAKE/argv.log"
check "stream says why" grep -q 'not configured' "$FAKE/notify.log"
echo '{"type":"rtmp_common","settings":{"key":"live_123"}}' >"$FAKE/obs-studio/basic/profiles/P/service.json"
reset; "$OC" stream
check "stream with a key -> streaming toggle" grep -qx 'streaming toggle' "$FAKE/argv.log"
reset; FAKE_PICK="Streaming: start / stop" "$OC" menu
check "menu offers streaming when configured, and runs it" grep -qx 'streaming toggle' "$FAKE/argv.log"
rm -f "$FAKE/obs-studio/basic/profiles/P/service.json"
reset; FAKE_PICK="Status" "$OC" menu
check "menu hides streaming without a key" bash -c '! grep -q Streaming "$1"' _ "$FAKE/rows.log"
check "menu Status runs info" grep -qx 'info' "$FAKE/argv.log"

reset; check "is-recording false" bash -c '! "$1" is-recording' _ "$OC"
touch "$FAKE/rec"; check "is-recording true" "$OC" is-recording
reset; check "is-paused false" bash -c '! "$1" is-paused' _ "$OC"
touch "$FAKE/paused"; check "is-paused true" "$OC" is-paused

reset; touch "$FAKE/down"; "$OC" record
check "refused connection -> WebSocket hint" grep -q 'WebSocket' "$FAKE/notify.log"
printf '{"server_enabled": false, "server_port": 4455, "server_password": "x"}' >"$FAKE/obs-studio/plugin_config/obs-websocket/config.json"
reset; touch "$FAKE/down"; "$OC" record
check "server_enabled=false -> says to enable it" grep -q 'Enable WebSocket server' "$FAKE/notify.log"

reset; OBS_CTL_ASSUME_RUNNING=0 PATH="$HERE/bin:/usr/bin:/bin" OBS_CMD_BIN="$HERE/bin/obs-cmd" bash -c 'pgrep() { return 1; }; export -f pgrep; "$1" record' _ "$OC"
if pgrep -x obs >/dev/null 2>&1; then :; else check "OBS down -> no obs-cmd call, message" bash -c '[ ! -s "$1" ] && grep -q "not running" "$2"' _ "$FAKE/argv.log" "$FAKE/notify.log"; fi
reset; "$OC" --dry-run record >"$FAKE/dry.out"
check "--dry-run prints and does not call obs-cmd" bash -c 'grep -q "would run: obs-cmd recording toggle" "$1" && [ ! -s "$2" ]' _ "$FAKE/dry.out" "$FAKE/argv.log"

echo "obs-ctl test: $PASS passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
