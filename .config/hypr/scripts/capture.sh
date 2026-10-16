#!/usr/bin/env bash
# Capture menu (fzf-menu, vim keys; SUPER+CTRL+S) and the capture actions behind it: screenshots, OCR, QR, recording, GIF,
# scrolling screenshot, colour picker. Also the engine of the OCR bind/hook and the hub rows.
#
#   capture.sh                     interactive menu
#   capture.sh --list              print the menu entries (id <TAB> label)
#   capture.sh --do ID [ADDRESS]   run one action without the menu; ADDRESS (0x...) targets a window for the *-window ids
#   capture.sh ocr [window ADDR]   OCR a region (default) or a window  (SUPER+SHIFT+O, window-menu hook `ocr`)
#   --dry-run                      print the commands instead of running them (no slurp, no clipboard writes)
#
# Missing tools are never a crash: the entry shows "(not installed)" and a critical notification says what to
# install (the root script apply-system.sh installs tesseract, zbar, qrencode, gifski and wayscrollshot-bin).
# Screenshots land in ~/pics/screenshots (and the clipboard), recordings in ~/Videos/screencaptures.
set -u

SCRIPTS=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
SHOTS="$HOME/pics/screenshots"
VIDEOS="${CAPTURE_VIDEOS:-$HOME/Videos/screencaptures}"
RT="${XDG_RUNTIME_DIR:-/tmp}"
DRY=0

# id <TAB> label <TAB> required commands
MENU=$'shot-region\tScreenshot: region\thyprshot slurp
shot-window\tScreenshot: window\thyprshot
shot-monitor\tScreenshot: monitor\thyprshot
annotate\tScreenshot: region, annotate (satty)\tgrim slurp satty wl-copy
ocr-region\tOCR: region to clipboard (rus+eng)\tgrim slurp tesseract wl-copy
ocr-window\tOCR: window to clipboard (rus+eng)\tgrim tesseract wl-copy
qr-scan\tQR: scan region\tgrim slurp zbarimg wl-copy
qr-gen\tQR: generate from clipboard\twl-paste qrencode
rec-region\tRecord: region\tgpu-screen-recorder slurp
rec-window\tRecord: active window\tgpu-screen-recorder
rec-monitor\tRecord: monitor\tgpu-screen-recorder
rec-mic-region\tRecord with mic: region\tgpu-screen-recorder slurp
rec-mic-window\tRecord with mic: active window\tgpu-screen-recorder
rec-mic-monitor\tRecord with mic: monitor\tgpu-screen-recorder
rec-stop\tRecord: stop recording\tgpu-screen-recorder
gif\tGIF from the last recording (gifski)\tffmpeg
scroll\tScreenshot: scrolling (wayscrollshot)\twayscrollshot
color\tColor picker (choose format)\thyprpicker'

die() { echo "capture: $*" >&2; exit 1; }
note() { if ((DRY)); then echo "# notify: $*"; else notify-send -a capture -t 3000 "$@"; fi; }

# dunst renders markup: neutralise &, < and > in recognised text
esc() { local t=$1; t=${t//&/&amp;}; t=${t//</&lt;}; printf '%s' "${t//>/&gt;}"; }

# run, or print under --dry-run
x() { if ((DRY)); then echo "$*"; else "$@"; fi; }

# true when every command exists; otherwise a critical notification naming the first missing one
need() {
  local c
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      case $c in
        tesseract) hint="install tesseract, tesseract-data-eng, tesseract-data-rus" ;;
        zbarimg) hint="install zbar" ;;
        qrencode) hint="install qrencode" ;;
        gifski) hint="install gifski" ;;
        wayscrollshot) hint="install wayscrollshot-bin (AUR)" ;;
        *) hint="install $c" ;;
      esac
      if ((DRY)); then echo "# missing: $c ($hint)"; else
        notify-send -a capture -u critical "Capture: $c is missing" "$hint (sudo ~/dotfiles/apply-system.sh)"
      fi
      return 1
    fi
  done
}

missing() {
  local c
  for c in $1; do command -v "$c" >/dev/null 2>&1 || return 0; done
  return 1
}

# ───────────────────────────── windows and regions ─────────────────────────────

# prints "x,y wxh" (grim -g format, logical px) of ADDRESS or the active window; shows the window's workspace first
window_geo() {
  local addr=${1:-${HUB_TARGET:-}} json
  addr=${addr#address:}
  if [[ -n $addr ]]; then
    json=$(hyprctl clients -j | jq -c --arg a "$addr" '.[] | select(.address == $a)')
  else
    json=$(hyprctl activewindow -j)
  fi
  [[ -n $json ]] || return 1
  local wsid active
  wsid=$(jq -r '.workspace.id' <<<"$json")
  active=$(hyprctl monitors -j | jq -r --argjson m "$(jq '.monitor' <<<"$json")" '.[] | select(.id == $m) | .activeWorkspace.id')
  if [[ $wsid != "$active" ]] && ((!DRY)); then
    # the window is not visible: bring it up, otherwise grim would photograph whatever is on screen there
    hyprd focuswindow "address:$(jq -r .address <<<"$json")" >/dev/null
    sleep 0.35
    json=$(hyprctl clients -j | jq -c --arg a "$(jq -r .address <<<"$json")" '.[] | select(.address == $a)')
  fi
  jq -r '"\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"' <<<"$json"
}

region_geo() {
  # shellcheck disable=SC2016
  if ((DRY)); then echo '$(slurp)'; return 0; fi
  slurp
}

# ───────────────────────────── OCR ─────────────────────────────

do_ocr() { # GEO
  local geo=$1 img langs text
  img="$RT/capture-ocr-$$.png"
  langs=rus+eng
  if ((DRY)); then
    echo "grim -g \"$geo\" $img"
    echo "tesseract $img - -l $langs --psm 6 | wl-copy"
    need tesseract || true
    return 0
  fi
  need grim tesseract wl-copy || return 1
  if ! tesseract --list-langs 2>/dev/null | grep -qx rus; then
    langs=eng
    note "OCR" "Russian data (tesseract-data-rus) is missing, using English only"
  fi
  grim -g "$geo" "$img" || { note "OCR failed" "could not capture the screen"; return 1; }
  text=$(tesseract "$img" - -l "$langs" --psm 6 2>/dev/null | sed -e 's/[[:space:]]*$//')
  rm -f "$img"
  if [[ -z ${text//[[:space:]]/} ]]; then
    note "OCR" "no text recognised"
    return 0
  fi
  printf '%s' "$text" | wl-copy
  note "OCR copied to clipboard" "$(esc "${text:0:300}")"
}

cmd_ocr() { # [window [ADDR]]
  local geo
  if [[ ${1:-} == window ]]; then
    geo=$(window_geo "${2:-}") || { note "OCR" "no such window"; return 1; }
  else
    geo=$(region_geo) || return 0
    [[ -n $geo ]] || return 0
  fi
  do_ocr "$geo"
}

# ───────────────────────────── QR ─────────────────────────────

do_qr_scan() {
  local geo img out
  img="$RT/capture-qr-$$.png"
  if ((DRY)); then
    echo "grim -g \"\$(slurp)\" $img"
    echo "zbarimg -q --raw -Sdisable -Sqrcode.enable $img   # otpauth:// and otpauth-migration:// are NOT copied"
    need zbarimg || true
    return 0
  fi
  need grim zbarimg wl-copy || return 1
  geo=$(slurp) || return 0
  grim -g "$geo" "$img" || { note "QR" "could not capture the screen"; return 1; }
  out=$(zbarimg -q --raw -Sdisable -Sqrcode.enable "$img" 2>/dev/null)
  rm -f "$img"
  if [[ -z $out ]]; then
    note "QR" "no QR code found in the region"
    return 0
  fi
  # one-time-password secrets must not reach the clipboard history (cliphist stores every text copy)
  if grep -qiE '^otpauth(-migration)?://' <<<"$out"; then
    notify-send -a capture -u critical -t 8000 "QR is a 2FA secret" "Not copied, so it stays out of the clipboard history. Import it with 2fa-import (hub row: Import Google Authenticator)."
    return 0
  fi
  printf '%s' "$out" | wl-copy
  note "QR copied to clipboard" "$(esc "${out:0:300}")"
}

do_qr_gen() {
  local text png txt
  if ((DRY)); then
    echo "wl-paste -n | qrencode -t png -s 12 -m 2 -o $RT/capture-qr.png && imv -b ffffff $RT/capture-qr.png"
    echo "# fallback without imv: ghostty --class=float.tui -e qrencode -t ansiutf8"
    need qrencode || true
    return 0
  fi
  need wl-paste qrencode || return 1
  text=$(wl-paste -n 2>/dev/null)
  [[ -n $text ]] || { note "QR" "the clipboard has no text"; return 0; }
  if command -v imv >/dev/null 2>&1; then
    png="$RT/capture-qr-$$.png"
    if ! (umask 077; printf '%s' "$text" | qrencode -t png -s 12 -m 2 -o "$png"); then
      note "QR" "text is too long for a QR code"; rm -f "$png"; return 1
    fi
    imv -b ffffff "$png"
    rm -f "$png"
  else
    txt="$RT/capture-qr-$$.txt"
    (umask 077; printf '%s' "$text" >"$txt")
    # shellcheck disable=SC2016
    ghostty --class=float.tui -e bash -c 'qrencode -t ansiutf8 <"$1" || echo "text is too long for a QR code"; rm -f "$1"; read -rsn1 -p "press any key"' _ "$txt"
  fi
}

# ───────────────────────────── recording, GIF ─────────────────────────────

do_gif() {
  local src out
  src=$(find "$VIDEOS" -maxdepth 1 -name '*.mp4' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)
  [[ -n $src ]] || { note "GIF" "no recordings in $VIDEOS"; return 1; }
  out="${src%.mp4}.gif"
  if ((DRY)); then
    echo "last recording: $src"
    if command -v gifski >/dev/null 2>&1; then
      echo "ffmpeg -i $src -vf fps=15,scale='min(960,iw)':-2 -f yuv4mpegpipe - | gifski --quality 90 -o $out -"
    else
      echo "# gifski missing, would fall back to: ffmpeg palettegen/paletteuse -> $out"
    fi
    return 0
  fi
  need ffmpeg || return 1
  if pgrep -x gpu-screen-reco >/dev/null; then
    note "GIF" "a recording is still running; stop it first"
    return 1
  fi
  note "GIF" "converting $(basename "$src") ..."
  if command -v gifski >/dev/null 2>&1; then
    ffmpeg -v error -i "$src" -an -vf "fps=15,scale='min(960,iw)':-2" -f yuv4mpegpipe - | gifski --quality 90 -o "$out" - \
      || { note "GIF failed" "gifski exited with an error"; return 1; }
  else
    ffmpeg -v error -y -i "$src" -an -vf "fps=15,scale='min(960,iw)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" "$out" \
      || { note "GIF failed" "ffmpeg exited with an error"; return 1; }
    note "GIF" "gifski is not installed, used the ffmpeg palette fallback"
  fi
  note "GIF saved" "$out ($(du -h "$out" | cut -f1))"
}

do_scroll() {
  local out
  out="$SHOTS/scroll_$(date +%F_%H-%M-%S).png"
  if ((DRY)); then
    echo "wayscrollshot -o $out    # select the region, scroll, S = save, C = copy"
    need wayscrollshot || true
    return 0
  fi
  need wayscrollshot || return 1
  mkdir -p "$SHOTS"
  wayscrollshot -o "$out"
  [[ -s $out ]] && note "Scrolling screenshot saved" "$out"
}

do_color() {
  local fmt
  if ((DRY)); then echo "hyprpicker -a -f <hex|rgb|hsl|hsv|cmyk>"; return 0; fi
  need hyprpicker fzf-menu || return 1
  fmt=$(printf '%s\n' hex rgb hsl hsv cmyk | fzf-menu -p color --header 'copy the picked colour as ...') || return 0
  sleep 0.3   # let the menu's workspace animation finish before the picker freezes the screen
  [[ -n $fmt ]] || return 0
  hyprpicker -a -f "$fmt"
}

# ───────────────────────────── dispatch ─────────────────────────────

run_action() { # ID [ADDRESS]
  local id=$1 addr=${2:-} req
  req=$(awk -F'\t' -v id="$id" '$1 == id { print $3 }' <<<"$MENU")
  [[ -n $req ]] || die "unknown action: $id"
  # shellcheck disable=SC2086
  if ((!DRY)); then need $req || return 1; fi
  mkdir -p "$SHOTS"
  # shellcheck disable=SC2086 # $addr is empty or one word
  case $id in
    shot-region) x hyprshot -m region -o "$SHOTS" ;;
    shot-window) x hyprshot -m window -m active -o "$SHOTS" ;;
    shot-monitor) x hyprshot -m output -m active -o "$SHOTS" ;;
    annotate)
      # shellcheck disable=SC2016
      if ((DRY)); then echo 'grim -g "$(slurp)" - | satty -f - --copy-command wl-copy --output-filename ~/pics/screenshots/%F_%T.png'; else
        local geo; geo=$(slurp) || return 0
        grim -g "$geo" - | satty -f - --copy-command wl-copy --output-filename "$SHOTS/%F_%T.png"
      fi ;;
    ocr-region) cmd_ocr ;;
    ocr-window) cmd_ocr window "$addr" ;;
    qr-scan) do_qr_scan ;;
    qr-gen) do_qr_gen ;;
    rec-region) x "$SCRIPTS/rec-toggle.sh" region ;;
    rec-window) x "$SCRIPTS/rec-toggle.sh" window $addr ;;
    rec-monitor) x "$SCRIPTS/rec-toggle.sh" monitor ;;
    rec-mic-region) x "$SCRIPTS/rec-toggle.sh" region --mic ;;
    rec-mic-window) x "$SCRIPTS/rec-toggle.sh" window $addr --mic ;;
    rec-mic-monitor) x "$SCRIPTS/rec-toggle.sh" monitor --mic ;;
    rec-stop) x "$SCRIPTS/rec-toggle.sh" stop ;;
    gif) do_gif ;;
    scroll) do_scroll ;;
    color) do_color ;;
  esac
}

menu_rows() { # prints id <TAB> label (with the missing-tool suffix)
  local id label req
  while IFS=$'\t' read -r id label req; do
    if missing "$req"; then label+="  (not installed)"; fi
    printf '%s\t%s\n' "$id" "$label"
  done <<<"$MENU"
}

args=()
for a in "$@"; do
  if [[ $a == --dry-run ]]; then DRY=1; else args+=("$a"); fi
done
set -- "${args[@]+"${args[@]}"}"

case ${1:-} in
  --list) menu_rows ;;
  --do) [[ -n ${2:-} ]] || die "--do needs an id"; run_action "$2" "${3:-}" ;;
  ocr) shift; cmd_ocr "$@" ;;
  "")
    rows=$(menu_rows)
    pick=$(cut -f2 <<<"$rows" | fzf-menu -p capture --index) || exit 0
    [[ -n $pick ]] || exit 0
    id=$(sed -n "$((pick + 1))p" <<<"$rows" | cut -f1)
    sleep 0.3   # the menu's workspace animation must be gone before a screenshot or the region picker
    run_action "$id"
    ;;
  *) die "usage: capture.sh [--list | --do ID [ADDRESS] | ocr [window ADDR]] [--dry-run]" ;;
esac
