#!/usr/bin/env bash
# Waybar custom/media: what the active MPRIS player plays (YouTube Music, Zen video, Spotify, ...), hidden when nothing does.
#   media.sh --follow        continuous: playerctl follows the active player, one JSON line per change (restarts when
#                            playerctl exits because no player exists)
#   media.sh menu            R click: fzf-menu with previous / next / play-pause / stop / focus the player window
#   media.sh toggle|next|prev|stop   playerctl wrappers (clicks and scroll)
# Shown only while a player is Playing (class normal; style.css maps it to a palette token). Tooltip ends with the click hint line.
set -u

G_PLAY='󰎆'
MAX=38
SEP='|||'
EMPTY='{"text":""}'

trunc() { # trunc TEXT MAX
  local t=$1 m=$2
  if ((${#t} > m)); then printf '%s…' "${t:0:m-1}"; else printf '%s' "$t"; fi
}

render() { # status player artist title album
  local status=$1 player=$2 artist=$3 title=$4 album=$5 text cls=normal glyph=$G_PLAY tip
  case $status in
    Playing) ;;
    # a paused or stopped player hides the module (media keys still resume it)
    *) echo "$EMPTY"; return ;;
  esac
  [[ -n $title ]] || { echo "$EMPTY"; return; }
  if [[ -n $artist ]]; then text=$(trunc "$artist - $title" "$MAX"); else text=$(trunc "$title" "$MAX"); fi
  tip="$title"
  [[ -n $artist ]] && tip+=$'\n'"$artist"
  [[ -n $album ]] && tip+=$'\n'"$album"
  tip+=$'\n'"$player ($status)"$'\n\n'"L: play/pause · M: next · R: menu · Scroll: next/previous"
  jq -cn --arg t "$glyph $text" --arg c "$cls" --arg tip "$tip" '{text: $t, class: $c, tooltip: $tip}'
}

follow() {
  local status player artist title album pid="" fd
  # playerctl runs in a process substitution that survives the SIGTERM of this script (it only dies on its next write into the
  # closed pipe, which never comes while no player plays): every waybar restart left one orphan. Kill it on every way out.
  reap() { [[ -n $pid ]] && kill "$pid" 2>/dev/null; pid=""; }
  trap 'reap; exit 0' TERM INT HUP
  trap reap EXIT
  while :; do
    if command -v playerctl >/dev/null 2>&1; then
      exec {fd}< <(playerctl --follow metadata --format "{{status}}$SEP{{playerName}}$SEP{{artist}}$SEP{{title}}$SEP{{album}}" 2>/dev/null)
      pid=$!
      while IFS= read -r -u "$fd" line; do
        status=${line%%"$SEP"*}; line=${line#*"$SEP"}
        player=${line%%"$SEP"*}; line=${line#*"$SEP"}
        artist=${line%%"$SEP"*}; line=${line#*"$SEP"}
        title=${line%%"$SEP"*}; album=${line#*"$SEP"}
        render "$status" "$player" "$artist" "$title" "$album"
      done
      exec {fd}<&-
      reap
    fi
    echo "$EMPTY"
    sleep 5 &
    wait $!
  done
}

focus_player() {
  local player addr
  player=$(playerctl metadata --format '{{playerName}}' 2>/dev/null) || return 1
  # the window whose class or title mentions the player (ytmdesktop -> youtube-music-desktop-app is found through the class list)
  addr=$(hyprctl clients -j | jq -r --arg p "$player" '
    [.[] | select((.class | ascii_downcase | contains($p | ascii_downcase)) or (.title | ascii_downcase | contains($p | ascii_downcase)))][0].address // empty')
  if [[ -z $addr ]]; then
    case $player in
      ytmdesktop*) addr=$(hyprctl clients -j | jq -r '[.[] | select(.class == "youtube-music-desktop-app")][0].address // empty') ;;
      firefox* | zen*) addr=$(hyprctl clients -j | jq -r '[.[] | select(.class | test("zen"; "i"))][0].address // empty') ;;
    esac
  fi
  [[ -n $addr ]] && hyprd focuswindow "address:$addr" >/dev/null
}

menu() {
  local choice
  command -v playerctl >/dev/null 2>&1 || { notify-send -a media "Media" "playerctl is missing (sudo ./apply-system.sh --only install)"; exit 0; }
  choice=$(printf '%s\n' "Play / pause" "Next track" "Previous track" "Stop" "Focus the player window" |
    fzf-menu -p media --header "$(playerctl metadata --format '{{artist}} - {{title}}' 2>/dev/null)") || exit 0
  case $choice in
    "Play / pause") playerctl play-pause ;;
    "Next track") playerctl next ;;
    "Previous track") playerctl previous ;;
    Stop) playerctl stop ;;
    "Focus the player window") focus_player ;;
  esac
}

case ${1:---follow} in
  --follow) follow ;;
  menu) menu ;;
  toggle) playerctl play-pause ;;
  next) playerctl next ;;
  prev) playerctl previous ;;
  stop) playerctl stop ;;
  *) echo "usage: media.sh --follow | menu | toggle | next | prev | stop" >&2; exit 2 ;;
esac
