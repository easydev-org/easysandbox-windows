#!/usr/bin/env bash
# Photograph the guest every N seconds for the whole run, and keep the frames.
#
# WHY THIS EXISTS SEPARATELY FROM THE CLASSIFIER.
#
# The wait loop asks screen-read.py a yes/no question and logs one word per probe. That
# is useful for deciding when to stop, and useless for understanding what happened:
# "unknown" for nine minutes tells you nothing, and the frame behind it is gone.
#
# This runs alongside, on its own clock, and writes a timestamped PNG every interval so
# the whole boot can be replayed afterwards. It never decides anything and never fails
# the job - if a capture is missed, the next one is 30 seconds away.
#
# Names are HHMMSS so a plain sort is chronological. PPM is deleted after conversion:
# 1280x800 PPM is 3 MB and a long boot is fifty of them, while the PNG is ~200 KB.
set -u

NAME="${NAME:-sshinst}"
OUT="${OUT:-shots/frames}"
INTERVAL="${INTERVAL:-30}"
DEADLINE="${DEADLINE:-3600}"
MON="${MON:-/run/shm/monitor.sock}"

mkdir -p "$OUT"
MANIFEST="$OUT/frames.tsv"
: > "$MANIFEST"

start=$SECONDS
index=0
while [ $((SECONDS - start)) -lt "$DEADLINE" ]; do
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$NAME"; then
    echo "frames: container gone after $((SECONDS - start))s"
    break
  fi
  index=$((index + 1))
  stamp=$(date -u +%H%M%S)
  tag=$(printf '%03d-%s' "$index" "$stamp")

  docker exec "$NAME" python3 /tmp/shotsock.py "$MON" "/tmp/f.ppm" >/dev/null 2>&1 || true
  docker cp "$NAME:/tmp/f.ppm" "/tmp/f.ppm" >/dev/null 2>&1 || true

  if [ -s /tmp/f.ppm ]; then
    # Classify HERE, while the raw framebuffer is still on hand. The taskbar test reads
    # P6 pixels and cannot work from a PNG, and keeping every PPM would be 3 MB a frame.
    # So the verdict is recorded now, next to the frame it belongs to, and the report
    # reads it back instead of guessing later.
    stage=$(python3 scripts/screen-read.py /tmp/f.ppm 2>/dev/null || echo "?")
    python3 scripts/ppm2png.py /tmp/f.ppm "$OUT/$tag.png" >/dev/null 2>&1 || true
    if [ -s "$OUT/$tag.png" ]; then
      printf '%s\t%s\t%s\t%s\n' "$tag" "$((SECONDS - start))" "$stage" "$(stat -c%s "$OUT/$tag.png")" >> "$MANIFEST"
      echo "frames: $tag ($((SECONDS - start))s) $stage"
    fi
    rm -f /tmp/f.ppm
  else
    printf '%s\t%s\t%s\t%s\n' "$tag" "$((SECONDS - start))" "no-frame" "0" >> "$MANIFEST"
    echo "frames: $tag - no frame"
  fi
  sleep "$INTERVAL"
done

echo "frames: captured $index frames in $((SECONDS - start))s"
ls -1 "$OUT" | head -5
echo "frames: total on disk: $(ls -1 "$OUT" 2>/dev/null | wc -l)"
