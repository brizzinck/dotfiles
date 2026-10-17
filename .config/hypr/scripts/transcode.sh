#!/usr/bin/env bash
# transcode: shrink or convert a picture or video for sharing (Telegram, mail, bug reports). fzf-menu flow, ffmpeg only.
# Idea and presets after Omarchy omarchy-transcode (MIT).
#   transcode.sh                          pick a file, a format and a size in menus
#   transcode.sh FILE FORMAT SIZE         no menus. Pictures: FORMAT jpg|png|webp, SIZE original|3160|2160|1080 (longest side, px)
#                                         Videos: FORMAT mp4|gif, SIZE original|2160|1080|720 (height, px)
#   --dry-run                             print the ffmpeg command, write nothing
# The result lands next to the source as NAME-1080p.mp4 / NAME-1080.jpg (never overwrites), and a file:// URI is copied so
# it can be dropped into Telegram or a browser (wl-copy, text/uri-list).
set -u
DRY=0
args=()
for a in "$@"; do
  if [[ $a == --dry-run ]]; then DRY=1; else args+=("$a"); fi
done
set -- "${args[@]+"${args[@]}"}"

DIRS=("$HOME/pics/screenshots" "$HOME/Videos/screencaptures" "$HOME/Videos/downloads" "$HOME/Videos" "$HOME/Downloads")
IMG_RE='\.(png|jpe?g|webp|bmp|tiff?|heic|avif)$'
VID_RE='\.(mp4|mkv|webm|mov|avi|gif|m4v)$'

say() { if ((DRY)); then echo "# $*"; else notify-send -a transcode -t 4000 "$@"; fi; }
fail() { echo "transcode: $*" >&2; ((DRY)) || notify-send -a transcode -u critical "Transcode" "$*"; exit 1; }
command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg is missing"

file=${1:-}
if [[ -z $file ]]; then
  # newest first, at most 400 entries from the usual capture folders
  rows=$(for d in "${DIRS[@]}"; do [[ -d $d ]] && find "$d" -maxdepth 1 -type f -regextype posix-extended \
    \( -iregex ".*($IMG_RE)" -o -iregex ".*($VID_RE)" \) -printf '%T@\t%p\n' 2>/dev/null; done | sort -rn | head -n 400 | cut -f2- | awk '!seen[$0]++')
  [[ -n $rows ]] || fail "no pictures or videos in ~/pics/screenshots, ~/Videos, ~/Downloads"
  file=$(printf '%s\n' "$rows" | sed "s|^$HOME|~|" | fzf-menu -p transcode --header 'file to convert') || exit 0
  file=${file/#\~/$HOME}
fi
[[ -f $file ]] || fail "no such file: $file"

kind=video
[[ ${file,,} =~ $IMG_RE ]] && kind=image
fmt=${2:-}
size=${3:-}
if [[ -z $fmt ]]; then
  if [[ $kind == image ]]; then opts=$'jpg\npng\nwebp'; else opts=$'mp4\ngif'; fi
  fmt=$(printf '%s\n' "$opts" | fzf-menu -p format) || exit 0
fi
if [[ -z $size ]]; then
  if [[ $kind == image ]]; then opts=$'3160\n2160\n1080\noriginal'; else opts=$'1080\n720\n2160\noriginal'; fi
  size=$(printf '%s\n' "$opts" | fzf-menu -p size --header 'longest side (px) for pictures, height (px) for videos') || exit 0
fi
[[ $size == original || $size =~ ^[0-9]+$ ]] || fail "bad size: $size"

base=${file%.*}
suffix=$size
if [[ $kind == video && $size != original ]]; then suffix="${size}p"; fi
out="$base-$suffix.$fmt"
n=2
while [[ -e $out ]]; do out="$base-$suffix-$n.$fmt"; n=$((n + 1)); done

cmd=(ffmpeg -hide_banner -loglevel error -y -i "$file")
if [[ $kind == image ]]; then
  vf=()
  [[ $size != original ]] && vf=(-vf "scale='if(gt(iw,ih),min($size,iw),-2)':'if(gt(iw,ih),-2,min($size,ih))'")
  case $fmt in
    jpg) cmd+=("${vf[@]}" -q:v 3) ;;
    png) cmd+=("${vf[@]}") ;;
    webp) cmd+=("${vf[@]}" -quality 85) ;;
    *) fail "pictures: jpg, png or webp" ;;
  esac
else
  vf=()
  [[ $size != original ]] && vf=("scale=-2:'min($size,ih)'")
  case $fmt in
    mp4)
      cmd+=(-c:v libx264 -preset medium -crf 23 -pix_fmt yuv420p -c:a aac -b:a 128k -movflags +faststart)
      ((${#vf[@]})) && cmd+=(-vf "${vf[0]}") ;;
    gif)
      # one palette pass: 12 fps, 720 px wide at most
      h=${size/original/720}
      cmd+=(-vf "fps=12,scale=-2:'min($h,ih)':flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" -an) ;;
    *) fail "videos: mp4 or gif" ;;
  esac
fi
cmd+=("$out")

if ((DRY)); then printf '%q ' "${cmd[@]}"; echo; exit 0
fi
say "Converting" "$(basename "$file") -> $(basename "$out")"
tmp="$out.part.${out##*.}"
cmd[${#cmd[@]}-1]=$tmp
if "${cmd[@]}"; then
  mv -f "$tmp" "$out"
  printf 'file://%s\n' "$out" | wl-copy --type text/uri-list 2>/dev/null || true
  say "Converted" "$out ($(du -h "$out" | cut -f1)); the file is in the clipboard, drop it where you want it"
else
  rm -f "$tmp"
  fail "ffmpeg failed on $file"
fi
