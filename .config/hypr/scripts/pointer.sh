#!/usr/bin/env bash
# pointer.sh: drive the mouse pointer from the keyboard (wl-kbptr + wlrctl, both AUR packages).
# Every action checks its tool first and shows a short notification when it is missing, so a bind never fails silently.
#   pointer.sh hint            SUPER+apostrophe: label grid, then bisect, then click (wl-kbptr)
#   pointer.sh drag            SUPER+CTRL+apostrophe: pick a start and an end, press-move-release (text selection, drag and drop)
#   pointer.sh mode            SUPER+ALT+M: enter the `mouse` submap (hjkl move, space click, ...; needs wlrctl)
#   pointer.sh hint-in-mode    `f` inside mouse mode: leave the submap, run wl-kbptr, come back
#   pointer.sh move DX DY | click left|right|middle | scroll DY DX     (the mouse submap's keys, through wlrctl)
#   --dry-run as the first argument prints the commands instead of running them.
# Colours of the overlay: ~/.config/wl-kbptr/config (symlink to the generated palette fragment, themes/palette).
set -u

DRY=0
if [[ ${1:-} == --dry-run ]]; then
  DRY=1
  shift
fi

notify() {
  if ((DRY)); then echo "DRY: notify: $1"; return 0; fi
  notify-send -a pointer -u low -t 4000 -h string:x-dunst-stack-tag:pointer "Keyboard pointer" "$1" 2>/dev/null || true
}

need() { # need TOOL: succeed when it exists; otherwise tell the owner how to get it
  if command -v "$1" >/dev/null 2>&1; then return 0; fi
  notify "$1 is not installed (AUR; install it with: sudo ~/dotfiles/apply-system.sh --only install)"
  return 1
}

run() {
  if ((DRY)); then echo "DRY: $*"; else "$@" >/dev/null; fi
}

# wl-kbptr takes its labels from the ACTIVE layout, so on ua/ru the Latin labels could not be typed. Switch the main
# keyboard to layout 1 (us) for the run and put the layout back afterwards.
with_us_layout() {
  local info=() kb idx rc
  mapfile -t info < <(hyprctl devices -j 2>/dev/null | jq -r '[.keyboards[] | select(.main)][0] | (.name // empty), (.active_layout_index // 0)')
  kb=${info[0]:-}
  idx=${info[1]:-0}
  if [[ -z $kb || $idx == 0 ]]; then
    run "$@"
    return
  fi
  run hyprctl switchxkblayout "$kb" 0
  run "$@"
  rc=$?
  run hyprctl switchxkblayout "$kb" "$idx"
  return $rc
}

case ${1:-} in
  hint)
    need wl-kbptr || exit 0
    with_us_layout wl-kbptr -o modes=tile,bisect
    ;;
  drag)
    need wl-kbptr || exit 0
    with_us_layout wl-kbptr --drag -o modes=tile,bisect
    ;;
  mode)
    need wlrctl || exit 0
    run hyprctl eval 'df_mouse_mode(true)'
    ;;
  hint-in-mode)
    need wl-kbptr || exit 0
    run hyprd submap reset
    with_us_layout wl-kbptr -o modes=tile,bisect
    run hyprd submap mouse
    ;;
  move)
    need wlrctl || exit 0
    run wlrctl pointer move "${2:?dx}" "${3:?dy}"
    ;;
  click)
    need wlrctl || exit 0
    run wlrctl pointer click "${2:?button}"
    ;;
  scroll)
    need wlrctl || exit 0
    run wlrctl pointer scroll "${2:?dy}" "${3:-0}"
    ;;
  *)
    echo "usage: pointer.sh [--dry-run] hint|drag|mode|hint-in-mode|move DX DY|click BUTTON|scroll DY DX" >&2
    exit 2
    ;;
esac
