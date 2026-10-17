#!/usr/bin/env bash
# Wallpaper: the palette-driven vector art, one swaybg per output.
#   wallpaper.sh apply   [--dry-run] [--force]  render what is missing, then make swaybg match (default; quiet on
#                                     success); --force restarts every swaybg (SUPER+O)
#   wallpaper.sh render  [--dry-run]  render the PNGs only
#   wallpaper.sh status               per output: size, PNG, running swaybg
#
# Source: ~/.local/state/theme/current/wallpaper.svg (themes/palette/templates/wallpaper.svg.tmpl, the figure in the
# token green_soft; fallback: the black variant in the repo). The PNG of every output is rendered at the output's native
# PHYSICAL size (hyprctl monitors -j) into ~/.cache/wallpaper/ with rsvg-convert on the bg_oled colour, so swaybg shows
# it 1:1 (-m fill). The art is fitted whole and centred: on a different aspect ratio (16:10 panel) the rest stays
# bg_oled, never cropped. The cache key holds the SVG + colour + size, so a palette change renders again and the old
# file of that output is removed. swaybg is only restarted for an output whose instance differs from the wanted
# (-o NAME -i FILE); a stray swaybg without -o or for an unknown output is killed, so there is exactly one per output.
#
# Re-trace the art from the raster (the repo only keeps the vector, never the raster):
#   magick lol.png -colorspace gray -resize 1200x675 -blur 0x1.4 -threshold 40% -negate fig.pbm
#   potrace -s --turdsize 4 --alphamax 1.33 --opttolerance 0.4 -C '#67774e' fig.pbm
# then paste the <g> element into the template and swap the fill for {{green_soft}}.
set -u

cache="${XDG_CACHE_HOME:-$HOME/.cache}/wallpaper"
state="${XDG_STATE_HOME:-$HOME/.local/state}/theme"
repo_black="$HOME/dotfiles/themes/generated/black"
uid=$(id -u)
rt=${XDG_RUNTIME_DIR:-/run/user/$uid}

mode=apply
dry=0
force=0
for a in "$@"; do
  case $a in
  apply | render | status) mode=$a ;;
  --dry-run) dry=1 ;;
  --force) force=1 ;;
  -h | --help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "wallpaper.sh: unknown argument: $a" >&2; exit 2 ;;
  esac
done

fail() {
  echo "wallpaper.sh: $*" >&2
  command -v notify-send >/dev/null 2>&1 && notify-send -u normal -a wallpaper "Wallpaper" "$*"
  exit 1
}

# session environment (called from a theme hook or a terminal as well as from Hyprland)
if [[ -z ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
  sig=$(find "$rt/hypr" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2)
  [[ -n $sig ]] && export HYPRLAND_INSTANCE_SIGNATURE=$sig
fi
if [[ -z ${WAYLAND_DISPLAY:-} || ! -S $rt/$WAYLAND_DISPLAY ]]; then
  for s in "$rt"/wayland-[0-9]*; do
    [[ -S $s && $s != *.lock ]] && { export WAYLAND_DISPLAY=${s##*/}; break; }
  done
fi
export XDG_RUNTIME_DIR=$rt

svg="$state/current/wallpaper.svg"
[[ -r $svg ]] || svg="$repo_black/wallpaper.svg"
[[ -r $svg ]] || fail "no wallpaper.svg (run themes/palette/render.py)"
tokens="$(dirname "$svg")/tokens.json"
bg=$(jq -r '.tokens.bg_oled // empty' "$tokens" 2>/dev/null)
[[ $bg =~ ^#[0-9a-fA-F]{6}$ ]] || bg='#000000'

# art size from the viewBox (1200 675)
read -r aw ah < <(sed -n 's/.*viewBox="0 0 \([0-9]*\) \([0-9]*\)".*/\1 \2/p' "$svg" | head -1)
[[ ${aw:-0} -gt 0 && ${ah:-0} -gt 0 ]] || fail "$svg has no viewBox"

command -v hyprctl >/dev/null 2>&1 || fail "hyprctl not found"
mapfile -t outs < <(hyprctl monitors -j 2>/dev/null | jq -r '.[] | "\(.name) \(.width) \(.height)"')
((${#outs[@]})) || fail "hyprctl reports no outputs"

key=$(printf '%s %s' "$bg" "$(cat "$svg")" | sha256sum | cut -c1-10)

png_for() { printf '%s/%s-%sx%s-%s.png' "$cache" "$1" "$2" "$3" "$key"; }

render() { # render NAME W H -> PNG, fitted whole and centred on bg
  local name=$1 w=$2 h=$3 out fw fh
  out=$(png_for "$name" "$w" "$h")
  [[ -s $out ]] && return 0
  if ((w * ah <= h * aw)); then
    fw=$w
    fh=$(((w * ah + aw / 2) / aw))
  else
    fh=$h
    fw=$(((h * aw + ah / 2) / ah))
  fi
  if ((dry)); then
    echo "render $name ${w}x${h}: art ${fw}x${fh} at +$(((w - fw) / 2))+$(((h - fh) / 2)) -> $out"
    return 0
  fi
  mkdir -p "$cache"
  if rsvg-convert -f png -b "$bg" -w "$fw" -h "$fh" --page-width "$w" --page-height "$h" \
    --left "$(((w - fw) / 2))" --top "$(((h - fh) / 2))" -o "$out.tmp" "$svg" 2>/dev/null; then
    mv -f "$out.tmp" "$out"
  else
    rm -f "$out.tmp"
    fail "rsvg-convert failed for $name (${w}x${h})"
  fi
  # drop the older renders of this output (other size or palette)
  find "$cache" -maxdepth 1 -name "$name-*.png" ! -name "$(basename "$out")" -delete 2>/dev/null
}

# running swaybg instances of this user: "pid output file" (output/file empty when not given)
running() {
  local pid args o i
  while read -r pid; do
    mapfile -d '' -t args <"/proc/$pid/cmdline" 2>/dev/null || continue
    o='' i=''
    for ((n = 1; n < ${#args[@]}; n++)); do
      case ${args[n]} in
      -o | --output) o=${args[n + 1]:-} ;;
      -i | --image) i=${args[n + 1]:-} ;;
      esac
    done
    printf '%s|%s|%s\n' "$pid" "$o" "$i"
  done < <(pgrep -u "$uid" -x swaybg)
}

if [[ $mode == status ]]; then
  echo "svg: $svg  bg: $bg  key: $key"
  for line in "${outs[@]}"; do
    read -r name w h <<<"$line"
    png=$(png_for "$name" "$w" "$h")
    printf '%s %sx%s  png: %s (%s)  swaybg: %s\n' "$name" "$w" "$h" "$png" "$([[ -s $png ]] && echo present || echo missing)" \
      "$(running | awk -F'|' -v o="$name" '$2 == o {printf "%s ", $1}')"
  done
  exit 0
fi

# one run at a time (hotplug, theme switch and the bind can overlap); swaybg is started with fd 9 closed
exec 9>"$rt/wallpaper.lock"
flock 9

for line in "${outs[@]}"; do
  read -r name w h <<<"$line"
  render "$name" "$w" "$h"
done
[[ $mode == render ]] && exit 0

command -v swaybg >/dev/null 2>&1 || fail "swaybg not found"
declare -A want=()
for line in "${outs[@]}"; do
  read -r name w h <<<"$line"
  want[$name]=$(png_for "$name" "$w" "$h")
done

# keep the instance that already matches (no flicker on hotplug), kill everything else
declare -A have=()
while IFS='|' read -r pid o i; do
  if ((!force)) && [[ -n $o && ${want[$o]:-} == "$i" && -z ${have[$o]:-} ]]; then
    have[$o]=$pid
  else
    if ((dry)); then echo "kill swaybg $pid (-o '$o' -i '$i')"; else kill "$pid" 2>/dev/null; fi
  fi
done < <(running)

for name in "${!want[@]}"; do
  [[ -n ${have[$name]:-} ]] && continue
  if ((dry)); then
    echo "swaybg -o $name -i ${want[$name]} -m fill -c $bg"
  else
    setsid -f swaybg -o "$name" -i "${want[$name]}" -m fill -c "$bg" >/dev/null 2>&1 </dev/null 9>&-
  fi
done
exit 0
