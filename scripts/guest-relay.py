#!/usr/bin/env python3
"""Relay TCP from a container port to the guest's sshd.

    guest-relay.py <listen-port> <guest-address> <guest-port> [bind-address]

Runs inside the dockur container. One thread per direction per client, and a fresh
upstream connection for every client, so concurrent SSH sessions do not share state.

WHY THIS IS STILL NEEDED, after the container-side DNAT was copied from sandbox.sh.

The host side settles it, printed by the last run:

  host nat:     -i docker0 -p tcp --dport 2222 -j DNAT --to-destination 172.17.0.2:2222
  host listen:  LISTEN 0.0.0.0:2222   (docker-proxy)
  host -> 172.17.0.2:2222  ->  nothing

docker rewrites the destination on the HOST, so a published port arrives here already
addressed to 172.17.0.2:2222 - not LOCAL - and a container-side nat rule can never match
it. The rules copied from sandbox.sh remain correct for traffic originating inside the
container; they are simply not the path a published port takes. That path ends at the
container's own address, where nothing was listening.

Bind address exists because of that: listening on 0.0.0.0 works, but naming the address
docker forwards to makes the intent explicit and keeps the relay off the loopback.
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
    if len(sys.argv) not in (4, 5):
        sys.exit("usage: guest-relay.py <listen-port> <guest-address> <guest-port> [bind]")
    listen, target, tport = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])
    bind = sys.argv[4] if len(sys.argv) == 5 else None

    # MATCH THE SOCKET THAT WORKS.
    #
    # Measured side by side in one run:
    #
    #   my relay :  LISTEN 0  64   0.0.0.0:2222   0.0.0.0:*
    #   dockur   :  LISTEN 0 511         *:8006         *:*
    #
    # Two differences, both plausible causes of 'answers inside, silent outside':
    #
    #   * is an IPv6 socket with IPV6_V6ONLY off, so it accepts both families. docker
    #     reaches the container over a dual-stack bridge; an IPv4-only socket can miss
    #     connections that arrive mapped.
    #   backlog 511 against my 64 - the kernel drops SYNs beyond the queue, and a
    #     published port under docker's proxy can burst.
    #
    # So this mirrors dockur exactly: AF_INET6, V6ONLY off, backlog 511. The bind address
    # argument is still honoured when given (translated to its IPv6 form), because the
    # caller passes one.
    srv = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
    except (AttributeError, OSError):
        pass
    host = "::" if not bind or bind in ("0.0.0.0", "::") else bind
    srv.bind((host, listen))
    srv.listen(511)
    print("relaying [%s]:%d -> %s:%d (dual-stack, backlog 511)" % (host, listen, target, tport), flush=True)
    while True:
        client, _ = srv.accept()
        threading.Thread(target=serve, args=(client, target, tport), daemon=True).start()


main()
