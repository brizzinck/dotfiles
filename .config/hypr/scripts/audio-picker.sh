#!/usr/bin/env bash
# Output / input device picker (fzf-menu, vim keys). SUPER+SHIFT+A, also a hub row.
#   Enter      make the device the default and move the running streams to it (Output rows; Input rows never move
#              streams: EasyEffects (processAllInputs) routes every recording app, a stream moved by hand would leave it)
#   Alt+Enter  make it the default only (running streams stay where they are)
#   The first Input row, "Automatic (best microphone)", forgets a manual choice (ee-ctl auto): USB mic > Bluetooth > built-in.
#   A manual Input pick pins the microphone for the session; the login autostart (audio-ensure --boot) clears it.
#   audio-picker.sh --list              print the rows (index, kind, id, default marker, name)
#   audio-picker.sh --pick N [--keep]   apply row N without the menu (--keep = Alt+Enter behaviour)
#   audio-picker.sh --next              switch to the next output device and move the running streams (SHIFT+Mute)
#   --dry-run                           print the commands instead of running them
# Pattern after Omarchy omarchy-audio-output-switch (MIT).
set -u

DRY=0
KEEP=0
PICK=""
LIST=0
NEXT=0
while (($#)); do
  case $1 in
    --dry-run) DRY=1 ;;
    --keep) KEEP=1 ;;
    --list) LIST=1 ;;
    --next) NEXT=1 ;;
    --pick) shift; PICK=${1:-} ;;
    *) echo "usage: audio-picker.sh [--list | --pick N [--keep]] [--dry-run]" >&2; exit 2 ;;
  esac
  shift
done

def_sink=$(pactl get-default-sink 2>/dev/null)
def_source=$(pactl get-default-source 2>/dev/null)

# row: kind <TAB> node id <TAB> node.name <TAB> description ; sinks first, then sources (monitors are not Audio/Source)
mapfile -t ROWS < <(pw-dump | jq -r '
  [ .[] | select(.type == "PipeWire:Interface:Node") | .info.props as $p
    | select($p["media.class"] == "Audio/Sink" or $p["media.class"] == "Audio/Source")
    | [(if $p["media.class"] == "Audio/Sink" then "Output" else "Input" end), .id, $p["node.name"],
       ($p["node.description"] // $p["node.name"])] ]
  | (map(select(.[0] == "Output")) + map(select(.[0] == "Input"))) | .[] | @tsv')
((${#ROWS[@]})) || { notify-send -a audio -u low "Audio devices" "no devices found"; exit 1; }
# the Automatic row heads the Input rows; it carries the marker while no manual microphone choice (source pin) exists
pin=$(pw-dump | jq -r '[.[] | select(.type == "PipeWire:Interface:Metadata" and .props["metadata.name"] == "default") | .metadata[]?
  | select(.key == "default.configured.audio.source")] | length')
first_in=${#ROWS[@]}
for i in "${!ROWS[@]}"; do [[ ${ROWS[$i]} == Input$'\t'* ]] && { first_in=$i; break; }; done
ROWS=("${ROWS[@]:0:first_in}" "Input"$'\t'"auto"$'\t'"-"$'\t'"Automatic (best microphone)" "${ROWS[@]:first_in}")

labels=()
for r in "${ROWS[@]}"; do
  IFS=$'\t' read -r kind id name desc <<<"$r"
  mark="  "
  if [[ $kind == Output && $name == "$def_sink" ]]; then mark="● "; fi
  if [[ $kind == Input ]]; then
    if [[ $id == auto ]]; then [[ ${pin:-0} == 0 ]] && mark="● "; elif [[ $name == "$def_source" ]]; then mark="● "; fi
  fi
  labels+=("$mark$kind: $desc")
done

if ((LIST)); then
  for i in "${!ROWS[@]}"; do printf '%s\t%s\n' "$i" "${labels[$i]}"; done
  exit 0
fi

if ((NEXT)); then
  # the next Output row after the default one (wraps around)
  outs=() cur=-1
  for i in "${!ROWS[@]}"; do
    IFS=$'\t' read -r kind id name desc <<<"${ROWS[$i]}"
    [[ $kind == Output ]] || continue
    outs+=("$i")
    [[ $name == "$def_sink" ]] && cur=${#outs[@]}
  done
  if ((${#outs[@]} < 2)); then
    ((DRY)) && echo "only one output device" || notify-send -a audio -u low -t 2500 "Audio output" "only one output device"
    exit 0
  fi
  # cur is the 1-based position of the default; the next one is that index modulo the count (0-based)
  PICK=${outs[$((cur % ${#outs[@]}))]}
  ((cur < 0)) && PICK=${outs[0]}
fi

if [[ -z $PICK ]]; then
  # NORMAL y (yank) behaves like Alt+Enter: leave the list as if that --expect key had been pressed
  export FZF_MENU_NORMAL_BINDS='y:become(printf "alt-enter\n%s\n" {1})'
  out=$(printf '%s\n' "${labels[@]}" | fzf-menu -p audio --index --expect=alt-enter \
    --header '● = default    Enter: set default + move streams    Alt+Enter / y: set default only') || exit 0
  [[ $(sed -n 1p <<<"$out") == alt-enter ]] && KEEP=1
  PICK=$(sed -n 2p <<<"$out")
  [[ -n $PICK ]] || exit 0
fi
[[ $PICK =~ ^[0-9]+$ && -n ${ROWS[$PICK]:-} ]] || { echo "audio-picker: bad row '$PICK'" >&2; exit 2; }

IFS=$'\t' read -r kind id name desc <<<"${ROWS[$PICK]}"
run() { if ((DRY)); then echo "$*"; else "$@" >/dev/null 2>&1; fi; }

if [[ $kind == Input && $id == auto ]]; then
  run ee-ctl auto
  ((DRY)) && exit 0
  notify-send -a audio -t 2500 -h string:x-dunst-stack-tag:audio-picker "Default input changed" "Automatic: USB mic > Bluetooth > built-in"
  exit 0
fi

run wpctl set-default "$id"
moved=0
# only playback streams are moved; recording streams stay where EasyEffects (processAllInputs) put them, and they follow the default by themselves
if ((!KEEP)) && [[ $kind == Output ]]; then
  # sink inputs = playback streams; the sink is addressed by node.name
  while read -r si _; do
    [[ -n $si ]] || continue
    run pactl move-sink-input "$si" "$name" && moved=$((moved + 1))
  done < <(pactl list short sink-inputs)
fi

((DRY)) && exit 0
msg="$kind: $desc"
((moved)) && msg+=$'\n'"moved $moved stream(s)"
notify-send -a audio -t 2500 -h string:x-dunst-stack-tag:audio-picker "Default $(tr '[:upper:]' '[:lower:]' <<<"$kind") changed" "$msg"
