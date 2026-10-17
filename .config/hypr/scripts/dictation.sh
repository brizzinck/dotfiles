#!/usr/bin/env bash
# dictation: offline voice typing with Voxtype (AUR voxtype-bin), local Whisper `small`, ru / uk / en. Nothing leaves the machine.
#   dictation.sh toggle        SUPER+ALT+D: start dictating, or stop and type the text into the focused window
#   dictation.sh start|stop    F9 held = start on press, stop on release
#   dictation.sh lang [auto|ru|uk|en]   choose the language (no argument: fzf-menu); restarts the daemon
#   dictation.sh model         download the Whisper model (ggml-small.bin, ~466 MB) when it is missing
#   dictation.sh status        idle | recording | transcribing | off
#   dictation.sh --follow      continuous JSON for waybar custom/dictation (hidden while idle)
#   dictation.sh run           what voxtype.service executes (language into a runtime copy of the config, then the daemon)
#   dictation.sh menu          waybar right click: language, model, status
#   --dry-run                  print what would run
# Everything is guarded like pointer.sh: without voxtype the keys only show how to install it. Media that plays is paused while
# you dictate and resumed afterwards. The microphone is shared with calls: never start it while a call is running.
set -u

RT="${XDG_RUNTIME_DIR:-/tmp}"
STATE_FILE="$RT/voxtype/state"
LANGF="${XDG_STATE_HOME:-$HOME/.local/state}/dictation/lang"
PAUSED_MARK="$RT/dictation-paused-media"
MODEL_DIR="${VOXTYPE_MODEL_DIR:-$HOME/.local/share/voxtype/models}"
MODEL_FILE="$MODEL_DIR/ggml-small.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
CONF_SRC="${XDG_CONFIG_HOME:-$HOME/.config}/voxtype/config.toml"
G_REC='󰍬'
G_BUSY='󰔟'
DRY=0
args=()
for a in "$@"; do
  if [[ $a == --dry-run ]]; then DRY=1; else args+=("$a"); fi
done
set -- "${args[@]+"${args[@]}"}"

say() { if ((DRY)); then echo "note: $*"; else notify-send -a dictation -t 3500 -h string:x-dunst-stack-tag:dictation "$@"; fi; }
poke() { pkill -o -u "$UID" -RTMIN+18 -x waybar 2>/dev/null || true; }
lang() { local l; l=$(cat "$LANGF" 2>/dev/null); echo "${l:-auto}"; }

installed() { command -v voxtype >/dev/null 2>&1; }
need_voxtype() {
  installed && return 0
  say -u normal "Dictation needs voxtype" "install with: sudo ./apply-system.sh --only install   (or the hub row, Setup)"
  return 1
}

model_ok() { [[ -s $MODEL_FILE ]]; }

cmd_model() {
  if model_ok; then echo "model present: $MODEL_FILE"; return 0; fi
  if ((DRY)); then echo "curl -L -C - -o $MODEL_FILE.part $MODEL_URL && mv -f $MODEL_FILE.part $MODEL_FILE"; return 0; fi
  mkdir -p "$MODEL_DIR"
  say "Dictation: downloading the Whisper model" "ggml-small.bin, about 466 MB, once"
  if curl -L -C - --fail --progress-bar -o "$MODEL_FILE.part" "$MODEL_URL"; then
    # the small multilingual model is 487601967 bytes: a short file is a failed download
    if (($(stat -c %s "$MODEL_FILE.part") > 480000000)); then
      mv -f "$MODEL_FILE.part" "$MODEL_FILE"
      say "Dictation: model ready" "$MODEL_FILE"
      return 0
    fi
  fi
  say -u normal "Dictation: model download failed" "run again: dictation.sh model (it resumes)"
  return 1
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
    say -u normal "Dictation: the model is missing" "downloading it now (about 466 MB), then try again"
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
  voxtype record start; poke
}
cmd_stop_inner() {
  if ((DRY)); then echo "voxtype record stop"; return; fi
  voxtype record stop; poke
  resume_media
}
cmd_start() { ready || return 0; [[ $(status_text) == recording ]] || cmd_start_inner; }
cmd_stop() { installed || return 0; [[ $(status_text) == recording ]] && cmd_stop_inner; return 0; }

cmd_lang() {
  local pick=${1:-}
  if [[ -z $pick ]]; then
    pick=$(printf '%s\n' auto ru uk en | fzf-menu -p "dictation language" --header "now: $(lang)") || return 0
  fi
  [[ $pick == auto || $pick == ru || $pick == uk || $pick == en ]] || { echo "dictation: language must be auto, ru, uk or en" >&2; return 2; }
  if ((DRY)); then echo "lang -> $pick (file $LANGF), systemctl --user restart voxtype.service"; return 0; fi
  mkdir -p "$(dirname "$LANGF")"
  echo "$pick" >"$LANGF"
  systemctl --user try-restart voxtype.service 2>/dev/null || true
  say "Dictation language" "$pick"
}

cmd_run() {
  # runtime copy of the tracked config with the chosen language; the daemon reads that copy
  local l dir conf
  l=$(lang)
  dir="$RT/voxtype"
  conf="$dir/config.toml"
  mkdir -p "$dir"
  if [[ -r $CONF_SRC ]]; then
    sed -E "s/^language = \"[^\"]*\"/language = \"$l\"/" "$CONF_SRC" >"$conf"
  else
    printf 'state_file = "auto"\n[hotkey]\nenabled = false\n[whisper]\nmodel = "small"\nlanguage = "%s"\n' "$l" >"$conf"
  fi
  if ((DRY)); then echo "exec voxtype -c $conf daemon"; return 0; fi
  exec voxtype -c "$conf" daemon
}

cmd_follow() {
  local last="" s text cls tip
  exec {TICKFD}<> <(:)
  while :; do
    s=$(status_text)
    if [[ $s != "$last" ]]; then
      last=$s
      case $s in
        recording) text="$G_REC dictating"; cls=critical; tip="Dictating: speak, then SUPER+ALT+D (or release F9) types the text" ;;
        transcribing) text="$G_BUSY typing"; cls=warning; tip="Transcribing what you said" ;;
        *) text=""; cls=normal; tip="" ;;
      esac
      if [[ -z $text ]]; then echo '{"text":""}'
      else jq -cn --arg t "$text" --arg c "$cls" --arg tip "$tip"$'\n\n'"L: toggle · M: language · R: menu" '{text: $t, class: $c, tooltip: $tip}'
      fi
    fi
    read -r -t 0.5 -u "$TICKFD" _ || true
  done
}

cmd_menu() {
  local pick
  pick=$(printf '%s\n' "Toggle dictation" "Language: auto" "Language: ru" "Language: uk" "Language: en" "Download the model" |
    fzf-menu -p dictation --header "language: $(lang) · state: $(status_text)") || return 0
  case $pick in
    "Toggle dictation") cmd_toggle ;;
    "Language: "*) cmd_lang "${pick#Language: }" ;;
    "Download the model") setsid -f "$0" model >/dev/null 2>&1 </dev/null ;;
  esac
}

case ${1:-} in
  toggle) cmd_toggle ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  lang) shift; cmd_lang "${1:-}" ;;
  model) cmd_model ;;
  status) status_text ;;
  --follow) cmd_follow ;;
  run) cmd_run ;;
  menu) cmd_menu ;;
  *) echo "usage: dictation.sh toggle|start|stop|lang [L]|model|status|--follow|run|menu [--dry-run]" >&2; exit 2 ;;
esac
