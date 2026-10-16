#!/usr/bin/env bash
# sysalert: one-shot system health check run by sysalert.timer (every 3 min). Sends dunst alerts for
#   disk free < 10 % (/ and /home), battery < 15 % while discharging, CPU temp (k10temp) > 90 C for 3 checks,
#   memory pressure (PSI some avg60 > 15) or MemAvailable < 10 %, load5 > nproc for 3 checks.
# Rate limit: a condition alerts once, then again after REPEAT minutes while it stays true; recovery resets it.
# State lives in $XDG_RUNTIME_DIR/sysalert. `sysalert.sh --dry-run` prints alerts instead of sending them and
# does not touch the state. The paths below can be overridden by environment variables for tests.
set -u

STATE="${SYSALERT_STATE:-${XDG_RUNTIME_DIR:-/tmp}/sysalert}"
BAT_DIR="${SYSALERT_BAT:-/sys/class/power_supply/BAT0}"
PRESSURE="${SYSALERT_PSI:-/proc/pressure/memory}"
MEMINFO="${SYSALERT_MEMINFO:-/proc/meminfo}"
LOADAVG="${SYSALERT_LOADAVG:-/proc/loadavg}"
TEMP_FILE="${SYSALERT_TEMP:-}"
DISK_MIN_FREE=10 BAT_MIN=15 TEMP_MAX=90 PSI_MAX=15 MEM_MIN_FREE=10 SUSTAIN=3
REPEAT=$((${SYSALERT_REPEAT_MIN:-30} * 60))
DRY=0
[[ ${1:-} == --dry-run ]] && DRY=1
mkdir -p "$STATE"

now=$(date +%s)

alert() { # alert KEY TITLE BODY  (rate limited)
  local key=$1 f="$STATE/alerted.$1" last
  last=$(cat "$f" 2>/dev/null || echo 0)
  ((now - last < REPEAT)) && return 0
  if ((DRY)); then
    echo "ALERT $key: $2 - $3"
  else
    echo "$now" >"$f"
    "${SYSALERT_NOTIFY:-notify-send}" -a sysalert -u critical -h "string:x-dunst-stack-tag:sysalert-$key" "$2" "$3" 2>/dev/null || true
  fi
}
clear_alert() { ((DRY)) || rm -f "$STATE/alerted.$1" "$STATE/count.$1"; }

# sustained(KEY, CONDITION_TRUE 0/1): true after SUSTAIN consecutive true checks
sustained() {
  local key=$1 cond=$2 f="$STATE/count.$1" n
  if ((cond)); then
    n=$(($(cat "$f" 2>/dev/null || echo 0) + 1))
    ((DRY)) || echo "$n" >"$f"
    ((n >= SUSTAIN)) && return 0
    return 1
  fi
  ((DRY)) || rm -f "$f"
  return 1
}

# disk
for mp in / /home; do
  mountpoint -q "$mp" 2>/dev/null || continue
  used=$(df --output=pcent "$mp" 2>/dev/null | tail -1 | tr -dc '0-9')
  [[ -n $used ]] || continue
  key="disk$(echo "$mp" | tr '/' '_')"
  if ((100 - used < DISK_MIN_FREE)); then
    alert "$key" "Low disk space on $mp" "$((100 - used))% free"
  else
    clear_alert "$key"
  fi
done

# battery
if [[ -r $BAT_DIR/capacity ]]; then
  cap=$(cat "$BAT_DIR/capacity"); st=$(cat "$BAT_DIR/status" 2>/dev/null)
  if [[ $st == Discharging ]] && ((cap < BAT_MIN)); then
    alert battery "Battery low" "${cap}% and discharging"
  else
    clear_alert battery
  fi
fi

# CPU temperature (k10temp Tctl) sustained
tf=$TEMP_FILE
if [[ -z $tf ]]; then
  for h in /sys/class/hwmon/hwmon*; do
    [[ $(cat "$h/name" 2>/dev/null) == k10temp ]] && { tf="$h/temp1_input"; break; }
  done
fi
if [[ -n $tf && -r $tf ]]; then
  t=$(($(cat "$tf") / 1000))
  hot=0; ((t > TEMP_MAX)) && hot=1
  if sustained temp "$hot"; then alert temp "CPU is hot" "${t} C for several minutes"; else ((hot)) || clear_alert temp; fi
fi

# memory: PSI pressure or low MemAvailable
mem_bad=""
if [[ -r $PRESSURE ]]; then
  p=$(awk '$1 == "some" { for (i = 2; i <= NF; i++) if ($i ~ /^avg60=/) { sub("avg60=", "", $i); print int($i) } }' "$PRESSURE")
  [[ -n $p ]] && ((p > PSI_MAX)) && mem_bad="memory pressure avg60 ${p}%"
fi
if [[ -r $MEMINFO ]]; then
  total=$(awk '/^MemTotal:/ { print $2 }' "$MEMINFO"); avail=$(awk '/^MemAvailable:/ { print $2 }' "$MEMINFO")
  if [[ -n $total && -n $avail ]] && ((total > 0 && avail * 100 / total < MEM_MIN_FREE)); then
    mem_bad="${mem_bad:+$mem_bad, }only $((avail * 100 / total))% memory available"
  fi
fi
if [[ -n $mem_bad ]]; then alert memory "Memory pressure" "$mem_bad"; else clear_alert memory; fi

# sustained load
if [[ -r $LOADAVG ]]; then
  l5=$(awk '{ print int($2) }' "$LOADAVG"); cores=$(nproc)
  busy=0; ((l5 > cores)) && busy=1
  if sustained load "$busy"; then alert load "Sustained high load" "load5 ${l5} on ${cores} cores"; else ((busy)) || clear_alert load; fi
fi
exit 0
