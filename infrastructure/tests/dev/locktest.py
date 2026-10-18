"""posting-requirements.txt (REVIEW-DEV-d #16): every requirement is `name==version` with only sha256 hashes behind it, posting itself
is in it, and there is no other kind of line. usage: locktest.py LOCKFILE"""
import re
import sys

lines = open(sys.argv[1]).read().splitlines()
bad, names, i = [], [], 0
while i < len(lines):
    l = lines[i]
    if not l.strip() or l.startswith("#"):
        i += 1
        continue
    m = re.fullmatch(r"([A-Za-z0-9_.-]+)==([^\s\\]+) \\", l)
    if not m:
        bad.append(l)
        i += 1
        continue
    names.append(f"{m.group(1)}=={m.group(2)}")
    i += 1
    n = 0
    while i < len(lines) and re.fullmatch(r" +--hash=sha256:[0-9a-f]{64}( \\)?", lines[i]):
        n += 1
        i += 1
    if n == 0:
        bad.append(f"{names[-1]}: no hash")
print("packages:", len(names), "bad:", bad[:3])
sys.exit(0 if len(names) > 40 and not bad and "posting==2.11.1" in names else 1)
