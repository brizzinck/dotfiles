#!/usr/bin/env python3
"""One terminal confirmation against the run.sh isolated fake backend; no real session or display."""
import errno
import os
import pty
import select
import signal
import sys
import time

pid, fd = pty.fork()
if pid == 0:
    os.execv('/usr/bin/python3', ['/usr/bin/python3', '-I', '-B', sys.argv[1], 'apply', '--personal-only'])
output = bytearray()
answered = False
deadline = time.monotonic() + 30
try:
    while time.monotonic() < deadline:
        if not select.select([fd], [], [], 0.1)[0]:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError as error:
            if error.errno == errno.EIO:
                break
            raise
        if not chunk:
            break
        output.extend(chunk)
        if len(output) > 1024 * 1024:
            raise RuntimeError('fake terminal output limit')
        if not answered and b'Apply this plan? [y/N] ' in output:
            os.write(fd, b'y\n')
            answered = True
    else:
        raise RuntimeError('fake terminal timeout')
    _, status = os.waitpid(pid, 0)
    pid = None
    sys.stdout.buffer.write(output)
    sys.exit(os.waitstatus_to_exitcode(status))
finally:
    os.close(fd)
    if pid is not None:
        try: os.kill(pid, signal.SIGKILL)
        except ProcessLookupError: pass
        os.waitpid(pid, 0)
