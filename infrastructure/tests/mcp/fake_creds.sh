#!/usr/bin/env bash
# fake creds-install: keeps the JSON payload it was given on stdin and its arguments (the test inspects them), and plays the
# "sealed" send list in $FAKE_DIR/sealed-send.txt: --print-send-allowlist prints it, a payload with send_allowlist replaces it, a
# payload with allowlist narrows it to the chats that stay readable (what the real root helper does by itself).
if [[ ${1:-} == --print-send-allowlist ]]; then
  echo "print-send-allowlist" >>"$FAKE_DIR/argv.log"
  cat "$FAKE_DIR/sealed-send.txt" 2>/dev/null || echo
  exit 0
fi
cat >"$FAKE_DIR/creds-payload.json"
echo "$*" >"$FAKE_DIR/creds-args.txt"
echo "creds-install called" >>"$FAKE_DIR/argv.log"
python3 - "$FAKE_DIR" <<'PY'
import json, os, sys
d = sys.argv[1]
p = json.load(open(f"{d}/creds-payload.json"))
sealed = f"{d}/sealed-send.txt"
bare = lambda n: int(str(abs(n))[3:]) if str(abs(n)).startswith("100") and len(str(abs(n))) >= 13 else abs(n)
ids = lambda t: [int(x) for x in t.split(",") if x.strip()]
if "send_allowlist" in p:
    open(sealed, "w").write(p["send_allowlist"] + "\n")
elif "allowlist" in p and os.path.exists(sealed):
    read = {bare(i) for i in ids(p["allowlist"])}
    kept = ",".join(str(i) for i in ids(open(sealed).read()) if bare(i) in read)
    open(sealed, "w").write(kept + "\n")
PY
