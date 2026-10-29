#!/usr/bin/env bash
# Make the guest's sshd reachable on the container's published port.
#
# WHY THIS IS NEEDED. With NET_ADMIN, dockur gives the guest its own address on a tap
# bridge (the run log says 'Mode: NAT' and 'Guest: 172.30.0.2'), and then QEMU's
# arguments carry no hostfwd at all:
#
#   -netdev tap,id=hostnet0,ifname=qemu,script=no,downscript=no
#
# So docker publishing 2222 forwards to the container, and nothing carries it further.
# USER_PORTS does not help here - its own documentation says it applies 'when using
# user-mode networking'.
#
# In NAT mode the container reaches the guest by address, so one DNAT rule is enough.
# It is added inside the container, where NET_ADMIN applies.
set -eu

NAME="${NAME:-sshinst}"
PORT="${PORT:-2222}"

guest=$(docker logs "$NAME" 2>&1 | sed -n 's/.*Guest: \([0-9.]*\).*/\1/p' | tail -1 || true)
if [ -z "$guest" ]; then
  echo "could not read the guest address from the container log; assuming 172.30.0.2"
  guest="172.30.0.2"
fi
echo "guest address: $guest, port: $PORT"

# REACH THE GUEST FIRST. If the container cannot open a TCP connection to the guest's
# sshd, no nat rule will help - the fault would be the tap/bridge or the guest's
# firewall, not the forward. Checked before touching iptables so the two failures are
# never confused again.
echo "--- can the container reach the guest directly? ---"
docker exec "$NAME" sh -c "
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 5 $guest $PORT && echo 'direct: open' || echo 'direct: closed'
  else
    timeout 5 sh -c \"echo > /dev/tcp/$guest/$PORT\" 2>/dev/null && echo 'direct: open' || echo 'direct: closed'
  fi
" 2>&1 | sed 's/^/  /'

# Redirect traffic arriving on the container's port to the guest's sshd. PREROUTING
# covers packets from the host, OUTPUT covers the container itself - both are needed
# by different paths, and adding both is cheap.
docker exec "$NAME" sh -c "
  iptables -t nat -C PREROUTING -p tcp --dport $PORT -j DNAT --to-destination $guest:$PORT 2>/dev/null ||
  iptables -t nat -A PREROUTING -p tcp --dport $PORT -j DNAT --to-destination $guest:$PORT
  iptables -t nat -C OUTPUT -p tcp --dport $PORT -j DNAT --to-destination $guest:$PORT 2>/dev/null ||
  iptables -t nat -A OUTPUT -p tcp --dport $PORT -j DNAT --to-destination $guest:$PORT
  echo '--- nat table ---'
  iptables -t nat -S | grep $PORT || true
" 2>&1 | sed 's/^/  /'
