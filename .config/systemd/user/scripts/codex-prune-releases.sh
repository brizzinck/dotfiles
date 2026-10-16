#!/usr/bin/env bash
# Prune old Codex app-server releases: keep the release `current` points to plus the newest other one
# (rollback), delete the rest. A release that a running process still executes from is never deleted.
# Run weekly by codex-prune-releases.timer (user unit, ~/.config/systemd/user/).
set -euo pipefail

base="${CODEX_HOME:-$HOME/.codex}/packages/app-server-daemon"
releases="$base/releases"

[ -d "$releases" ] || exit 0
cur="$(readlink -f -- "$base/current" 2>/dev/null || true)"
if [ -z "$cur" ] || [ ! -d "$cur" ]; then
  echo "codex-prune: no valid 'current' release, nothing to do"
  exit 0
fi

# in_use DIR: true when any of our processes runs a binary from, or has its cwd inside, DIR
in_use() {
  local dir="$1" p target
  for p in /proc/[0-9]*; do
    for target in "$p/exe" "$p/cwd"; do
      case "$(readlink -- "$target" 2>/dev/null || true)" in
        "$dir" | "$dir"/*) return 0 ;;
      esac
    done
  done
  return 1
}

# newest first by modification time, current excluded
# shellcheck disable=SC2012  # release directory names are plain version strings
mapfile -t others < <(ls -1dt -- "$releases"/*/ 2>/dev/null | sed 's#/$##' | grep -vxF -- "$cur" || true)

kept=0
for dir in "${others[@]}"; do
  if [ "$kept" -lt 1 ]; then
    kept=$((kept + 1))
    echo "codex-prune: keep $(basename "$dir") (rollback)"
    continue
  fi
  if in_use "$dir"; then
    echo "codex-prune: skip $(basename "$dir") (still running)"
    continue
  fi
  echo "codex-prune: remove $(basename "$dir")"
  rm -rf -- "$dir"
done
