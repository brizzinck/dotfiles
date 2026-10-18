#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2015,SC1007,SC2174,SC2034
# Offline tests of the AUDIO2 microphone chain: ee-ctl (socket trust, prepare, load, ns, auto, status), the audio-ensure EasyEffects
# checks and boot/fix modes, the raw/chain mic probes, the input picker, and the static files (preset, WirePlumber priority rules,
# unit). Fakes only: a fake EasyEffects control server (fake-ee.py), fake pactl / pw-dump / pw-metadata / wpctl / pw-record /
# systemctl / notify-send / pkill. No real audio, no notification, no real EasyEffects, nothing of the live session is touched.
#   infrastructure/tests/audio/run.sh [--quick]     --quick skips the cases that wait (doctor runs this)
#   ONLY=1,3 infrastructure/tests/audio/run.sh      pick sections
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
QUICK=0
[ "${1:-}" = --quick ] && QUICK=1
EE="$REPO/.local/bin/ee-ctl"
AE="$REPO/.local/bin/audio-ensure"
T=$(mktemp -d)
FAKEPIDS=()
cleanup() {
  local p
  for p in "${FAKEPIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT
mkdir -p "$T/bin" "$T/home" "$T/fake" "$T/tmp"
chmod 700 "$T"
mkdir -p -m 700 "$T/run"
F="$T/fake"
fails=0
passes=0
pass() { printf 'PASS  %s\n' "$1"; passes=$((passes + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
skip() { printf 'SKIP  %s\n' "$1"; }
expect() { local n=$1; shift; if "$@" >/dev/null 2>&1; then pass "$n"; else fail "$n"; fi; }
want() { [ -z "${ONLY:-}" ] || [[ ",$ONLY," == *",$1,"* ]]; }
logged() { grep -qF -- "$1" "$2" 2>/dev/null; }

# ── fakes ──
cat >"$T/bin/pw-dump" <<'X'
#!/bin/sh
cat "$FAKE/pw-dump.json" 2>/dev/null || echo '[]'
X
cat >"$T/bin/pw-metadata" <<'X'
#!/bin/sh
echo "pw-metadata $*" >>"$FAKE/log"
X
cat >"$T/bin/wpctl" <<'X'
#!/bin/sh
echo "wpctl $*" >>"$FAKE/log"
X
cat >"$T/bin/notify-send" <<'X'
#!/bin/sh
echo "notify $*" >>"$FAKE/log"
X
cat >"$T/bin/pkill" <<'X'
#!/bin/sh
echo "pkill $*" >>"$FAKE/log"
X
cat >"$T/bin/logger" <<'X'
#!/bin/sh
echo "logger $*" >>"$FAKE/log"
X
cat >"$T/bin/pactl" <<'X'
#!/bin/sh
# pactl fake: get-default-source from $FAKE/default-source, JSON lists from $FAKE/{cards,sources,sinks}.json, info ok
case "$*" in
  "get-default-source") cat "$FAKE/default-source" 2>/dev/null ;;
  "info") echo "Server Name: fake" ;;
  "--format=json list cards") cat "$FAKE/cards.json" 2>/dev/null || echo '[]' ;;
  "--format=json list sources") cat "$FAKE/sources.json" 2>/dev/null || echo '[]' ;;
  "--format=json list sinks") cat "$FAKE/sinks.json" 2>/dev/null || echo '[]' ;;
  "list short source-outputs") cat "$FAKE/source-outputs" 2>/dev/null ;;
  *) echo "pactl $*" >>"$FAKE/log" ;;
esac
exit 0
X
cat >"$T/bin/systemctl" <<'X'
#!/bin/sh
# systemctl --user fake: unit state machine in $FAKE/unit-state (active|inactive|failed), argv logged
echo "systemctl $*" >>"$FAKE/log"
shift   # --user
case "$1" in
  is-active) s=$(cat "$FAKE/unit-state" 2>/dev/null || echo inactive); echo "$s"; [ "$s" = active ]; exit ;;
  start|restart) [ -e "$FAKE/unit-start-fails" ] && exit 1; echo active >"$FAKE/unit-state"
    [ -x "$FAKE/on-unit-start" ] && "$FAKE/on-unit-start"; exit 0 ;;
  stop) echo inactive >"$FAKE/unit-state" ;;
esac
exit 0
X
chmod +x "$T/bin/"*
export FAKE="$F" PATH="$T/bin:$PATH" HOME="$T/home" XDG_RUNTIME_DIR="$T/run" USER=testuser
export EE_SOCKET="$T/run/EasyEffectsServer" EE_CONFIG_DIR="$T/home/.config/easyeffects" EE_DATA_DIR="$T/home/.local/share/easyeffects"
export EE_PROC_NAME="ee-fake-proc-$$"
export EE_PRESET_SRC="$T/home/.config/audio/easyeffects-mic.json" EE_BACKUP_DIR="$T/home/backup" EE_TMP_ROOT="$T/tmp"
mkdir -p "$T/home/.config/audio"
cp "$REPO/.config/audio/easyeffects-mic.json" "$EE_PRESET_SRC"

EEPID=""
ee_start() { # ee_start [fake-ee args]
  rm -f "$F/ee-log" "$F/ee-log.ready"
  python3 -I "$HERE/fake-ee.py" "$EE_SOCKET" "$F/ee-log" "$@" &
  EEPID=$!
  FAKEPIDS+=("$EEPID")
}
ee_wait() { local i; for i in $(seq 1 50); do [ -e "$F/ee-log.ready" ] && return 0; sleep 0.1; done; return 1; }
ee_stop() { [ -n "$EEPID" ] && { kill "$EEPID" 2>/dev/null; wait "$EEPID" 2>/dev/null; }; EEPID=""; rm -f "$EE_SOCKET"; }
reset_log() { : >"$F/log"; }
no_ee() { ee_stop; }

# ── 1. ee-ctl socket ──
if want 1; then
  ee_start; ee_wait
  [ "$("$EE" socket)" = "$EE_SOCKET" ] && pass "1 socket: EE_SOCKET wins" || fail "1 socket: EE_SOCKET wins"
  ee_stop
  # fallback to /tmp/runtime-$USER (the Qt rule when /run/user/UID is 0710)
  mkdir -p -m 700 "$T/tmp/runtime-testuser"
  ( EE_SOCKET= python3 -I "$HERE/fake-ee.py" "$T/tmp/runtime-testuser/EasyEffectsServer" "$F/ee-log2" & echo $! >"$F/pid2"; wait ) &
  FAKEPIDS+=("$!")
  for _ in $(seq 1 50); do [ -S "$T/tmp/runtime-testuser/EasyEffectsServer" ] && break; sleep 0.1; done
  [ "$(EE_SOCKET= "$EE" socket)" = "$T/tmp/runtime-testuser/EasyEffectsServer" ] && pass "1 socket: falls back to /tmp/runtime-USER" || fail "1 socket: falls back to /tmp/runtime-USER"
  chmod 770 "$T/tmp/runtime-testuser"
  if EE_SOCKET= "$EE" socket >/dev/null 2>&1; then fail "1 socket: refuses a group-writable dir"; else pass "1 socket: refuses a group-writable dir"; fi
  chmod 700 "$T/tmp/runtime-testuser"
  kill "$(cat "$F/pid2" 2>/dev/null)" 2>/dev/null
  rm -f "$T/tmp/runtime-testuser/EasyEffectsServer"
  : >"$T/run/notasocket"
  if EE_SOCKET="$T/run/notasocket" XDG_RUNTIME_DIR="$T/none" "$EE" socket >/dev/null 2>&1; then fail "1 socket: refuses a regular file"; else pass "1 socket: refuses a regular file"; fi
  rm -f "$T/run/notasocket"
fi

# ── 2. ee-ctl prepare ──
if want 2; then
  if ! command -v kwriteconfig6 >/dev/null 2>&1; then
    skip "2 prepare: kwriteconfig6 missing"
  else
    RC="$EE_CONFIG_DIR/db/easyeffectsrc"
    mkdir -p "$EE_CONFIG_DIR/db"
    cat >"$RC" <<'X'
[StreamInputs]
inputDevice=alsa_input.usb-Apple__Inc._EarPods
plugins=rnnoise#0,pitch#0,autotune#0,autogain#0
visiblePage=pluginsPage

[StreamOutputs]
outputDevice=alsa_output.stale.sink

[Window]
width=1275
X
    "$EE" prepare --dry-run >/dev/null
    cmp -s "$RC" <(cat <<'X'
[StreamInputs]
inputDevice=alsa_input.usb-Apple__Inc._EarPods
plugins=rnnoise#0,pitch#0,autotune#0,autogain#0
visiblePage=pluginsPage

[StreamOutputs]
outputDevice=alsa_output.stale.sink

[Window]
width=1275
X
) && [ ! -e "$EE_DATA_DIR/input/mic-clean.json" ] && pass "2 prepare --dry-run writes nothing" || fail "2 prepare --dry-run writes nothing"
    mkdir -p "$EE_DATA_DIR/input"
    echo '{"old":1}' >"$EE_DATA_DIR/input/mic-clean.json"
    "$EE" prepare; rc=$?
    out=$(python3 -I - "$RC" <<'PY'
import configparser, sys
c = configparser.RawConfigParser(interpolation=None, strict=False); c.optionxform = str; c.read(sys.argv[1])
want = {("Window","enableServiceMode"):"true",("Window","autostartOnLogin"):"false",("Window","width"):"1275",
 ("EffectsPipelines","processAllInputs"):"true",("EffectsPipelines","excludeMonitorStreams"):"true",
 ("EffectsPipelines","inactivityTimerEnable"):"true",("EffectsPipelines","bypass"):"false",
 ("StreamInputs","useDefaultInputDevice"):"true",("StreamInputs","inputDevice"):"",("StreamInputs","plugins"):"rnnoise#0",
 ("StreamInputs","listenToMic"):"false",("StreamInputs","blocklist"):"",("StreamInputs","visiblePage"):"pluginsPage",
 ("Presets","lastLoadedInputPreset"):"mic-clean",("StreamOutputs","outputDevice"):"alsa_output.stale.sink"}
bad = [k for k, v in want.items() if c.get(k[0], k[1], fallback=None) != v]
print("bad: %s" % bad if bad else "ok")
PY
)
    [ $rc -eq 0 ] && [ "$out" = ok ] && pass "2 prepare: managed keys written, other keys (outputs, width) untouched" || fail "2 prepare: managed keys ($out)"
    [ "$(readlink "$EE_DATA_DIR/input/mic-clean.json")" = "$EE_PRESET_SRC" ] && pass "2 prepare: preset linked to the repo file" || fail "2 prepare: preset link"
    ls "$T/home/backup"/preset-*/mic-clean.json >/dev/null 2>&1 && pass "2 prepare: a regular preset file is backed up, not lost" || fail "2 prepare: preset backup"
    "$EE" prepare && [ "$(readlink "$EE_DATA_DIR/input/mic-clean.json")" = "$EE_PRESET_SRC" ] && pass "2 prepare: idempotent" || fail "2 prepare: idempotent"
    if [ "$QUICK" = 0 ]; then
      ( exec -a "$EE_PROC_NAME" sleep 30 ) &
      FAKEPIDS+=("$!")
      sleep 0.3
      if "$EE" prepare >/dev/null 2>&1; then fail "2 prepare: refuses while easyeffects runs"; else pass "2 prepare: refuses while easyeffects runs"; fi
      kill "$!" 2>/dev/null
    fi
  fi
fi

# ── 3. ee-ctl load ──
if want 3; then
  ee_start; ee_wait
  "$EE" load --wait 3; rc=$?
  [ $rc -eq 0 ] && logged "load_preset:input:mic-clean" "$F/ee-log" && pass "3 load: sends load_preset:input:mic-clean and confirms it" || fail "3 load: confirm (rc $rc)"
  ee_stop
  ee_start --sticky-preset other-preset; ee_wait
  if "$EE" load --wait 1 >/dev/null 2>&1; then fail "3 load: fails when another preset is reported"; else pass "3 load: fails when another preset is reported"; fi
  ee_stop
  if [ "$QUICK" = 0 ]; then
    ee_start --delay 1; # late socket
    "$EE" load --wait 6; rc=$?
    [ $rc -eq 0 ] && pass "3 load: waits for a late socket" || fail "3 load: late socket (rc $rc)"
    ee_stop
  fi
  if "$EE" load --wait 1 >/dev/null 2>&1; then fail "3 load: fails without a server"; else pass "3 load: fails without a server"; fi
fi

# ── 4. ee-ctl ns ──
if want 4; then
  ee_start --bypass false; ee_wait; reset_log
  "$EE" ns status --quiet; rc=$?
  out=$("$EE" ns status --quiet)
  [ $rc -eq 0 ] && [ -z "$out" ] && pass "4 ns status --quiet: on = exit 0, silent" || fail "4 ns status --quiet ($rc '$out')"
  [ "$("$EE" ns status)" = on ] && pass "4 ns status prints on" || fail "4 ns status prints on"
  grep -q notify "$F/log" && fail "4 ns status never notifies" || pass "4 ns status never notifies"
  "$EE" ns off; rc=$?
  logged "set_property:input:rnnoise:0:bypass:true" "$F/ee-log" && [ $rc -eq 0 ] && pass "4 ns off sets bypass true" || fail "4 ns off"
  "$EE" ns status --quiet && fail "4 ns status after off is exit 1" || pass "4 ns status after off is exit 1"
  "$EE" ns toggle
  [ "$(tail -1 "$F/ee-log" | head -1)" != "" ] && logged "set_property:input:rnnoise:0:bypass:false" "$F/ee-log" && pass "4 ns toggle from off sets bypass false" || fail "4 ns toggle from off"
  "$EE" ns toggle
  [ "$(grep -c 'set_property.*bypass:true' "$F/ee-log")" -eq 2 ] && pass "4 ns toggle from on sets bypass true" || fail "4 ns toggle from on"
  "$EE" ns on
  [ "$(grep -c '^notify' "$F/log")" -eq 4 ] && pass "4 ns: one notification per change (off, toggle, toggle, on)" || fail "4 ns notifications ($(grep -c '^notify' "$F/log"))"
  grep -q 'pkill.*RTMIN+8' "$F/log" && pass "4 ns pokes the waybar toggles (RTMIN+8)" || fail "4 ns poke"
  ee_stop; ee_start --global 1; ee_wait
  "$EE" ns status --quiet && fail "4 ns status: global bypass on counts as off" || pass "4 ns status: global bypass on counts as off"
  ee_stop; reset_log
  "$EE" ns toggle >/dev/null 2>&1; rc=$?
  [ $rc -eq 1 ] && [ "$(grep -c '^notify' "$F/log")" -eq 1 ] && grep -q 'not running' "$F/log" && pass "4 ns toggle with EE dead: exit 1 + one notification" || fail "4 ns toggle dead (rc $rc)"
  reset_log
  "$EE" ns status --quiet; rc=$?
  [ $rc -eq 1 ] && ! grep -q '^notify' "$F/log" && pass "4 ns status with EE dead: exit 1, no notification" || fail "4 ns status dead"
fi

# ── 5. ee-ctl auto ──
if want 5; then
  cat >"$F/pw-dump.json" <<'X'
[{"id":30,"type":"PipeWire:Interface:Metadata","props":{"metadata.name":"default"},
  "metadata":[{"subject":0,"key":"default.audio.source","type":"Spa:String:JSON","value":{"name":"alsa_input.usb-fifine"}},
              {"subject":0,"key":"default.configured.audio.source","type":"Spa:String:JSON","value":{"name":"alsa_input.usb-fifine"}},
              {"subject":0,"key":"default.configured.audio.sink","type":"Spa:String:JSON","value":{"name":"alsa_output.pci-x"}},
              {"subject":0,"key":"default.audio.sink","type":"Spa:String:JSON","value":{"name":"alsa_output.pci-x"}}]}]
X
  reset_log
  "$EE" auto >/dev/null; rc=$?
  [ $rc -eq 0 ] && [ "$(grep -c '^pw-metadata' "$F/log")" -eq 1 ] && logged "pw-metadata -n default -d 0 default.configured.audio.source" "$F/log" && pass "5 auto: deletes only default.configured.audio.source" || fail "5 auto argv ($(cat "$F/log"))"
  grep -q 'sink\|all' "$F/log" && fail "5 auto never touches sink keys or 'all'" || pass "5 auto never touches sink keys or 'all'"
  cat >"$F/pw-dump.json" <<'X'
[{"id":30,"type":"PipeWire:Interface:Metadata","props":{"metadata.name":"default"},
  "metadata":[{"subject":0,"key":"default.audio.source","type":"Spa:String:JSON","value":{"name":"alsa_input.pci-x"}}]}]
X
  reset_log
  out=$("$EE" auto); rc=$?
  [ $rc -eq 0 ] && ! grep -q '^pw-metadata' "$F/log" && pass "5 auto: no pin, nothing run ($out)" || fail "5 auto without pin"
fi

# ── 11. static files ──
if want 11; then
  python3 -I - "$REPO/.config/audio/easyeffects-mic.json" <<'PY' && pass "11 preset: only rnnoise#0, vad off, bypass off" || fail "11 preset JSON"
import json, sys
p = json.load(open(sys.argv[1]))["input"]
assert p["plugins_order"] == ["rnnoise#0"], p["plugins_order"]
assert p["rnnoise#0"]["enable-vad"] is False and p["rnnoise#0"]["bypass"] is False
assert not [k for k in p if k.startswith(("pitch", "autotune", "autogain"))]
PY
  python3 -I - "$REPO/.config/wireplumber/wireplumber.conf.d/52-mic-priority.conf" <<'PY' && pass "11 52-mic-priority: fifine/EarPods 2600, webcam 900, internal 1000, BT/EE untouched" || fail "11 mic priority rules"
import re, sys
txt = open(sys.argv[1]).read()
rules = re.findall(r'node\.name = "(~?)([^"]+)".*?priority\.session = (\d+)', txt, re.S)
assert len(rules) == 3, rules
def prio(name, default):
    p = default
    for tilde, pat, val in rules:  # later rules override earlier ones
        if (re.search(pat, name) if tilde else name == pat):
            p = int(val)
    return p
assert prio("alsa_input.usb-3142_fifine_Microphone-00.analog-stereo", 2000) == 2600
assert prio("alsa_input.usb-Apple__Inc._EarPods_LY9V7QVJ2P-00.mono-fallback", 2000) == 2600
assert prio("alsa_input.usb-046d_HD_Pro_Webcam_C920-02.analog-stereo", 2000) == 900
assert prio("alsa_input.usb-Logitech_Camera_X-00.analog-stereo", 2000) == 900
assert prio("alsa_input.pci-0000_04_00.6.analog-stereo", 2009) == 1000
assert prio("bluez_input.40_58_99_2F_C1_63", 2010) == 2010
assert prio("easyeffects_source", 0) == 0
PY
  U="$REPO/.config/systemd/user/easyeffects.service"
  grep -q '^\[Install\]' "$U" && fail "11 unit has no [Install]" || pass "11 unit has no [Install]"
  grep -q '^ExecCondition=.*WAYLAND_DISPLAY' "$U" && grep -q '^Restart=on-failure' "$U" && grep -q '^PartOf=pipewire.service' "$U" && pass "11 unit: ExecCondition on the Wayland socket, Restart=on-failure, PartOf pipewire" || fail "11 unit keys"
  grep -q '^Restart=always' "$U" && fail "11 unit is never Restart=always" || pass "11 unit is never Restart=always"
  python3 -m py_compile "$EE" "$HERE/fake-ee.py" 2>/dev/null && pass "11 ee-ctl and fake-ee compile" || fail "11 py_compile"
  rm -rf "$REPO/.local/bin/__pycache__" "$HERE/__pycache__"
fi

echo "---- $passes passed, $fails failed"
[ "$fails" -eq 0 ]
