#!/usr/bin/env bash
# url-clean: strip tracking parameters (utm_*, fbclid, gclid, yclid, igshid, mc_eid, ...) from every URL in the text.
#   url-clean.sh              clean the clipboard in place (manual only) and notify
#   url-clean.sh --stdin      filter stdin to stdout
set -u
clean() {
  python3 -I -c '
import re, sys
from urllib.parse import urlsplit, urlunsplit, parse_qsl, urlencode
TRACK = re.compile(r"^(utm_.*|fbclid|gclid|dclid|gbraid|wbraid|msclkid|yclid|ysclid|igshid|igsh|ref_src|ref_url|mc_eid|mc_cid|_hsenc|_hsmi|mkt_tok|vero_id|oly_.*|s_cid|pk_.*|trk|trkid|spm|scm|cmpid|wt_mc|ocid|rb_clickid|__s|_openstat)$", re.I)
SI_HOSTS = ("youtube.com", "youtu.be", "music.youtube.com", "open.spotify.com", "spotify.link", "tiktok.com")
def fix(m):
    u = m.group(0)
    tail = ""
    while u and u[-1] in ".,;:!?)]}>\"\x27":
        tail = u[-1] + tail; u = u[:-1]
    p = urlsplit(u)
    host = (p.hostname or "").lower()
    keep = []
    for k, v in parse_qsl(p.query, keep_blank_values=True):
        if TRACK.match(k): continue
        if k.lower() == "si" and host.endswith(SI_HOSTS): continue
        keep.append((k, v))
    return urlunsplit((p.scheme, p.netloc, p.path, urlencode(keep), p.fragment)) + tail
sys.stdout.write(re.sub(r"https?://[^\s<>\"]+", fix, sys.stdin.read()))
'
}
if [[ ${1:-} == --stdin ]]; then clean; exit 0; fi
command -v wl-paste >/dev/null 2>&1 || { echo "wl-paste not found" >&2; exit 1; }
in=$(wl-paste -n -t text/plain 2>/dev/null) || in=""
[[ -n $in ]] || { notify-send -a url-clean "URL cleaner" "clipboard has no text"; exit 0; }
out=$(printf '%s' "$in" | clean)
if [[ $out == "$in" ]]; then
  notify-send -a url-clean -t 2000 "URL cleaner" "nothing to remove"
else
  printf '%s' "$out" | wl-copy
  notify-send -a url-clean -t 3000 "URL cleaner" "tracking parameters removed from the clipboard"
fi
