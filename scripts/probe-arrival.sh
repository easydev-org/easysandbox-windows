#!/usr/bin/env bash
# While a connection is attempted from the host, ask the container what its kernel saw.
#
# This is the distinction never yet measured: whether the SYN reaches the listener and is
# ignored, or never arrives at all. Everything else has been inference from the outcome.
#
#   SYN_RECV  present  -> the packet arrived, the listener did not complete the handshake
#   ESTABLISHED        -> connected, so the failure is later
#   nothing            -> the packet never reached this namespace
set -u

NAME="${NAME:-sshinst}"
PORT="${PORT:-2222}"
HOST="${HOST:-127.0.0.1}"

echo "--- container socket state BEFORE any connection ---"
docker exec "$NAME" sh -c "ss -tan | grep ':$PORT' | head -10" 2>/dev/null | sed "s/^/    /" || echo "    (none)"

echo "--- opening a connection from this host, holding it briefly ---"
( exec 3<>/dev/tcp/$HOST/$PORT 2>/dev/null; sleep 6 ) &
holder=$!
sleep 2

echo "--- container socket state DURING (SYN_RECV or ESTABLISHED would prove arrival) ---"
docker exec "$NAME" sh -c "ss -tan | grep ':$PORT' | head -10" 2>/dev/null | sed "s/^/    /" || echo "    (none)"

echo "--- container counters for the port (SYNs received?) ---"
docker exec "$NAME" sh -c "(ss -s 2>/dev/null | head -6)" 2>/dev/null | sed "s/^/    /" || true

wait $holder 2>/dev/null || true
echo "--- done ---"
