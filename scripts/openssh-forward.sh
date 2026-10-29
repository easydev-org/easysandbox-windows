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

# NO DNAT IN THIS CONTAINER - IT HIJACKS THE RELAY.
#
# I copied setup_network() here, and the rules were correct in isolation: PREROUTING
# position 1, scoped to tcp/2222, DNAT to the guest, MASQUERADE, FORWARD accepts. The
# run then showed both things at once:
#
#   container: LISTEN 0.0.0.0:2222        (the relay, working)
#   host -> 172.17.0.2:2222 -> nothing     (never reached it)
#
# Because a packet from the host arrives at eth0 addressed to 172.17.0.2:2222, which IS
# LOCAL with dport 2222 - so my own rule matched it and sent it to 172.30.0.2:2222
# instead of letting it reach the relay that was waiting on that exact address. The
# rules were fighting the listener.
#
# Upstream does not have this problem because it has no relay and no VNC: its DNAT is
# the only mechanism. Here the published port already arrives addressed to this
# container, so the listener alone is the whole answer. The DNAT is removed, and any
# copy an earlier run installed is removed too - leaving it would silently steal the
# traffic again.
echo "--- removing EVERY nat rule an earlier run installed ---"
# THE OLD CLEANUP MISSED MOST OF THEM, and that is why the relay looked unreachable
# while being perfectly healthy. It deleted by a fully specified rule:
#     -D PREROUTING -m comment --comment QEMU_DNAT -j QEMU_DNAT
# which only matches a jump whose target is QEMU_DNAT. The run printed two survivors:
#     -A PREROUTING ! -i docker -m addrtype --dst-type LOCAL -j QEMU_DNAT
#     -A PREROUTING -i docker -m comment --comment QEMU_DNAT -j DNAT --to-destination 172.17.0.1
# Neither matches that pattern, and the first hijacks exactly what docker forwards: a
# packet for 172.17.0.2:2222 IS dst-type LOCAL, so it was handed on to the guest instead
# of reaching the relay listening on that address - the listener up, answering itself,
# never seeing outside traffic.
#
# So delete by LINE NUMBER, walking each chain backwards, matching only the comment.
docker exec "$NAME" sh -c "
  for chain in PREROUTING POSTROUTING OUTPUT; do
    nums=$(iptables -t nat -L $chain --line-numbers -n 2>/dev/null | awk '/QEMU_DNAT/ {print $1}' | sort -rn)
    for n in $nums; do iptables -t nat -D $chain $n 2>/dev/null || true; done
  done
  iptables -t nat -F QEMU_DNAT 2>/dev/null || true
  iptables -t nat -X QEMU_DNAT 2>/dev/null || true
  echo '  PREROUTING after cleanup:'
  iptables -t nat -S PREROUTING 2>/dev/null | head -8
" 2>&1 | sed 's/^/  /'

echo "--- container -> guest:$PORT ---"
docker exec "$NAME" sh -c "
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 5 '$GUEST_IP' '$PORT' && echo '  direct: open' || echo '  direct: closed'
  else
    timeout 5 sh -c 'echo > /dev/tcp/$GUEST_IP/$PORT' 2>/dev/null && echo '  direct: open' || echo '  direct: closed'
  fi
" 2>&1

# AND A LISTENER ON THE CONTAINER'S OWN ADDRESS.
#
# The host side was printed on the last run and settles it:
#
#   host nat:      -i docker0 -p tcp --dport 2222 -j DNAT --to-destination 172.17.0.2:2222
#   host listen:   LISTEN 0.0.0.0:2222   (docker-proxy)
#   host -> 172.17.0.2:2222  ->  nothing
#
# docker rewrites the destination on the HOST, before the packet ever enters this
# namespace, so by the time it arrives here its destination is 172.17.0.2:2222 - no
# longer LOCAL - and my container-side DNAT can never match. The container-side rules
# are still right for traffic that originates inside; they are simply not the path a
# published port takes.
#
# The path a published port takes ends at 172.17.0.2:2222 inside this container, where
# nothing was listening. So something now listens there, relaying to the guest. That is
# the one piece docker's own DNAT assumes exists.
echo "--- starting a listener on the container address ---"
# Parsed on the HOST. Running awk with {print \$4} inside docker exec -> sh -c is what
# produced 'awk: backslash not last character on line' on the previous run, and the
# relay silently fell back to 0.0.0.0.
# grep -oE avoids the escaped-paren sed pattern; the same backslash nesting
# that broke awk would break sed identically. Parsed on the host.
CPORT_IP=$(docker exec "$NAME" sh -c "ip -4 -o addr show eth0 2>/dev/null" 2>/dev/null | grep -oE "inet [0-9.]+" | head -1 | cut -d" " -f2)
echo "  container ip: ${CPORT_IP:-unknown}"
docker cp "$(dirname "$0")/guest-relay.py" "$NAME:/tmp/guest-relay.py"
docker exec "$NAME" sh -c 'pkill -f guest-relay.py 2>/dev/null || true; rm -f /tmp/relay.log' || true
# BIND 0.0.0.0, THE SAME AS THE LISTENER THAT WORKS.
#
# The control test separated cause from coincidence in one shot - same script, same
# moment, same IP:
#
#   this machine -> 172.17.0.2:8006  ->  HTTP/1.1 200 OK      (dockur's own listener)
#   this machine -> 172.17.0.2:2222  ->  nothing              (my relay)
#   container    -> 172.17.0.2:2222  ->  SSH-2.0-OpenSSH...   (relay is fine)
#
# So the path to that address is open and the relay answers; the only structural
# difference is the bind address. dockur listens on 0.0.0.0, my relay bound the
# container's specific address. A socket bound to 172.17.0.2 and reached through docker's
# DNAT can reply along a path the peer will not accept, whereas 0.0.0.0 matches what the
# working listener does. Changing exactly that one thing.
# BIND THE CONTAINER ADDRESS - reverted from 0.0.0.0 after measuring both.
#
# The 0.0.0.0 attempt was made on the theory that dockur's working 8006 listener binds
# 0.0.0.0 and mine should match. That run failed differently: even the container's own
# self-connect returned nothing, which pointed at sshd rather than the bind. Checking the
# frame proved it - the guest's PowerShell showed
#
#   + FullyQualifiedErrorId : CouldNotStopService,RestartServiceCommand
#
# so sshd was still on port 22 and the relay had nothing upstream to talk to. The bind
# was never the problem; a bind that works (172.17.0.2, measured 'SSH-2.0-OpenSSH...')
# should not be changed on a theory.
# BIND 0.0.0.0 - the single-variable test that has never actually been run.
#
# The current data, all from runs where sshd was confirmed working:
#
#   container -> 172.17.0.2:2222 -> SSH-2.0-OpenSSH...   relay answers
#   this host -> 172.17.0.2:2222 -> nothing
#   this host -> 172.17.0.2:8006 -> HTTP 200 OK          same ip, different port
#
# 8006 is dockur's own listener and binds 0.0.0.0. Mine binds 172.17.0.2. Earlier I
# changed this to 0.0.0.0 and reverted it when that run failed - but the reason that run
# failed was sshd, not the bind (the frame showed CouldNotStopService). So the combination
# 'working sshd + bind 0.0.0.0' has never been tested. sshd is now proven by the step
# that prints Get-Service and Get-NetTCPConnection, so this changes one variable.
# No bind argument: guest-relay.py now creates an AF_INET6 socket with IPV6_V6ONLY off
# and listen(511), mirroring dockur's own listener (measured 'LISTEN 0 511 *:8006 *:*'),
# which is the one that answers from outside. Passing 0.0.0.0 would keep it IPv4-only.
docker exec -d "$NAME" sh -c "python3 /tmp/guest-relay.py $PORT $GUEST_IP $PORT > /tmp/relay.log 2>&1"
sleep 4
docker exec "$NAME" sh -c "
  echo '  relay pid:' \$(pgrep -f guest-relay.py | tr '\n' ' ')
  (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep ':'$PORT' ' | sed 's/^/  /' || echo '  (not listening)'
  sed 's/^/  log: /' /tmp/relay.log 2>/dev/null || echo '  (no log)'
"
