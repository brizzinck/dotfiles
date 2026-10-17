#!/usr/bin/env bash
# pinned: the pinned apps on the waybar (list: ~/.config/waybar/pinned.tsv, state: pinned-watch.py). One waybar module per
# app, custom/pin#ID, in both bars. pinned-watch.py (one daemon) renders the module output; this script prints it and
# handles the clicks.
#
#   pinned.sh module ID    print the module JSON (waybar exec of the first pin, and the fallback of the others when their file does
#                          not exist yet; also starts the daemon when it is not running; the other pins just `cat` the file)
#   pinned.sh click ID     L: focus the app (repeat: next window of the app); launch it when it has no window
#   pinned.sh middle ID    M: mark as read (clears the soft "new" highlight)
#   pinned.sh menu ID      R: fzf-menu with the windows, New window / Launch, Mark read, Close all windows
#   pinned.sh gen          print the module definitions (group/pinned + custom/pin#ID per row) as jsonc;
#                          bar.sh render writes them to ~/.local/state/waybar/pinned.jsonc, which both bars include
#   pinned.sh list         print the ids, one per line
#   pinned.sh check        verify the list, the generated modules in both bars and the daemon (doctor.sh); prints problems
#   pinned.sh start        start the daemon unless it runs
#   pinned.sh edit         open pinned.tsv in $EDITOR (float.tui terminal), then reload the bar
#   --dry-run              print the focus / launch / close commands instead of running them
# Waybar signal 14 = the daemon changed a module file (pkill -o -u $(id -u) -RTMIN+14 -x waybar). The "new" flag of an app
# is the file $XDG_RUNTIME_DIR/pinned/new/ID: set by pinned-watch.py on a matching notification, removed on focus.
# Test hooks: PINNED_DIR, PINNED_TSV, PINNED_NO_POKE (see pinned-watch.py).
set -u

HERE="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
WATCH="$HERE/pinned-watch.py"
TSV="${PINNED_TSV:-$HOME/.config/waybar/pinned.tsv}"
DIR="${PINNED_DIR:-${XDG_RUNTIME_DIR:-/tmp}/pinned}"
PROTECTED="$HOME/.config/hypr/scripts/safe-close.sh"
DRY=0
args=()
for a in "$@"; do
  if [[ $a == --dry-run ]]; then DRY=1; else args+=("$a"); fi
done
set -- "${args[@]+"${args[@]}"}"

note() { notify-send -a pinned -h string:x-dunst-stack-tag:pinned -t 2500 "$@" 2>/dev/null || true; }

# row ID: sets LABEL GLYPH CLS LAUNCH NOTIFY from pinned.tsv (comments and blank lines skipped; "-" = none)
row() {
  local id _l
  while IFS=$'\t' read -r id LABEL GLYPH CLS LAUNCH NOTIFY _l; do
    [[ $id == "$1" ]] && return 0
  done < <(grep -vE '^[[:space:]]*(#|$)' "$TSV" 2>/dev/null)
  return 1
}

ids() { grep -vE '^[[:space:]]*(#|$)' "$TSV" 2>/dev/null | cut -f1; }

# daemon_alive: cheap check (builtins only, no python start, no fork): the pid file names a live pinned-watch.py
daemon_alive() {
  local pid argv=()
  { pid=$(<"$DIR/pid"); } 2>/dev/null || return 1
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  mapfile -d '' -t argv <"/proc/$pid/cmdline" 2>/dev/null || return 1
  [[ ${argv[*]} == *pinned-watch* ]]
}

start_daemon() {
  [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || return 1
  daemon_alive && return 0
  mkdir -p "$DIR/new"
  # 9>&-: the daemon must not inherit bar.sh's lock
  setsid -f "$WATCH" </dev/null >>"$DIR/watch.log" 2>&1 9>&-
}

refresh() { "$WATCH" --refresh 2>/dev/null || start_daemon; }

# windows: "address<TAB>class<TAB>workspace<TAB>title" per window of the app, most recently focused first
windows() {
  hyprctl clients -j 2>/dev/null | jq -r --arg re "$CLS" '
    [.[] | select(.mapped and .workspace.name != "special:menu" and (.class | test($re; "i")))] | sort_by(.focusHistoryID) | .[]
    | [.address, .class, .workspace.name, (.title | gsub("[\t\n\r]"; " "))] | @tsv'
}

close_addr() {
  if ((DRY)); then echo "would run: hyprd closewindow address:$1"; else hyprd closewindow "address:$1" >/dev/null 2>&1; fi
}

launch() {
  if ((DRY)); then echo "would run: $LAUNCH"; return 0; fi
  # same entry as the rofi launcher; detached so the app outlives this script
  setsid -f bash -c "$LAUNCH" </dev/null >/dev/null 2>&1 9>&-
}

focus_addr() {
  if ((DRY)); then echo "would run: hyprd focuswindow address:$1"; else hyprd focuswindow "address:$1" >/dev/null 2>&1; fi
}

clear_new() { ((DRY)) || rm -f "$DIR/new/$1"; }

cmd_module() {
  local f="$DIR/$1.json"
  start_daemon >/dev/null 2>&1 || true
  if [[ -r $f ]]; then cat "$f"; return 0; fi
  # no daemon output yet (login race, or Hyprland is not up): a dim icon from the list
  row "$1" || return 0
  printf '{"text": "%s", "class": ["dim"], "tooltip": "%s"}\n' "$GLYPH" "$LABEL"
}

cmd_click() {
  row "$1" || { note "Pinned apps" "unknown app: $1"; return 1; }
  local -a w addrs=()
  local active a i cur=-1 target n
  mapfile -t w < <(windows)
  if ((${#w[@]} == 0)); then launch; return 0; fi
  active=$(hyprctl activewindow -j 2>/dev/null | jq -r '.address // ""')
  n=${#w[@]}
  while IFS= read -r a; do addrs+=("$a"); done < <(printf '%s\n' "${w[@]}" | cut -f1 | sort)
  for i in "${!addrs[@]}"; do [[ ${addrs[$i]} == "$active" ]] && cur=$i; done
  if ((cur >= 0 && n > 1)); then
    target=${addrs[$(((cur + 1) % n))]} # already on the app: the next window, in a stable order
  elif ((cur >= 0)); then
    target=$active
  else
    target=${w[0]%%$'\t'*} # the window of the app that was focused last
  fi
  focus_addr "$target"
  clear_new "$1"
  ((DRY)) || refresh
}

cmd_middle() {
  row "$1" || return 1
  clear_new "$1"
  ((DRY)) || refresh
}

cmd_menu() {
  row "$1" || return 1
  command -v fzf-menu >/dev/null 2>&1 || { note "Pinned apps" "fzf-menu not found"; return 1; }
  local -a w rows=() acts=()
  local line addr cls ws title pick n yes
  mapfile -t w < <(windows)
  n=${#w[@]}
  for line in "${w[@]}"; do
    IFS=$'\t' read -r addr cls ws title <<<"$line"
    rows+=("Focus: ${title:-$cls}  (ws $ws)")
    acts+=("focus $addr")
  done
  if ((n)); then rows+=("New window"); else rows+=("Launch $LABEL"); fi
  acts+=(launch)
  if [[ -e $DIR/new/$1 ]]; then rows+=("Mark read"); acts+=(read); fi
  if ((n)); then rows+=("Close all windows ($n)"); acts+=(close); fi
  pick=$(printf '%s\n' "${rows[@]}" | fzf-menu -p "$LABEL" --index) || return 0
  case ${acts[$pick]:-} in
    focus*) focus_addr "${acts[$pick]#focus }"; clear_new "$1" ;;
    launch) launch ;;
    read) clear_new "$1" ;;
    close)
      cls=$(cut -f2 <<<"${w[0]}")
      if "$PROTECTED" --check "$cls" 2>/dev/null | grep -q '^protected'; then # browsers, terminals, Telegram: ask first
        yes=$(printf '%s\n' "No, keep them open" "Yes, close $n window(s) of $LABEL" | fzf-menu -p "close $LABEL?") || return 0
        [[ $yes == Yes* ]] || return 0
      fi
      for line in "${w[@]}"; do close_addr "${line%%$'\t'*}"; done
      ;;
  esac
  ((DRY)) || refresh
}

# gen: module definitions for the rows, as jsonc for bar.sh render
cmd_gen() {
  local id mods="" defs=() ex
  while read -r id; do
    [[ $id =~ ^[a-z0-9]+$ ]] || continue
    if [[ -z $mods ]]; then
      # the first pin is the one place that runs the script: it prints the file and restarts a dead daemon
      ex="~/.config/waybar/scripts/pinned.sh module $id"
    else
      # every other pin only reads the file pinned-watch.py wrote (8 ms of bash saved per pin and poke); the script is
      # the fallback while the file does not exist yet (login race)
      ex="cat \\\"\$XDG_RUNTIME_DIR/pinned/$id.json\\\" 2>/dev/null || ~/.config/waybar/scripts/pinned.sh module $id"
    fi
    mods+="${mods:+, }\"custom/pin#$id\""
    defs+=("  \"custom/pin#$id\": {
    \"exec\": \"$ex\",
    \"return-type\": \"json\",
    \"signal\": 14,
    \"interval\": 300,
    \"on-click\": \"~/.config/waybar/scripts/pinned.sh click $id\",
    \"on-click-middle\": \"~/.config/waybar/scripts/pinned.sh middle $id\",
    \"on-click-right\": \"~/.config/waybar/scripts/pinned.sh menu $id\"
  }")
  done < <(ids)
  printf '// Generated by pinned.sh gen (bar.sh render) from ~/.config/waybar/pinned.tsv; do not edit.\n{\n'
  printf '  "group/pinned": { "orientation": "inherit", "modules": [%s] }' "$mods"
  for id in "${defs[@]}"; do printf ',\n%s' "$id"; done
  printf '\n}\n'
}

cmd_check() {
  local p=() id n=0 state mods
  state="${BAR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/waybar}"
  [[ -r $TSV ]] || { echo "pinned.tsv missing"; return 0; }
  while IFS=$'\t' read -r id LABEL GLYPH CLS LAUNCH NOTIFY _l; do
    n=$((n + 1))
    if [[ -z $NOTIFY || -z $LAUNCH || -z $CLS || -z $GLYPH || -z $LABEL || ! $id =~ ^[a-z0-9]+$ ]]; then p+=("row $n ($id): needs 6 fields"); continue; fi
    printf '' | grep -E -- "$CLS" >/dev/null 2>&1; (($? == 2)) && p+=("$id: class regex does not compile")
    [[ $NOTIFY == - ]] || { printf '' | grep -E -- "$NOTIFY" >/dev/null 2>&1; (($? == 2)) && p+=("$id: notify regex does not compile"); }
    command -v "${LAUNCH%% *}" >/dev/null 2>&1 || p+=("$id: launch command ${LAUNCH%% *} not found")
  done < <(grep -vE '^[[:space:]]*(#|$)' "$TSV")
  ((n)) || p+=("pinned.tsv has no rows")
  # the generated include and the bars
  if [[ -r $state/pinned.jsonc ]]; then
    mods=$(cmd_gen | diff -q - "$state/pinned.jsonc" >/dev/null 2>&1 && echo same || echo stale)
    [[ $mods == same ]] || p+=("$state/pinned.jsonc is stale (run: bar.sh reload)")
  else
    p+=("$state/pinned.jsonc missing (run: bar.sh render)")
  fi
  grep -c '"include".*pinned.jsonc' "$HERE/../config" 2>/dev/null | grep -qx 2 || p+=("config does not include pinned.jsonc in both bars")
  grep -c '"group/pinned",' "$HERE/../config" 2>/dev/null | grep -qx 2 || p+=("config does not list group/pinned in both bars")
  daemon_alive || p+=("pinned-watch.py is not running (pinned.sh start)")
  local IFS=';'
  echo "${p[*]}"
}

cmd_edit() {
  local ed="${EDITOR:-nvim}"
  ghostty --class=float.tui -e bash -c "$ed \"\$1\"" _ "$TSV"
  "$HERE/bar.sh" reload
}

case ${1:-} in
  module) cmd_module "${2:?id}" ;;
  click) cmd_click "${2:?id}" ;;
  middle) cmd_middle "${2:?id}" ;;
  menu) cmd_menu "${2:?id}" ;;
  gen) cmd_gen ;;
  list) ids ;;
  check) cmd_check ;;
  start) start_daemon ;;
  edit) cmd_edit ;;
  *) echo "usage: pinned.sh module|click|middle|menu ID | gen | list | check | start | edit [--dry-run]" >&2; exit 2 ;;
esac
