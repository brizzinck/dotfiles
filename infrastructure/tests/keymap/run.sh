#!/usr/bin/env bash
# Offline test of the SUPER+/ shortcut search (.config/keymap/keymap.py): see test_keymap.py.
#   run.sh [--quick]   --quick (doctor) = the unit and live-database parts, no tmux
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec env PYTHONDONTWRITEBYTECODE=1 PYTHONPYCACHEPREFIX=/tmp/pycache python3 -I -B "$HERE/test_keymap.py" "$@"
