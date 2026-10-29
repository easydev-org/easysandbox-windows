#!/usr/bin/env bash
# Ask the container whether anything answers on its own address, on this port.
#
# This separates the two failures that have been confused throughout: a relay that is
# not answering, and a path from the host that does not arrive. If this prints a banner
# and the host still does not, the problem is between the host and the container.
set -u

NAME="${NAME:-sshinst}"
PORT="${PORT:-2222}"

ip=$(docker exec "$NAME" sh -c "ip -4 -o addr show eth0 2>/dev/null" 2>/dev/null | grep -oE "inet [0-9.]+" | head -1 | cut -d" " -f2 || true)
echo "  container eth0: ${ip:-unknown}"

for target in ${ip:-} 127.0.0.1; do
  banner=$(docker exec "$NAME" sh -c "timeout 5 bash -c 'exec 3<>/dev/tcp/$target/$PORT; head -c 40 <&3'" 2>/dev/null | tr -d "\r\n" || true)
  echo "  container -> $target:$PORT -> ${banner:-nothing}"
done

echo "  listening:"
docker exec "$NAME" sh -c "(ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep ":$PORT "" 2>/dev/null | sed "s/^/    /" || echo "    (nothing)"
echo "  relay log:"
docker exec "$NAME" sh -c "cat /tmp/relay.log 2>/dev/null" 2>/dev/null | sed "s/^/    /" || echo "    (no log)"

# THE CONTROL TEST, on port 8006.
#
# 8006 is noVNC, which dockur itself listens on inside the container - nothing to do
# with the relay, the DNAT or sshd. If this layer can reach the container's 8006, the
# path is fine and only the 2222 part is broken. If it cannot, then this layer never
# reaches 172.17.0.2 at all and every 'nothing' I have been reading about 2222 was
# measured from a place with no route - which would explain why every fix to the guest
# and the relay changed nothing.
cid=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NAME" 2>/dev/null || true)
echo "  --- control: this machine -> container 8006 (native dockur listener) ---"
if [ -n "$cid" ]; then
  c=$(timeout 5 bash -c "exec 3<>/dev/tcp/$cid/8006; printf 'GET / HTTP/1.0\r\n\r\n' >&3; head -c 40 <&3" 2>/dev/null | tr -d "\r\n" || true)

  echo "    -> $cid:8006 -> ${c:-nothing}"
fi
  c=$(timeout 5 bash -c "exec 3<>/dev/tcp/$cid/8006; printf 'GET / HTTP/1.0\r\n\r\n' >&3; head -c 40 <&3" 2>/dev/null | tr -d "\r\n" || true)

echo "    -> 127.0.0.1:8006 -> ${c2:-nothing}"

echo "  --- filter INPUT in the container (does anything drop 2222?) ---"
docker exec "$NAME" sh -c "iptables -S INPUT 2>/dev/null | head -20" 2>&1 | sed "s/^/    /"
echo "  --- all established/半开 connections to the port ---"
docker exec "$NAME" sh -c "(ss -tn 2>/dev/null || netstat -tn 2>/dev/null) | grep ':$PORT' | head -10" 2>&1 | sed "s/^/    /" || true
echo "  --- is anything else listening on 8006 for comparison ---"
docker exec "$NAME" sh -c "(ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep ':8006'" 2>&1 | sed "s/^/    /" || true

echo "  --- NETNS CHECK (read on the host, no nesting) ---"
relay_pid=$(docker exec "$NAME" pgrep -f guest-relay.py 2>/dev/null | head -1)
nginx_pid=$(docker exec "$NAME" pgrep -x nginx 2>/dev/null | head -1)
echo "    relay pid=${relay_pid:-none} nginx pid=${nginx_pid:-none}"
docker exec "$NAME" sh -c "readlink /proc/\$1/ns/net 2>/dev/null; readlink /proc/1/ns/net 2>/dev/null" _ "${relay_pid:-1}" 2>/dev/null | sed "s/^/    relay/1 netns: /" || true
if [ -n "$relay_pid" ]; then
  docker exec "$NAME" readlink "/proc/$relay_pid/ns/net" 2>/dev/null | sed "s/^/    relay netns: /"
fi
if [ -n "$nginx_pid" ]; then
  docker exec "$NAME" readlink "/proc/$nginx_pid/ns/net" 2>/dev/null | sed "s/^/    nginx netns: /"
fi
docker exec "$NAME" readlink /proc/1/ns/net 2>/dev/null | sed "s/^/    pid1  netns: /"
echo "  --- which netns owns eth0 (the one docker forwards to) ---"
docker exec "$NAME" sh -c "ip -o link show eth0 2>/dev/null | head -2" 2>&1 | sed "s/^/    /"
