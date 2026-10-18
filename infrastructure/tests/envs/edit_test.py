#!/usr/bin/env python3
"""Unit test of the TOML line editor of `envs` (imported, never run): comments, blank lines and order survive."""
import importlib.machinery
import importlib.util
import sys
import tomllib

loader = importlib.machinery.SourceFileLoader("envs_mod", sys.argv[1])
spec = importlib.util.spec_from_loader("envs_mod", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
T = m.TomlText
bad = []


def eq(name, got, want):
    if got != want:
        bad.append(f"{name}:\n--- got\n{got}\n--- want\n{want}")


src = ('# head comment\nproject = "billing"   # trailing\nenvironments = ["dev", "prod"]\n\n# secrets\n[secrets]\n'
       'A = "a"  # keep\n\nB = ""\n\n[other]\nx = 1\n')
ed = T(src)
ed.set(None, "default", '"dev"')
eq("add top-level key after the last top-level key", ed.text().split("\n")[3], 'default = "dev"')
ed.set(None, "project", '"billing2"')
eq("replace keeps the trailing comment", ed.text().split("\n")[1], 'project = "billing2"   # trailing')
ed.set("secrets", "C", '"desc"')
t = ed.text()
eq("new key goes after the last key of its table, before [other]",
   t.index('C = "desc"') < t.index("[other]") and t.index('C = "desc"') > t.index('B = ""'), True)
eq("comments kept", "# head comment" in t and "# secrets" in t and "# keep" in t, True)
ed.rename("secrets", "A", "AA")
eq("rename keeps value and comment", 'AA = "a"  # keep' in ed.text(), True)
eq("remove returns True", ed.remove("secrets", "B"), True)
eq("remove of a missing key returns False", ed.remove("secrets", "ZZ"), False)
doc = tomllib.loads(ed.text())
eq("result parses and has the expected keys", sorted(doc["secrets"]), ["AA", "C"])
eq("other table untouched", doc["other"], {"x": 1})
# a table that does not exist yet is appended at the end
ed = T('[a]\nk = 1\n')
ed.set("env", "NAME", m.toml_str('va"l\\ue\n'))
doc = tomllib.loads(ed.text())
eq("string escaping round-trips", doc["env"]["NAME"], 'va"l\\ue\n')
eq("existing table kept", doc["a"], {"k": 1})
ed = T("")
ed.set("env", "X", '"1"')
eq("empty file gets the table", tomllib.loads(ed.text()), {"env": {"X": "1"}})
# refusals
for name, text, tab, key in (("quoted key", '[secrets]\n"A B" = "x"\nC = ""\n', "secrets", "C"),
                             ("multi-line array", 'environments = [\n "dev",\n "prod",\n]\n', None, "environments")):
    try:
        T(text).set(tab, key, '"v"')
        bad.append(f"{name}: not refused")
    except m.Fail:
        pass
if bad:
    print("\n".join(bad))
    sys.exit(1)
