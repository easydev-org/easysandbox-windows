#!/usr/bin/env bash
# Bake a CLEAN Windows golden disk with dockur, in separately invocable stages.
#
# PRODUCE vs CONSUME. dockur/windows produces the disk - it is a complete QEMU
# guest with unattended installation wired in (answer.sh rewrites the
# autounattend XML per version). easysandbox consumes it through
# GOLDEN_DISK_IMAGE and must not grow a second, divergent install path.
#
# WHY STAGES. GitHub publishes no streaming log API: /actions/jobs/{id}/logs is
# a redirect to a blob that only materialises after the job ends, and is 403/404
# while the job runs. The one progress signal that IS live and documented is
# the step list from /actions/jobs/{id}. So the slow part is its own step, and
# a long install shows up as "bake: wait for install -> in_progress" instead of
# one opaque 90-minute block.
#
#   prepare   fetch the ISO/image dockur will install from (nothing is installed)
#   start     create and start the container
#   wait      block until the guest has finished installing
#   extract   stop the guest and copy the qcow2 out
#
# run <stage> selects one. Bare invocation runs all four in order, so the
# script still works by hand.
set -Eeuo pipefail

STAGE="${1:-all}"
VERSION="${VERSION:-11}"
DISK_SIZE="${DISK_SIZE:-64G}"
RAM="${RAM:-4G}"
CPUS="${CPUS:-4}"
STORAGE="${STORAGE:?set STORAGE}"
OUT="${OUT:?set OUT}"
WAIT="${WAIT:-5400}"
NAME="${NAME:-winbake}"

# A fixed name is what lets the stages be separate steps: step N+1 has to find
# the container step N started. docker run would refuse a duplicate, so clear a
# leftover from a previous attempt instead of failing on it.

# Files the stages share hold state that outlives a step but not the job.
# GITHUB_WORKSPACE survives between steps; /tmp does too, but being explicit
# about the path avoids depending on that.
STATE="${STATE:-$(dirname "$OUT")/.bake-state}"
mkdir -p "$STATE"

log() { echo "[bake $(date -u +%H:%M:%S)] $*"; }

claim_kvm() {
  # /dev/kvm ships as root:kvm 0660, so the runner user cannot open it and QEMU
  # would silently fall back to TCG - a Windows install then takes many hours
  # instead of tens of minutes, which looks like a hang rather than a failure.
  if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666"' | sudo tee /etc/udev/rules.d/99-kvm4all.rules >/dev/null
    sudo udevadm control --reload-rules
    sudo udevadm trigger --name-match=kvm
  fi
  [ -e /dev/kvm ] || { echo "NO /dev/kvm"; return 2; }
  ls -la /dev/kvm
}

stage_prepare() {
  log "windows $VERSION -> $OUT"
  mkdir -p "$STORAGE" "$(dirname "$OUT")"
  claim_kvm
  # Nothing to download here: dockur fetches its own ISO inside the container,
  # and pre-fetching would pin a URL that dockur chooses. This stage exists so
  # the KVM claim and the workspace check happen in a fast, visible step - if
  # they are going to fail, they fail in seconds rather than after an hour.
  log "prepare done; storage=$STORAGE"
}

stage_start() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  log "starting dockur/windows (host arch $(uname -m))"
  # dockurr/windows is multi-arch and picks its variant from the host: an
  # amd64 guest on an x86_64 runner, an ARM64 guest on an aarch64 one, both
  # native. Passing --platform would force emulation and defeat that.
  #
  # No AUTO_UNATTEND variable exists - unattended is the default and MANUAL is
  # the escape hatch forced on only when an answer file is missing.
  docker run -d --name "$NAME" \
    --device=/dev/kvm \
    -e "VERSION=$VERSION" \
    -e "DISK_SIZE=$DISK_SIZE" \
    -e "RAM_SIZE=$RAM" \
    -e "CPU_CORES=$CPUS" \
    -v "$STORAGE:/storage" \
    dockurr/windows > /dev/null
  sleep 5
  docker ps --filter "name=^$NAME$" --format "{{.Names}} {{.Status}}" || true
  log "start done"
}

stage_wait() {
  log "waiting for $STORAGE/boot (dockur creates it only after Setup completes)"
  # The marker, not a timer: install.sh createMarker "boot" runs after a
  # successful installation, and its presence is also what stops this container
  # re-installing on the next start. Any other signal means "has been running",
  # not "finished".
  deadline=$(( SECONDS + WAIT ))
  last_beat=0
  while (( SECONDS < deadline )); do
    if [ -f "$STORAGE/boot" ]; then log "boot marker present after ${SECONDS}s"; return 0; fi
    if ! docker ps --format "{{.Names}}" | grep -qx "$NAME"; then
      log "container exited before the marker appeared; tail:"
      docker logs "$NAME" 2>&1 | tail -60 || true
      return 1
    fi
    # Heartbeat every 30s. The qcow2 size is the only health signal visible from
    # the host: dockur creates the disk early and Setup grows it, so a size that
    # has stopped moving is the one way to tell "still installing" from "stuck".
    if (( SECONDS - last_beat >= 30 )); then
      last_beat=$SECONDS
      disk=$(find "$STORAGE" -name "*.qcow2" -type f -printf "%s\n" 2>/dev/null | sort -n | tail -1)
      : "${disk:=0}"
      tail_line=$(docker logs --tail 1 "$NAME" 2>&1 | tr -d "\r" | cut -c1-100 || true)
      log "${SECONDS}s  disk=$((disk/1048576))MiB  dockur: $tail_line"
    fi
    sleep 20
  done
  log "TIMEOUT after ${WAIT}s; tail:"
  docker logs "$NAME" 2>&1 | tail -60 || true
  return 1
}

stage_extract() {
  log "stopping the guest so the filesystem is consistent"
  docker stop -t 180 "$NAME" >/dev/null 2>&1 || true
  shopt -s nullglob
  cands=("$STORAGE"/data.qcow2 "$STORAGE"/*.qcow2)
  if [ ${#cands[@]} -eq 0 ]; then log "no qcow2 under $STORAGE"; ls -la "$STORAGE"; return 1; fi
  SRC="${cands[0]}"
  log "extracting $SRC"
  ls -la "$SRC"
  # Convert so the output is a standalone qcow2 regardless of what dockur used.
  qemu-img convert -O qcow2 "$SRC" "$OUT"
  qemu-img info "$OUT" | head -6
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  log "BAKED windows $VERSION -> $OUT"
}

case "$STAGE" in
  prepare) stage_prepare ;;
  start)   stage_prepare; stage_start ;;
  wait)    stage_wait ;;
  extract) stage_extract ;;
  all)     stage_prepare; stage_start; stage_wait; stage_extract ;;
  *) echo "usage: $0 [prepare|start|wait|extract|all]"; exit 64 ;;
esac
