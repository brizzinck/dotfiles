"""Private HOME/XDG and refusal tools for invented native-write tests only."""
import atexit
import os
from pathlib import Path
import tempfile

_fixture = tempfile.TemporaryDirectory(prefix='fake-write-environment-')
atexit.register(_fixture.cleanup)
root = Path(_fixture.name)
tools = root / 'bin'; tools.mkdir(mode=0o700)
for name in ('bw', 'rbw', 'fzf-menu', 'ghostty', 'notify-send', 'hyprctl', 'wl-copy'):
    path = tools / name; path.write_text('#!/bin/sh\nexit 97\n'); path.chmod(0o700)
os.environ.clear()
os.environ.update({'HOME': str(root), 'PATH': str(tools) + ':/usr/bin:/bin', 'LANG': 'C.UTF-8'})
for name in ('XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME', 'XDG_RUNTIME_DIR'):
    path = root / name; path.mkdir(mode=0o700); os.environ[name] = str(path)
