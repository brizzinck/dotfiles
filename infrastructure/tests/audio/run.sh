#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2015,SC1007,SC2174,SC2034,SC2181,SC2010
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
  is-active) s=$(cat "$FAKE/unit-state" 2>/dev/null || echo inactive); [ "$2" = --quiet ] || echo "$s"; [ "$s" = active ]; exit ;;
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

# ── audio-ensure fixtures ──
cat >"$T/bin/pw-record" <<'X'
#!/bin/sh
# fake pw-record: logs argv, writes a 16 kHz mono s16 wav (mode in $FAKE/rec-mode: live | constant | zeros) to the last argument
echo "pw-record $*" >>"$FAKE/log"
for a; do out=$a; done
python3 -I - "$out" "$(cat "$FAKE/rec-mode" 2>/dev/null || echo live)" <<'PY'
import array, math, sys
mode = sys.argv[2]
n = 24000
if mode == "live":
    s = [int(3000 * math.sin(i * 0.05) + (i * 7919 % 400)) for i in range(n)]
elif mode == "constant":
    s = [-30000 + (i % 3) for i in range(n)]
else:
    s = [0] * n
a = array.array("h", s)
open(sys.argv[1], "wb").write(b"RIFF" + b"\0" * 40 + a.tobytes())
PY
X
chmod +x "$T/bin/pw-record"
export AE_EE_BIN=/bin/sh AE_EE_UNIT="$T/home/easyeffects.service" EE_CTL="$EE" AE_FAST=1 AE_WAIT_N=3 XDG_STATE_HOME="$T/state"
: >"$AE_EE_UNIT"
mkdir -p "$T/state/wireplumber"
HWSRC=alsa_input.pci-0000_04_00.6.analog-stereo
ae_fixture() { # healthy world: cards on their profile, hw sink+source, default = hw, good rc, no pin, no links, unit active
  echo '[{"name":"alsa_card.pci-0000_04_00.6","active_profile":"HiFi","profiles":{"HiFi":{"available":true}}}]' >"$F/cards.json"
  echo '[{"name":"alsa_output.pci-0000_04_00.6.analog-stereo"},{"name":"easyeffects_sink"}]' >"$F/sinks.json"
  printf '[{"name":"%s"},{"name":"easyeffects_source"},{"name":"alsa_output.x.monitor"}]\n' "$HWSRC" >"$F/sources.json"
  echo "$HWSRC" >"$F/default-source"
  echo '[{"id":30,"type":"PipeWire:Interface:Metadata","props":{"metadata.name":"default"},"metadata":[{"subject":0,"key":"default.audio.source","type":"Spa:String:JSON","value":{"name":"'"$HWSRC"'"}}]}]' >"$F/pw-dump.json"
  echo active >"$F/unit-state"
  rm -f "$F/unit-start-fails" "$F/rec-mode" "$T/state/wireplumber/stream-properties"
  mkdir -p "$EE_CONFIG_DIR/db"
  cat >"$EE_CONFIG_DIR/db/easyeffectsrc" <<'X2'
[EffectsPipelines]
processAllInputs=true

[StreamInputs]
useDefaultInputDevice=true
listenToMic=false
plugins=rnnoise#0
X2
  reset_log
}
ae() { "$AE" "$@"; }

# ── 6. audio-ensure --ee ──
if want 6; then
  ae_fixture; ee_stop; ee_start --preset mic-clean; ee_wait
  out=$(ae --ee); rc=$?
  [ $rc -eq 0 ] && [ -z "$out" ] && pass "6 --ee: healthy chain = exit 0, no lines" || fail "6 --ee healthy (rc $rc: $out)"
  ae --check >/dev/null; [ $? -eq 0 ] && pass "6 --check: healthy = exit 0" || fail "6 --check healthy"
  echo easyeffects_source >"$F/default-source"
  out=$(ae --ee); rc=$?
  [ $rc -eq 1 ] && grep -q 'default source is easyeffects_source' <<<"$out" && pass "6 --ee: default = easyeffects_source with a microphone present (A)" || fail "6 --ee A (rc $rc: $out)"
  ae --check | grep -q 'default source is easyeffects_source' && pass "6 --check carries the A line" || fail "6 --check A line"
  echo "$HWSRC" >"$F/default-source"
  echo inactive >"$F/unit-state"
  out=$(ae --ee); rc=$?
  [ $rc -eq 1 ] && grep -q 'unit is not active' <<<"$out" && pass "6 --ee: unit inactive (C)" || fail "6 --ee unit (rc $rc: $out)"
  echo active >"$F/unit-state"
  ee_stop; ee_start --preset other-preset; ee_wait
  out=$(ae --ee); rc=$?
  [ $rc -eq 1 ] && grep -q 'preset is "other-preset"' <<<"$out" && pass "6 --ee: wrong preset (C)" || fail "6 --ee preset (rc $rc: $out)"
  ee_stop; ee_start --preset mic-clean --global 1; ee_wait
  out=$(ae --ee); rc=$?
  [ $rc -eq 1 ] && grep -q 'global bypass is on' <<<"$out" && pass "6 --ee: global bypass on (C)" || fail "6 --ee global (rc $rc: $out)"
  ee_stop; ee_start --preset mic-clean --bypass true; ee_wait
  out=$(ae --ee); rc=$?
  [ $rc -eq 0 ] && grep -q '^note: noise suppression is switched off' <<<"$out" && pass "6 --ee: rnnoise bypass = owner's toggle, info only" || fail "6 --ee bypass (rc $rc: $out)"
  ee_stop; ee_start --preset mic-clean; ee_wait
  sed -i 's/processAllInputs=true/processAllInputs=false/' "$EE_CONFIG_DIR/db/easyeffectsrc"
  out=$(ae --ee); rc=$?
  [ $rc -eq 1 ] && grep -q 'processAllInputs is "false"' <<<"$out" && pass "6 --ee: processAllInputs=false (C)" || fail "6 --ee processAll (rc $rc: $out)"
  sed -i 's/processAllInputs=false/processAllInputs=true/; s/^plugins=.*/plugins=rnnoise#0,pitch#0/' "$EE_CONFIG_DIR/db/easyeffectsrc"
  out=$(ae --ee); rc=$?
  [ $rc -eq 1 ] && grep -q 'old pitch/autotune/autogain chain' <<<"$out" && pass "6 --ee: old pitch plugin in the rc (C)" || fail "6 --ee pitch (rc $rc: $out)"
  sed -i 's/^plugins=.*/plugins=rnnoise#0/; s/^listenToMic=.*/listenToMic=true/' "$EE_CONFIG_DIR/db/easyeffectsrc"
  out=$(ae --ee); rc=$?
  [ $rc -eq 1 ] && grep -q 'listenToMic is true' <<<"$out" && pass "6 --ee: listenToMic (C)" || fail "6 --ee listenToMic (rc $rc: $out)"
  sed -i 's/^listenToMic=.*/listenToMic=false/' "$EE_CONFIG_DIR/db/easyeffectsrc"
  cat >"$F/pw-dump.json" <<X2
[{"id":30,"type":"PipeWire:Interface:Metadata","props":{"metadata.name":"default"},"metadata":[
  {"subject":0,"key":"default.configured.audio.source","type":"Spa:String:JSON","value":{"name":"alsa_input.usb-fifine"}}]}]
X2
  out=$(ae --ee); rc=$?
  [ $rc -eq 0 ] && grep -q '^note: microphone is pinned by a manual choice (alsa_input.usb-fifine)' <<<"$out" && pass "6 --ee: a source pin is info only (exit 0)" || fail "6 --ee pin (rc $rc: $out)"
  ae_fixture
  printf '[stream-properties]\nInput/Audio:application.name:Foo={"target":"alsa_input.usb-x"}\nOutput/Audio:application.name:Bar={"target":"easyeffects_sink"}\n' >"$T/state/wireplumber/stream-properties"
  out=$(ae --ee); rc=$?
  [ $rc -eq 0 ] && grep -q '^note: WirePlumber stream-properties stores a capture target' <<<"$out" && pass "6 --ee: stored capture target = info (G5)" || fail "6 --ee G5 (rc $rc: $out)"
  AE_EE_BIN=/nonexistent ae --ee >/dev/null; [ $? -eq 3 ] && pass "6 --ee: EasyEffects not installed = exit 3" || fail "6 --ee n/a"
  AE_EE_UNIT=/nonexistent ae --ee >/dev/null; [ $? -eq 3 ] && pass "6 --ee: unit file missing = exit 3" || fail "6 --ee n/a unit"
  grep -q '^notify' "$F/log" && fail "6 check modes never notify" || pass "6 check modes never notify"
  ee_stop
fi

# ── 7. audio-ensure --boot / fix ──
if want 7; then
  PIN='[{"id":30,"type":"PipeWire:Interface:Metadata","props":{"metadata.name":"default"},"metadata":[{"subject":0,"key":"default.configured.audio.source","type":"Spa:String:JSON","value":{"name":"alsa_input.usb-fifine"}}]}]'
  ae_fixture; echo inactive >"$F/unit-state"; echo "$PIN" >"$F/pw-dump.json"; ee_stop; ee_start --preset mic-clean; ee_wait
  ae --boot 2>"$F/err"; rc=$?
  [ $rc -eq 0 ] && logged "pw-metadata -n default -d 0 default.configured.audio.source" "$F/log" && pass "7 --boot clears the source pin" || fail "7 --boot pin (rc $rc)"
  logged "systemctl --user start easyeffects" "$F/log" && pass "7 --boot starts the unit" || fail "7 --boot start"
  [ "$(grep -c 'mic chain ok' "$F/err")" -eq 1 ] && grep -q "mic chain ok: $HWSRC -> easyeffects (RNNoise) -> apps" "$F/err" && pass "7 --boot healthy: one 'mic chain ok' line" || fail "7 --boot healthy line ($(cat "$F/err"))"
  grep -q '^notify' "$F/log" && fail "7 --boot healthy never notifies" || pass "7 --boot healthy never notifies"
  # broken: the preset never takes -> one restart, exactly one notification
  ae_fixture; echo inactive >"$F/unit-state"; ee_stop; ee_start --sticky-preset other-preset; ee_wait
  ae --boot 2>"$F/err"; rc=$?
  [ $rc -eq 1 ] && [ "$(grep -c 'systemctl --user restart easyeffects' "$F/log")" -eq 1 ] && pass "7 --boot broken: the unit is restarted exactly once" || fail "7 --boot restart count (rc $rc)"
  [ "$(grep -c '^notify' "$F/log")" -eq 1 ] && grep -q 'noise suppression is not running' "$F/log" && pass "7 --boot broken: exactly one notification" || fail "7 --boot notification ($(grep -c '^notify' "$F/log"))"
  # fix mode: pin kept, no notification, unit started
  ae_fixture; echo inactive >"$F/unit-state"; echo "$PIN" >"$F/pw-dump.json"; ee_stop; ee_start --sticky-preset other-preset; ee_wait
  ae 2>"$F/err"; rc=$?
  grep -q 'pw-metadata' "$F/log" && fail "7 fix mode never clears the pin" || pass "7 fix mode never clears the pin"
  logged "systemctl --user start easyeffects" "$F/log" && pass "7 fix mode starts a stopped unit" || fail "7 fix start"
  grep -q '^notify' "$F/log" && fail "7 fix mode never notifies" || pass "7 fix mode never notifies"
  # card heal still works: a card on off with an available saved profile restarts wireplumber once
  ae_fixture; ee_stop; ee_start --preset mic-clean; ee_wait
  echo '[{"name":"alsa_card.pci-0000_04_00.6","active_profile":"off","profiles":{"HiFi":{"available":true}}}]' >"$F/cards.json"
  printf '[default-profile]\nalsa_card.pci-0000_04_00.6=HiFi\n' >"$T/state/wireplumber/default-profile"
  ae --check | grep -q 'is on profile off' && pass "7 --check still reports a card stuck on off" || fail "7 --check card"
  ae 2>"$F/err"; grep -q 'restarting wireplumber' "$F/err" && logged "systemctl --user restart wireplumber.service" "$F/log" && pass "7 fix mode still restarts wireplumber for a stuck card" || fail "7 card heal"
  rm -f "$T/state/wireplumber/default-profile"
  ee_stop
fi

# ── 8. mic probes ──
if want 8; then
  ae_fixture; ee_stop
  ae --mic >"$F/out"; rc=$?
  [ $rc -eq 0 ] && grep -q '^live signal' "$F/out" && pass "8 --mic: live signal = exit 0" || fail "8 --mic live (rc $rc)"
  grep -q "pw-record -P { node.dont-move = true } --target $HWSRC" "$F/log" && pass "8 --mic: the raw probe carries node.dont-move and the default source" || fail "8 --mic argv ($(cat "$F/log"))"
  echo constant >"$F/rec-mode"; ae --mic >/dev/null; [ $? -eq 1 ] && pass "8 --mic: constant rail = exit 1" || fail "8 --mic constant"
  echo zeros >"$F/rec-mode"; ae --mic >/dev/null; [ $? -eq 2 ] && pass "8 --mic: digital silence = exit 2" || fail "8 --mic zeros"
  rm -f "$F/rec-mode"
  CHAINOK='{"id":1,"type":"PipeWire:Interface:Node","info":{"props":{"node.name":"'"$HWSRC"'"}}},
 {"id":2,"type":"PipeWire:Interface:Node","info":{"props":{"node.name":"ee_sie_rnnoise#0"}}},
 {"id":3,"type":"PipeWire:Interface:Node","info":{"props":{"node.name":"easyeffects_source"}}},
 {"id":4,"type":"PipeWire:Interface:Node","info":{"props":{"node.name":"pw-record"}}},
 {"id":10,"type":"PipeWire:Interface:Link","info":{"output-node-id":1,"input-node-id":2}},
 {"id":11,"type":"PipeWire:Interface:Link","info":{"output-node-id":3,"input-node-id":4}}'
  echo "[$CHAINOK]" >"$F/pw-dump.json"
  reset_log
  out=$(ae --mic --chain); rc=$?
  [ $rc -eq 0 ] && grep -q "^live signal .* via $HWSRC\$" <<<"$out" && pass "8 --mic --chain: live signal via the default microphone, exit 0" || fail "8 --mic --chain (rc $rc: $out)"
  grep -q 'pw-record --target easyeffects_source' "$F/log" && ! grep -q 'dont-move' "$F/log" && pass "8 --mic --chain records easyeffects_source (no dont-move)" || fail "8 --mic --chain argv"
  echo "[${CHAINOK//\"output-node-id\":1,/\"output-node-id\":5,}, {\"id\":5,\"type\":\"PipeWire:Interface:Node\",\"info\":{\"props\":{\"node.name\":\"alsa_input.usb-other\"}}}]" >"$F/pw-dump.json"
  out=$(ae --mic --chain); rc=$?
  [ $rc -eq 4 ] && grep -q 'EasyEffects reads alsa_input.usb-other, default is' <<<"$out" && pass "8 --mic --chain: EE linked to a non-default node = exit 4" || fail "8 --mic --chain non-default (rc $rc: $out)"
  echo '[]' >"$F/pw-dump.json"
  ae --mic --chain >/dev/null; [ $? -eq 4 ] && pass "8 --mic --chain: nothing linked = exit 4" || fail "8 --mic --chain unlinked"
  printf '[{"name":"%s"}]\n' "$HWSRC" >"$F/sources.json"
  ae --mic --chain >/dev/null; [ $? -eq 3 ] && pass "8 --mic --chain: no easyeffects_source = exit 3" || fail "8 --mic --chain n/a"
  ae --chain >/dev/null 2>&1; [ $? -eq 2 ] && pass "8 --chain without --mic is a usage error" || fail "8 --chain usage"
  ls "$T/run" | grep -q audio-mic && fail "8 probes leave no temp audio" || pass "8 probes leave no temp audio"
fi

# ── 10. audio-picker (input rows) ──
if want 10; then
  AP="$REPO/.config/hypr/scripts/audio-picker.sh"
  node() { printf '{"id":%s,"type":"PipeWire:Interface:Node","info":{"props":{"media.class":"%s","node.name":"%s","node.description":"%s"}}}' "$1" "$2" "$3" "$4"; }
  meta() { printf '{"id":30,"type":"PipeWire:Interface:Metadata","props":{"metadata.name":"default"},"metadata":[%s]}' "$1"; }
  mkdir -p "$T/bin2"
  cat >"$T/bin2/pactl" <<'X'
#!/bin/sh
case "$*" in
  "get-default-sink") echo alsa_output.pci-x.analog-stereo ;;
  "get-default-source") cat "$FAKE/default-source" ;;
  "list short sink-inputs") printf '41\t5\t6\tx\n42\t5\t6\tx\n' ;;
  "list short source-outputs") printf '51\t5\t6\tx\n' ;;
  *) echo "pactl $*" >>"$FAKE/log" ;;
esac
X
  chmod +x "$T/bin2/pactl"
  echo "$HWSRC" >"$F/default-source"
  echo "[$(node 10 Audio/Sink alsa_output.pci-x.analog-stereo "Speakers"),$(node 11 Audio/Source "$HWSRC" "Built-in mic"),$(node 12 Audio/Source alsa_input.usb-fifine "Fifine USB"),$(meta '')]" >"$F/pw-dump.json"
  OLDPATH=$PATH; PATH="$T/bin2:$PATH"
  list=$("$AP" --list)
  grep -q $'^1\t● Input: Automatic (best microphone)' <<<"$list" && pass "10 picker: the Automatic row heads the Input rows and carries the marker without a pin" || fail "10 picker list ($list)"
  grep -q $'^2\t● Input: Built-in mic' <<<"$list" && pass "10 picker: the default input keeps its marker" || fail "10 picker default marker"
  out=$("$AP" --pick 3 --dry-run)
  [ "$out" = "wpctl set-default 12" ] && pass "10 picker: an Input pick is only wpctl set-default (no move-source-output)" || fail "10 picker input pick ($out)"
  out=$("$AP" --pick 1 --dry-run)
  [ "$out" = "ee-ctl auto" ] && pass "10 picker: the Automatic row runs ee-ctl auto" || fail "10 picker auto ($out)"
  out=$("$AP" --pick 0 --dry-run)
  grep -q '^pactl move-sink-input 41 alsa_output.pci-x.analog-stereo' <<<"$out" && grep -q '^wpctl set-default 10' <<<"$out" && pass "10 picker: an Output pick still moves the playback streams" || fail "10 picker output pick ($out)"
  echo "[$(node 10 Audio/Sink alsa_output.pci-x.analog-stereo "Speakers"),$(node 11 Audio/Source "$HWSRC" "Built-in mic"),$(meta '{"subject":0,"key":"default.configured.audio.source","type":"Spa:String:JSON","value":{"name":"x"}}')]" >"$F/pw-dump.json"
  "$AP" --list | grep -q $'^1\t  Input: Automatic' && pass "10 picker: no marker on Automatic while a manual choice pins the source" || fail "10 picker pinned marker"
  PATH=$OLDPATH
fi

# ── 12. waybar toggles (ns) ──
if want 12; then
  TG="$REPO/.config/waybar/scripts/toggles.sh"
  mkdir -p "$T/home/.local/bin"
  ln -sf "$EE" "$T/home/.local/bin/ee-ctl"
  export TOGGLES_EE_BIN=/bin/sh
  echo "$HWSRC" >"$F/default-source"
  printf '[{"name":"%s","description":"Built-in mic"}]\n' "$HWSRC" >"$F/sources.json"
  ee_stop; ee_start --preset mic-clean; ee_wait
  out=$("$TG" switch ns)
  [ "$(jq -r .class <<<"$out")" = enabled ] && grep -q 'on (Built-in mic)' <<<"$out" && grep -q 'L: toggle"' <<<"$out" && pass "12 toggles: ns on = enabled, shows the active microphone, hint line" || fail "12 toggles ns on ($out)"
  "$TG" state ns && pass "12 toggles: state ns = exit 0 when on" || fail "12 toggles state on"
  sum=$("$TG" summary-raw)
  grep -q '󰍬\|󰍭' <<<"$(jq -r .text <<<"$sum")" && fail "12 toggles: ns on never appears in the summary glyphs" || pass "12 toggles: ns on never appears in the summary glyphs"
  [ "$(jq -r .class <<<"$sum")" = dim ] && pass "12 toggles: healthy machine still reads all off" || fail "12 toggles summary class ($sum)"
  ee_stop; ee_start --preset mic-clean --bypass true; ee_wait
  out=$("$TG" switch ns)
  [ "$(jq -r .class <<<"$out")" = dim ] && grep -q 'Noise suppression (EasyEffects): off' <<<"$out" && pass "12 toggles: ns off = dim child" || fail "12 toggles ns off ($out)"
  sum=$("$TG" summary-raw)
  [ "$(jq -r .class <<<"$sum")" = warning ] && [ "$(jq -r .text <<<"$sum")" = '󰍭' ] && pass "12 toggles: ns off shows its glyph in the summary with class warning" || fail "12 toggles summary off ($sum)"
  "$TG" state ns && fail "12 toggles: state ns = exit 1 when off" || pass "12 toggles: state ns = exit 1 when off"
  ee_stop
  out=$("$TG" switch ns)
  grep -q 'EasyEffects is not running' <<<"$out" && pass "12 toggles: EasyEffects not running is spelled out" || fail "12 toggles dead ($out)"
  [ "$(jq -r .class <<<"$("$TG" summary-raw)")" = warning ] && pass "12 toggles: a dead chain is a warning in the summary" || fail "12 toggles dead summary"
  out=$(TOGGLES_EE_BIN=/nonexistent "$TG" switch ns)
  [ "$(jq -r .text <<<"$out")" = "" ] && pass "12 toggles: without EasyEffects the switch is hidden" || fail "12 toggles hidden ($out)"
  unset TOGGLES_EE_BIN
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
