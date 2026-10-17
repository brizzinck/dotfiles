#!/usr/bin/env bash
# fake picker (the MCP_TG_PICK protocol of mcp-telegram-setup): the rows arrive on stdin, the work directory is $MCP_TG_PICK_DIR whose
# `sel` file holds the ticked ids. $FAKE_PICK_IDS (space separated) is XORed into it (a listed id that is ticked becomes unticked, like
# a Tab on it); FAKE_PICK_CANCEL=1 = Esc (exit 1). The rows are kept in $FAKE_DIR/pick-rows.txt.
cat >"$FAKE_DIR/pick-rows.txt"
[[ ${FAKE_PICK_CANCEL:-0} == 1 ]] && exit 1
python3 - "$MCP_TG_PICK_DIR/sel" $FAKE_PICK_IDS <<'PY'
import sys
p = sys.argv[1]
sel = {int(x) for x in open(p).read().split()}
for a in sys.argv[2:]:
    sel ^= {int(a)}
open(p, "w").write("".join(f"{i}\n" for i in sorted(sel)))
PY
