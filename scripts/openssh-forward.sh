#!/usr/bin/env bash
# Make the guest reachable on the container's published ports.
#
# COPIED FROM THE PROJECT'S OWN sandbox.sh, function setup_network(), rather than
# invented. This repository ships the real implementation (Containerfile + sandbox.sh +
# guest/), and its networking section already solves this exact problem. Reading it
# first would have saved several attempts at a Python relay.
#
# The rules, and why each is needed - I had got three of the five wrong before:
#
#   sysctl net.ipv4.ip_forward=1
#       forwarding is off by default; without it nothing crosses eth0 <-> bridge
#   PREROUTING ! -i BRIDGE -m addrtype --dst-type LOCAL -j QEMU_DNAT
#       the ! -i guard stops traffic arriving FROM the bridge being re-DNAT'd into it
#   QEMU_DNAT -p tcp --dport PORT -j DNAT --to-destination GUEST_IP:PORT
#       SCOPED TO ONE PORT, which is where this deviates from upstream on purpose.
#       sandbox.sh DNATs everything that arrives for a local address, because that
#       image has no VNC at all: Containerfile sets DISPLAY=none, drops the noVNC
#       assets and never exposes 8006. This workflow does publish 8006 for the web
#       console, and a blanket DNAT would send those connections to the guest, which
#       has nothing on 8006 - killing the console. So the rule names the port.
#   POSTROUTING -s BRIDGE_IP/PREFIX ! -d ... ! -o BRIDGE -j MASQUERADE
#       the guest's replies need source NAT, or they leave with an address the sender
#       cannot route back to
#   FORWARD ACCEPT in both directions
#       the filter table's default policy drops the forwarded flows even when nat is
#       correct
#
# docker publish plus these rules is the whole mechanism. There is no listener for port
# 22 inside the upstream container either - DNAT is what answers.
set -eu

BRIDGE="${BRIDGE:-docker}"
BRIDGE_IP="${BRIDGE_IP:-172.30.0.1}"
GUEST_IP="${GUEST_IP:-172.30.0.2}"
PREFIX="${PREFIX:-24}"
NAME="${NAME:-sshinst}"
PORT="${PORT:-2222}"

echo "--- guest address, from the container log ---"
detected=$(docker logs "$NAME" 2>&1 | sed -n 's/.*Guest: \([0-9.]*\).*/\1/p' | tail -1 || true)
if [ -n "$detected" ]; then
  GUEST_IP="$detected"
fi
echo "  guest_ip=$GUEST_IP bridge_ip=$BRIDGE_IP prefix=$PREFIX"

echo "--- interfaces in the container ---"
docker exec "$NAME" sh -c "ip -o -4 addr show 2>/dev/null" 2>/dev/null | sed 's/^/  /' || true

# The bridge NAME is not assumed. sandbox.sh defaults to 'docker', but this is the
# upstream dockur image, whose bridge may be named differently. It is identified by the
# address it owns, parsed on the HOST - nesting $4 and quotes through docker exec -> sh
# -c is what produced nonsense output in earlier attempts.
real_bridge=$(docker exec "$NAME" sh -c "ip -o -4 addr show 2>/dev/null" 2>/dev/null \
  | awk -v ip="$BRIDGE_IP" '$4 ~ ip {print $2; exit}' || true)
if [ -n "$real_bridge" ]; then
  BRIDGE="$real_bridge"
  echo "  bridge owning $BRIDGE_IP: $BRIDGE"
else
  echo "  no interface owns $BRIDGE_IP; keeping '$BRIDGE'"
fi

echo "--- ip_forward ---"
docker exec "$NAME" sh -c 'sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true'
docker exec "$NAME" sh -c 'cat /proc/sys/net/ipv4/ip_forward' 2>/dev/null | sed 's/^/  ip_forward=/' || true

echo "--- installing the nat and filter rules (tcp/$PORT only) ---"
docker exec "$NAME" sh -c "
  iptables -t nat -N QEMU_DNAT 2>/dev/null || true
  iptables -t nat -F QEMU_DNAT

  iptables -t nat -C PREROUTING -m addrtype --dst-type LOCAL -p tcp --dport '$PORT' -j QEMU_DNAT 2>/dev/null ||
  iptables -t nat -A PREROUTING ! -i '$BRIDGE' -m addrtype --dst-type LOCAL -p tcp --dport '$PORT' -m comment --comment QEMU_DNAT -j QEMU_DNAT

  iptables -t nat -C POSTROUTING -s '$BRIDGE_IP/$PREFIX' -j MASQUERADE 2>/dev/null ||
  iptables -t nat -A POSTROUTING -s '$BRIDGE_IP/$PREFIX' ! -d '$BRIDGE_IP/$PREFIX' ! -o '$BRIDGE' -m comment --comment QEMU_DNAT -j MASQUERADE

  iptables -t nat -A QEMU_DNAT -p tcp --dport '$PORT' -m comment --comment QEMU_DNAT -j DNAT --to-destination '$GUEST_IP':'$PORT'

  iptables -t filter -C FORWARD -s '$BRIDGE_IP/$PREFIX' -j ACCEPT 2>/dev/null ||
  iptables -t filter -A FORWARD -s '$BRIDGE_IP/$PREFIX' -i '$BRIDGE' ! -o '$BRIDGE' -j ACCEPT

  iptables -t filter -C FORWARD -d '$GUEST_IP/32' -j ACCEPT 2>/dev/null ||
  iptables -t filter -A FORWARD -d '$GUEST_IP/32' ! -i '$BRIDGE' -o '$BRIDGE' -j ACCEPT

  echo '  --- nat QEMU_DNAT ---'
  iptables -t nat -S QEMU_DNAT 2>/dev/null
  echo '  --- nat PREROUTING/POSTROUTING (ours) ---'
  iptables -t nat -S PREROUTING 2>/dev/null | grep QEMU_DNAT || true
  iptables -t nat -S POSTROUTING 2>/dev/null | grep QEMU_DNAT || true
  echo '  --- filter FORWARD (ours) ---'
  iptables -S FORWARD 2>/dev/null | grep '172.30.' || true
" 2>&1 | sed 's/^/  /'

echo "--- container -> guest:$PORT ---"
docker exec "$NAME" sh -c "
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 5 '$GUEST_IP' '$PORT' && echo '  direct: open' || echo '  direct: closed'
  else
    timeout 5 sh -c 'echo > /dev/tcp/$GUEST_IP/$PORT' 2>/dev/null && echo '  direct: open' || echo '  direct: closed'
  fi
" 2>&1
