#!/usr/bin/env bash
# ytdl: download the video whose URL is in the clipboard (yt-dlp) into ~/Videos/downloads. Hub row and capture menu entry.
#   ytdl.sh [URL] [--dry-run]       URL defaults to the clipboard; only http(s) URLs without whitespace are accepted
set -u
OUT="${YTDL_DIR:-$HOME/Videos/downloads}"
DRY=0
URL=""
for a in "$@"; do
  case $a in --dry-run) DRY=1 ;; *) URL=$a ;; esac
done
[[ -n $URL ]] || URL=$(wl-paste --no-newline 2>/dev/null | head -c 2000)
if [[ ! $URL =~ ^https?://[^[:space:]]+$ ]]; then
  echo "the clipboard does not hold a single http(s) URL"
  ((DRY)) || notify-send -a ytdl -u normal "Download video" "the clipboard does not hold a URL"
  exit 1
fi
if ((DRY)); then echo "yt-dlp -P $OUT $URL"; exit 0; fi
command -v yt-dlp >/dev/null 2>&1 || { notify-send -a ytdl -u critical "Download video" "yt-dlp is missing: install it from the hub"; exit 1; }
mkdir -p "$OUT"
notify-send -a ytdl -t 2500 "Download video" "$URL"
if yt-dlp -P "$OUT" --no-playlist "$URL"; then
  notify-send -a ytdl -t 6000 "Video downloaded" "$OUT"
else
  notify-send -a ytdl -u critical "Download failed" "$URL"
  exit 1
fi
