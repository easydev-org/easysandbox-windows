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
