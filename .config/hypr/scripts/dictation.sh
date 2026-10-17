#!/usr/bin/env bash
# dictation: offline voice typing with Voxtype (AUR voxtype-bin), local Whisper, ru / uk / en. Nothing leaves the machine.
#   dictation.sh toggle        SUPER+ALT+D: start dictating, or stop and type the text into the focused window
#   dictation.sh start|stop    F9 held = start on press, stop on release
#   dictation.sh cycle         SUPER+ALT+SHIFT+D, waybar middle click: next language ru -> uk -> en -> ru (one replacing notification)
#   dictation.sh lang [L]      choose the language: ru, uk, en, auto or a comma list such as en,ru,uk (no argument: fzf-menu);
#                              remembered in ~/.local/state/dictation/lang, default ru; restarts the daemon
#   dictation.sh model [NAME]  no argument: download the chosen model when it is missing; NAME (small, large-v3-turbo, ...):
#                              download it if needed and make it the chosen one (~/.local/state/dictation/model, default small)
#   dictation.sh backend [--probe|--path]   which build runs (GPU Vulkan or CPU avx512/avx2/baseline); --probe redoes the detection
#   dictation.sh status        idle | recording | transcribing | off
#   dictation.sh --follow      continuous JSON for waybar custom/dictation (always shows the language and the state)
#   dictation.sh run           what voxtype.service executes (language + model into a runtime copy of the config, then the
#                              best daemon binary of /usr/lib/voxtype, no root needed)
#   dictation.sh menu          waybar right click: language, model, backend, status
#   --dry-run                  print what would run
# Backend choice (no root, no PATH hack, no drop-in): the package ships voxtype-{vulkan,avx512,avx2,baseline}. run executes the
# variant directly: Vulkan when a real GPU works (probed once with a silent clip, cached in ~/.local/state/dictation/backend
# until the Vulkan build, an ICD file or the kernel changes; llvmpipe does not count; two automatic restarts of the unit demote
# it), else the best CPU build by the CPU flags (avx512 > avx2 > baseline).
# Everything is guarded like pointer.sh: without voxtype the keys only show how to install it. Media that plays is paused while
# you dictate and resumed afterwards. The microphone is shared with calls: never start it while a call is running.
set -u

RT="${XDG_RUNTIME_DIR:-/tmp}"
STATE_FILE="$RT/voxtype/state"
SDIR="${XDG_STATE_HOME:-$HOME/.local/state}/dictation"
LANGF="$SDIR/lang"
MODELF="$SDIR/model"
BACKF="$SDIR/backend"
DEFAULT_LANG=ru
DEFAULT_MODEL=small
PAUSED_MARK="$RT/dictation-paused-media"
MODEL_DIR="${VOXTYPE_MODEL_DIR:-$HOME/.local/share/voxtype/models}"
MODEL_URL_BASE="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
LIBDIR="${VOXTYPE_LIBDIR:-/usr/lib/voxtype}"
CPUINFO="${DICTATION_CPUINFO:-/proc/cpuinfo}"
CONF_SRC="${XDG_CONFIG_HOME:-$HOME/.config}/voxtype/config.toml"
G_MIC='󰍬'
G_BUSY='󰔟'
DRY=0
args=()
for a in "$@"; do
  if [[ $a == --dry-run ]]; then DRY=1; else args+=("$a"); fi
done
set -- "${args[@]+"${args[@]}"}"


say() { if ((DRY)); then echo "note: $*"; else notify-send -a dictation -t 3500 -h string:x-dunst-stack-tag:dictation "$@"; fi; }
poke() { pkill -o -u "$UID" -RTMIN+18 -x waybar 2>/dev/null || true; }

# --- chosen language and model (state files; defaults ru and small) ---
valid_lang() { [[ $1 == auto || $1 =~ ^(ru|uk|en)(,(ru|uk|en))*$ ]]; }
# _lang / _model set LANG_V / MODEL_V without a subshell (the --follow loop calls them every tick, so they must not fork)
_lang() { LANG_V=""; [[ -r $LANGF ]] && read -r LANG_V <"$LANGF"; valid_lang "$LANG_V" || LANG_V=$DEFAULT_LANG; }
lang() { _lang; echo "$LANG_V"; }
valid_model() { [[ $1 =~ ^[a-z0-9][a-z0-9.-]*$ ]]; }
_model() { MODEL_V=""; [[ -r $MODELF ]] && read -r MODEL_V <"$MODELF"; valid_model "$MODEL_V" || MODEL_V=$DEFAULT_MODEL; }
model_name() { _model; echo "$MODEL_V"; }
model_path() { echo "$MODEL_DIR/ggml-${1:-$(model_name)}.bin"; }
model_ok() { [[ -s $(model_path) ]]; }

# --- voxtype binaries ---
# the client binary only sends signals to the daemon (record start|stop); VOXTYPE_BIN replaces both roles (tests)
vt_client() {
  if [[ -n ${VOXTYPE_BIN:-} ]]; then [[ -x $VOXTYPE_BIN ]] && echo "$VOXTYPE_BIN"; return; fi
  command -v voxtype
}
installed() { vt_client >/dev/null 2>&1; }
need_voxtype() {
  installed && return 0
  say -u normal "Dictation needs voxtype" "install with: sudo ./apply-system.sh --only install   (or the hub row, Setup)"
  return 1
}

# --- backend: Vulkan when a real GPU works, else the best CPU build by CPU flags ---
cpu_variant() { # prints avx512 | avx2 | baseline (only builds that exist), nothing when none exists
  local flags
  flags=" $(grep -m1 '^flags' "$CPUINFO" 2>/dev/null) "
  has() { [[ $flags == *" $1 "* ]]; }
  if has avx512f && has avx512bw && has avx512vl && has avx512dq && [[ -x $LIBDIR/voxtype-avx512 ]]; then echo avx512; return; fi
  if has avx2 && has fma && [[ -x $LIBDIR/voxtype-avx2 ]]; then echo avx2; return; fi
  [[ -x $LIBDIR/voxtype-baseline ]] && echo baseline
  return 0
}

probe_model() { # the smallest installed model, so the probe is quick
  local m
  for m in tiny base small "$(model_name)"; do [[ -s $(model_path "$m") ]] && { echo "$m"; return 0; }; done
  return 1
}

# probe_vulkan: 0 = a real GPU works (prints its name), 1 = no usable GPU, 2 = cannot probe (no model yet)
probe_vulkan() {
  local bin=$LIBDIR/voxtype-vulkan m wav out dev
  [[ -x $bin ]] || return 1
  m=$(probe_model) || return 2
  wav="$RT/dictation-probe.wav"
  # one second of silence, 16 kHz mono 16-bit
  { printf 'RIFF\x24\x7d\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x80\x3e\x00\x00\x00\x7d\x00\x00\x02\x00\x10\x00data\x00\x7d\x00\x00'; head -c 32000 /dev/zero; } >"$wav"
  out=$(timeout 40 "$bin" --model "$m" --language en transcribe "$wav" 2>&1)
  rm -f "$wav"
  grep -q 'using Vulkan' <<<"$out" || return 1
  dev=$(sed -n 's/^ggml_vulkan: [0-9]* = \([^|]*[^| ]\) *|.*/\1/p' <<<"$out" | head -n1 | sed 's/ ([a-z_]*)$//')
  grep -qiE 'llvmpipe|lavapipe|swiftshader|software' <<<"$dev" && return 1
  echo "${dev:-Vulkan device}"
}

backend_key() { # changes when the Vulkan build, an ICD file or the kernel changes
  { stat -c '%n %Y %s' "$LIBDIR/voxtype-vulkan" /usr/share/vulkan/icd.d/*.json /etc/vulkan/icd.d/*.json 2>/dev/null; uname -r; } | cksum | cut -d' ' -f1
}
read_cache() {
  C_KEY="" C_BACKEND="" C_DEVICE="" C_REASON=""
  local k v
  [[ -r $BACKF ]] || return 1
  while IFS='=' read -r k v; do
    case $k in key) C_KEY=$v ;; backend) C_BACKEND=$v ;; device) C_DEVICE=$v ;; reason) C_REASON=$v ;; esac
  done <"$BACKF"
  [[ -n $C_BACKEND ]]
}
write_cache() { # write_cache KEY
  mkdir -p "$SDIR"
  printf 'key=%s\nbackend=%s\ndevice=%s\nreason=%s\n' "$1" "$BK_BACKEND" "$BK_DEVICE" "$BK_REASON" >"$BACKF.tmp" && mv -f "$BACKF.tmp" "$BACKF"
}

# resolve_backend [--probe]: sets BK_BACKEND (vulkan | avx512 | avx2 | baseline | package | custom), BK_BIN, BK_DEVICE, BK_REASON
resolve_backend() {
  local key dev rc
  BK_BACKEND="" BK_BIN="" BK_DEVICE="" BK_REASON=""
  if [[ -n ${VOXTYPE_BIN:-} ]]; then BK_BACKEND=custom BK_BIN=$VOXTYPE_BIN BK_REASON="VOXTYPE_BIN"; return 0; fi
  key=$(backend_key)
  if [[ ${1:-} != --probe ]] && read_cache && [[ $C_KEY == "$key" ]]; then
    BK_BACKEND=$C_BACKEND BK_DEVICE=$C_DEVICE BK_REASON=$C_REASON
  else
    dev=$(probe_vulkan)
    rc=$?
    if ((rc == 0)); then
      BK_BACKEND=vulkan BK_DEVICE=$dev BK_REASON="Vulkan device works"
    else
      BK_BACKEND=$(cpu_variant)
      ((rc == 1)) && BK_REASON="no usable Vulkan device" || BK_REASON="Vulkan not probed yet (no model)"
    fi
    ((rc == 2)) || write_cache "$key"
  fi
  case $BK_BACKEND in
    vulkan) BK_BIN=$LIBDIR/voxtype-vulkan ;;
    avx512 | avx2 | baseline) BK_BIN=$LIBDIR/voxtype-$BK_BACKEND ;;
  esac
  if [[ -z $BK_BIN || ! -x $BK_BIN ]]; then BK_BACKEND=package BK_BIN=$(command -v voxtype) BK_REASON="no variant in $LIBDIR"; fi
  return 0
}
backend_label() {
  case $BK_BACKEND in
    vulkan) echo "GPU Vulkan${BK_DEVICE:+ ($BK_DEVICE)}" ;;
    avx512 | avx2 | baseline) echo "CPU $BK_BACKEND" ;;
    package) echo "CPU (package default)" ;;
    custom) echo "custom ($BK_BIN)" ;;
    *) echo "not detected yet (set when the daemon starts)" ;;
  esac
}

cmd_backend() {
  case ${1:-} in
    --probe) resolve_backend --probe ;;
    --path) resolve_backend; echo "$BK_BIN"; return 0 ;;
    *) resolve_backend ;;
  esac
  echo "backend: $(backend_label)"
  echo "binary:  $BK_BIN"
  echo "reason:  $BK_REASON"
}

# --- models ---
cmd_model() {
  local name=${1:-} f url want got
  if [[ -z $name ]]; then name=$(model_name); fi
  valid_model "$name" || { echo "dictation: bad model name: $name" >&2; return 2; }
  f=$(model_path "$name")
  url="$MODEL_URL_BASE/ggml-$name.bin"
  if [[ ! -s $f ]]; then
    if ((DRY)); then echo "curl -L -C - -o $f.part $url && mv -f $f.part $f"
    else
      mkdir -p "$MODEL_DIR"
      want=$(curl -sIL --max-time 20 "$url" | tr -d '\r' | awk 'tolower($1)=="content-length:" {n=$2} END {print n+0}')
      say "Dictation: downloading the Whisper model" "ggml-$name.bin, $((want / 1048576)) MB, once"
      got=$(stat -c %s "$f.part" 2>/dev/null || echo 0)
      if ((want == 0 || got < want)); then curl -L -C - --fail --progress-bar -o "$f.part" "$url"; fi
      got=$(stat -c %s "$f.part" 2>/dev/null || echo 0)
      # a short file is a failed download (small is 487601967 bytes, large-v3-turbo 1624555275)
      if ((got > 50000000 && (want == 0 || got >= want))); then
        mv -f "$f.part" "$f"
        say "Dictation: model ready" "$f"
      else
        say -u normal "Dictation: model download failed" "run again: dictation.sh model $name (it resumes)"
        return 1
      fi
    fi
  fi
  # an explicit name also becomes the chosen model
  if [[ -n ${1:-} && $name != "$(model_name)" ]]; then
    if ((DRY)); then echo "model -> $name (file $MODELF), systemctl --user restart voxtype.service"; return 0; fi
    mkdir -p "$SDIR"
    echo "$name" >"$MODELF"
    systemctl --user try-restart --no-block voxtype.service 2>/dev/null || true
    say "Dictation model: $name"
  fi
  return 0
}

ensure_daemon() {
  systemctl --user is-active -q voxtype.service && return 0
  if ((DRY)); then echo "systemctl --user start voxtype.service"; return 0; fi
  systemctl --user start voxtype.service 2>/dev/null
  # the daemon needs a moment to load the model before it accepts a record command
  for _ in 1 2 3 4 5 6 7 8 9 10; do systemctl --user is-active -q voxtype.service && break; sleep 0.3; done
  sleep 0.5
}

ready() { need_voxtype || return 1; if ! model_ok; then
    say -u normal "Dictation: the model is missing" "downloading $(model_name) now, then try again"
    ((DRY)) || [[ ${DICTATION_NO_DOWNLOAD:-0} == 1 ]] || setsid -f "$0" model >/dev/null 2>&1 </dev/null
    return 1
  fi
  ensure_daemon; }

status_text() { # idle | recording | transcribing | off
  local s
  if ! installed; then echo off; return; fi
  s=$(cat "$STATE_FILE" 2>/dev/null)
  case $s in recording | transcribing) echo "$s" ;; idle) echo idle ;; *) systemctl --user is-active -q voxtype.service && echo idle || echo off ;; esac
}

pause_media() {
  command -v playerctl >/dev/null 2>&1 || return 0
  if playerctl -a status 2>/dev/null | grep -qx Playing; then
    : >"$PAUSED_MARK"
    playerctl -a pause 2>/dev/null
  fi
}
resume_media() {
  [[ -e $PAUSED_MARK ]] || return 0
  rm -f "$PAUSED_MARK"
  command -v playerctl >/dev/null 2>&1 && playerctl play 2>/dev/null
  return 0
}

cmd_toggle() {
  ready || return 0
  if [[ $(status_text) == recording ]]; then cmd_stop_inner; else cmd_start_inner; fi
}
cmd_start_inner() {
  if ((DRY)); then echo "voxtype record start"; return; fi
  pause_media
  "$(vt_client)" record start; poke
}
cmd_stop_inner() {
  if ((DRY)); then echo "voxtype record stop"; return; fi
  "$(vt_client)" record stop; poke
  resume_media
}
cmd_start() { ready || return 0; [[ $(status_text) == recording ]] || cmd_start_inner; }
cmd_stop() { installed || return 0; [[ $(status_text) == recording ]] && cmd_stop_inner; return 0; }

set_lang() { # set_lang L: store, restart the daemon without waiting, one replacing notification
  local l=$1 s
  s=$(status_text)
  if [[ $s == recording || $s == transcribing ]]; then
    say -t 2500 "Dictation is busy" "finish the current phrase, then switch the language"
    return 0
  fi
  if ((DRY)); then echo "lang -> $l (file $LANGF), systemctl --user restart voxtype.service"; return 0; fi
  mkdir -p "$SDIR"
  echo "$l" >"$LANGF"
  systemctl --user try-restart --no-block voxtype.service 2>/dev/null || true
  say -t 1800 "Dictation: ${l^^}"
}

cmd_lang() {
  local pick=${1:-}
  if [[ -z $pick ]]; then
    pick=$(printf '%s\n' ru uk en auto en,ru,uk | fzf-menu -p "dictation language" --header "now: $(lang)") || return 0
  fi
  valid_lang "$pick" || { echo "dictation: language must be ru, uk, en, auto or a comma list like en,ru,uk" >&2; return 2; }
  set_lang "$pick"
}

cmd_cycle() { # ru -> uk -> en -> ru; anything else (auto, a list) starts again at ru
  local next
  case $(lang) in ru) next=uk ;; uk) next=en ;; *) next=ru ;; esac
  set_lang "$next"
}

cmd_run() {
  # runtime copy of the tracked config with the chosen language and model; the daemon reads that copy
  local l m dir conf n
  l=$(lang)
  m=$(model_name)
  dir="$RT/voxtype"
  conf="$dir/config.toml"
  mkdir -p "$dir"
  if [[ -r $CONF_SRC ]]; then
    sed -E -e "s/^language = \"[^\"]*\"/language = \"$l\"/" -e "s/^model = \"[^\"]*\"/model = \"$m\"/" "$CONF_SRC" >"$conf"
  else
    printf 'state_file = "auto"\n[hotkey]\nenabled = false\n[whisper]\nmodel = "%s"\nlanguage = "%s"\n' "$m" "$l" >"$conf"
  fi
  resolve_backend
  # a Vulkan daemon that crash-loops (two automatic restarts) is demoted to the best CPU build until the next probe
  if [[ $BK_BACKEND == vulkan ]] && ((! DRY)); then
    n=$(systemctl --user show voxtype.service -p NRestarts --value 2>/dev/null)
    if [[ ${n:-0} =~ ^[0-9]+$ ]] && ((${n:-0} >= 2)); then
      BK_BACKEND=$(cpu_variant) BK_DEVICE="" BK_REASON="Vulkan daemon crash-looped, demoted"
      write_cache "$(backend_key)"
      resolve_backend
    fi
  fi
  if ((DRY)); then echo "exec $BK_BIN -c $conf daemon   # $(backend_label)"; return 0; fi
  [[ -n $BK_BIN && -x $BK_BIN ]] || { echo "dictation: no voxtype binary found" >&2; exit 1; }
  exec "$BK_BIN" -c "$conf" daemon
}

# cmd_follow: the idle loop forks nothing (builtins only: read, [[ ]], command -v). It ticks every 0.5 s because a continuous
# waybar script has no other way to learn that a state file changed; `jq` runs only when the output changes. `installed` is
# checked again every 10 s, `systemctl is-active` only when the state file is missing or unknown (at most every 10 s), the
# backend cache only when it appeared, vanished or is newer than the stamp of the last read.
cmd_follow() {
  local last="" key s l m st act="" text cls tip head inst=1 tick=0 act_tick=-100 ref="$RT/dictation-follow.$$" have=0
  exec {TICKFD}<> <(:)
  trap 'rm -f "$ref"' EXIT
  trap 'exit 0' TERM INT HUP
  BK_BACKEND="" BK_DEVICE=""
  while :; do
    ((tick % 20 == 0)) && { installed && inst=1 || inst=0; }
    st=""
    if ((inst)); then
      [[ -r $STATE_FILE ]] && IFS= read -r st <"$STATE_FILE"
      case $st in
        recording | transcribing | idle) s=$st; act_tick=-100 ;;
        *)
          if ((tick - act_tick >= 20)); then
            systemctl --user is-active -q voxtype.service && act=idle || act=off
            act_tick=$tick
          fi
          s=$act ;;
      esac
    else
      s=off
    fi
    _lang; l=$LANG_V
    _model; m=$MODEL_V
    # the backend cache: re-read when it appeared, vanished or is newer than the reference stamp of the last read
    if [[ -e $BACKF ]]; then
      if ((! have)) || [[ $BACKF -nt $ref ]]; then
        : >"$ref"
        have=1
        BK_BACKEND="" BK_DEVICE=""
        read_cache && BK_BACKEND=$C_BACKEND BK_DEVICE=$C_DEVICE
      fi
    elif ((have)); then
      have=0 BK_BACKEND="" BK_DEVICE=""
    fi
    key="$s|$l|$m|$BK_BACKEND|$BK_DEVICE"
    if [[ $key != "$last" ]]; then
      last=$key
      if ((! inst)); then
        echo '{"text":""}'
      else
        case $s in
          recording) text="$G_MIC ${l^^} rec"; cls=critical; head="Dictating: speak, then SUPER+ALT+D (or release F9) types the text" ;;
          transcribing) text="$G_BUSY ${l^^}"; cls=warning; head="Transcribing what you said" ;;
          *) text="$G_MIC ${l^^}"; cls=dim; head="Dictation is idle: SUPER+ALT+D or hold F9 to dictate" ;;
        esac
        BK_BIN="" BK_REASON=""
        tip="$head"$'\n\n'"Language: ${l^^}"$'\n'"Model: $m"$'\n'"Backend: $(backend_label)"
        jq -cn --arg t "$text" --arg c "$cls" --arg tip "$tip"$'\n\n'"L: dictate · M: next language · R: menu" '{text: $t, class: $c, tooltip: $tip}'
      fi
    fi
    ((tick++))
    read -r -t 0.5 -u "$TICKFD" _ || true
  done
}

cmd_menu() {
  local pick l m x rows
  l=$(lang)
  m=$(model_name)
  mark() { [[ $1 == "$2" ]] && echo "● " || echo "  "; }
  rows=$(
    printf '%s\n' "Toggle dictation" "Next language (ru > uk > en)"
    for x in ru uk en auto en,ru,uk; do printf '%sLanguage: %s\n' "$(mark "$l" "$x")" "$x"; done
    printf '%sModel: small (466 MB, fast)\n' "$(mark "$m" small)"
    printf '%sModel: large-v3-turbo (1.6 GB, slower)\n' "$(mark "$m" large-v3-turbo)"
    printf '%s\n' "Backend: detect again" "Download the chosen model"
  )
  pick=$(fzf-menu -p dictation --header "language: ${l^^} · model: $m · state: $(status_text)" <<<"$rows") || return 0
  pick=${pick#"● "}
  pick=${pick#"  "}
  case $pick in
    "Toggle dictation") cmd_toggle ;;
    "Next language"*) cmd_cycle ;;
    "Language: "*) cmd_lang "${pick#Language: }" ;;
    "Model: "*) pick=${pick#Model: }; setsid -f "$0" model "${pick%% *}" >/dev/null 2>&1 </dev/null ;;
    "Backend: detect again")
      cmd_backend --probe >/dev/null
      systemctl --user try-restart --no-block voxtype.service 2>/dev/null || true
      resolve_backend; say "Dictation backend" "$(backend_label)" ;;
    "Download the chosen model") setsid -f "$0" model >/dev/null 2>&1 </dev/null ;;
  esac
}

case ${1:-} in
  toggle) cmd_toggle ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  cycle) cmd_cycle ;;
  lang) shift; cmd_lang "${1:-}" ;;
  model) shift; cmd_model "${1:-}" ;;
  backend) shift; cmd_backend "${1:-}" ;;
  status) status_text ;;
  --follow) cmd_follow ;;
  run) cmd_run ;;
  menu) cmd_menu ;;
  *) echo "usage: dictation.sh toggle|start|stop|cycle|lang [L]|model [NAME]|backend [--probe|--path]|status|--follow|run|menu [--dry-run]" >&2; exit 2 ;;
esac
