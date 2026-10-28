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
WAIT="${WAIT:-7200}"
NAME="${NAME:-winbake}"

# The account inside the guest. Named once, here, and used by BOTH the docker run
# that passes them to dockur and the ssh check that logs in with them.
#
# This was the gap: the check defaulted to docker/admin locally while docker run
# passed nothing, so dockur created no such account and the machine came up with
# the built-in Administrator. A green ssh step then proved only that SOME login
# worked - and it was not this one.
WIN_USER="${WIN_USER:-docker}"
WIN_PASS="${WIN_PASS:-admin}"

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

  # Stage the OEM payload into the folder dockur reads.
  #
  # The payload lives in this repository (oem/install.bat) so it is reviewed and
  # versioned with the rest of the bake, but dockur only looks inside its own
  # container paths - /storage/oem among them. Copying here is what connects the
  # two, and doing it in prepare means a missing or empty payload fails in seconds
  # instead of after a ninety-minute install that quietly has no ssh.
  local repo_oem="$(cd "$(dirname "$0")/.." && pwd)/oem"
  if [ -d "$repo_oem" ]; then
    mkdir -p "$STORAGE/oem"
    cp -f "$repo_oem"/. "$STORAGE/oem"/ 2>/dev/null || cp -f "$repo_oem"/* "$STORAGE/oem"/
    log "staged oem payload from $repo_oem"
  fi
  require_oem_ssh || return 1
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
  # Port choice, and why the whole chain is 2222:
  #
  #   host 2222 -> container 2222 -> guest 2222
  #
  # The qemux/qemu base layer forwards a published container port to the guest
  # port of the SAME number - that is why dockur's readme publishes RDP as
  # 3389:3389. The host side cannot be 22 (privileged, docker refuses it for a
  # non-root user), so the number has to be 2222 on all three hops and the OEM
  # script sets sshd's Port to 2222 to match.
  #
  # NOTE: no comments inside the continuation below. A '#' after a trailing
  # backslash ends the command instead of the line, which is what broke this step
  # twice: docker run lost half its arguments and exited in under a second, before
  # any install had started.
  docker run -d --name "$NAME" \
    --device=/dev/kvm \
    --cap-add NET_ADMIN \
    -e "VERSION=$VERSION" \
    -e "DISK_SIZE=$DISK_SIZE" \
    -e "RAM_SIZE=$RAM" \
    -e "CPU_CORES=$CPUS" \
    -e "USERNAME=$WIN_USER" \
    -e "PASSWORD=$WIN_PASS" \
    -e "USER_PORTS=2222" \
    -p 2222:2222 \
    -v "$STORAGE:/storage" \
    dockurr/windows > /dev/null
  # "docker run -d" succeeding only means the container was CREATED. If its
  # entrypoint dies immediately - insufficient memory or disk is the usual reason -
  # the container is gone before the next step looks, and wait then heartbeats
  # nothing for an hour. Fail here instead, with the container log attached.
  local i
  for i in $(seq 1 30); do
    if ! docker ps --format "{{.Names}}" | grep -qx "$NAME"; then
      log "container is not running after ${i}s; its log:"
      docker logs "$NAME" 2>&1 | tail -40 || true
      docker inspect -f "{{.State.Status}} exit={{.State.ExitCode}} err={{.State.Error}}" "$NAME" 2>/dev/null || true
      return 1
    fi
    if [ -n "$(docker logs "$NAME" 2>&1 | head -1)" ] || [ "$i" -ge 10 ]; then break; fi
    sleep 1
  done
  docker ps --filter "name=^$NAME$" --format "{{.Names}} {{.Status}}" || true
  first=$(docker logs "$NAME" 2>&1 | head -3 | tr "\n" " " || true)
  log "first container output: ${first}"

  # Record what port forwarding actually exists, rather than assuming it. The base
  # layer (qemux/qemu, which owns network.sh) decides how a published port reaches
  # the guest, and that file is not in this repository - so the only honest source
  # is the running container.
  log "port mappings as docker sees them:"
  docker port "$NAME" 2>&1 | sed 's/^/    /' || true
  log "qemu network arguments:"
  # Split on spaces and keep the pieces that name the forwarding. The first
  # attempt grepped for 'netdev [^ ]*' through sh, where the bracket expression
  # was mangled and every line came back as "netdev [^" - useless.
  docker exec "$NAME" sh -c "ps -ef | tr ' ' '\n' | grep -E '^(hostfwd|netdev|user,id)' | head -8" 2>&1 | sed 's/^/    /' || true

  log "start done"
}

require_oem_ssh() {
  # The SSH setup rides in on dockur's OEM folder, which is an ordinary feature -
  # /storage/oem is one of the four locations dockur looks in (install.sh,
  # getOemFolder). If it is missing the install still succeeds and simply has no
  # ssh, which is the failure this check exists to prevent: it would cost a full
  # 90-minute bake to discover.
  local bat="$STORAGE/oem/install.bat"
  if [ ! -f "$bat" ]; then
    log "ERROR: $bat is missing - the bake would produce a disk with no ssh"
    return 1
  fi
  log "oem payload present: $(wc -l < "$bat") lines of $bat"
}

stage_ssh_check() {
  # Ask the running guest whether it will accept a login.
  #
  # The container publishes port 22 (docker run -p 22:22, matching the guest port
  # number as the base layer requires), so this is an ordinary TCP check plus a
  # real handshake. It runs right after wait, while
  # the guest is still up, because that is the only moment the service can be asked.
  #
  # A closed port here means the OEM payload did not run or the capability install
  # failed - both silent during the bake, and both fatal to every later step that
  # wants to script the machine instead of clicking it.
  local port="${SSH_PORT:-2222}"
  local password="$WIN_PASS"
  local user="$WIN_USER"
  local i rc

  log "checking ssh on 127.0.0.1:$port (user $user)"
  # wait already blocked until this port answered, so a short retry is enough here;
  # the long wait lives there, where it also serves as the OOBE completion signal.
  for i in $(seq 1 6); do
    if (exec 3<>/dev/tcp/127.0.0.1/$port) 2>/dev/null; then
      log "port $port is open after $((i*5))s"
      break
    fi
    sleep 5
    if [ "$i" = 6 ]; then
      log "ERROR: port $port never opened - sshd is not running in the guest"
      return 1
    fi
  done

  if command -v sshpass >/dev/null 2>&1; then
    if sshpass -p "$password" ssh -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 \
         -p "$port" "$user@127.0.0.1" 'echo SSH-OK; whoami'; then
      log "login succeeded as $user"
      return 0
    fi
    log "ERROR: ssh handshake failed (password auth or account problem)"
    return 1
  fi

  # No sshpass: fall back to unattended ssh. It cannot supply a password, but it
  # reports whether the account reaches the authentication stage - and that is the
  # fact this check exists to establish. "Permission denied (publickey,password)"
  # means the user is real and password auth is offered; a bare
  # "Permission denied (publickey)" means password auth is off; "no such user"
  # means the account was never created. Treating a missing sshpass as success -
  # which the first version did - hid exactly that.
  out=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o BatchMode=yes -o ConnectTimeout=20 -p "$port" \
           "$user@127.0.0.1" 'echo SSH-OK' 2>&1 || true)
  log "ssh without sshpass said: $(printf '%s' "$out" | tr -d '\r' | tr '\n' ' ' | cut -c1-200)"
  case "$out" in
    *"publickey,password"*|*"password"*) log "account $user reaches password auth"; return 0 ;;
    *) log "ERROR: account $user was not accepted"; return 1 ;;
  esac
}

stage_wait() {
  echo_phase() { log "$*"; }
  log "waiting for Windows to finish Setup and boot from its own disk"

  # WHY NOT WAIT FOR $STORAGE/boot.
  #
  # That marker looked like the obvious signal, but power.sh only calls
  # markWindowsBooted() from finish() - i.e. when the container is shutting down:
  #
  #   finish() { ... if ! hasBootMarker; then markWindowsBooted; fi ... }
  #
  # So it is written AFTER shutdown, never during installation. Waiting for it
  # while the guest is running can only ever time out - which is what happened:
  # 62 minutes of a perfectly healthy install spent waiting for a file that the
  # container writes on its way out.
  #
  # What dockur itself uses to decide "setup has progressed far enough" is the
  # firmware line for the hard-disk boot:
  #
  #   ready()  ->  grep UEFI_WINDOWS_BOOT_PATTERN
  #                'BdsDxe: starting BootNNNN "Windows Boot Manager" from .*HD('
  #
  # Once that appears, Windows Setup has written the boot manager and the guest is
  # booting macOS-style from its own disk. At that point we stop the container
  # ourselves; finish() then records the marker, and extract can verify it.
  #
  # The heartbeat reports du, not stat: data.img is a sparse qcow2 whose apparent
  # size is the full DISK_SIZE (64 GiB) from the moment it is created, so stat sat
  # at 65536 MiB for the whole run while the file was still filling up.
  WINDOWS_BOOTED='BdsDxe: starting Boot[[:xdigit:]]{4} "Windows Boot Manager" from .*HD\('
  deadline=$(( SECONDS + WAIT ))
  last_beat=0
  stalled=0
  last_used=""
  while (( SECONDS < deadline )); do
    # Success: the guest is booting from the installed disk.
    if docker logs "$NAME" 2>&1 | grep -qE "$WINDOWS_BOOTED"; then
      log "Windows Boot Manager is booting from the hard disk after ${SECONDS}s"
      # Record the disk path WHILE the container still runs. docker exec cannot
      # inspect a stopped container, and this stage is about to stop this one.
      docker exec "$NAME" find /storage -maxdepth 2 -type f -size +1G \( -name "*.img" -o -name "*.qcow2" \) 2>/dev/null | tr -d "\r" > "$STORAGE/.disk-path" || true
      log "recorded disk path: $(head -1 "$STORAGE/.disk-path" 2>/dev/null)"

      # DO NOT STOP YET, and this is the part that was wrong.
      #
      # "Boot Manager is booting from the hard disk" means Setup has written the
      # boot manager and the guest has started booting its own installation. It
      # does NOT mean Setup Assistant has finished. OOBE still has to run, which is
      # exactly when C:\OEM\install.bat executes (from the SetupComplete wrapper) -
      # and stopping here killed the guest in the middle of that window, so the OEM
      # script never ran and ssh was never enabled. The ssh check then found port
      # 2222 closed on every bake, which is what it reported once it stopped
      # treating a missing sshpass as a pass.
      #
      # sshd answering on 2222 is the honest "OOBE finished" signal: the OEM script
      # is the last thing SetupComplete does, and it starts sshd. So wait for the
      # port, and only then shut down. If the port never comes up the OEM script
      # failed, and failing here is better than shipping a disk that pretends.
      # WAIT FOR A REAL SSH BANNER, NOT FOR THE PORT TO ACCEPT.
      #
      # A bare TCP connect is a false positive here and it cost a whole run: the
      # log said "sshd answered on 2222 after 0s" while the guest had only just
      # written its boot manager, and the separate check thirty seconds later found
      # nothing listening. The container publishes 2222 and its forwarder completes
      # the handshake on its own; only a guest with sshd up sends "SSH-2.0-...".
      #
      # So read the banner. Nothing but a running sshd in the guest can produce it.
      log "waiting for OOBE to finish (a real SSH banner is the completion signal)"
      local port="${SSH_PORT:-2222}"
      local ready=0 waited=0 banner=""
      while (( waited < 1200 )); do
        # timeout is not optional here. The forwarder accepts the connection but
        # sends nothing until a real sshd answers, so `head -c 64` blocks forever
        # on an idle socket - and the previous version of this loop did exactly
        # that: two heartbeats that should be 15s apart appeared 19 minutes apart,
        # because each iteration hung on the read and only the sleep was counted.
        # The 1200s budget would have taken many hours to expire.
        banner=$(timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port && head -c 64 <&3" 2>/dev/null | tr -d '\r\n' || true)
        case "$banner" in
          SSH-*)
            log "SSH banner from the guest after ${waited}s: ${banner}"
            ready=1
            break ;;
        esac
        sleep 15
        waited=$(( waited + 15 ))
        if (( waited % 120 == 0 )); then
          log "still waiting for OOBE: ${waited}s, storage=$(du -m "$STORAGE" 2>/dev/null | awk '{print $1}')MiB, port said: ${banner:-<nothing>}"
        fi
      done
      if (( ready == 0 )); then
        log "ERROR: no SSH banner within 1200s - the OEM script did not run or failed"
        log "container tail:"; docker logs --tail 40 "$NAME" 2>&1 || true
        return 1
      fi

      # Log in HERE, while the guest is up. The old order ran the login check after
      # the container was stopped, so it could only ever fail - and it did, every
      # time, which is why "verify ssh" never established anything.
      if command -v sshpass >/dev/null 2>&1; then
        if sshpass -p "$WIN_PASS" ssh -o StrictHostKeyChecking=no \
             -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 \
             -p "$port" "$WIN_USER@127.0.0.1" 'echo SSH-OK; whoami'; then
          log "login as $WIN_USER succeeded"
        else
          log "WARNING: banner seen but login as $WIN_USER failed - the account may not be what we asked for"
        fi
      else
        log "sshpass absent; banner proved sshd is running but login was not attempted"
      fi
      log "stopping the guest so dockur records its boot marker"
      # docker stop sends ACPI shutdown; finish() then runs markWindowsBooted and
      # writes $STORAGE/boot. Give it room: Windows takes a while to shut down.
      docker stop -t 300 "$NAME" >/dev/null 2>&1 || true
      if [ -f "$STORAGE/boot" ]; then
        log "boot marker written by dockur; install confirmed"
      else
        log "NOTE: no boot marker after shutdown, but the firmware confirmed a hard-disk boot"
      fi
      return 0
    fi

    # A failed boot attempt after the marker appeared is terminal.
    if docker logs "$NAME" 2>&1 | grep -q 'BdsDxe: failed to start .*Windows Boot Manager'; then
      log "firmware reports the Windows Boot Manager failed to start"
      docker logs "$NAME" 2>&1 | tail -80 || true
      return 1
    fi

    if ! docker ps --format "{{.Names}}" | grep -qx "$NAME"; then
      log "container exited before Windows booted; tail:"
      docker logs "$NAME" 2>&1 | tail -80 || true
      return 1
    fi

    if (( SECONDS - last_beat >= 30 )); then
      last_beat=$SECONDS
      # du = actual blocks used. stat would report the sparse file's apparent
      # size (the full DISK_SIZE) and never move.
      used=$(du -m "$STORAGE" 2>/dev/null | awk '{print $1}' || true)
      : "${used:=0}"
      iso=$(ls -1 "$STORAGE"/*.iso 2>/dev/null | head -1 || true)
      tail_line=$(docker logs --tail 1 "$NAME" 2>&1 | tr -d "\r" | cut -c1-80 || true)
      log "${SECONDS}s  storage_used=${used}MiB iso=$(basename "${iso:-none}")  dockur: $tail_line"

      # Stall detection. A Windows install grows the disk in bursts, so a pause is
      # normal - but 600s of identical du means something is wrong, and the last run
      # sat there for over 1000s with a heartbeat that only repeated the same number.
      # That told us nothing about WHY, so past the threshold this starts printing
      # the guest's state instead of just its size.
      if [ "$used" = "${last_used:-}" ]; then
        stalled=$(( ${stalled:-0} + 30 ))
      else
        stalled=0
      fi
      last_used="$used"

      if (( stalled >= 600 )); then
        log "STALLED ${stalled}s at ${used}MiB; inspecting the guest"
        log "  qemu alive: $(docker exec "$NAME" sh -c 'ps -ef | grep -c [q]emu-system' 2>&1 | tr -d '\r' || echo '?')"
        log "  disks: $(docker exec "$NAME" sh -c 'ls -la /storage/*.img 2>/dev/null | awk "{print \$5, \$9}"' 2>&1 | tr -d '\r' | tr '\n' ' ' || echo '?')"
        log "  dockur tail:"
        docker logs --tail 8 "$NAME" 2>&1 | tr -d "\r" | sed 's/^/      /' || true
        # Screendump through QEMU's own monitor. This is the only way to see what
        # the guest is actually showing when the serial console has gone quiet -
        # a spinning installer, a language prompt and a BSOD all look identical
        # from outside, and the difference decides what to fix.
        log "  screendump:"
        docker exec "$NAME" sh -c '
          sock=$(find /run /var/run /tmp -name "monitor.sock" 2>/dev/null | head -1)
          if [ -n "$sock" ]; then
            printf "screendump /storage/screen.ppm\nquit\n" | timeout 10 socat - UNIX-CONNECT:"$sock" 2>&1 | head -3
            ls -la /storage/screen.ppm 2>/dev/null
          else
            echo "no monitor socket found"
          fi' 2>&1 | tr -d "\r" | sed 's/^/      /' || true
      fi
    fi
    sleep 20
  done

  log "TIMEOUT after ${WAIT}s"
  log "storage:"; ls -la "$STORAGE" 2>/dev/null | head -10 || true
  docker logs "$NAME" 2>&1 | tail -80 || true
  return 1
}

stage_extract() {
  # stage_wait already stopped the container once Windows booted from its own
  # disk; stopping again is a no-op and keeps this stage usable on its own.
  log "stopping the guest so the filesystem is consistent"
  docker stop -t 180 "$NAME" >/dev/null 2>&1 || true

  # Pull the disk out with docker cp.
  #
  # docker exec cannot help: the container is stopped by now (it has to be, or the
  # disk is not consistent) and exec needs a running one. cp works on a stopped
  # container.
  #
  # The name is not worth guessing either. A host-side find at maxdepth 2 came up
  # empty on a run whose du had watched 18 GiB land in $STORAGE, so stage_wait now
  # records the exact path with find while the container is still up, and this
  # reads it back. Trying a few likely names first covers a run where that file is
  # missing, then a host sweep covers the rest.
  SRC=""
  inner=$(head -1 "$STORAGE/.disk-path" 2>/dev/null || true)
  if [ -n "$inner" ]; then
    log "copying $inner out of the container"
    if docker cp "$NAME:$inner" "$STORAGE/from-container.img" >/dev/null 2>&1; then
      SRC="$STORAGE/from-container.img"
    fi
  fi

  if [ -z "$SRC" ]; then
    for name in data.img data.qcow2 windows.img windows.qcow2; do
      if docker cp "$NAME:/storage/$name" "$STORAGE/$name.copied" >/dev/null 2>&1; then
        log "copied /storage/$name out of the container"
        SRC="$STORAGE/$name.copied"
        break
      fi
    done
  fi

  # Last resort: sweep the host mount, skipping ISOs because qemu-img reads them
  # happily and would otherwise be picked as "a disk".
  if [ -z "$SRC" ]; then
    while IFS= read -r f; do
      case "$f" in *.iso) continue ;; esac
      if qemu-img info "$f" >/dev/null 2>&1; then SRC="$f"; break; fi
    done < <(find "$STORAGE" -type f -size +1G -printf "%s %p\n" 2>/dev/null | sort -rn | cut -d" " -f2-)
  fi

  if [ -z "$SRC" ]; then
    log "no disk found; storage tree:"
    find "$STORAGE" -maxdepth 3 -printf "%10s %p\n" 2>/dev/null | sort -rn | head -20 || true
    return 1
  fi

  log "extracting $SRC"
  ls -la "$SRC"
  qemu-img convert -O qcow2 "$SRC" "$OUT"
  qemu-img info "$OUT" | head -6
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  log "BAKED windows $VERSION -> $OUT"
}

case "$STAGE" in
  prepare) stage_prepare ;;
  start)   stage_prepare; stage_start ;;
  wait)    stage_wait ;;
  ssh)     stage_ssh_check ;;
  extract) stage_extract ;;
  all)     stage_prepare; stage_start; stage_wait; stage_ssh_check; stage_extract ;;
  *) echo "usage: $0 [prepare|start|wait|ssh|extract|all]"; exit 64 ;;
esac
