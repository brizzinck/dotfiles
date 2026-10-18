#!/usr/bin/env python3
"""Unit test of the .env parser of `envs import` (imported, never run)."""
import importlib.machinery
import importlib.util
import sys

loader = importlib.machinery.SourceFileLoader("envs_mod", sys.argv[1])
spec = importlib.util.spec_from_loader("envs_mod", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
bad = []


def eq(name, got, want):
    if got != want:
        bad.append(f"{name}: got {got!r}, want {want!r}")


text = '''# a comment
PLAIN=value
export EXPORTED=1
SPACED = spaced value
INLINE=abc # trailing comment
HASHED=abc#notacomment
SINGLE='a "quoted" $NOT_EXPANDED # kept'
DOUBLE="tab\\there \\"q\\" back\\\\slash \\n end" # after
MULTI="first
second line
third"
EMPTY=
REF=${HOME}/x
DUP=1
DUP=2
this is not a line
export 1BAD=x
UNCLOSED="never closed
'''
vals, warns, errs = m.parse_dotenv(text)
eq("plain", vals["PLAIN"], "value")
eq("export prefix", vals["EXPORTED"], "1")
eq("spaces around =", vals["SPACED"], "spaced value")
eq("inline comment after an unquoted value", vals["INLINE"], "abc")
eq("# without a space before it stays", vals["HASHED"], "abc#notacomment")
eq("single quotes are literal", vals["SINGLE"], 'a "quoted" $NOT_EXPANDED # kept')
eq("double quote escapes", vals["DOUBLE"], 'tab\there "q" back\\slash \n end')
eq("multi-line double quoted value", vals["MULTI"], "first\nsecond line\nthird")
eq("empty value", vals["EMPTY"], "")
eq("${VAR} kept literally", vals["REF"], "${HOME}/x")
eq("later duplicate wins", vals["DUP"], "2")
eq("no UNCLOSED key", "UNCLOSED" in vals, False)
eq("warning for ${...}", any(w.startswith("REF:") and "${" in w for w in warns), True)
eq("warning for the duplicate", any(w.startswith("DUP:") for w in warns), True)
eq("two bad lines and the unterminated quote", len(errs), 3)
eq("errors carry line numbers", all(e.startswith("line ") for e in errs), True)
eq("errors never carry the content", any("this is not" in e or "never closed" in e or "1BAD" in e for e in errs), False)
if bad:
    print("\n".join(bad))
    sys.exit(1)
