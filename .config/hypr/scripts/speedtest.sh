#!/usr/bin/env bash
# speedtest: latency, download and upload against Cloudflare (speed.cloudflare.com, no account, no token), result on screen and
# as a notification. Hub row "Network speed test" (terminal).
#   speedtest.sh [--dry-run]
set -u
DOWN_BYTES=50000000
UP_BYTES=20000000
HOST=speed.cloudflare.com
DRY=0
[[ ${1:-} == --dry-run ]] && DRY=1
if ((DRY)); then
  echo "latency : curl -w %{time_connect} https://$HOST/cdn-cgi/trace (best of 3)"
  echo "download: curl https://$HOST/__down?bytes=$DOWN_BYTES"
  echo "upload  : $UP_BYTES zero bytes POSTed to https://$HOST/__up"
  exit 0
fi
command -v curl >/dev/null 2>&1 || { echo "curl is missing"; exit 1; }
mbit() { awk -v b="$1" 'BEGIN { printf "%.1f", b * 8 / 1000000 }'; }
echo "testing against $HOST ..."
best=""
for _ in 1 2 3; do
  t=$(curl -s -o /dev/null --max-time 5 -w '%{time_connect}' "https://$HOST/cdn-cgi/trace" 2>/dev/null) || continue
  best=$(awk -v a="${best:-9}" -v b="$t" 'BEGIN { print (b < a) ? b : a }')
done
lat=$(awk -v t="${best:-0}" 'BEGIN { printf "%d", t * 1000 }')
echo "latency : ${lat} ms"
down=$(curl -s -o /dev/null --max-time 40 -w '%{speed_download}' "https://$HOST/__down?bytes=$DOWN_BYTES" 2>/dev/null || echo 0)
echo "download: $(mbit "$down") Mbit/s"
up=$(head -c "$UP_BYTES" /dev/zero | curl -s -o /dev/null --max-time 40 -w '%{speed_upload}' -X POST --data-binary @- "https://$HOST/__up" 2>/dev/null || echo 0)
echo "upload  : $(mbit "$up") Mbit/s"
notify-send -a speedtest -t 8000 "Speed test" "down $(mbit "$down") Mbit/s · up $(mbit "$up") Mbit/s · ${lat} ms" 2>/dev/null || true
