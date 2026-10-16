#!/usr/bin/env bash
# Output / input device picker in rofi. SUPER+SHIFT+A, also a hub row.
#   Enter      make the device the default and move the running streams to it
#   Alt+Enter  make it the default only (running streams stay where they are)
#   audio-picker.sh --list              print the rows (index, kind, id, default marker, name)
#   audio-picker.sh --pick N [--keep]   apply row N without rofi (--keep = Alt+Enter behaviour)
#   --dry-run                           print the commands instead of running them
# Pattern after Omarchy omarchy-audio-output-switch (MIT).
set -u

DRY=0
KEEP=0
PICK=""
LIST=0
while (($#)); do
  case $1 in
    --dry-run) DRY=1 ;;
    --keep) KEEP=1 ;;
    --list) LIST=1 ;;
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

labels=()
for r in "${ROWS[@]}"; do
  IFS=$'\t' read -r kind id name desc <<<"$r"
  mark="  "
  if [[ $kind == Output && $name == "$def_sink" ]] || [[ $kind == Input && $name == "$def_source" ]]; then mark="● "; fi
  labels+=("$mark$kind: $desc")
done

if ((LIST)); then
  for i in "${!ROWS[@]}"; do printf '%s\t%s\n' "$i" "${labels[$i]}"; done
  exit 0
fi

if [[ -z $PICK ]]; then
  rc=0
  PICK=$(printf '%s\n' "${labels[@]}" | rofi -dmenu -i -format i -p audio \
    -kb-custom-1 'Alt+Return' -mesg '● = default    Enter: set default + move streams    Alt+Enter: set default only') || rc=$?
  case $rc in 0) ;; 10) KEEP=1 ;; *) exit 0 ;; esac
  [[ -n $PICK ]] || exit 0
fi
[[ $PICK =~ ^[0-9]+$ && -n ${ROWS[$PICK]:-} ]] || { echo "audio-picker: bad row '$PICK'" >&2; exit 2; }

IFS=$'\t' read -r kind id name desc <<<"${ROWS[$PICK]}"
run() { if ((DRY)); then echo "$*"; else "$@" >/dev/null 2>&1; fi; }

run wpctl set-default "$id"
moved=0
if ((!KEEP)); then
  if [[ $kind == Output ]]; then
    # sink inputs = playback streams; the sink is addressed by node.name
    while read -r si _; do
      [[ -n $si ]] || continue
      run pactl move-sink-input "$si" "$name" && moved=$((moved + 1))
    done < <(pactl list short sink-inputs)
  else
    while read -r so _; do
      [[ -n $so ]] || continue
      run pactl move-source-output "$so" "$name" && moved=$((moved + 1))
    done < <(pactl list short source-outputs)
  fi
fi

((DRY)) && exit 0
msg="$kind: $desc"
((moved)) && msg+=$'\n'"moved $moved stream(s)"
notify-send -a audio -t 2500 -h string:x-dunst-stack-tag:audio-picker "Default $(tr '[:upper:]' '[:lower:]' <<<"$kind") changed" "$msg"
