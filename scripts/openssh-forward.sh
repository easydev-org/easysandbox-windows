#!/usr/bin/env bash
# Make the guest's sshd reachable on the container's published port.
#
# WHAT IS MEASURED, and it has not changed through four attempts:
#
#   guest side          Test-NetConnection 127.0.0.1:2222   -> True
#   container -> guest  connect 172.30.0.2:2222             -> "Connection succeeded!"
#   host -> container   read a banner on 127.0.0.1:2222     -> nothing
#
# QEMU runs '-netdev tap,...' with no hostfwd, because NET_ADMIN makes dockur bridge the
# guest onto its own address. So docker publishes 2222, forwards into the container, and
# nothing is bound there. nat-table DNAT did not help: docker's userland proxy hands the
# connection straight into the namespace, so it never appears as forwarded traffic.
#
# The relay is the right shape - listen here, connect upstream - but starting it with
# 'nohup python3 ... &' inside docker exec did NOT work, and the evidence was in the
# failure output: '(no relay log)' and '(nothing on that port)'. The backgrounded child
# of an exec dies with that exec.
#
# So the relay is started as a detached session with setsid and its output redirected by
# the shell that launches it, and then the listener is CONFIRMED before moving on - a
# relay that is not listening is worse than none, because everything downstream then
# tests the wrong thing.
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

echo "--- installing the relay ---"
docker cp "$(dirname "$0")/guest-relay.py" "$NAME:/tmp/guest-relay.py"

echo "--- starting it detached ---"
# docker exec -d is the supported way to leave a process running in a container: the exec
# returns immediately and the process is not tied to it. The first attempt used
# 'nohup ... &' inside a foreground exec, and the child died with the exec - visible in
# the failure output as '(no relay log)' and '(nothing on that port)'.
docker exec "$NAME" sh -c 'pkill -f guest-relay.py 2>/dev/null || true; rm -f /tmp/relay.log' || true
docker exec -d "$NAME" sh -c "python3 /tmp/guest-relay.py $PORT $guest $PORT > /tmp/relay.log 2>&1"
sleep 4
docker exec "$NAME" sh -c "
  echo '  pid: '\$(pgrep -f guest-relay.py | tr '\n' ' ')
  echo '  log:'
  sed 's/^/    /' /tmp/relay.log 2>/dev/null || echo '    (no log written)'
" 2>&1 | sed 's/^/  /'

echo "--- is it actually listening? ---"
docker exec "$NAME" sh -c "
  if (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -q ':$PORT '; then
    (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep ':$PORT ' | sed 's/^/  /'
    echo '  LISTENING'
  else
    echo '  NOT LISTENING - the relay did not come up'
    exit 1
  fi
" 2>&1 | sed 's/^/  /'

echo "--- relay the port from inside the container (should now answer) ---"
docker exec "$NAME" sh -c "
  if command -v nc >/dev/null 2>&1; then
    timeout 8 nc 127.0.0.1 $PORT < /dev/null 2>&1 | head -1 || true
  else
    timeout 8 sh -c \"exec 3<>/dev/tcp/127.0.0.1/$PORT; head -c 60 <&3\" 2>/dev/null || true
  fi
" 2>&1 | sed 's/^/  /'
