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
LIMIT="${BOOT_WAIT:-1800}"
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
last_change=$SECONDS
prev=""
while : ; do
  waited=$((SECONDS - start))
  if [ "$waited" -ge "$LIMIT" ]; then
    echo "TIMEOUT after ${waited}s (limit ${LIMIT}s); last stage '${stage}'"
    break
  fi
  stage=$(probe boot)
  # A PROGRESSING INSTALL IS NOT A STUCK ONE.
  #
  # Measured desktop times on this same disk: 637, 780, 804, 838, 883, 910s - and a
  # 900s limit cut the last run off at 914s while the screen still said 'installing'.
  # That is a cap set too close to the observed maximum, not a fault. The limit is now
  # generous, and the thing worth reporting is whether the picture is still changing:
  # an install that keeps repainting is working, whatever the clock says.
  if [ "$stage" != "$prev" ]; then
    last_change=$SECONDS
    changed="$((SECONDS - start))s"
  else
    changed="$((SECONDS - last_change))s ago"
  fi
  echo "t=${waited}s stage=${stage} (last change ${changed})"
  prev="$stage"
  [ "$stage" = "desktop" ] && break
  sleep 15
done

if [ "$stage" != "desktop" ]; then
  echo "never reached a desktop"
  docker logs --tail 40 "$NAME" 2>&1 || true
  exit 1
fi

echo "desktop reached after $((SECONDS - start))s"
