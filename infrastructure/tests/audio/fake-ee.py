#!/usr/bin/env python3
# fake EasyEffects 8.3.0 control server for the audio tests: a unix socket at the path given as argv[1] that speaks the same
# newline-terminated text grammar as the real QLocalServer (see .local/bin/ee-ctl). Every received command goes to the log file.
#   fake-ee.py SOCKET LOG [--delay SEC] [--preset NAME] [--bypass true|false] [--global 1|2] [--sticky-preset NAME] [--slow SEC]
# --delay      do not listen for SEC seconds (EasyEffects still starting)
# --preset     last loaded input preset at start (default empty, like a fresh start)
# --sticky-preset  load_preset:input:X always leaves NAME loaded (a preset that did not take)
# --slow       sleep SEC before every reply
# Unknown getters stay silent here; the real server answers error_property_not_found (the clients only need a bounded wait).
# get_global_bypass answers a bare digit without a newline like the real server; the other getters end in a newline.
import os
import socket
import sys
import time

sock, log = sys.argv[1], sys.argv[2]
opt = {"preset": "", "bypass": "false", "global": "2", "sticky": None, "slow": 0.0, "delay": 0.0}
a = sys.argv[3:]
while a:
    k = a.pop(0)
    v = a.pop(0)
    if k == "--delay":
        opt["delay"] = float(v)
    elif k == "--preset":
        opt["preset"] = v
    elif k == "--bypass":
        opt["bypass"] = v
    elif k == "--global":
        opt["global"] = v
    elif k == "--sticky-preset":
        opt["sticky"] = v
    elif k == "--slow":
        opt["slow"] = float(v)
time.sleep(opt["delay"])
try:
    os.unlink(sock)
except OSError:
    pass
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock)
srv.listen(8)
open(log + ".ready", "w").close()
while True:
    c, _ = srv.accept()
    data = c.recv(4096).decode(errors="replace")
    for line in data.split("\n"):
        line = line.strip()
        if not line:
            continue
        with open(log, "a") as f:
            f.write(line + "\n")
        if opt["slow"]:
            time.sleep(opt["slow"])
        rep = None
        if line.startswith("load_preset:input:"):
            opt["preset"] = opt["sticky"] if opt["sticky"] is not None else line.split(":", 2)[2]
            opt["bypass"] = "false"
        elif line == "get_last_loaded_preset:input":
            rep = opt["preset"] + "\n"
        elif line == "get_property:input:rnnoise:0:bypass":
            rep = opt["bypass"] + "\n"
        elif line.startswith("set_property:input:rnnoise:0:bypass:"):
            opt["bypass"] = line.rsplit(":", 1)[1]
        elif line == "get_global_bypass":
            rep = opt["global"]
        elif line == "quit_app":
            c.close()
            sys.exit(0)
        if rep is not None:
            c.sendall(rep.encode())
    # like the real QLocalServer the connection stays open until the client closes it (a client that waits for a newline
    # after a bare "2" really waits)
    c.settimeout(2)
    try:
        c.recv(4096)
    except OSError:
        pass
    c.close()
