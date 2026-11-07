#!/usr/bin/env bash
# All IPC and CLI calls use scratch fakes, never the owner's desktop or skw daemon.
set -euo pipefail
unset WAYLAND_DISPLAY DISPLAY
export PYTHONDONTWRITEBYTECODE=1
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec python3 -I -B "$HERE/test.py" "$@"
