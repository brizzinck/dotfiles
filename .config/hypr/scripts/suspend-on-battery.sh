#!/usr/bin/env bash
# hypridle on-timeout: suspend only when running on battery (mains offline).
set -u

for ac in /sys/class/power_supply/AC* /sys/class/power_supply/ADP*; do
  [[ -r $ac/online ]] || continue
  [[ $(<"$ac/online") == 0 ]] && exec systemctl suspend
  exit 0
done
