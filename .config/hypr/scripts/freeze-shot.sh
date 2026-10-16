#!/usr/bin/env bash
# Frozen-screen region screenshot: the screen is frozen at the moment of the key press (hyprpicker -r -z renders a
# snapshot as an overlay), the region is selected on that frozen image, grim then cuts from the same frozen overlay.
#
#   freeze-shot.sh save        region -> ~/pics/screenshots + clipboard   (CTRL+ALT+S)
#   freeze-shot.sh annotate    region -> satty (copy to clipboard, save)  (CTRL+ALT+SHIFT+S)
#   --dry-run                  print the commands, freeze nothing
#
# Why not `hyprshot -z`: it kills hyprpicker the moment slurp exits and grims afterwards, so the saved pixels come from
# the live screen, not from the frozen one. Here grim runs while the overlay is still up, and an EXIT/INT/TERM trap
# removes the overlay on every path (Esc in slurp, a failed grim, a signal). A second press during the selection
# cancels it (the flock holder is told to stop).
set -u

SHOTS="$HOME/pics/screenshots"
RT="${XDG_RUNTIME_DIR:-/tmp}"
DRY=0
mode=
for a in "$@"; do
  case $a in
    --dry-run) DRY=1 ;;
    save | annotate) mode=$a ;;
  esac
done
[[ -n $mode ]] || { echo "usage: freeze-shot.sh save|annotate [--dry-run]" >&2; exit 2; }

SATTY=(satty --copy-command wl-copy --output-filename "$SHOTS/%F_%T.png")

if ((DRY)); then
  echo "hyprpicker -r -z &    # freeze now"
  echo "geo=\$(slurp -d)      # Esc = cancel, the trap kills hyprpicker"
  if [[ $mode == save ]]; then
    echo "grim -g \"\$geo\" $SHOTS/<date>_hyprshot.png && wl-copy --type image/png < <file>"
  else
    echo "grim -g \"\$geo\" <tmp.png>; kill hyprpicker; ${SATTY[*]} -f <tmp.png>"
  fi
  exit 0
fi

for c in hyprpicker slurp grim wl-copy; do
  command -v "$c" >/dev/null 2>&1 || { notify-send -a capture -u critical "Frozen screenshot: $c is missing" "install $c"; exit 1; }
done
[[ $mode == save ]] || command -v satty >/dev/null 2>&1 || { notify-send -a capture -u critical "Frozen screenshot: satty is missing" "install satty"; exit 1; }

# one instance: a second press cancels the running selection instead of stacking a second freeze
exec 9>"$RT/freeze-shot.lock"
if ! flock -n 9; then
  pkill -x slurp
  exit 0
fi

HP=
tmp=
cleanup() {
  [[ -n $HP ]] && kill "$HP" 2>/dev/null
  [[ -n $tmp ]] && rm -f "$tmp"
  HP=
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

mkdir -p "$SHOTS"
hyprpicker -r -z >/dev/null 2>&1 9>&- &
HP=$!
# wait (max 1 s) until the freeze overlay is mapped, so slurp draws over it and not over the live screen
for _ in $(seq 20); do
  hyprctl layers 2>/dev/null | grep -q hyprpicker && break
  kill -0 "$HP" 2>/dev/null || exit 1
  sleep 0.05
done

geo=$(slurp -d) || exit 0
[[ -n $geo ]] || exit 0

if [[ $mode == save ]]; then
  file="$SHOTS/$(date +'%Y-%m-%d-%H%M%S_hyprshot.png')"
  grim -g "$geo" "$file" || { notify-send -a capture -u critical "Frozen screenshot failed" "grim could not capture"; exit 1; }
  cleanup
  wl-copy --type image/png <"$file"
  notify-send -a Hyprshot -i "$file" "Screenshot saved" "Image saved in <i>$file</i> and copied to the clipboard."
else
  tmp=$(mktemp "$RT/freeze-shot-XXXXXX.png")
  grim -g "$geo" "$tmp" || { notify-send -a capture -u critical "Frozen screenshot failed" "grim could not capture"; exit 1; }
  cleanup   # unfreeze before the editor opens; tmp is removed by the next cleanup call (EXIT trap)
  tmp=$(readlink -f "$tmp")
  trap 'rm -f "$tmp"' EXIT
  exec 9>&-   # do not hold the lock while the editor is open
  "${SATTY[@]}" -f "$tmp"
fi
