"""Human-only names inventory; no backend calls or shell evaluation."""
import json
import os
from pathlib import Path
import re
import stat
import urllib.parse

PRUNE = {".git", "node_modules", ".venv", "venv", "vendor", "target", "build", "dist", "__pycache__"}


def classification(name, value):
    if re.search(r"(?:TOKEN|SECRET|PASSWORD|PASSWD|PRIVATE_KEY|API_KEY|ACCESS_KEY|CREDENTIAL)", name, re.I):
        return "secret", "name-shape"
    try:
        parsed = urllib.parse.urlsplit(value)
        if parsed.scheme and parsed.password is not None:
            return "secret", "URL-with-password"
    except ValueError:
        pass
    if len(value) >= 24 and re.fullmatch(r"[A-Za-z0-9_+/=-]+", value) and re.search(r"[A-Za-z]", value) and re.search(r"[0-9]", value):
        return "secret", "token-shape"
    if re.search(r"(?:PORT|HOST|MODE|ENV|DEBUG|ENABLED|TIMEOUT|REGION|LOCALE|TZ)$", name, re.I):
        return "plain", "name-shape"
    return "unknown", "literal"


def run(args, c):
    c.E.refuse_agent("scan")
    root = Path(os.path.abspath(args.directory or os.getcwd()))
    if args.depth < 0 or args.depth > 32:
        c.E.fail("scan depth must be between 0 and 32", 2)
    if (any(part in PRUNE or part in (".ssh", ".gnupg", ".claude", ".codex", ".gemini") for part in root.parts)
            or c.forbidden_source(root) or any(c.forbidden_source(root, parent) for parent in root.parents)):
        c.E.fail("scan root is a credential location", 4)
    try:
        with c.D.parent_fd(root / "placeholder") as (fd, _):
            if not stat.S_ISDIR(os.fstat(fd).st_mode) or os.fstat(fd).st_uid != os.getuid():
                c.E.fail("scan root is unsafe", 4)
    except OSError:
        c.E.fail("scan root is unsafe", 4)
    records, errors, skipped, visited = [], [], 0, 0
    def walk(directory, depth):
        nonlocal skipped, visited
        try:
            with c.D.parent_fd(directory / "placeholder") as (directory_fd, _):
                with os.scandir(directory_fd) as entries:
                    children = sorted(((entry.name, entry.stat(follow_symlinks=False)) for entry in entries), key=lambda entry: entry[0])
        except OSError:
            errors.append({"path": str(directory.relative_to(root)), "line": 0, "error": "unreadable"}); return
        for entry_name, st in children:
            path = directory / entry_name
            visited += 1
            if visited > 10000:
                c.E.fail("scan inventory exceeds supported entry limit", 4)
            try:
                if c.forbidden_source(path, root) or entry_name in PRUNE:
                    skipped += 1; continue
                if stat.S_ISDIR(st.st_mode):
                    if depth < args.depth and st.st_dev == root.stat().st_dev:
                        walk(path, depth + 1)
                    else:
                        skipped += 1
                    continue
                if entry_name != ".env" and not entry_name.startswith(".env."):
                    continue
                if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_nlink != 1 or st.st_size > c.D.MAX_DOCUMENT:
                    skipped += 1; continue
                snap = c.D.read_document(path, root)
                doc = c.D.DotenvDocument(snap.text)
                for record in doc.records:
                    if record.value.startswith("bw://"):
                        c.D.parse_bw_ref(record.value)
                        kind, reason = "secret-reference", "reference"
                    else:
                        kind, reason = classification(record.name, record.value)
                    records.append({"path": str(path.relative_to(root)), "name": record.name,
                                    "classification": kind, "reason": reason,
                                    "template": any(word in entry_name.casefold() for word in ("example", "sample", "template"))})
            except c.D.Problem as problem:
                errors.append({"path": str(path.relative_to(root)), "line": problem.line or 0, "error": "parse error"})
            except OSError:
                errors.append({"path": str(path.relative_to(root)), "line": 0, "error": "unreadable"})
    walk(root, 0)
    result = {"records": records, "errors": errors, "counts": {"assignments": len(records), "errors": len(errors), "skipped": skipped}}
    if args.json:
        c.E.say(json.dumps(result, ensure_ascii=True, sort_keys=True))
    else:
        for row in records:
            safe = json.dumps(row["path"], ensure_ascii=True)[1:-1]
            c.E.say("\t".join((safe, row["name"], row["classification"], row["reason"], "template" if row["template"] else "source")))
        for error in errors:
            safe = json.dumps(error["path"], ensure_ascii=True)[1:-1]
            c.E.warn(safe + ": " + error["error"] + " at line " + str(error["line"]) + " (values hidden)")
        c.E.say("scan: %s assignments, %s errors, %s skipped paths" % (len(records), len(errors), skipped))
    return 1 if errors else 0
