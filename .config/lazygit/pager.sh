#!/bin/sh
# lazygit diff pager: delta when installed, otherwise pass git's colored diff through untouched.
if command -v delta >/dev/null 2>&1; then
  exec delta --dark --paging=never
fi
exec cat
