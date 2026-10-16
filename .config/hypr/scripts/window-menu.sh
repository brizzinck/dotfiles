#!/usr/bin/env bash
# Window action menu in rofi. SUPER+SHIFT+W, also "This window" in the hub.
# The target window is captured BEFORE rofi opens (rofi is a layer surface, it does not change focus) and every
# action uses `address:` dispatchers; dispatchers that only work on the active window refocus the target first.
#
#   window-menu.sh                       interactive menu for the active window (or $HUB_TARGET = address:0x...)
#   window-menu.sh --addr 0x...          target a specific window
#   window-menu.sh --list                print the top-level menu entries (id <TAB> label)
#   window-menu.sh --do ID [ARG]         run one action without rofi (ids from --list; sub-actions below)
#   window-menu.sh --dry-run ...         print the hyprctl/shell commands instead of running them
#
# Sub-actions for --do: opacity <1|0.9|0.8|0.7|0.5|opaque|reset>, size <60|80|pip|center>,
#   group <toggle|left|right|lock>, workspace <N|scratch>, monitor <name>, copy <class|title|both|pid|rule>
#
# Hooks for later stages: every executable file in window-hooks/ becomes a menu entry. The entry label is the
# first `# menu: Label` line of the file (default: the file name). The hook is run as `hook ADDRESS` with
# WIN_ADDR WIN_CLASS WIN_TITLE WIN_PID WIN_X WIN_Y WIN_W WIN_H WIN_WS WIN_MON in its environment. Missing = no entry.
set -u

SCRIPTS=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
HOOKS="$SCRIPTS/window-hooks"
SHOTS="$HOME/pics/screenshots"
DRY=0
ADDR=""

die() { echo "window-menu: $*" >&2; exit 1; }

# ───────────────────────────── target window ─────────────────────────────

load_window() {
  local want=${ADDR:-${HUB_TARGET:-}} json
  want=${want#address:}
  if [[ -n $want ]]; then
    json=$(hyprctl clients -j | jq -c --arg a "$want" '.[] | select(.address == $a)')
  else
    json=$(hyprctl activewindow -j)
  fi
  [[ -n $json ]] || die "no target window"
  eval "$(jq -r '@sh "A=\(.address // "") CLASS=\(.class) TITLE=\(.title) PID=\(.pid) FLOATING=\(.floating) PINNED=\(.pinned) WS=\(.workspace.name) MONID=\(.monitor) X=\(.at[0]) Y=\(.at[1]) W=\(.size[0]) H=\(.size[1]) XWAY=\(.xwayland) GROUPED=\(.grouped | length) FSC=\(.fullscreenClient)"' <<<"$json")"
  [[ -n $A ]] || die "no target window"
  MON=$(hyprctl monitors -j | jq -r --argjson id "$MONID" '.[] | select(.id == $id) | .name')
  ACTIVE=$(hyprctl activewindow -j | jq -r '.address // ""')
  export WIN_ADDR=$A WIN_CLASS=$CLASS WIN_TITLE=$TITLE WIN_PID=$PID WIN_X=$X WIN_Y=$Y WIN_W=$W WIN_H=$H WIN_WS=$WS WIN_MON=$MON
}

# ───────────────────────────── helpers ─────────────────────────────

# hyprctl dispatch (address-capable dispatchers)
hc() {
  if ((DRY)); then echo "hyprctl dispatch $*"; else hyprctl dispatch "$@" >/dev/null; fi
}

# dispatchers that act on the active window only: refocus the target first (skipped when it is already active)
hc_active() {
  if [[ $A == "$ACTIVE" ]]; then
    hc "$@"
  elif ((DRY)); then
    echo "hyprctl --batch 'dispatch focuswindow address:$A ; dispatch $*'"
  else
    hyprctl --batch "dispatch focuswindow address:$A ; dispatch $*" >/dev/null
  fi
}

# same for a shell command that needs the target to be the active window
sh_active() {
  if [[ $A != "$ACTIVE" ]]; then
    if ((DRY)); then echo "hyprctl dispatch focuswindow address:$A"; else hyprctl dispatch focuswindow "address:$A" >/dev/null; fi
  fi
  if ((DRY)); then echo "$*"; else bash -c "$*"; fi
}

note() { if ((DRY)); then echo "notify: $*"; else notify-send -a window-menu -t 2500 "$@"; fi; }

rofi_menu() { # $1 prompt, $2 mesg; entries on stdin; prints the chosen index
  local n
  mapfile -t _entries
  n=${#_entries[@]}
  ((n > 14)) && n=14
  printf '%s\n' "${_entries[@]}" | rofi -dmenu -i -p "$1" -mesg "$2" -format i -no-custom \
    -theme-str "window { width: 520px; } listview { lines: $n; }"
}

confirm() {
  local answer
  if ((DRY)); then echo "confirm: $1 (skipped in dry-run)"; return 0; fi
  answer=$(printf 'no\nyes\n' | rofi -dmenu -i -p "$1?" -theme-str 'window { width: 360px; } listview { lines: 2; }') || return 1
  [[ $answer == yes ]]
}

copy_text() {
  if ((DRY)); then printf 'wl-copy: %s\n' "$1"; else printf '%s' "$1" | wl-copy; fi
  note "Copied" "$1"
}

monitor_geom() { # prints "mx my lw lh rl rt rr rb" of the target's monitor in logical pixels
  hyprctl monitors -j | jq -r --argjson id "$MONID" '.[] | select(.id == $id)
    | "\(.x) \(.y) \((.width / .scale) | floor) \((.height / .scale) | floor) \(.reserved[0]) \(.reserved[1]) \(.reserved[2]) \(.reserved[3])"'
}

# ───────────────────────────── actions ─────────────────────────────

act_float() { hc togglefloating "address:$A"; }

act_pin() {
  if [[ $PINNED == true ]]; then
    hc pin "address:$A"
  else
    [[ $FLOATING == true ]] || hc setfloating "address:$A"
    hc pin "address:$A"
  fi
}

act_fullscreen() { hc_active fullscreen 0; }
act_maximize() { hc_active fullscreen 1; }
act_fakefs() { if [[ $FSC == 2 ]]; then hc_active fullscreenstate 0 0; else hc_active fullscreenstate 0 2; fi; }

act_opacity() {
  case ${1:-} in
    opaque) hc setprop "address:$A" opaque toggle ;;
    reset) hc setprop "address:$A" opacity -1 ;;
    1 | 0.9 | 0.8 | 0.7 | 0.5) hc setprop "address:$A" opacity "$1" ;;
    *) die "opacity: unknown value '${1:-}'" ;;
  esac
}

act_size() {
  local mx my lw lh _rl _rt rr rb pw ph px py
  read -r mx my lw lh _rl _rt rr rb <<<"$(monitor_geom)"
  case ${1:-} in
    60 | 80)
      [[ $FLOATING == true ]] || hc setfloating "address:$A"
      hc resizewindowpixel "exact $1% $((${1} + 5))%,address:$A"
      hc_active centerwindow
      ;;
    center) hc_active centerwindow ;;
    pip)
      pw=$((lw / 4))
      ph=$((pw * 9 / 16))
      px=$((mx + lw - rr - pw - 12))
      py=$((my + lh - rb - ph - 12))
      [[ $FLOATING == true ]] || hc setfloating "address:$A"
      hc resizewindowpixel "exact $pw $ph,address:$A"
      hc movewindowpixel "exact $px $py,address:$A"
      [[ $PINNED == true ]] || hc pin "address:$A"
      ;;
    *) die "size: unknown value '${1:-}'" ;;
  esac
}

act_group() {
  case ${1:-} in
    toggle) hc_active togglegroup ;;
    left) hc_active moveintogroup l ;;
    right) hc_active moveintogroup r ;;
    lock) hc_active lockactivegroup toggle ;;
    *) die "group: unknown value '${1:-}'" ;;
  esac
}

act_workspace() {
  case ${1:-} in
    scratch) hc movetoworkspacesilent "special:scratch,address:$A" ;;
    [0-9]*) hc movetoworkspacesilent "$1,address:$A" ;;
    *) die "workspace: unknown value '${1:-}'" ;;
  esac
}

act_monitor() {
  [[ -n ${1:-} ]] || die "monitor: name required"
  hc_active movewindow "mon:$1"
}

act_shot() { sh_active "hyprshot -m window -m active -o '$SHOTS'"; }
act_annotate() {
  sh_active "grim -g '$X,$Y ${W}x${H}' - | satty -f - --copy-command wl-copy --output-filename '$SHOTS/%F_%T.png'"
}
act_record() { if ((DRY)); then echo "$SCRIPTS/rec-toggle.sh window $A"; else "$SCRIPTS/rec-toggle.sh" window "$A"; fi; }

act_copy() {
  local cls_re
  case ${1:-} in
    class) copy_text "$CLASS" ;;
    title) copy_text "$TITLE" ;;
    both) copy_text "$CLASS $TITLE" ;;
    pid) copy_text "$PID" ;;
    rule)
      cls_re=${CLASS//./\\.}
      copy_text "$(printf 'windowrule {\n    name = %s\n    match:class = ^(%s)$\n}' "$CLASS" "$cls_re")"
      ;;
    *) die "copy: unknown value '${1:-}'" ;;
  esac
}

act_info() {
  note "$CLASS" "$(printf 'title: %s\npid: %s  %s\nworkspace: %s  monitor: %s\nat %s,%s  size %sx%s\nfloating: %s  pinned: %s' \
    "$TITLE" "$PID" "$([[ $XWAY == true ]] && echo xwayland || echo wayland)" "$WS" "$MON" "$X" "$Y" "$W" "$H" "$FLOATING" "$PINNED")"
}

act_close() { hc closewindow "address:$A"; }
act_kill() { confirm "force kill $CLASS" && hc killwindow "address:$A"; }
act_killapp() {
  local a
  confirm "close all $CLASS windows" || return 0
  while read -r a; do
    [[ -n $a ]] && hc closewindow "address:$a"
  done < <(hyprctl clients -j | jq -r --arg c "$CLASS" '.[] | select(.class == $c) | .address')
}

hook_file() { echo "$HOOKS/$1"; }
act_hook() {
  local f
  f=$(hook_file "${1:-}")
  [[ -x $f ]] || die "hook not found: ${1:-}"
  if ((DRY)); then echo "hook: $f $A (WIN_ADDR=$A WIN_CLASS=$CLASS WIN_PID=$PID WIN_X=$X WIN_Y=$Y WIN_W=$W WIN_H=$H)"; else "$f" "$A"; fi
}

# ───────────────────────────── menu ─────────────────────────────

# top-level entries: "id<TAB>label"
menu_entries() {
  local f label
  printf '%s\t%s\n' float "$([[ $FLOATING == true ]] && echo 'Tile (stop floating)' || echo 'Float')"
  printf '%s\t%s\n' pin "$([[ $PINNED == true ]] && echo 'Unpin' || echo 'Pin on all workspaces')"
  printf '%s\t%s\n' fullscreen 'Fullscreen'
  printf '%s\t%s\n' maximize 'Maximize (keep bar)'
  printf '%s\t%s\n' fakefs "$([[ $FSC == 2 ]] && echo 'Fullscreen inside tile: off' || echo 'Fullscreen inside tile')"
  printf '%s\t%s\n' opacity 'Opacity...'
  printf '%s\t%s\n' size 'Size and position...'
  printf '%s\t%s\n' group 'Group (tabs)...'
  printf '%s\t%s\n' workspace 'Move to workspace...'
  if (($(hyprctl monitors -j | jq length) > 1)); then printf '%s\t%s\n' monitor 'Move to monitor...'; fi
  command -v hyprshot >/dev/null && printf '%s\t%s\n' shot 'Screenshot this window'
  command -v satty >/dev/null && printf '%s\t%s\n' annotate 'Screenshot and annotate this window'
  command -v gpu-screen-recorder >/dev/null && printf '%s\t%s\n' record 'Record this window (toggle)'
  for f in "$HOOKS"/*; do
    [[ -f $f && -x $f ]] || continue
    label=$(sed -n '1,8s/^# menu: *//p' "$f" | head -n1)
    printf 'hook:%s\t%s\n' "${f##*/}" "${label:-${f##*/}}"
  done
  printf '%s\t%s\n' copy 'Copy class / title / pid / windowrule...'
  printf '%s\t%s\n' info 'Window info'
  printf '%s\t%s\n' close 'Close'
  printf '%s\t%s\n' kill 'Force kill... (confirm)'
  printf '%s\t%s\n' killapp "Close all $CLASS windows... (confirm)"
}

sub_pick() { # $1 prompt; entries "value<TAB>label" on stdin; prints the value
  local -a vals labels
  local v l i
  while IFS=$'\t' read -r v l; do vals+=("$v"); labels+=("$l"); done
  i=$(printf '%s\n' "${labels[@]}" | rofi_menu "$1" "$(mesg_line)") || return 1
  printf '%s' "${vals[i]}"
}

sub_menu() {
  local pick
  case $1 in
    opacity)
      pick=$(printf '%s\t%s\n' 1 '100%' 0.9 '90%' 0.8 '80%' 0.7 '70%' 0.5 '50%' opaque 'Toggle forced opaque' reset 'Reset to default' | sub_pick opacity) || return 0
      act_opacity "$pick" ;;
    size)
      pick=$(printf '%s\t%s\n' 60 'Float centered 60%' 80 'Float centered 80%' pip 'Picture-in-picture (bottom-right, pinned)' center 'Center (floating)' | sub_pick size) || return 0
      act_size "$pick" ;;
    group)
      pick=$(printf '%s\t%s\n' toggle 'Toggle group' left 'Move into group on the left' right 'Move into group on the right' lock 'Lock / unlock group' | sub_pick group) || return 0
      act_group "$pick" ;;
    workspace)
      pick=$({ hyprctl workspaces -j | jq -r '.[] | select(.id > 0) | "\(.id)\t\(.windows)"' | sort -n | awk -F'\t' '{ w[$1] = $2 }
          END { for (i = 1; i <= 20; i++) printf "%d\tWorkspace %d%s\n", i, i, (i in w ? "  (" w[i] " windows)" : "") }'
        printf 'scratch\tScratch (special)\n'; } | sub_pick workspace) || return 0
      act_workspace "$pick" ;;
    monitor)
      pick=$(hyprctl monitors -j | jq -r --argjson id "$MONID" '.[] | select(.id != $id) | "\(.name)\t\(.name) (\(.description))"' | sub_pick monitor) || return 0
      act_monitor "$pick" ;;
    copy)
      pick=$(printf '%s\t%s\n' class "Class: $CLASS" title "Title: ${TITLE:0:50}" both 'Class and title' pid "PID: $PID" rule 'windowrule stub for this class' | sub_pick copy) || return 0
      act_copy "$pick" ;;
  esac
}

mesg_line() {
  local t=${TITLE:0:50}
  t=${t//&/&amp;}; t=${t//</&lt;}; t=${t//>/&gt;}
  local c=${CLASS//&/&amp;}
  printf '%s · %s · pid %s · ws %s' "$c" "$t" "$PID" "$WS"
}

run_do() {
  local id=$1
  shift
  case $id in
    float) act_float ;; pin) act_pin ;; fullscreen) act_fullscreen ;; maximize) act_maximize ;; fakefs) act_fakefs ;;
    opacity) act_opacity "$@" ;; size) act_size "$@" ;; group) act_group "$@" ;; workspace) act_workspace "$@" ;;
    monitor) act_monitor "$@" ;; shot) act_shot ;; annotate) act_annotate ;; record) act_record ;;
    copy) act_copy "$@" ;; info) act_info ;; close) act_close ;; kill) act_kill ;; killapp) act_killapp ;;
    hook:*) act_hook "${id#hook:}" ;;
    *) die "unknown action '$id'" ;;
  esac
}

interactive() {
  local -a ids labels
  local id label i
  while IFS=$'\t' read -r id label; do ids+=("$id"); labels+=("$label"); done < <(menu_entries)
  i=$(printf '%s\n' "${labels[@]}" | rofi_menu win "$(mesg_line)") || exit 0
  id=${ids[i]}
  case $id in
    opacity | size | group | workspace | monitor | copy) sub_menu "$id" ;;
    *) run_do "$id" ;;
  esac
}

# ───────────────────────────── main ─────────────────────────────

mode=interactive
doargs=()
while (($#)); do
  case $1 in
    --dry-run) DRY=1 ;;
    --addr) shift; ADDR=${1:?address} ;;
    --list) mode=list ;;
    --do) mode=act; shift; doargs=("$@"); break ;;
    -h | --help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
  shift
done

load_window
case $mode in
  list) menu_entries ;;
  act) ((${#doargs[@]})) || die "--do needs an action id"; run_do "${doargs[@]}" ;;
  *) interactive ;;
esac
