#!/usr/bin/env python3
"""vault-share: the scopes of the Bitwarden vault that td and yc may read, and (later in this file) the broker that serves
them. Python 3 stdlib only, runs under `python3 -I`; `vault-share` (.local/bin/vault-share) is the command.

SCOPES. /etc/vault-share/scopes.tsv (root-owned, rendered by `sudo ./apply-system.sh --only users`) holds one rule per line,
`user<TAB>rule`, `#` starts a comment:

  P/**        every item whose folder is P or below P   (`Shared/**`, `Users/td/**`, `Work/Acme/**`)
  P/NAME      exactly one item: folder P, item name NAME (the split is at the LAST `/`, so an item name that contains `/` cannot
              be written: use a folder rule)

Comparison is exact and case-sensitive after NFC. An item without a folder is never in scope. `Work/Acme/**` does not include
items stored directly in `Work`; a folder that only exists as the parent of another one holds no items of its own.
Refused when the file is checked: `**`, `/**`, empty or `.` / `..` segments, control characters, any other `*`, a leading or
trailing `/` (other than the `/**` suffix), more than 512 characters, the user root, the owner, or a name that is not a
Linux login name. The repo file infrastructure/vault-share/scopes.tsv has only generic rows (user `*` = every interactive
managed user, `{user}` = that user's name); company rows live in the owner's ~/.config/vault-share/scopes.local.tsv (0600, never
in the repo). `Linux/<user>` is in no scope: the Linux passwords stay the owner's.

  vault-share.py check-scopes FILE [--owner NAME]
  vault-share.py render-scopes --repo FILE [--local FILE] --managed "td yc" --owner NAME
"""
import os
import re
import stat
import sys
import unicodedata
from pathlib import Path

sys.dont_write_bytecode = True
os.umask(0o077)

USER_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,30}$")
MAX_RULE = 512


# ───────────────────────────── scope grammar ─────────────────────────────

def nfc(s):
    return unicodedata.normalize("NFC", s)


def valid_path(p):
    """Problem text for a folder path (no wildcard), or None."""
    if not p:
        return "empty path"
    if p.startswith("/") or p.endswith("/"):
        return "leading or trailing /"
    for seg in p.split("/"):
        if seg in ("", ".", ".."):
            return "empty, . or .. segment"
    return None


def parse_rule(rule):
    """-> ((kind, folder, name), None) or (None, problem). kind is prefix (P/**) or item (P/NAME)."""
    rule = nfc(rule)
    if len(rule) > MAX_RULE:
        return None, "rule longer than 512 characters"
    if any(ord(c) < 32 or ord(c) == 127 for c in rule):
        return None, "control character"
    if rule in ("**", "/**"):
        return None, f"{rule!r} would match everything"
    if rule.endswith("/**"):
        p = rule[:-3]
        if "*" in p:
            return None, "wildcard other than the /** suffix"
        bad = valid_path(p)
        return ((("prefix", p, None), None) if bad is None else (None, bad))
    if "*" in rule:
        return None, "wildcard other than the /** suffix"
    if "/" not in rule:
        return None, "an item rule needs a folder (FOLDER/NAME)"
    folder, name = rule.rsplit("/", 1)
    bad = valid_path(folder) or (None if name not in ("", ".", "..") else "empty, . or .. item name")
    return ((("item", folder, name), None) if bad is None else (None, bad))


def parse_rules(text, *, owner=None):
    """-> ({user: [rule tuples]}, [problem lines]). A bad line is a problem and is skipped."""
    rules, problems = {}, []
    for n, line in enumerate(text.splitlines(), 1):
        raw = line.strip()
        if not raw or raw.startswith("#"):
            continue
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 2:
            problems.append(f"line {n}: expected user<TAB>rule")
            continue
        user, rule = parts[0].strip(), parts[1].strip()
        if not USER_RE.match(user):
            problems.append(f"line {n}: {user!r} is not a login name")
            continue
        if user == "root" or (owner and user == owner):
            problems.append(f"line {n}: no scope for {user} (root and the owner read the vault directly)")
            continue
        r, bad = parse_rule(rule)
        if bad:
            problems.append(f"line {n}: {bad}")
            continue
        rules.setdefault(user, []).append(r)
    return rules, problems


def in_scope(user_rules, folder, name):
    """True when the item (folder, name) is inside one of the rules. No folder = never."""
    if not folder:
        return False
    folder, name = nfc(folder), nfc(name or "")
    for kind, f, n in user_rules or ():
        if kind == "prefix" and (folder == f or folder.startswith(f + "/")):
            return True
        if kind == "item" and folder == f and name == n:
            return True
    return False


def rule_text(r):
    return f"{r[1]}/**" if r[0] == "prefix" else f"{r[1]}/{r[2]}"


def render_scopes(repo_text, local_text, managed_interactive, owner):
    """The /etc/vault-share/scopes.tsv text for the interactive managed users -> (text, warnings, problems).
    Repo rows may use user `*` and `{user}`; a row for a user that is not an interactive managed user is dropped with a
    warning (the company rows of the local file name td and yc, and a machine without yc must still work)."""
    managed = [u for u in managed_interactive if u and u != owner and u != "root"]
    warnings, problems, out = [], [], {}

    def feed(text, label, expand):
        for n, line in enumerate(text.splitlines(), 1):
            raw = line.strip()
            if not raw or raw.startswith("#"):
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 2:
                problems.append(f"{label} line {n}: expected user<TAB>rule")
                continue
            user, rule = parts[0].strip(), parts[1].strip()
            targets = managed if (user == "*" and expand) else [user]
            if user == "*" and not expand:
                problems.append(f"{label} line {n}: user * is only allowed in the repo file")
                continue
            for u in targets:
                if u not in managed:
                    if user != "*":
                        warnings.append(f"{label} line {n}: {user} is not an interactive managed user here, row dropped")
                    continue
                r = rule.replace("{user}", u) if expand else rule
                parsed, bad = parse_rule(r)
                if bad:
                    problems.append(f"{label} line {n}: {bad}")
                    continue
                out.setdefault(u, [])
                if rule_text(parsed) not in out[u]:
                    out[u].append(rule_text(parsed))

    feed(repo_text, "repo scopes", True)
    feed(local_text or "", "local scopes", False)
    lines = ["# /etc/vault-share/scopes.tsv: rendered by apply-system.sh (--only users) from infrastructure/vault-share/scopes.tsv",
             "# and the owner's ~/.config/vault-share/scopes.local.tsv. Do not edit; one rule per line, user<TAB>rule."]
    for u in sorted(out):
        for r in out[u]:
            lines.append(f"{u}\t{r}")
    return "\n".join(lines) + "\n", warnings, problems


def trusted_local_file(path, owner_uid):
    """The owner's overlay counts only when it is a regular file of the owner that nobody else can write."""
    try:
        st = os.lstat(path)
    except OSError:
        return False, "missing"
    if not stat.S_ISREG(st.st_mode):
        return False, "not a regular file (symlink?)"
    if st.st_uid != owner_uid:
        return False, "not owned by the owner"
    if st.st_mode & 0o022:
        return False, "group- or other-writable"
    return True, ""


# ───────────────────────────── CLI ─────────────────────────────

def opt(argv, name):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return None


def cmd_check_scopes(argv):
    if not argv:
        print("usage: vault-share.py check-scopes FILE [--owner NAME]", file=sys.stderr)
        return 2
    try:
        text = Path(argv[0]).read_text()
    except OSError as e:
        print(f"cannot read {argv[0]}: {e.strerror}", file=sys.stderr)
        return 4
    rules, problems = parse_rules(text, owner=opt(argv, "--owner"))
    for p in problems:
        print(p, file=sys.stderr)
    if problems:
        return 4
    print(f"ok: {sum(len(v) for v in rules.values())} rules for {len(rules)} users")
    return 0


def cmd_render_scopes(argv):
    repo, local, managed, owner = opt(argv, "--repo"), opt(argv, "--local"), opt(argv, "--managed"), opt(argv, "--owner")
    if not (repo and owner and managed is not None):
        print('usage: vault-share.py render-scopes --repo FILE [--local FILE] --managed "td yc" --owner NAME', file=sys.stderr)
        return 2
    try:
        repo_text = Path(repo).read_text()
    except OSError as e:
        print(f"cannot read {repo}: {e.strerror}", file=sys.stderr)
        return 4
    local_text = ""
    if local and os.path.lexists(local):
        ok, why = trusted_local_file(local, os.getuid())
        if ok:
            local_text = Path(local).read_text()
        else:
            print(f"warning: {local} ignored: {why}", file=sys.stderr)
    text, warnings, problems = render_scopes(repo_text, local_text, managed.split(), owner)
    for w in warnings:
        print("warning: " + w, file=sys.stderr)
    for p in problems:
        print(p, file=sys.stderr)
    if problems:
        return 4
    sys.stdout.write(text)
    return 0


COMMANDS = {"check-scopes": cmd_check_scopes, "render-scopes": cmd_render_scopes}


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    fn = COMMANDS.get(argv[0])
    if fn is None:
        print(f"unknown command {argv[0]}", file=sys.stderr)
        return 2
    return fn(argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
