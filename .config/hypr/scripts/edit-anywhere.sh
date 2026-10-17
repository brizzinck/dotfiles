#!/usr/bin/env bash
# edit-anywhere: SUPER+CTRL+E opens a small floating nvim (ghostty class float.edit) at the mouse pointer for text fields that
# have no vim; the text you write is pasted back into the window you came from.
#   edit-anywhere.sh open    the keybind: record the focused window, take the primary selection (the text selected on screen)
#                            as the starting text, open the editor in INSERT mode
#   edit-anywhere.sh help
#   --dry-run                (first argument) with `open`: print the geometry and the command, touch nothing
#
# In the editor: Ctrl+S (insert or normal), ZZ or :wq = finish; :q! or closing the window = cancel (nothing is pasted). Finish:
# the text goes to the clipboard, the window closes, the window you came from is focused again and gets the paste shortcut
# (Ctrl+V, Ctrl+Shift+V for terminals; the physical V key, so it works on the ua and ru layouts too). Text that was selected there
# is replaced because it is still selected in that field (GTK, Chromium and Electron fields replace a selection on paste). A
# terminal has no such replacement, so nothing is preloaded when you start from a terminal. The clipboard you had before is
# put back after a few seconds, unless it held an image, a password-manager copy or something that is not text.
# The nvim side is edit-anywhere.lua (loaded with -c, nothing in the owner's nvim config changes; K3 layout auto-switch is
# part of that config and works). The keyboard layout you had when you pressed the key is restored when the editor closes.
# Files: $XDG_RUNTIME_DIR/edit-anywhere/ (tmpfs, 0700), removed after every run.
# Test hooks: EDIT_ANYWHERE_DIR, EDIT_ANYWHERE_TERMINAL (command prefix replacing `ghostty --class=float.edit --title=edit-anywhere -e`),
# EDIT_ANYWHERE_NVIM, EDIT_ANYWHERE_NVIM_ARGS (extra nvim arguments, one per line), EDIT_ANYWHERE_RESTORE_DELAY (seconds, default 4),
# EDIT_ANYWHERE_NO_NOTIFY=1, EDIT_ANYWHERE_SYNC=1 (finish in the foreground), EDIT_ANYWHERE_KEEP=1 (keep the files).
set -u

DRY=0
if [[ ${1:-} == --dry-run ]]; then DRY=1; shift; fi
CMD=${1:-}
[[ $# -gt 0 ]] && shift
SELF=$(readlink -f "${BASH_SOURCE[0]}")
HERE=$(dirname "$SELF")
# shellcheck source=paste-lib.sh
. "$HERE/paste-lib.sh"
RUN=${EDIT_ANYWHERE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/edit-anywhere}
CLASS=float.edit
NVIM=${EDIT_ANYWHERE_NVIM:-nvim}
LUA="$HERE/edit-anywhere.lua"
read -ra TERMINAL <<<"${EDIT_ANYWHERE_TERMINAL:-ghostty --class=$CLASS --title=edit-anywhere -e}"
MAX_SELECTION=100000
MAX_CLIP=1000000
WIN_W=900
WIN_H=360

say() { # say TITLE [BODY]
  [[ ${EDIT_ANYWHERE_NO_NOTIFY:-0} == 1 ]] || { command -v notify-send >/dev/null && notify-send -a edit-anywhere -t 4000 -h string:x-dunst-stack-tag:edit-anywhere "$1" "${2:-}" 2>/dev/null; }
  printf '%s: %s\n' "$1" "${2:-}" >&2
}

editor_address() { hyprctl clients -j 2>/dev/null | jq -r --arg c "$CLASS" '[.[] | select(.class == $c)][0].address // empty'; }
window_exists() { hyprctl clients -j 2>/dev/null | jq -e --arg a "$1" 'any(.[]; .address == $a)' >/dev/null 2>&1; }
layout_index() { hyprctl devices -j 2>/dev/null | jq -r '[.keyboards[] | select(.main == true)][0].active_layout_index // empty'; }

selection_text() { # the primary selection as text; empty when none, not text, or too long
  local types
  types=$(wl-paste --primary --list-types 2>/dev/null) || return 0
  grep -qi 'x-kde-passwordmanagerhint' <<<"$types" && return 0
  grep -qiE '^(text/plain|string$|utf8_string$)' <<<"$types" || return 0
  local t
  t=$(wl-paste --primary --no-newline --type text/plain 2>/dev/null | head -c "$((MAX_SELECTION + 1))"; printf x)
  t=${t%x}
  ((${#t} > MAX_SELECTION)) && return 0
  printf '%s' "$t"
}

geometry() { # geometry -> "X Y W H": monitor-relative logical position (window centred on the pointer, clamped to the work area), size
  local cur mons
  cur=$(hyprctl cursorpos -j 2>/dev/null) || return 1
  mons=$(hyprctl monitors -j 2>/dev/null) || return 1
  jq -r --argjson c "$cur" --argjson W "$WIN_W" --argjson H "$WIN_H" '
    def lw: (if ((.transform // 0) % 2) == 1 then .height else .width end) / (.scale // 1);
    def lh: (if ((.transform // 0) % 2) == 1 then .width else .height end) / (.scale // 1);
    [.[] | select((.disabled // false) | not)] as $m
    | ([$m[] | select($c.x >= .x and $c.x < .x + lw and $c.y >= .y and $c.y < .y + lh)][0]
       // [$m[] | select(.focused)][0] // $m[0]) as $mo
    | ($mo.reserved // [0, 0, 0, 0]) as $r
    | ($mo | lw) as $mw | ($mo | lh) as $mh
    | ([$W, $mw - $r[0] - $r[2] - 16] | min | floor) as $w
    | ([$H, $mh - $r[1] - $r[3] - 16] | min | floor) as $h
    | ([([($c.x - $mo.x - $w / 2), ($r[0] + 8)] | max), ($mw - $r[2] - 8 - $w)] | min | floor) as $x
    | ([([($c.y - $mo.y - $h / 2), ($r[1] + 8)] | max), ($mh - $r[3] - 8 - $h)] | min | floor) as $y
    | "\($x) \($y) \($w) \($h)"' <<<"$mons"
}

launch() { # launch X Y W H: exec rules place the window (float, monitor-relative move, size) before it maps
  local x=$1 y=$2 w=$3 h=$4 cmd lua
  cmd="${TERMINAL[*]} $SELF _session"
  if ((DRY)); then printf '[dry-run] geometry %s,%s %sx%s: %s\n' "$x" "$y" "$w" "$h" "$cmd"; return 0; fi
  if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && command -v hyprctl >/dev/null 2>&1 && [[ -z ${EDIT_ANYWHERE_TERMINAL:-} ]]; then
    lua=$(jq -nr --arg c "$cmd" --arg mv "$x $y" --arg sz "$w $h" '"hl.dsp.exec_cmd(\($c | tojson), { float = true, move = \($mv | tojson), size = \($sz | tojson) })"')
    hyprctl dispatch "$lua" >/dev/null 2>&1 && return 0
  fi
  setsid -f "${TERMINAL[@]}" "$SELF" _session >/dev/null 2>&1 </dev/null
}

cmd_open() {
  local existing prev class sel geo
  existing=$(editor_address)
  if [[ -n $existing ]]; then hyprd focuswindow "address:$existing" >/dev/null 2>&1; return 0; fi
  prev=$(tg_record)
  class=""
  [[ -n $prev ]] && class=$(paste_class "$prev")
  if ((!DRY)); then
    (umask 077; mkdir -p "$RUN") && chmod 700 "$RUN"
    rm -f -- "$RUN/text.txt" "$RUN/saved" "$RUN/prev" "$RUN/prev-class" "$RUN/layout" "$RUN/clip.prev" "$RUN/clip.kind" "$RUN/nvim-args"
  fi
  sel=""
  if [[ $(paste_mods "$class") != "CTRL SHIFT" ]]; then sel=$(selection_text); fi
  geo=$(geometry) || { say "Edit anywhere" "Hyprland did not answer (cursor position or monitors)"; return 1; }
  if ((DRY)); then
    printf '[dry-run] target window=%s class=%s, preloaded %s characters from the primary selection\n' "${prev:-none}" "${class:-?}" "${#sel}"
  else
    printf '%s' "$prev" >"$RUN/prev"
    printf '%s' "$class" >"$RUN/prev-class"
    layout_index >"$RUN/layout"
    printf '%s' "$sel" >"$RUN/text.txt"
    [[ -n ${EDIT_ANYWHERE_NVIM_ARGS:-} ]] && printf '%s' "$EDIT_ANYWHERE_NVIM_ARGS" >"$RUN/nvim-args"
  fi
  # shellcheck disable=SC2086
  launch $geo
}

restore_layout() {
  local want cur
  want=$(cat "$RUN/layout" 2>/dev/null)
  [[ $want =~ ^[0-9]+$ ]] || return 0
  cur=$(layout_index)
  [[ -n $cur && $cur != "$want" ]] && hyprctl switchxkblayout all "$want" >/dev/null 2>&1
  return 0
}

cleanup() { [[ ${EDIT_ANYWHERE_KEEP:-0} == 1 ]] || rm -f -- "$RUN/text.txt" "$RUN/saved" "$RUN/prev" "$RUN/prev-class" "$RUN/layout" "$RUN/clip.prev" "$RUN/clip.kind" "$RUN/nvim-args"; }

cmd_session() { # runs inside the floating terminal; when it returns the window closes
  local rc extra=() args
  [[ -d $RUN ]] || { echo "edit-anywhere: no session directory" >&2; return 1; }
  cd "$RUN" || return 1
  args=${EDIT_ANYWHERE_NVIM_ARGS:-$(cat "$RUN/nvim-args" 2>/dev/null)}
  [[ -n $args ]] && mapfile -t extra <<<"$args" # one argument per line
  # the window closing under the editor (SIGHUP) is a cancel: the text must not linger in the session directory
  trap 'cleanup; exit 0' HUP TERM
  EDIT_ANYWHERE_DIR=$RUN "$NVIM" -n -i NONE --cmd 'set noswapfile noundofile nobackup nowritebackup shada=' \
    "${extra[@]}" -c "luafile $LUA" "$RUN/text.txt"
  rc=$?
  trap - HUP TERM
  restore_layout
  if [[ $rc -eq 0 && -e $RUN/saved ]]; then
    if [[ ${EDIT_ANYWHERE_SYNC:-0} == 1 ]]; then "$SELF" _finish; else setsid -f "$SELF" _finish >/dev/null 2>&1 </dev/null; fi
  else
    cleanup
  fi
  return 0
}

save_clipboard() { # remember a plain text clipboard (not an image, not a password-manager copy, not huge) for the restore
  local types
  rm -f -- "$RUN/clip.prev" "$RUN/clip.kind"
  types=$(wl-paste --list-types 2>/dev/null) || return 0
  [[ -n $types ]] || return 0
  grep -qi 'x-kde-passwordmanagerhint' <<<"$types" && return 0
  grep -qi '^image/' <<<"$types" && return 0
  grep -qiE '^(text/plain|string$|utf8_string$)' <<<"$types" || return 0
  wl-paste --no-newline --type text/plain 2>/dev/null | head -c "$((MAX_CLIP + 1))" >"$RUN/clip.prev"
  if (($(stat -c %s "$RUN/clip.prev") > MAX_CLIP)); then rm -f "$RUN/clip.prev"; return 0; fi
  echo text >"$RUN/clip.kind"
}

restore_clipboard_later() { # restore_clipboard_later TEXT: after a few seconds, only if the clipboard still holds our text
  local delay=${EDIT_ANYWHERE_RESTORE_DELAY:-4} ours
  [[ -e $RUN/clip.kind && -s $RUN/clip.prev ]] || return 0
  ours=$(mktemp "$RUN/ours.XXXXXX")
  printf '%s' "$1" >"$ours"
  (
    sleep "$delay"
    cur=$(wl-paste --no-newline --type text/plain 2>/dev/null; printf x)
    want=$(cat "$ours"; printf x)
    if [[ $cur == "$want" ]]; then wl-copy -t text/plain <"$RUN/clip.prev"; fi
    rm -f -- "$RUN/clip.prev" "$RUN/clip.kind" "$ours"
  ) >/dev/null 2>&1 </dev/null &
}

cmd_finish() { # copy, wait for the window to be gone, refocus, paste, restore the clipboard
  local text prev i
  text=$(cat "$RUN/text.txt" 2>/dev/null; printf x)
  text=${text%x}
  prev=$(cat "$RUN/prev" 2>/dev/null)
  if [[ -z ${text//[[:space:]]/} ]]; then
    say "Edit anywhere" "empty text, nothing pasted"
    cleanup
    return 0
  fi
  save_clipboard
  printf '%s' "$text" | wl-copy -t text/plain
  if [[ -z $prev ]]; then
    say "Edit anywhere" "no window to paste into: the text is on the clipboard"
    rm -f -- "$RUN/clip.prev" "$RUN/clip.kind"; cleanup
    return 0
  fi
  # the editor window closes when its terminal command returns: wait for it (at most 3 s)
  for ((i = 0; i < 60; i++)); do [[ -z $(editor_address) ]] && break; sleep 0.05; done
  if ! window_exists "$prev"; then
    say "Edit anywhere" "the target window is gone: the text is on the clipboard"
    rm -f -- "$RUN/clip.prev" "$RUN/clip.kind"; cleanup
    return 0
  fi
  hyprd focuswindow "address:$prev" >/dev/null 2>&1
  for ((i = 0; i < 40; i++)); do [[ $(tg_active) == "$prev" ]] && break; sleep 0.025; done
  sleep 0.2 # the physical Ctrl of Ctrl+S is released by now; the paste shortcut is sent with explicit modifiers
  if ! tg_ok "$prev" edit-anywhere; then
    say "Edit anywhere" "focus changed: the text is on the clipboard"
    rm -f -- "$RUN/clip.prev" "$RUN/clip.kind"; cleanup
    return 0
  fi
  paste_send "$prev"
  restore_clipboard_later "$text"
  # the session files go now; clip.prev (and the marker of our text) stay for the restore
  rm -f -- "$RUN/text.txt" "$RUN/saved" "$RUN/prev" "$RUN/prev-class" "$RUN/layout" "$RUN/nvim-args"
}

case $CMD in
  open) cmd_open ;;
  _session) cmd_session ;;
  _finish) cmd_finish ;;
  -h | --help | help | "") sed -n '2,/^set -u/p' "$0" | sed '$d;s/^# \{0,1\}//' ;;
  *) echo "edit-anywhere: unknown command $CMD (open)" >&2; exit 2 ;;
esac
