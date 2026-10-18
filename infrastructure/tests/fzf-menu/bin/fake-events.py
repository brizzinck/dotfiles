#!/usr/bin/python3 -IB
"""fake Hyprland event socket (.socket2.sock) for the fzf-menu tests: fake-events.py SOCKET FIFO CONNFILE
Listens on SOCKET; every line written into FIFO is sent to every connected client; CONNFILE gets one line per accepted client."""
import os
import select
import socket
import sys

path, fifo, conn_file = sys.argv[1:4]
os.makedirs(os.path.dirname(path), exist_ok=True)
if os.path.exists(path):
    os.unlink(path)
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path)
srv.listen(8)
ffd = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)   # O_RDWR: opening never blocks and the fifo never reports EOF
clients = []
while True:
    r, _, _ = select.select([srv, ffd], [], [], 1.0)
    if srv in r:
        c, _ = srv.accept()
        clients.append(c)
        with open(conn_file, "a") as f:
            f.write("connected\n")
    if ffd in r:
        data = os.read(ffd, 4096)
        for c in list(clients):
            try:
                c.sendall(data)
            except OSError:
                clients.remove(c)
