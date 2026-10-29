#!/usr/bin/env bash
# Wait for the Windows guest to reach a desktop, streaming progress.
#
# Extracted from the workflow so log-stream can run it by path: a long step whose
# log only appears after it ends cannot be watched, and this step is the longest in
# the job. GitHub serves a running job's log from a blob published on completion, so
# the only way to see progress live is a check run - which is what log-stream writes.
#
# Prints one line per probe: the elapsed wall-clock seconds and what the screen shows.
set -u

NAME="${NAME:-sshinst}"
LIMIT="${BOOT_WAIT:-900}"
SHOTS="${SHOTS:-shots}"
OCR="${OCR:-scripts/screen-read.py}"
MON="${MON:-/run/shm/monitor.sock}"

mkdir -p "$SHOTS"

probe() {
  local tag="$1"
  docker exec "$NAME" python3 /tmp/shotsock.py "$MON" "/tmp/$tag.ppm" >/dev/null 2>&1 || true
  docker cp "$NAME:/tmp/$tag.ppm" "$SHOTS/$tag.ppm" >/dev/null 2>&1 || true
  if [ -s "$SHOTS/$tag.ppm" ]; then
    python3 "$OCR" "$SHOTS/$tag.ppm" 2>/dev/null || echo unknown
  else
    echo "no-frame"
  fi
}

start=$SECONDS
stage=""
while : ; do
  waited=$((SECONDS - start))
  if [ "$waited" -ge "$LIMIT" ]; then
    echo "TIMEOUT after ${waited}s (limit ${LIMIT}s); last stage '${stage}'"
    break
  fi
  stage=$(probe boot)
  echo "t=${waited}s stage=${stage}"
  [ "$stage" = "desktop" ] && break
  sleep 15
done

if [ "$stage" != "desktop" ]; then
  echo "never reached a desktop"
  docker logs --tail 40 "$NAME" 2>&1 || true
  exit 1
fi

echo "desktop reached after $((SECONDS - start))s"
