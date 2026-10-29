#!/usr/bin/env bash
# Make the guest's sshd reachable on the container's published port.
#
# THE MEASUREMENTS, in the order they were taken:
#
#   guest side         Test-NetConnection 127.0.0.1:2222        -> True
#   container -> guest direct connect 172.30.0.2:2222           -> open
#   host -> container  read an SSH banner on 127.0.0.1:2222     -> nothing
#
# QEMU's own argv has no hostfwd, because NET_ADMIN makes dockur build a tap bridge and
# give the guest its own address ('Mode: NAT', 'Guest: 172.30.0.2').
#
# So the container CAN reach sshd and the gap is the container's own port 2222: docker
# publishes it and forwards into the container, where nothing is listening. nat-table
# DNAT was tried first and did not help - docker's userland proxy terminates the
# connection before it becomes forwarded traffic in PREROUTING.
#
# The fix that matches the measurement is an application-level relay inside the
# container: listen on the published port, hand each connection to the guest. It uses
# only what has already been shown to work.
set -eu

NAME="${NAME:-sshinst}"
PORT="${PORT:-2222}"

guest=$(docker logs "$NAME" 2>&1 | sed -n 's/.*Guest: \([0-9.]*\).*/\1/p' | tail -1 || true)
if [ -z "$guest" ]; then
  echo "could not read the guest address from the container log; assuming 172.30.0.2"
  guest="172.30.0.2"
fi
echo "guest address: $guest, port: $PORT"

echo "--- can the container reach the guest directly? ---"
docker exec "$NAME" sh -c "
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 5 $guest $PORT && echo 'direct: open' || echo 'direct: closed'
  else
    timeout 5 sh -c \"echo > /dev/tcp/$guest/$PORT\" 2>/dev/null && echo 'direct: open' || echo 'direct: closed'
  fi
" 2>&1 | sed 's/^/  /'

echo "--- starting the relay 0.0.0.0:$PORT -> $guest:$PORT ---"
docker cp "$(dirname "$0")/guest-relay.py" "$NAME:/tmp/guest-relay.py"
docker exec "$NAME" sh -c "
  pkill -f guest-relay.py 2>/dev/null || true
  nohup python3 /tmp/guest-relay.py $PORT $guest $PORT > /tmp/relay.log 2>&1 &
  sleep 2
  echo '  relay pid:' \$(pgrep -f guest-relay.py | head -1)
  echo '  listening sockets:'
  (ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null) | grep $PORT | sed 's/^/    /' || echo '    (none)'
  echo '  relay log:'
  cat /tmp/relay.log 2>/dev/null | sed 's/^/    /' || true
" 2>&1 | sed 's/^/  /'
