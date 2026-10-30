#!/usr/bin/env python3
"""Make the guest's sshd reachable on the container's published port.

Replaces openssh-forward.sh. That script accumulated 240 lines of comments because every
fault was diagnosed in place and the explanation left behind; the actual work is short and
is written out below without the archaeology.

WHAT THE LAYERS ARE, since the confusion between them cost many rounds:

    layer 1  CI runner            172.17.0.1 (docker0)
    layer 2  container            eth0 172.17.0.2   <- docker publishes the port here
    layer 3  QEMU guest           172.30.0.2        <- dockur's bridge, sshd listens here

A published port is rewritten by docker ON THE HOST to 172.17.0.2:PORT before it enters the
container, so a container-side nat rule cannot intercept it: by then it is no longer a
LOCAL destination. What docker expects to find is a listener at that address, and nothing
in the dockur image listens on our port. So this starts one, relaying to the guest.

Several things are deliberately NOT done, each of which was tried and each of which made
things worse:

  * no DNAT inside the container - it matches the very traffic docker forwards (a packet
    for 172.17.0.2:2222 is dst-type LOCAL with dport 2222) and sends it to the guest,
    past the relay. Both were live at once for two rounds.
  * no bind to the container's specific address - the socket that answers from outside is
    dockur's own, which binds all addresses. Bound to 172.17.0.2 the relay answered itself
    and nobody else.
  * no assumption that 'no banner' means 'not forwarded' - the banner here takes about ten
    seconds, and a six-second read reported a working port as dead for many rounds.
"""
import argparse
import re
import sys
import time

import xsh


def parse_guest_ip(log_text):
    """Pull the guest address out of dockur's banner line.

    It prints:  'Guest: 172.30.0.2 (Windows)  |  Mode: NAT'
    Reading it beats assuming 172.30.0.2, which would silently break if dockur changed its
    bridge subnet.
    """
    found = re.findall(r"Guest:\s*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)", log_text or "")
    return found[-1] if found else None


def parse_ifaddrs(text):
    """Map interface name -> IPv4 address, from `ip -o -4 addr show` output.

    Example line:
      2: eth0    inet 172.17.0.2/16 brd 172.17.255.255 scope global eth0
    """
    result = {}
    for line in (text or "").splitlines():
        m = re.match(r"\s*\d+:\s+(\S+)\s+inet\s+([0-9.]+)/", line)
        if m:
            result[m.group(1)] = m.group(2)
    return result


def bridge_for(addrs, bridge_ip):
    """Which interface owns bridge_ip. Never assume the name 'docker'."""
    for name, addr in addrs.items():
        if addr == bridge_ip:
            return name
    return None


def relay_listening(listen_out, port):
    """True if something is listening on the port, from `ss -ltn` or `netstat -ltn`."""
    for line in (listen_out or "").splitlines():
        if re.search(r"[:.]%d\s" % port, line):
            return True
    return False


RELAY = """#!/usr/bin/env python3
import socket, sys, threading

listen, target, tport = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])

def pump(src, dst):
    try:
        while True:
            b = src.recv(65536)
            if not b:
                break
            dst.sendall(b)
    except Exception:
        pass
    finally:
        for s in (src, dst):
            try: s.shutdown(socket.SHUT_RDWR)
            except Exception: pass
            try: s.close()
            except Exception: pass

def serve(c):
    try:
        u = socket.create_connection((target, tport), timeout=10)
    except Exception:
        try: c.close()
        except Exception: pass
        return
    threading.Thread(target=pump, args=(c, u), daemon=True).start()
    threading.Thread(target=pump, args=(u, c), daemon=True).start()

srv = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    srv.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
except Exception:
    pass
srv.bind(("::", listen))
srv.listen(511)
print("relaying [::]:%d -> %s:%d" % (listen, target, tport), flush=True)
while True:
    try:
        c, _ = srv.accept()
    except Exception:
        break
    threading.Thread(target=serve, args=(c,), daemon=True).start()
"""

CLEANUP = """#!/bin/sh
# Remove every nat rule this project left behind, by line number, highest first.
# A file, not an inline string: nesting $chain through docker exec -> sh -c expanded it
# on the host and set -u aborted the loop, so the hijacking rule survived every cleanup.
set -u
for chain in PREROUTING POSTROUTING OUTPUT; do
  nums=$(iptables -t nat -L $chain --line-numbers -n 2>/dev/null | grep QEMU_DNAT | cut -d" " -f1 | sort -rn)
  for n in $nums; do
    iptables -t nat -D $chain $n 2>/dev/null || true
  done
done
iptables -t nat -F QEMU_DNAT 2>/dev/null || true
iptables -t nat -X QEMU_DNAT 2>/dev/null || true
echo "  PREROUTING after cleanup:"
iptables -t nat -S PREROUTING 2>/dev/null | head -8
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--container", default="sshinst")
    ap.add_argument("--port", type=int, default=2222)
    ap.add_argument("--bridge-ip", default="172.30.0.1")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    name = args.container
    port = args.port

    print("--- where the guest is ---", flush=True)
    logs = xsh.run(["docker", "logs", name], echo=False).text
    guest_ip = parse_guest_ip(logs) or "172.30.0.2"
    print("  guest: %s" % guest_ip, flush=True)

    print("--- container interfaces ---", flush=True)
    addrs = parse_ifaddrs(
        xsh.run(["docker", "exec", name, "ip", "-o", "-4", "addr", "show"], echo=False).out
    )
    for iface, addr in addrs.items():
        print("  %-8s %s" % (iface, addr), flush=True)
    bridge = bridge_for(addrs, args.bridge_ip) or "docker"
    print("  bridge owning %s: %s" % (args.bridge_ip, bridge), flush=True)
    container_ip = addrs.get("eth0")
    xsh.need(container_ip, "no eth0 address; cannot know where docker forwards")
    print("  docker forwards to: %s" % container_ip, flush=True)

    print("--- ip_forward ---", flush=True)
    xsh.docker_exec(name, "sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true\n"
                          "cat /proc/sys/net/ipv4/ip_forward\n", echo=False)

    print("--- removing earlier nat rules ---", flush=True)
    xsh.docker_exec(name, CLEANUP, echo=True)

    print("--- can the container reach the guest's sshd? ---", flush=True)
    probe = xsh.docker_exec(
        name,
        "if timeout 5 sh -c 'echo > /dev/tcp/%s/%d' 2>/dev/null; then echo open; "
        "else echo closed; fi\n" % (guest_ip, port),
        echo=False,
    )
    if "open" not in probe.out:
        xsh.need(False, "the container cannot reach %s:%d - the guest's sshd is not up, so a "
                        "relay would have nothing to forward to" % (guest_ip, port))
    print("  direct: open", flush=True)

    print("--- starting the relay on all addresses ---", flush=True)
    import os
    import tempfile
    fd, path = tempfile.mkstemp(suffix=".py")
    with os.fdopen(fd, "w") as f:
        f.write(RELAY)
    try:
        xsh.run(["docker", "cp", path, "%s:/tmp/relay.py" % name], check=True, echo=False)
    finally:
        os.unlink(path)
    xsh.run(["docker", "exec", name, "pkill", "-f", "/tmp/relay.py"], echo=False)
    # docker exec -d: the supported way to leave a process running. A backgrounded child of
    # a foreground exec dies with it, which is what made the relay invisible once.
    xsh.run(["docker", "exec", "-d", name, "sh", "-c",
             "python3 /tmp/relay.py %d %s %d > /tmp/relay.log 2>&1" % (port, guest_ip, port)],
            check=True, echo=False)
    time.sleep(4)

    print("--- is it listening, and what does it say ---", flush=True)
    status = xsh.docker_exec(
        name,
        "(ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep ':%d ' || echo '(nothing)'\n"
        "echo '--- log ---'\ncat /tmp/relay.log 2>/dev/null || echo '(no log)'\n" % port,
        echo=False,
    )
    for line in status.out.splitlines():
        print("  " + line, flush=True)
    xsh.need(relay_listening(status.out, port),
             "the relay is not listening on %d - docker forwards here and finds nothing" % port)

    print("\nforward ready: %s:%d -> %s:%d" % (container_ip, port, guest_ip, port), flush=True)
    return 0


def selftest():
    cases = [
        ("dockur banner", "some output\nGuest: 172.30.0.2 (Windows)  |  Mode: NAT", "172.30.0.2"),
        ("no banner", "nothing here", None),
        ("several banners takes the last",
         "Guest: 172.30.0.2 ...\nGuest: 172.30.0.9 ...", "172.30.0.9"),
    ]
    bad = 0
    for desc, text, want in cases:
        got = parse_guest_ip(text)
        mark = "ok " if got == want else "FAIL"
        bad += got != want
        print("  %s guest-ip %-32s -> %s" % (mark, desc, got))

    addrs = parse_ifaddrs(
        "1: lo    inet 127.0.0.1/8 scope host lo\n"
        "2: eth0    inet 172.17.0.2/16 brd 172.17.255.255 scope global eth0\n"
        "3: docker    inet 172.30.0.1/24 scope global docker\n"
    )
    for desc, got, want in [
        ("eth0 parsed", addrs.get("eth0"), "172.17.0.2"),
        ("bridge by address", bridge_for(addrs, "172.30.0.1"), "docker"),
        ("bridge missing", bridge_for(addrs, "10.9.9.1"), None),
    ]:
        mark = "ok " if got == want else "FAIL"
        bad += got != want
        print("  %s %-32s -> %s" % (mark, desc, got))

    for desc, out, want in [
        ("dual-stack listener", "LISTEN 0 511 *:2222 *:*", True),
        ("specific address", "LISTEN 0 64 172.17.0.2:2222 0.0.0.0:*", True),
        ("different port", "LISTEN 0 511 *:8006 *:*", False),
        ("nothing", "(nothing)", False),
    ]:
        got = relay_listening(out, 2222)
        mark = "ok " if got == want else "FAIL"
        bad += got != want
        print("  %s listening %-28s -> %s" % (mark, desc, got))

    print("\n%s" % ("all cases passed" if bad == 0 else "%d FAILED" % bad))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
