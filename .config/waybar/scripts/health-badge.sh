#!/usr/bin/env bash
# health-badge: waybar custom/health exec. Prints the shared cached health run (cache.sh) and remembers that exact output
# as waybar-cache/health-shown.json, the snapshot health-details.sh (left click) lists, so the badge and the details view
# always describe the same state. Both bars run it; the last writer wins and they print the same cached run.
set -u
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
DIR="${WAYBAR_CACHE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/waybar-cache}"

out=$("$HERE/cache.sh" health 55 -- "$HERE/health.sh")
tmp=$(mktemp "$DIR/health-shown.XXXXXX") && { printf '%s\n' "$out" >"$tmp" && mv -f "$tmp" "$DIR/health-shown.json" || rm -f "$tmp"; }
printf '%s\n' "$out"
