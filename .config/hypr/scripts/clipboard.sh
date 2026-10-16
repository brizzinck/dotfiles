#!/usr/bin/env bash
# Clipboard history: cliphist + fzf-menu (vim keys), with pins, a large image preview and a type filter. SUPER+C.
#   Enter      paste the entry into the window that was focused before the menu (CTRL+V, CTRL+SHIFT+V in terminals)
#   Alt+Enter  only copy it                 NORMAL: y (yank) copies, Enter pastes
#   Alt+p      pin / unpin (pins are text only, kept in ~/.local/share/clip-pins and shown first)     NORMAL: m (mark)
#   Alt+d      delete (a pin: unpin)                                                                   NORMAL: d
#   Alt+i      images only (again: all)     NORMAL: f          Alt+t   text only (again: all)       NORMAL: t
# Pin, delete and the filters act inside the open list (no reopening). The preview pane shows the selected text, or
# the image itself (kitty graphics, decoded on demand into a tmpfs cache, $XDG_RUNTIME_DIR/cliphist-preview).
# History entries are never password-manager copies (cliphist skips the sensitive hint), so there is no hint to keep.
#
#   clipboard.sh --list [img|txt]     print the rows (pins first)
#   clipboard.sh --rows               the rows of the current filter (the menu reloads with this)
#   clipboard.sh --preview ID         the preview pane for one row
#   clipboard.sh --delete ID | --pin ID | --filter img|txt   the in-menu actions
#   clipboard.sh --pin-text TEXT      pin text (tests / hub)
#   clipboard.sh --unpin N            remove pin N (1-based)
#   clipboard.sh --paste-last-image   SUPER+ALT+V: newest image from the history (else the newest file in
#                                     ~/pics/screenshots) back into the clipboard, pasted into the active window
#   clipboard.sh --do ROW [--copy]    run the Enter (or Alt+Enter) action on one row without the menu (tests)
#   --dry-run (first argument)        print what would be copied / sent, change nothing
# Test knobs: CLIP_DB (cliphist db path), CLIP_PINS, CLIP_PREVIEW, CLIP_SHOTS, CLIP_PREV (window address),
# FZF_MENU_HERE=1 (run the menu in the current terminal).
set -u

SCRIPTS=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=paste-lib.sh
. "$SCRIPTS/paste-lib.sh"

PINS="${CLIP_PINS:-${XDG_DATA_HOME:-$HOME/.local/share}/clip-pins}"   # one base64 line per pinned text
PREVIEW_CACHE="${CLIP_PREVIEW:-${XDG_RUNTIME_DIR:-/tmp}/cliphist-preview}"
MODE_FILE="${CLIP_MODE_FILE:-${XDG_RUNTIME_DIR:-/tmp}/cliphist-mode}"
SHOTS="${CLIP_SHOTS:-$HOME/pics/screenshots}"
SELF=$(readlink -f "${BASH_SOURCE[0]}")
FZF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fzf"
PIN_ICON='󰐃'
DRY=0
if [[ ${1:-} == --dry-run ]]; then DRY=1; PASTE_DRY=1; export PASTE_DRY; shift; fi

ch() { if [[ -n ${CLIP_DB:-} ]]; then cliphist -db-path "$CLIP_DB" "$@"; else cliphist "$@"; fi; }

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

# --- modes and previews -------------------------------------------------------------------------------------------
mode_get() { cat "$MODE_FILE" 2>/dev/null || echo all; }
mode_toggle() { # img|txt: the same filter again goes back to all
  local cur
  cur=$(mode_get)
  if [[ $cur == "$1" ]]; then echo all >"$MODE_FILE"; else echo "$1" >"$MODE_FILE"; fi
}
mode_header() {
  local m
  m=$(mode_get)
  case $m in img) m='images only' ;; txt) m='text only' ;; *) m='all' ;; esac
  printf 'clipboard: %s\nEnter paste  Alt+Enter/y copy  Alt+p/m pin  Alt+d/d delete  Alt+i/f images  Alt+t/t text' "$m"
}
row_of() { # id -> the full cliphist row
  ch list 2>/dev/null | awk -F'\t' -v id="$1" '$1 == id { print; exit }'
}
preview() { # id: the text, or the decoded image drawn by image-preview.sh
  local id=$1 row f lines
  if [[ $id == pin:* ]]; then
    pin_get "${id#pin:}" | head -c 20000
    return 0
  fi
  row=$(row_of "$id")
  [[ -n $row ]] || { echo "entry is gone"; return 0; }
  if [[ $row == *$'\t[[ binary data '* ]]; then
    ( umask 077; mkdir -p "$PREVIEW_CACHE" ) && chmod 700 "$PREVIEW_CACHE"
    f="$PREVIEW_CACHE/$id.img"
    [[ -s $f ]] || printf '%s\t\n' "$id" | ch decode >"$f" 2>/dev/null
    printf '%s\n' "${row#*$'\t'}"
    lines=$(( ${FZF_PREVIEW_LINES:-24} - 2 ))
    FZF_PREVIEW_LINES=$(( lines < 4 ? 4 : lines )) "$FZF_DIR/image-preview.sh" "$f"
  else
    printf '%s\t\n' "$id" | ch decode 2>/dev/null | head -c 20000
  fi
}
prune_previews() { # drop cached images whose entry left the history
  local f id ids
  [[ -d $PREVIEW_CACHE ]] || return 0
  ids=$(list_images | cut -f1)
  for f in "$PREVIEW_CACHE"/*.img; do
    [[ -e $f ]] || continue
    id=${f##*/}; id=${id%.img}
    grep -qxF "$id" <<<"$ids" || rm -f "$f"
  done
}
rows_now() { rows "$(mode_get)"; }

# in-menu actions
act_delete() { # id
  local id=$1 row
  if [[ $id == pin:* ]]; then pin_del "${id#pin:}"; return 0; fi
  row=$(row_of "$id")
  [[ -n $row ]] && printf '%s' "$row" | ch delete
}
act_pin() { # id
  local id=$1 row txt pin
  if [[ $id == pin:* ]]; then pin_del "${id#pin:}"; return 0; fi
  row=$(row_of "$id")
  [[ -n $row ]] || return 0
  if [[ $row == *'[[ binary data'* ]]; then
    notify-send -a clipboard -t 2000 "Clipboard" "only text can be pinned"
    return 0
  fi
  txt=$(printf '%s' "$row" | ch decode; echo x); txt=${txt%x}
  if pin=$(pin_find "$txt") && [[ -n $pin ]]; then pin_del "$pin"; else pin_add "$txt"; fi
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
  --list) rows "${2:-all}"; exit 0 ;;
  --rows) rows_now; exit 0 ;;
  --header) mode_header; exit 0 ;;
  --preview) preview "${2:?id}"; exit 0 ;;
  --delete) act_delete "${2:?id}"; exit 0 ;;
  --pin) act_pin "${2:?id}"; exit 0 ;;
  --filter) mode_toggle "${2:?img|txt}"; exit 0 ;;
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

# the window to paste into: whatever has focus before the menu opens
prev=${CLIP_PREV:-$(hyprctl activewindow -j 2>/dev/null | jq -r '.address // ""')}
echo all >"$MODE_FILE"
prune_previews
# in-menu actions: edit, then reload the rows and the header; NORMAL-mode letters are the vim spellings
reload="reload($SELF --rows)+transform-header($SELF --header)"
act_d="execute-silent($SELF --delete {1})+$reload"
act_p="execute-silent($SELF --pin {1})+$reload"
act_i="execute-silent($SELF --filter img)+$reload"
act_t="execute-silent($SELF --filter txt)+$reload"
export FZF_MENU_NORMAL_BINDS="d:$act_d
m:$act_p
f:$act_i
t:$act_t
y:become(printf 'alt-enter\n%s\n' {})"
out=$(rows_now | fzf-menu -p clip --delimiter=$'\t' --with-nth=2.. --no-sort --expect=alt-enter \
  --header "$(mode_header)" \
  --bind "alt-d:$act_d" --bind "alt-p:$act_p" --bind "alt-i:$act_i" --bind "alt-t:$act_t" \
  --preview "$SELF --preview {1}" --preview-window 'right,55%,wrap,border-left') || exit 0
key=$(sed -n 1p <<<"$out")
pick=$(sed -n '2,$p' <<<"$out")
[[ -n $pick ]] || exit 0
copy_row "$pick"
[[ $key == alt-enter ]] || paste_to "$prev"
exit 0
