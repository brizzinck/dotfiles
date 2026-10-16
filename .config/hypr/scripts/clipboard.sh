#!/usr/bin/env bash
# Clipboard history: cliphist + rofi, with pins, image thumbnails and a type filter. SUPER+C.
#   Enter      paste the entry into the window that was focused before the menu (CTRL+V, CTRL+SHIFT+V in terminals)
#   Alt+Enter  only copy it
#   Alt+p      pin / unpin (pins are text only, kept in ~/.local/share/clip-pins and shown first)
#   Alt+d      delete (a pin: unpin)
#   Alt+i      images only (again: all)        Alt+t   text only (again: all)
# The menu reopens after Alt+p / Alt+d / Alt+i / Alt+t. Image rows get a thumbnail icon from a tmpfs cache
# ($XDG_RUNTIME_DIR/cliphist-thumbs, one file per entry id, pruned when the entry leaves the history).
# History entries are never password-manager copies (cliphist skips the sensitive hint), so there is no hint to keep.
#
#   clipboard.sh --list [img|txt]     print the rows (pins first)
#   clipboard.sh --thumbs             refresh the thumbnail cache and list it (tests)
#   clipboard.sh --pin-text TEXT      pin text (tests / hub)
#   clipboard.sh --unpin N            remove pin N (1-based)
#   clipboard.sh --paste-last-image   SUPER+ALT+V: newest image from the history (else the newest file in
#                                     ~/pics/screenshots) back into the clipboard, pasted into the active window
#   clipboard.sh --do ROW [--copy]    run the Enter (or Alt+Enter) action on one row without rofi (tests)
#   --dry-run (first argument)        print what would be copied / sent, change nothing
# Test knobs: CLIP_DB (cliphist db path), CLIP_PINS, CLIP_THUMBS, CLIP_SHOTS, CLIP_PREV (window address).
set -u

SCRIPTS=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=paste-lib.sh
. "$SCRIPTS/paste-lib.sh"

PINS="${CLIP_PINS:-${XDG_DATA_HOME:-$HOME/.local/share}/clip-pins}"   # one base64 line per pinned text
THUMBS="${CLIP_THUMBS:-${XDG_RUNTIME_DIR:-/tmp}/cliphist-thumbs}"
SHOTS="${CLIP_SHOTS:-$HOME/pics/screenshots}"
THUMB_PX=160
PIN_ICON='󰐃'
DRY=0
if [[ ${1:-} == --dry-run ]]; then DRY=1; PASTE_DRY=1; export PASTE_DRY; shift; fi

ch() { if [[ -n ${CLIP_DB:-} ]]; then cliphist -db-path "$CLIP_DB" "$@"; else cliphist "$@"; fi; }

pin_count() { [[ -f $PINS ]] && wc -l <"$PINS" || echo 0; }
pin_get() { sed -n "${1}p" "$PINS" 2>/dev/null | base64 -d 2>/dev/null; }
pin_add() { # text
  local enc
  enc=$(printf '%s' "$1" | base64 -w0)
  mkdir -p "$(dirname "$PINS")"
  touch "$PINS"; chmod 600 "$PINS"
  grep -qxF "$enc" "$PINS" && return 1
  printf '%s\n' "$enc" >>"$PINS"
}
pin_del() { sed -i "${1}d" "$PINS" 2>/dev/null; }
pin_find() { # text -> line number of this text among the pins
  local enc
  enc=$(printf '%s' "$1" | base64 -w0)
  grep -nxF "$enc" "$PINS" 2>/dev/null | head -1 | cut -d: -f1
}

# cliphist prints image entries as "ID<TAB>[[ binary data 2 MiB png 800x600 ]]"
# shellcheck disable=SC2016
IMG_AWK='$2 ~ /^\[\[ binary data /'
list_images() { ch list 2>/dev/null | awk -F'\t' "$IMG_AWK"; }

rows() { # [all|img|txt]
  local mode=${1:-all} i=0 line t
  if [[ $mode != img && -s $PINS ]]; then
    while IFS= read -r line; do
      i=$((i + 1))
      t=$(printf '%s' "$line" | base64 -d 2>/dev/null | tr '\n\t' '  ' | cut -c1-120)
      printf 'pin:%s\t%s %s\n' "$i" "$PIN_ICON" "$t"
    done <"$PINS"
  fi
  case $mode in
    img) list_images ;;
    txt) ch list 2>/dev/null | awk -F'\t' "!($IMG_AWK)" ;;
    *) ch list 2>/dev/null ;;
  esac
}

# --- thumbnails ---------------------------------------------------------------------------------------------------
scale() { # stdin image -> stdout png no larger than THUMB_PX; the original bytes when no scaler is installed
  if command -v magick >/dev/null 2>&1; then
    magick - -thumbnail "${THUMB_PX}x${THUMB_PX}>" png:- 2>/dev/null
  elif command -v convert >/dev/null 2>&1; then
    convert - -thumbnail "${THUMB_PX}x${THUMB_PX}>" png:- 2>/dev/null
  else
    cat
  fi
}
thumb_make() { # id (run in parallel by thumbs_sync)
  local id=$1 tmp
  [[ -s $THUMBS/$id.png ]] && return 0
  tmp=$(mktemp "$THUMBS/.tmp.XXXXXX") || return 1
  if printf '%s\t\n' "$id" | ch decode 2>/dev/null | scale >"$tmp" && [[ -s $tmp ]]; then
    mv -f "$tmp" "$THUMBS/$id.png"
  else
    rm -f "$tmp"
  fi
}
thumbs_sync() { # decode only the missing thumbnails, drop the ones whose entry left the history
  ( umask 077; mkdir -p "$THUMBS" ) && chmod 700 "$THUMBS" || return 0
  local ids f id
  ids=$(list_images | cut -f1)
  for f in "$THUMBS"/*.png; do
    [[ -e $f ]] || continue
    id=${f##*/}; id=${id%.png}
    grep -qxF "$id" <<<"$ids" || rm -f "$f"
  done
  rm -f "$THUMBS"/.tmp.* 2>/dev/null
  export -f thumb_make scale ch
  export THUMBS THUMB_PX CLIP_DB
  # shellcheck disable=SC2016
  ( umask 077
    while read -r id; do [[ -n $id && ! -s $THUMBS/$id.png ]] && echo "$id"; done <<<"$ids" |
      xargs -r -P4 -n1 bash -c 'thumb_make "$1"' _ )
}
rofi_rows() { # mode: the rows, image rows carry the thumbnail as the rofi row icon
  local line id
  while IFS= read -r line; do
    id=${line%%$'\t'*}
    if [[ $line == *$'\t[[ binary data '* && -s $THUMBS/$id.png ]]; then
      printf '%s\0icon\x1f%s\n' "$line" "$THUMBS/$id.png"
    else
      printf '%s\n' "$line"
    fi
  done < <(rows "$1")
}

# --- actions ------------------------------------------------------------------------------------------------------
copy_row() { # row -> clipboard
  local id=${1%%$'\t'*}
  if ((DRY)); then echo "wl-copy <${id/#pin:/pin }>"; return 0; fi
  if [[ $id == pin:* ]]; then pin_get "${id#pin:}" | wl-copy; else printf '%s' "$1" | ch decode | wl-copy; fi
}
paste_to() { # window address: the copied entry goes in right away
  ((DRY)) || sleep 0.15   # let the selection settle (wl-clip-persist) and the menu release the keyboard
  paste_send "$1"
}
last_image() { # newest image of the history, else the newest screenshot file -> clipboard
  local row f
  row=$(rows img | head -1)
  if [[ -n $row ]]; then copy_row "$row"; return 0; fi
  # shellcheck disable=SC2012
  f=$(ls -t "$SHOTS"/*.png "$SHOTS"/*.jpg 2>/dev/null | head -1)
  if [[ -z $f ]]; then
    notify-send -a clipboard -t 2500 "Clipboard" "no image in the history or in ~/pics/screenshots"
    return 1
  fi
  if ((DRY)); then echo "wl-copy --type image/${f##*.} < $f"; return 0; fi
  wl-copy --type "image/$([[ $f == *.jpg ]] && echo jpeg || echo png)" <"$f"
}

case ${1:-} in
  --thumbs) thumbs_sync; ls "$THUMBS"; exit 0 ;;
  --list) rows "${2:-all}"; exit 0 ;;
  --pin-text) pin_add "${2:?text}"; exit 0 ;;
  --unpin) pin_del "${2:?n}"; exit 0 ;;
  --paste-last-image)
    last_image || exit 0
    ((DRY)) || sleep 0.3   # let the physical SUPER+ALT be released first
    paste_send "${CLIP_PREV:-}"
    exit 0 ;;
  --do)
    row=${2:?row}
    copy_row "$row"
    [[ ${3:-} == --copy ]] || paste_to "${CLIP_PREV:-}"
    exit 0 ;;
esac

# the window to paste into: whatever has focus before rofi takes the keyboard
prev=${CLIP_PREV:-$(hyprctl activewindow -j 2>/dev/null | jq -r '.address // ""')}
mode=all
while true; do
  rc=0
  thumbs_sync
  case $mode in img) label='clip: images' ;; txt) label='clip: text' ;; *) label=clip ;; esac
  # text rows reserve the icon height too, so the icons stay small in the mixed list and big in the images view
  icon=
  case $mode in img) icon='element-icon { size: 6em; }' ;; all) [[ -n $(ls -A "$THUMBS" 2>/dev/null) ]] && icon='element-icon { size: 3.4em; }' ;; esac
  pick=$(rofi_rows "$mode" | rofi -dmenu -i -p "$label" -display-columns 2 \
    -kb-custom-1 'Alt+d' -kb-custom-2 'Alt+p' -kb-custom-3 'Alt+i' -kb-custom-4 'Alt+t' -kb-custom-5 'Alt+Return' \
    -theme-str "$icon" \
    -mesg 'Enter: paste    Alt+Enter: copy    Alt+p: pin    Alt+d: delete    Alt+i: images    Alt+t: text') || rc=$?
  id=${pick%%$'\t'*}
  case $rc in
    0)
      [[ -n $pick ]] || exit 0
      copy_row "$pick"
      paste_to "$prev"
      exit 0 ;;
    14)
      [[ -n $pick ]] && copy_row "$pick"
      exit 0 ;;
    10)
      [[ -n $pick ]] || continue
      if [[ $id == pin:* ]]; then pin_del "${id#pin:}"; else printf '%s' "$pick" | ch delete; fi ;;
    11)
      [[ -n $pick ]] || continue
      if [[ $id == pin:* ]]; then
        pin_del "${id#pin:}"
      else
        txt=$(printf '%s' "$pick" | ch decode; echo x); txt=${txt%x}
        if [[ $pick == *'[[ binary data'* ]]; then
          notify-send -a clipboard -t 2000 "Clipboard" "only text can be pinned"
        elif pin=$(pin_find "$txt") && [[ -n $pin ]]; then
          pin_del "$pin"
        else
          pin_add "$txt"
        fi
      fi ;;
    12) [[ $mode == img ]] && mode=all || mode=img ;;
    13) [[ $mode == txt ]] && mode=all || mode=txt ;;
    *) exit 0 ;;
  esac
done
