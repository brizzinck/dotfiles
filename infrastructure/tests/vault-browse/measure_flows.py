#!/usr/bin/env python3
"""measure_flows.py FLOW SCRIPTS_DIR BIN_DIR: run one vault flow in-process against the fakes of this directory and print the
wall time. measure.sh sets the environment (fake bw with a delay per process) and counts the bw processes / server requests."""
import importlib.machinery
import importlib.util
import os
import sys
import time

flow, scripts, bindir = sys.argv[1], sys.argv[2], sys.argv[3]
sys.dont_write_bytecode = True


def load(path, name):
    loader = importlib.machinery.SourceFileLoader(name.replace("-", "_"), path)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


vb = load(f"{scripts}/vault-browse.py", "vault-browse")
ENTRY = {"id": "i-github", "type": "login"}
CTX = {"prev": "0xAAA", "entries": {}, "folder": "All"}
t0 = time.time()
if flow == "browser-open":
    entries = vb.list_entries()
    vb.read_index(build=True)
elif flow == "copy":
    vb.read_item_action("pass", "i-github", ENTRY, CTX)
elif flow == "type":
    vb.read_item_action("type", "i-github", ENTRY, CTX)
elif flow == "edit":
    vb.act_edit("i-github")
elif flow == "new-login":
    answers = iter(["newsite", "bob", "https://new.example", "g"])
    m = vb.vbw()
    m.ask = lambda label, default="": next(answers)
    vb.act_new_login("")
elif flow == "trash-open":
    vb.drop_index()
    vb.build_rows(vb.TRASH, vb.list_entries())
elif flow == "trash-restore":
    vb.act_restore("i-old", "old-forum")
elif flow == "send-chats-prep":
    setup = load(os.environ["MEASURE_SETUP"], "mcp-telegram-setup")
    m = setup.load_vault_bw()
    m.ensure()
    setup.find_item(m)
else:
    sys.exit(f"unknown flow {flow}")
print(f"{time.time() - t0:.2f}")
