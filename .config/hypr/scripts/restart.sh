#!/usr/bin/env bash
# restart: restart one desktop service after a confirmation (hub group Fix). An agent never runs this: audio and Wi-Fi drop calls.
#   restart.sh audio|wifi|trackpad|dunst [--yes] [--dry-run]
#   audio     pipewire, pipewire-pulse, wireplumber (drops a running call), then audio-ensure
#   wifi      radio off, one second, radio on (drops the connection)
#   trackpad  the touchpad is disabled for one second and enabled again (Hyprland device config)
#   dunst     the notification daemon (the history is lost)
set -u
WHAT=""
YES=0
DRY=0
for a in "$@"; do
  case $a in
    audio | wifi | trackpad | dunst) WHAT=$a ;;
    --yes) YES=1 ;;
    --dry-run) DRY=1 ;;
  esac
done
[[ -n $WHAT ]] || { echo "usage: restart.sh audio|wifi|trackpad|dunst [--yes] [--dry-run]" >&2; exit 2; }

run() { if ((DRY)); then echo "would run: $*"; else "$@"; fi; }
note() { if ((DRY)); then echo "note: $*"; else notify-send -a fix -t 3000 "$@"; fi; }

if ((!YES && !DRY)); then
  case $WHAT in
    audio) q="Restart audio (a running call drops)?" ;;
    wifi) q="Restart Wi-Fi (the connection drops)?" ;;
    trackpad) q="Restart the trackpad?" ;;
    dunst) q="Restart the notification daemon?" ;;
  esac
  [[ $(printf 'no\nyes\n' | fzf-menu -p "$q") == yes ]] || exit 0
fi

case $WHAT in
  audio)
    run systemctl --user restart pipewire pipewire-pulse wireplumber
    ((DRY)) || sleep 1.5
    command -v audio-ensure >/dev/null 2>&1 && run audio-ensure
    note "Audio restarted" "pipewire, pipewire-pulse, wireplumber" ;;
  wifi)
    run nmcli radio wifi off
    ((DRY)) || sleep 1
    run nmcli radio wifi on
    note "Wi-Fi restarted" "" ;;
  trackpad)
    dev=$(hyprctl devices -j 2>/dev/null | jq -r '[.mice[] | select(.name | test("touchpad"; "i"))][0].name // empty')
    [[ -n $dev ]] || { note "No trackpad" "Hyprland lists no touchpad device"; exit 0; }
    run hyprctl eval "hl.device({ name = \"$dev\", enabled = false })"
    ((DRY)) || sleep 1
    run hyprctl eval "hl.device({ name = \"$dev\", enabled = true })"
    note "Trackpad restarted" "$dev" ;;
  dunst)
    run pkill -x dunst
    ((DRY)) || sleep 0.5
    if ((DRY)); then echo "would run: setsid dunst"; else setsid -f dunst >/dev/null 2>&1; fi
    note "Notification daemon restarted" "" ;;
esac
