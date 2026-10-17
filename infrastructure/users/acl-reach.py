#!/usr/bin/env python3
"""acl-reach.py UID DIR [--allow NAME]... - what can the user UID reach inside DIR (normally /run/user/OWNER) through the file modes and ACLs?

Used by doctor.sh for the Wayland-only service user tgconfirm: it may traverse DIR and use the Wayland socket and nothing else. The
check follows the kernel rule, not just explicit ACL entries: the named-user entry (limited by the mask) when there is one, else
the group class when UID's primary group owns the file, else the OTHER bits, so a 0666 socket or a 0644 file in a 0755 directory
counts as reachable although no ACL entry names the user. Walks DIR (same filesystem only, depth 4, no symlinks), prints one line
per reachable socket (connect = w) or regular file (read = r) behind a traversable chain of directories, except the first-level names
given with --allow. Exit 0 = nothing reachable, 1 = something is, 2 = usage / getfacl problem.
"""
import os
import subprocess
import sys

DEPTH = 4


def parse(blocks_text: str) -> dict:
    """{path: {"owner": uid, "group": gid, "entries": [(tag, qualifier, perms)]}} from `getfacl -p -n` output."""
    out, cur = {}, None
    for line in blocks_text.splitlines():
        if line.startswith("# file: "):
            cur = {"owner": None, "group": None, "entries": []}
            out[line[8:]] = cur
        elif cur is None:
            continue
        elif line.startswith("# owner: "):
            cur["owner"] = line[9:].strip()
        elif line.startswith("# group: "):
            cur["group"] = line[9:].strip()
        elif line and not line.startswith(("#", "default:")):
            parts = line.split("\t")[0].split(":")
            if len(parts) == 3:
                cur["entries"].append((parts[0], parts[1], parts[2][:3]))
    return out


def effective(acl: dict, uid: int, gid: int) -> str:
    """The rwx the user gets from the ACL of one file."""
    entries = acl["entries"]
    mask = next((p for t, q, p in entries if t == "mask"), "rwx")

    def cap(p: str) -> str:
        return "".join(c if c in p and c in mask else "-" for c in "rwx")

    if acl["owner"] == str(uid):
        return next((p for t, q, p in entries if t == "user" and q == ""), "---")
    named = [p for t, q, p in entries if t == "user" and q == str(uid)]
    if named:
        return cap(named[0])
    group_hits = [p for t, q, p in entries if t == "group" and (q == "" and acl["group"] == str(gid) or q == str(gid))]
    if group_hits:
        return cap("".join(sorted(set("".join(group_hits)) - {"-"}, key="rwx".index)) or "---")
    return next((p for t, q, p in entries if t == "other"), "---")


def main(argv: list[str]) -> int:
    allow, args = set(), []
    it = iter(argv)
    for a in it:
        if a == "--allow":
            allow.add(next(it, ""))
        else:
            args.append(a)
    if len(args) != 2 or not args[0].isdigit():
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    uid, root = int(args[0]), os.path.normpath(args[1])
    try:
        import pwd
        gid = pwd.getpwuid(uid).pw_gid
    except (ImportError, KeyError):
        gid = -1
    dev = os.stat(root).st_dev
    paths, kinds = [root], {root: "d"}
    frontier = [(root, 0)]
    while frontier:
        d, depth = frontier.pop()
        if depth >= DEPTH:
            continue
        try:
            entries = list(os.scandir(d))
        except OSError:
            continue
        for e in entries:
            try:
                st = e.stat(follow_symlinks=False)
            except OSError:
                continue
            import stat as S
            if S.S_ISLNK(st.st_mode) or st.st_dev != dev:
                continue
            if S.S_ISDIR(st.st_mode):
                kinds[e.path] = "d"
                frontier.append((e.path, depth + 1))
            elif S.S_ISSOCK(st.st_mode):
                kinds[e.path] = "s"
            elif S.S_ISREG(st.st_mode):
                kinds[e.path] = "f"
            else:
                continue
            paths.append(e.path)
    acls: dict = {}
    for i in range(0, len(paths), 400):
        p = subprocess.run(["getfacl", "-p", "-n", *paths[i:i + 400]], capture_output=True, text=True)
        if p.returncode != 0 and not p.stdout:
            print("getfacl failed: " + p.stderr.strip()[:200], file=sys.stderr)
            return 2
        acls.update(parse(p.stdout))
    eff = {path: effective(acls[path], uid, gid) for path in paths if path in acls}
    bad = []
    for path in sorted(paths):
        if path == root or path not in eff or os.path.relpath(path, root).split(os.sep)[0] in allow and os.sep not in os.path.relpath(path, root):
            continue
        # every directory from the root down to the parent must be traversable (x)
        chain_ok, cur = eff.get(root, "---")[2] == "x", os.path.dirname(path)
        while chain_ok and cur != root:
            chain_ok = eff.get(cur, "---")[2] == "x"
            cur = os.path.dirname(cur)
        if not chain_ok:
            continue
        kind = kinds[path]
        if kind == "s" and eff[path][1] == "w":
            bad.append(f"socket {path} ({eff[path]})")
        elif kind == "f" and eff[path][0] == "r":
            bad.append(f"file {path} ({eff[path]})")
    for line in bad:
        print(line)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
