#!/usr/bin/env bash
# Clipboard history: cliphist + rofi, with pins. SUPER+C.
# Enter copies, Alt+p pins/unpins (pins are text only, kept in ~/.local/share/clip-pins and shown first),
# Alt+d deletes (a pin: unpins). The menu reopens after Alt+p / Alt+d.
#   clipboard.sh --list             print the rows (pins first)
#   clipboard.sh --pin-text TEXT    pin text (tests / hub)
#   clipboard.sh --unpin N          remove pin N (1-based)
set -u

PINS="${CLIP_PINS:-${XDG_DATA_HOME:-$HOME/.local/share}/clip-pins}"   # one base64 line per pinned text
PIN_ICON='󰐃'

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

rows() {
  local i=0 line t
  if [[ -s $PINS ]]; then
    while IFS= read -r line; do
      i=$((i + 1))
      t=$(printf '%s' "$line" | base64 -d 2>/dev/null | tr '\n\t' '  ' | cut -c1-120)
      printf 'pin:%s\t%s %s\n' "$i" "$PIN_ICON" "$t"
    done <"$PINS"
  fi
  cliphist list 2>/dev/null
}

case ${1:-} in
  --list) rows; exit 0 ;;
  --pin-text) pin_add "${2:?text}"; exit 0 ;;
  --unpin) pin_del "${2:?n}"; exit 0 ;;
esac

while true; do
  rc=0
  pick=$(rows | rofi -dmenu -i -p clip -display-columns 2 -kb-custom-1 'Alt+d' -kb-custom-2 'Alt+p' \
    -mesg 'Enter: copy    Alt+p: pin / unpin    Alt+d: delete') || rc=$?
  id=${pick%%$'\t'*}
  case $rc in
    0)
      if [[ $id == pin:* ]]; then pin_get "${id#pin:}" | wl-copy; else printf '%s' "$pick" | cliphist decode | wl-copy; fi
      exit 0 ;;
    10)
      if [[ $id == pin:* ]]; then pin_del "${id#pin:}"; else printf '%s' "$pick" | cliphist delete; fi ;;
    11)
      if [[ $id == pin:* ]]; then
        pin_del "${id#pin:}"
      else
        txt=$(printf '%s' "$pick" | cliphist decode; echo x); txt=${txt%x}
        if [[ $pick == *'[[ binary data'* ]]; then
          notify-send -a clipboard -t 2000 "Clipboard" "only text can be pinned"
        elif pin=$(pin_find "$txt") && [[ -n $pin ]]; then
          pin_del "$pin"
        else
          pin_add "$txt"
        fi
      fi ;;
    *) exit 0 ;;
  esac
done
