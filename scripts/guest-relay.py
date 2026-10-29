#!/usr/bin/env python3
"""Relay TCP from a container port to the guest's sshd.

    guest-relay.py <listen-port> <guest-address> <guest-port>

Runs inside the dockur container. One thread per direction per client, and a fresh
upstream connection for every client, so concurrent SSH sessions do not share state.

WHY A RELAY AND NOT iptables. The container can already open a connection to
172.30.0.2:2222 - that was measured. What is missing is something answering on the
container's own port, because docker's published-port proxy delivers the connection
into the container's network namespace where no process is listening; a nat-table
DNAT rule never sees that traffic as forwarded. Listening here and connecting
upstream is the same path the working measurement already took.
"""
import socket
import sys
import threading


def pump(src, dst):
    try:
        while True:
            chunk = src.recv(65536)
            if not chunk:
                break
            dst.sendall(chunk)
    except Exception:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass
            try:
                s.close()
            except Exception:
                pass


def serve(client, target, tport):
    try:
        upstream = socket.create_connection((target, tport), timeout=10)
    except Exception:
        try:
            client.close()
        except Exception:
            pass
        return
    threading.Thread(target=pump, args=(client, upstream), daemon=True).start()
    threading.Thread(target=pump, args=(upstream, client), daemon=True).start()


def main():
    if len(sys.argv) != 4:
        sys.exit("usage: guest-relay.py <listen-port> <guest-address> <guest-port>")
    listen, target, tport = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", listen))
    srv.listen(64)
    print("relaying 0.0.0.0:%d -> %s:%d" % (listen, target, tport), flush=True)
    while True:
        client, _ = srv.accept()
        threading.Thread(target=serve, args=(client, target, tport), daemon=True).start()


main()
