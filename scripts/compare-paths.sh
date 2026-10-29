#!/usr/bin/env bash
# Compare how the host dispatches 2222 and 8006, which behave differently despite
# sharing an IP, a container and a netns.
#
# The arrival probe settled one half: with a connection pending from this host, the
# container socket table shows NOTHING for 2222 - no SYN_RECV, no ESTABLISHED. The packet
# never enters the namespace. So no container-side rule, relay or bind setting can matter.
#
# 8006 does answer from the same host, so whichever path it takes is not the one 2222
# takes. This prints both paths side by side: docker nat rules, the host listeners, and
# the actual route the kernel picks for each destination.
set -u

PORT="${PORT:-2222}"
CIP="${CIP:-172.17.0.2}"

echo "=== nat rules mentioning either port ==="
iptables -t nat -S 2>/dev/null | grep -E "dport (2222|8006)" | sed "s/^/  /" || echo "  (none)"

echo "=== DOCKER chain, both ports ==="
iptables -t nat -S DOCKER 2>/dev/null | grep -E "(2222|8006)" | sed "s/^/  /" || echo "  (none)"

echo "=== host listeners ==="
(ss -ltnp 2>/dev/null || sudo ss -ltnp 2>/dev/null) | grep -E ":(2222|8006) " | sed "s/^/  /" || echo "  (none)"

echo "=== route to the container for each port (same dest, so same route) ==="
ip route get "$CIP" 2>/dev/null | sed "s/^/  /" || true

echo "=== does the host reach 8006 and 2222 right now? ==="
for p in 8006 "$PORT"; do
  r=$(timeout 4 bash -c "exec 3<>/dev/tcp/$CIP/$p; head -c 30 <&3" 2>/dev/null | tr -d "\r\n" || true)
  echo "  $CIP:$p -> ${r:-nothing}"
done

echo "=== is the container MAC/IP pair what docker thinks? ==="
docker inspect -f "{{.NetworkSettings.Networks}}" "${NAME:-sshinst}" 2>/dev/null | sed "s/^/  /" || true
