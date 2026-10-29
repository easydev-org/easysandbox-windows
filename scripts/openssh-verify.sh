#!/usr/bin/env bash
# Read a real SSH banner from the published port, and if it does not answer, say WHICH
# hop is dropping it rather than just "no banner".
#
# A bare TCP connect is not evidence - docker's proxy completes the handshake on its
# own, which produced false positives earlier. Only a guest that speaks first with
# "SSH-2.0-..." counts.
set -u

PORT="${PORT:-2222}"
HOST="${HOST:-127.0.0.1}"
NAME="${NAME:-sshinst}"
DEADLINE=$((SECONDS + 120))

banner_at() {
  timeout 6 bash -c "exec 3<>/dev/tcp/$1/$2; head -c 60 <&3" 2>/dev/null \
    | tr -d '\r\n' || true
}

echo "--- what is listening inside the container on $PORT ---"
docker exec "$NAME" sh -c "
  (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep ':$PORT ' || echo '  (nothing)'
" 2>&1 | sed 's/^/  /'

CID=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NAME" 2>/dev/null || true)
echo "--- container ip: ${CID:-unknown} ---"

# EVERY HOP. Inside the container the relay already answered with a real banner, so the
# relay is not the suspect; what is untested is the path from here to it. Testing the
# container's own address (bypassing docker's proxy) and the published port separately
# shows which one drops the connection.
if [ -n "$CID" ]; then
  direct=$(banner_at "$CID" "$PORT")
  echo "  host -> $CID:$PORT  ->  ${direct:-nothing}"
fi

echo "--- docker's own mapping ---"
docker port "$NAME" 2>&1 | sed 's/^/  /' || true

echo "--- nat rules in the container for this port ---"
docker exec "$NAME" sh -c "
  iptables -t nat -S 2>/dev/null | grep 2222 || echo '  (no nat rule)'
" 2>&1 | sed 's/^/  /'

echo "--- polling $HOST:$PORT for a banner ---"
while [ "$SECONDS" -lt "$DEADLINE" ]; do
  banner=$(banner_at "$HOST" "$PORT")
  if [ -n "$banner" ]; then
    echo "port $PORT said: $banner"
  else
    echo "port $PORT: no banner yet (${SECONDS}s)"
  fi
  case "$banner" in
    SSH-*)
      echo "VERIFIED: sshd is reachable on $HOST:$PORT"
      exit 0
      ;;
  esac
  sleep 10
done

echo "NOT VERIFIED: no SSH banner on $HOST:$PORT after ${SECONDS}s"
echo "--- relay log ---"
docker exec "$NAME" sh -c "cat /tmp/relay.log 2>/dev/null || echo '  (no relay log)'" 2>&1 | sed 's/^/  /'
exit 1
