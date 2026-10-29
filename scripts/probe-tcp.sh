#!/usr/bin/env bash
# Distinguish three outcomes that have been collapsed into one for many rounds:
#
#   connect fails      -> the SYN never arrived or was refused
#   connect succeeds, no data -> the packet path works and the peer is silent
#   banner             -> working
#
# Every earlier check used  exec 3<>/dev/tcp/... ; head -c 80 <&3  with a 4-6 second
# timeout and reported all three as "nothing". The 8006 control test differs in one way -
# it WRITES an HTTP request first - and it gets HTTP/1.1 200 OK from the same address in
# the same run where the read-only test reported nothing. That is only possible if the
# connection succeeds and the silence is what was being measured.
#
# So: connect and write nothing, read with a long timeout, and say which stage failed.
set -u

PORT="${PORT:-2222}"
HOST="${HOST:-127.0.0.1}"
WAIT="${WAIT:-25}"

pair=$(timeout 3 bash -c "exec 3<>/dev/tcp/$HOST/$PORT" 2>&1; echo "rc=$?")
case "$pair" in
  *rc=0*) echo "  connect: SUCCEEDED" ;;
  *)      echo "  connect: FAILED  ($pair)"; exit 0 ;;
esac

echo "  reading a banner for up to ${WAIT}s (SSH sends it unprompted)..."
banner=$(timeout "$WAIT" bash -c "exec 3<>/dev/tcp/$HOST/$PORT; head -c 80 <&3" 2>/dev/null | tr -d "\r\n" || true)
if [ -n "$banner" ]; then
  echo "  banner: $banner"
else
  echo "  banner: NONE in ${WAIT}s - connected but silent"
fi
