#!/usr/bin/env python3
"""Scope grammar of vault-share.py: matrix of match / refuse cases, rendering of the repo file and the overlay."""
import importlib.util
import os
import sys
import tempfile
import unicodedata

sys.dont_write_bytecode = True
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("vault_share", os.path.join(here, "../../../.config/hypr/scripts/vault-share.py"))
vs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vs)

passed = failed = 0


def check(name, ok):
    global passed, failed
    if ok:
        passed += 1
        print(f"ok    {name}")
    else:
        failed += 1
        print(f"FAIL  {name}")


def rules(text, owner="skalse"):
    return vs.parse_rules(text, owner=owner)


def match(rule, folder, name="x", user="td"):
    r, probs = rules(f"{user}\t{rule}\n")
    return not probs and vs.in_scope(r.get(user), folder, name)


# 2.1 matching
check("2.1 prefix rule matches the folder itself", match("Shared/**", "Shared"))
check("2.1 prefix rule matches a child", match("Shared/**", "Shared/Net"))
check("2.1 prefix rule matches a grandchild", match("Shared/**", "Shared/Net/Wifi"))
check("2.1 prefix rule does not match a sibling that starts the same (Shared2)", not match("Shared/**", "Shared2"))
check("2.1 prefix rule does not match a sibling that starts the same (Shared2/x)", not match("Shared/**", "Shared2/x"))
check("2.1 case-sensitive (shared/x)", not match("Shared/**", "shared/x"))
check("2.1 a parent is not matched by a child rule", not match("Work/Acme/**", "Work"))
check("2.1 a sibling of a nested rule is not matched", not match("Work/Acme/**", "Work/Globex"))
check("2.1 nested rule matches", match("Work/Acme/**", "Work/Acme/Hosting"))
check("2.1 item rule matches folder and name", match("Linux/td", "Linux", "td"))
check("2.1 item rule does not match another name", not match("Linux/td", "Linux", "yc"))
check("2.1 item rule does not match a subfolder", not match("Linux/td", "Linux/td", "td"))
check("2.1 item rule is exact on the folder", not match("Linux/td", "Linux/sub", "td"))
check("2.1 the split is at the last / (folder A/B, name C)", match("A/B/C", "A/B", "C") and not match("A/B/C", "A", "B/C"))
check("2.1 an item without a folder is never in scope", not vs.in_scope([("prefix", "Shared", None)], None, "x"))
check("2.1 an empty folder string is never in scope", not vs.in_scope([("prefix", "Shared", None)], "", "x"))
nfd = unicodedata.normalize("NFD", "Café")
check("2.1 NFC: a decomposed folder name matches a composed rule", match("Café/**", nfd))
check("2.1 NFC: a decomposed rule matches a composed folder", match(nfd + "/**", "Café"))
check("2.1 no rules for a user = nothing", not vs.in_scope(None, "Shared", "x") and not vs.in_scope([], "Shared", "x"))
# 2.1 refused
for bad, why in [("**", "bare **"), ("/**", "slash star star"), ("Shared/*", "single star"), ("Sh*red/**", "star inside"),
                 ("*/x", "leading star"), ("Shared//x/**", "empty segment"), ("Shared/./x/**", "dot segment"),
                 ("Shared/../x/**", "dotdot segment"), ("/Shared/**", "leading slash"), ("Shared/", "trailing slash"),
                 ("Shared", "item rule without a folder"), ("Sha\x01red/**", "control character"),
                 ("A/" + "x" * 520 + "/**", "longer than 512"), ("", "empty rule"), ("Shared/**/x", "star in the middle"),
                 ("Shared/x**", "star glued to a name")]:
    r, probs = rules(f"td\t{bad}\n")
    check(f"2.1 refused: {why}", bool(probs) and not r)
for user, why in [("root", "root"), ("skalse", "the owner"), ("Bad", "upper case"), ("1abc", "starts with a digit"),
                  ("a b", "space"), ("", "empty"), ("x" * 40, "too long")]:
    r, probs = rules(f"{user}\tShared/**\n")
    check(f"2.1 refused user: {why}", bool(probs) and not r)
r, probs = rules("td\tShared/**\n# comment\n\ntd\tUsers/td/**\n")
check("2.1 comments and blank lines are skipped, two rules kept", not probs and len(r["td"]) == 2)
r, probs = rules("td Shared/**\n")
check("2.1 a line without a tab is a problem", bool(probs))

# render
repo = "*\tShared/**\n*\tUsers/{user}/**\n"
text, warns, probs = vs.render_scopes(repo, "", ["td", "yc"], "skalse")
lines = [ln for ln in text.splitlines() if not ln.startswith("#")]
check("2.2 render: generic rows expand for td and yc", lines == ["td\tShared/**", "td\tUsers/td/**", "yc\tShared/**", "yc\tUsers/yc/**"])
check("2.2 render: no Linux/<user> row (the Linux passwords are the owner's)", "Linux" not in text)
text, warns, probs = vs.render_scopes(repo, "td\tWork/Acme/**\nyc\tWork/Globex/**\nghost\tWork/X/**\n", ["td", "yc"], "skalse")
check("2.3 overlay rows are added", "td\tWork/Acme/**" in text and "yc\tWork/Globex/**" in text)
check("2.3 an overlay row for a user that is not managed is dropped with a warning", "ghost" not in text and any("ghost" in w for w in warns))
text, warns, probs = vs.render_scopes(repo, "td\t**\n", ["td", "yc"], "skalse")
check("2.5 an invalid overlay row is a problem", bool(probs))
text, warns, probs = vs.render_scopes(repo, "*\tShared/**\n", ["td"], "skalse")
check("2.5 user * is refused in the overlay", bool(probs))
text, warns, probs = vs.render_scopes(repo, "", ["td", "skalse", "root"], "skalse")
check("2.2 render: the owner and root never get a row", "skalse\t" not in text and "root\t" not in text)
text, warns, probs = vs.render_scopes(repo, "td\tWork/Acme/**\ntd\tWork/Acme/**\n", ["td"], "skalse")
check("2.3 duplicate rows are written once", text.count("Work/Acme/**") == 1)

# 2.4 trusted overlay file
with tempfile.TemporaryDirectory() as d:
    f = os.path.join(d, "o.tsv")
    open(f, "w").write("td\tWork/Acme/**\n")
    os.chmod(f, 0o600)
    check("2.4 a 0600 file of the owner is trusted", vs.trusted_local_file(f, os.getuid())[0])
    os.chmod(f, 0o660)
    check("2.4 a group-writable file is refused", not vs.trusted_local_file(f, os.getuid())[0])
    os.chmod(f, 0o600)
    ln = os.path.join(d, "l.tsv")
    os.symlink(f, ln)
    check("2.4 a symlink is refused", not vs.trusted_local_file(ln, os.getuid())[0])
    check("2.4 a file of another uid is refused", not vs.trusted_local_file(f, os.getuid() + 1)[0])
    check("2.4 a missing file is not trusted", not vs.trusted_local_file(os.path.join(d, "none"), os.getuid())[0])

# the real repo file
repo_file = os.path.join(here, "../../vault-share/scopes.tsv")
text, warns, probs = vs.render_scopes(open(repo_file).read(), "", ["td", "yc"], "skalse")
check("2.6 the repo scopes.tsv renders without problems and passes check-scopes", not probs and not vs.parse_rules(text, owner="skalse")[1])
check("2.6 the repo scopes.tsv holds no company name and no Linux row", "Work" not in open(repo_file).read() and "Linux" not in "".join(
    ln for ln in open(repo_file).read().splitlines() if not ln.startswith("#")))

print(f"\nscopes: passed {passed}, failed {failed}")
sys.exit(1 if failed else 0)
