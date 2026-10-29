#!/usr/bin/env bash
# Read a real SSH banner from the published port, retrying, and report plainly.
#
# A bare TCP connect is not evidence: docker's proxy completes the handshake on its own,
# which produced false positives earlier in this project. The only proof is a guest
# that speaks first with "SSH-2.0-...".
set -u

PORT="${PORT:-2222}"
HOST="${HOST:-127.0.0.1}"
DEADLINE=$((SECONDS + 120))

while [ "$SECONDS" -lt "$DEADLINE" ]; do
  banner=$(timeout 6 bash -c "
    exec 3<>/dev/tcp/$HOST/$PORT
    head -c 80 <&3
  " 2>/dev/null | tr -d '\r\n' || true)

  if [ -n "$banner" ]; then
    echo "port $PORT said: $banner"
  else
    echo "port $PORT: no banner yet ($((SECONDS))s)"
  fi

  case "$banner" in
    SSH-*)
      echo "VERIFIED: sshd is reachable on $HOST:$PORT"
      exit 0
      ;;
  esac
  sleep 10
done

echo "NOT VERIFIED: no SSH banner on $HOST:$PORT after $((SECONDS))s"
echo "--- what the container believes is listening ---"
docker exec "${NAME:-sshinst}" sh -c "
  (ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null) | grep -E ':$PORT|:22 ' || echo '  (nothing on that port)'
  echo '--- relay log ---'
  cat /tmp/relay.log 2>/dev/null || echo '  (no relay log)'
" 2>&1 | sed 's/^/  /'
echo "--- docker port mapping ---"
docker port "${NAME:-sshinst}" 2>&1 | sed 's/^/  /' || true
exit 1
