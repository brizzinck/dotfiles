#!/usr/bin/env bash
# cache: share one run of an expensive waybar script between the two bars (compact and full run every module twice).
#   cache.sh NAME TTL -- CMD [ARGS...]   print the cached output of NAME when it is younger than TTL seconds; otherwise
#                                        run CMD once (flock), store its output atomically and print it. A caller that
#                                        loses the lock waits up to 5 s and prints what the winner stored.
#   cache.sh --drop NAME                 delete the entry (call it before poking a module whose data just changed)
# Entries live in $XDG_RUNTIME_DIR/waybar-cache. An empty output is stored too, so a quiet module is cached as well.
set -u

DIR="${WAYBAR_CACHE_DIR:-${XDG_RUNTIME_DIR:-/tmp}/waybar-cache}"
mkdir -p "$DIR"

if [[ ${1:-} == --drop ]]; then
  [[ -n ${2:-} ]] || { echo "usage: cache.sh --drop NAME" >&2; exit 2; }
  rm -f "$DIR/$2.json"
  exit 0
fi

if (($# < 4)) || [[ $3 != -- ]] || ! [[ $2 =~ ^[0-9]+$ ]]; then
  echo "usage: cache.sh NAME TTL -- CMD [ARGS...] | cache.sh --drop NAME" >&2
  exit 2
fi
name=$1 ttl=$2
shift 3
file="$DIR/$name.json"

fresh() { # younger than ttl
  local m
  [[ -e $file ]] || return 1
  m=$(stat -c %Y "$file" 2>/dev/null) || return 1
  (($(date +%s) - m < ttl))
}

if fresh; then cat "$file"; exit 0; fi

exec 9>"$DIR/$name.lock"
if flock -n 9; then
  # the previous holder may have just finished
  if fresh; then cat "$file"; exit 0; fi
  tmp=$(mktemp "$DIR/$name.XXXXXX")
  "$@" >"$tmp" 2>/dev/null
  mv -f "$tmp" "$file"
  cat "$file"
else
  flock -w 5 9 || true
  cat "$file" 2>/dev/null || true
fi
