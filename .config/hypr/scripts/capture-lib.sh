#!/usr/bin/env bash
# capture-lib: the endings of a capture (O1 D3), sourced by shot.sh, freeze-shot.sh and rec-toggle.sh.
#   cap_toast_shot FILE        toast with the picture as icon; a click (default action) opens satty on the file, the
#                              action menu (SUPER+ALT+X) also offers "Show folder" (yazi)
#   cap_process_recording FILE drop the first moment (the encoder's first frame, the PipeWire pop) and normalise the loudness
#                              of every audio track in place; keeps the raw file when anything fails
#   cap_toast_recording FILE   toast with a thumbnail, name, length and size; click = play (mpv), menu: "Show folder"
# The toasts wait for the user in a detached process (notify-send -A blocks until the notification is closed), so the
# calling script returns at once. CAPTURE_DRY=1 prints what would run instead of notifying or encoding (tests).
SHOTS="${SHOTS:-$HOME/pics/screenshots}"
CAP_THUMBS="${XDG_RUNTIME_DIR:-/tmp}/capture-thumbs"
CAP_LIB="${BASH_SOURCE[0]}"

cap_detach() { # run a function of this library in its own session
  if [[ ${CAPTURE_DRY:-0} == 1 ]]; then "$@"; return; fi
  setsid -f bash -c 'source "$1"; shift; "$@"' _ "$CAP_LIB" "$@" >/dev/null 2>&1 </dev/null
}

cap_open_folder() { # FILE: yazi on the file in a floating terminal
  if [[ ${CAPTURE_DRY:-0} == 1 ]]; then echo "ghostty --class=float.tui -e yazi $1"; return; fi
  ghostty --class=float.tui -e yazi "$1"
}

cap_shot_worker() {
  local file=$1 act
  if [[ ${CAPTURE_DRY:-0} == 1 ]]; then
    echo "notify-send -a Hyprshot -i $file -A default='Edit in satty' -A folder='Show folder' 'Screenshot saved'"
    return
  fi
  act=$(notify-send -a Hyprshot -i "$file" -t 15000 -A "default=Edit in satty" -A "folder=Show folder" \
    "Screenshot saved" "$(basename "$file")"$'\n'"copied to the clipboard · click to edit in satty" 2>/dev/null)
  case $act in
    default)
      if command -v satty >/dev/null 2>&1; then
        satty -f "$file" --copy-command wl-copy --output-filename "$SHOTS/%F_%T.png"
      else
        notify-send -a capture -u critical "satty is missing" "install it from the hub (Setup)"
      fi ;;
    folder) cap_open_folder "$file" ;;
  esac
}
cap_toast_shot() { cap_detach cap_shot_worker "$1"; }

# the first 0.1 s go (first encoder frame, PipeWire start pop); loudnorm per audio track, 48 kHz AAC
cap_process_recording() {
  local file=$1 tmp has_audio
  command -v ffmpeg >/dev/null 2>&1 || return 0
  [[ -s $file ]] || return 1
  tmp="${file%.mp4}.processing.mp4"
  has_audio=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$file" 2>/dev/null | head -n1)
  local -a cmd=(ffmpeg -hide_banner -loglevel error -y -ss 0.1 -i "$file" -map 0:v -c:v copy)
  if [[ -n $has_audio ]]; then
    cmd+=(-map '0:a?' -af "volume=enable='lt(t,0.4)':volume=0,afade=t=in:st=0.4:d=0.05,loudnorm=I=-14:TP=-1.5:LRA=11" -c:a aac -b:a 160k -ar 48000)
  fi
  cmd+=(-movflags +faststart "$tmp")
  if [[ ${CAPTURE_DRY:-0} == 1 ]]; then printf '%q ' "${cmd[@]}"; echo; return 0; fi
  if "${cmd[@]}" && [[ -s $tmp ]]; then
    mv -f "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
  fi
}

cap_recording_worker() {
  local file=$1 thumb dur size act
  mkdir -p "$CAP_THUMBS"
  thumb="$CAP_THUMBS/$(basename "${file%.*}").png"
  if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -hide_banner -loglevel error -y -ss 0.5 -i "$file" -frames:v 1 -vf scale=320:-1 "$thumb" 2>/dev/null \
      || ffmpeg -hide_banner -loglevel error -y -i "$file" -frames:v 1 -vf scale=320:-1 "$thumb" 2>/dev/null
  fi
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$file" 2>/dev/null | awk '{ s = int($1); printf "%d:%02d", s / 60, s % 60 }')
  size=$(du -h "$file" | cut -f1)
  if [[ ${CAPTURE_DRY:-0} == 1 ]]; then
    echo "notify-send -i $thumb -A default=Play -A folder='Show folder' 'Recording saved' '$(basename "$file") $dur $size'"
    return
  fi
  act=$(notify-send -a recorder -i "$thumb" -t 20000 -h string:x-dunst-stack-tag:recording-saved -A "default=Play" -A "folder=Show folder" \
    "Recording saved" "$(basename "$file") · ${dur:-?} · $size"$'\n'"click to play" 2>/dev/null)
  case $act in
    default)
      if command -v mpv >/dev/null 2>&1; then setsid -f mpv "$file" >/dev/null 2>&1 </dev/null
      else notify-send -a capture -u critical "mpv is missing" "install it from the hub (Setup)"; fi ;;
    folder) cap_open_folder "$file" ;;
  esac
}
cap_toast_recording() { cap_detach cap_recording_worker "$1"; }

# stop path of rec-toggle.sh: normalise first (a few seconds), then the toast with the thumbnail
cap_finish_recording_worker() { cap_process_recording "$1" || true; cap_recording_worker "$1"; }
cap_finish_recording() { cap_detach cap_finish_recording_worker "$1"; }
