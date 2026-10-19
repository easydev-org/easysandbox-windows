#!/usr/bin/env bash
# sandbox.sh — the ENTIRE Windows-sandbox runtime, in one file.
#
# This replaces the ~25 vendored boot scripts (vendor/run/*.sh) that were copied
# from the upstream dockur/qemu project. That project supports installing every
# Windows version from an ISO; this sandbox only ever BOOTS a pre-baked disk, so
# the installer, the answer files, samba, the VNC/noVNC web client, the version
# catalogue and the multi-machine/CPU matrices were all dead weight.
#
# What it does, in order:
#   1. materialise the golden disk (golden-disk.sh, kept separate)
#   2. network : bridge `docker` (172.30.0.1/24) + tap `qemu` + dnsmasq + NAT
#   3. audio   : a FIFO/relay pair QEMU writes to (AUDIO=Y), captured in-guest
#   4. firmware: copy OVMF code/vars into /storage/windows.{rom,vars}
#   5. serve   : nginx :8090 (/env,/worker,/easystream,/oem.cmd) + status ws
#   6. boot    : QEMU with the exact device set the sandbox needs
#
# Every external tool it needs (ip, iptables, dnsmasq, qemu-system-x86_64,
# nginx, websocketd, python3) is already in the base image.
set -Eeuo pipefail

# ── configuration (env overrides everything) ────────────────────────────────
APP="${APP:-Windows}"
PROCESS="${PROCESS:-windows}"
VERSION="${VERSION:-win11}"
STORAGE="${STORAGE:-/storage}"
QEMU_DIR="${QEMU_DIR:-/run/shm}"
DISK_FILE="${DISK_FILE:-/storage/data.qcow2}"
RAM_SIZE="${RAM_SIZE:-32768M}"
CPU_CORES="${CPU_CORES:-8}"
DISK_SIZE="${DISK_SIZE:-128G}"
MAC="${MAC:-}"
MTU="${MTU:-}"            # empty = inherit the node's uplink MTU (see detect_mtu)
UPLINK_DEV="${UPLINK_DEV:-eth0}"   # the pod's NIC; the guest's traffic NATs out here

BRIDGE="${BRIDGE:-docker}"
TAP="${TAP:-qemu}"
BRIDGE_IP="${BRIDGE_IP:-172.30.0.1}"
GUEST_IP="${GUEST_IP:-172.30.0.2}"
SYSTEM_IP="${SYSTEM_IP:-172.30.0.254}"
MASK="${MASK:-255.255.255.0}"
PREFIX="${PREFIX:-24}"

EST_PORT="${EAZYSTREAM_PORT:-48079}"
EST_HTTP_PORT="${EAZYSTREAM_HTTP_PORT:-48078}"
USER_PORTS="${USER_PORTS:-48080}"

AUDIO="${AUDIO:-N}"
SOUND="${SOUND:-intel-hda}"

ARGUMENTS="${ARGUMENTS:-}"
LOGO="${LOGO:-Y}"
DEBUG="${DEBUG:-N}"
SHUTDOWN="${SHUTDOWN:-Y}"

WROOT=/opt/agent-worker
mkdir -p "$STORAGE" "$QEMU_DIR"

log()  { printf '\033[1;34m❯\033[0m %s\n' "$*"; }
warn() { printf '\033[1;31m❯ Warning:\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m❯ ERROR:\033[0m %s\n' "$*" >&2; }
enabled() { case "${1^^}" in Y|YES|TRUE|1|ON) return 0;; *) return 1;; esac; }

# ── 1. golden disk (our own script; fetches the artifact base + seeds) ──────
if [ -f /run/golden-disk.sh ]; then . /run/golden-disk.sh; fi
if [ ! -s "$DISK_FILE" ]; then
  err "No guest disk at $DISK_FILE (this image boots a pre-baked disk and never installs Windows)."
  exit 69
fi

# The guest does NOT inherit the pod's env, so the few per-pod values it needs
# (the pre-auth token + the deployment HTTP proxy) are published as KEY=VALUE
# lines that nginx serves at :8090/env (00-token.conf).
{
  printf 'WORKER_TOKEN=%s\n' "${WORKER_TOKEN:-}"
  printf 'SANDBOX_PROXY=%s\n' "${SANDBOX_PROXY:-${HTTP_PROXY:-}}"
  # The guest launcher starts easystream with this as its CONTROL token, so a
  # leaked port cannot drive the guest. It is the same secret as WORKER_TOKEN,
  # and the worker presents it on est (Auth frame) / HTTP (?token=). VIEW stays
  # open (no view token) so anyone may watch.
  printf 'EAZYSTREAM_CONTROL_TOKEN=%s\n' "${EAZYSTREAM_CONTROL_TOKEN:-${WORKER_TOKEN:-}}"
  printf 'EAZYSTREAM_VIEW_TOKEN=%s\n' "${EAZYSTREAM_VIEW_TOKEN:-}"
} > "$QEMU_DIR/env"
chmod 644 "$QEMU_DIR/env" 2>/dev/null || true

# Drop any firmware an EARLIER image left on the persistent PVC: the OVMF build
# is image-owned (from /usr/share/OVMF), and a mismatched size makes QEMU refuse
# to start ("combined size of system firmware exceeds 8388608 bytes").
rm -f "$STORAGE/$PROCESS.rom" "$STORAGE/$PROCESS.vars" \
      "$STORAGE/uefi.rom" "$STORAGE/uefi.vars" \
      "$STORAGE/secure.rom" "$STORAGE/secure.vars" 2>/dev/null || true

# ── 2. network: bridge + tap + dnsmasq + NAT ───────────────────────────────
# The guest reaches the pod (and thus the artifact registry + nginx :8090) over
# this bridge; the tap carries the VM's traffic.
setup_network() {
  enabled "${NETWORK:-Y}" || return 0
  log "Initializing network..."

  # Deterministic MAC from a stable container id (matches the old behaviour:
  # the guest keeps its identity across restarts of the same pod).
  if [ -z "$MAC" ]; then
    MAC=$(cat "/$STORAGE/$PROCESS.mac" 2>/dev/null | tr -d '\r\n' || true)
  fi
  if [ -z "$MAC" ]; then
    local cid; cid=$(hostname)
    MAC=$(printf '%s' "$cid" | md5sum | sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/02:\1:\2:\3:\4:\5/')
    MAC="${MAC^^}"
  fi
  printf '%s' "$MAC" > "$STORAGE/$PROCESS.mac" 2>/dev/null || true

  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

  # Bridge (the guest's gateway).
  ip link add dev "$BRIDGE" type bridge 2>/dev/null || true
  ip link set "$BRIDGE" mtu "$MTU" 2>/dev/null || true
  ip address add "$BRIDGE_IP/$PREFIX" dev "$BRIDGE" 2>/dev/null || true
  ip link set "$BRIDGE" up
  # NAT networking is IPv4-only.
  sysctl -w "net.ipv6.conf.$BRIDGE.disable_ipv6=1" >/dev/null 2>&1 || true

  # Tap (the VM's NIC, enslaved to the bridge).
  ip tuntap add dev "$TAP" mode tap 2>/dev/null || true
  ip link set "$TAP" mtu "$MTU" 2>/dev/null || true
  ip link set dev "$TAP" up promisc on
  sysctl -w "net.ipv6.conf.$TAP.disable_ipv6=1" >/dev/null 2>&1 || true
  ip link set dev "$TAP" master "$BRIDGE"

  # dnsmasq: DHCP for the single guest + the in-cluster names.
  rm -f /var/run/dnsmasq.pid /etc/resolv.dnsmasq
  /usr/sbin/dnsmasq \
    --dhcp-authoritative \
    --dhcp-range="$GUEST_IP,$GUEST_IP" \
    --dhcp-host="$MAC,,$GUEST_IP,$APP,1h" \
    --dhcp-option=option:netmask,"$MASK" \
    --dhcp-option=option:router,"$BRIDGE_IP" \
    --dhcp-option=option:dns-server,"$BRIDGE_IP" \
    --dhcp-option=option:mtu,"$MTU" \
    --interface="$BRIDGE" --bind-interfaces --no-ping \
    --address=/host.lan/$BRIDGE_IP \
    --address=/system.lan/$SYSTEM_IP \
    --filter-AAAA \
    --pid-file=/var/run/dnsmasq.pid --log-facility=/var/log/dnsmasq.log

  # NAT: the guest's traffic leaves via eth0; pod-local ports are DNAT'd in.
  iptables -t nat -N QEMU_DNAT 2>/dev/null || true
  iptables -t nat -F QEMU_DNAT
  iptables -t nat -C PREROUTING -m addrtype --dst-type LOCAL -j QEMU_DNAT 2>/dev/null \
    || iptables -t nat -A PREROUTING ! -i "$BRIDGE" -m addrtype --dst-type LOCAL -m comment --comment QEMU_DNAT -j QEMU_DNAT
  iptables -t nat -C POSTROUTING -s "$BRIDGE_IP/$PREFIX" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s "$BRIDGE_IP/$PREFIX" ! -d "$BRIDGE_IP/$PREFIX" ! -o "$BRIDGE" -m comment --comment QEMU_DNAT -j MASQUERADE
  iptables -t nat -A QEMU_DNAT -m comment --comment QEMU_DNAT -j DNAT --to-destination "$GUEST_IP"
  iptables -t filter -C FORWARD -s "$BRIDGE_IP/$PREFIX" -j ACCEPT 2>/dev/null \
    || iptables -t filter -A FORWARD -s "$BRIDGE_IP/$PREFIX" -i "$BRIDGE" ! -o "$BRIDGE" -j ACCEPT
  iptables -t filter -C FORWARD -d "$GUEST_IP/32" -j ACCEPT 2>/dev/null \
    || iptables -t filter -A FORWARD -d "$GUEST_IP/32" ! -i "$BRIDGE" -o "$BRIDGE" -j ACCEPT
}

# ── host detection ─────────────────────────────────────────────────────────
# The vendored scripts probed the host so the sandbox worked on ANY node
# (Intel or AMD, apicv or not, a small pod or a big one). Keep that: never
# hard-code what the host reports, or the image only runs on the node it was
# built against.
host_cpu_flags() {
  local vendor vmx model flags
  vendor=$(awk -F': *' '/^vendor_id/{print $2; exit}' /proc/cpuinfo | tr -d ' ')
  vmx=$(sed -ne '/^vmx flags/s/^.*: //p' /proc/cpuinfo)
  model=$(awk -F': *' '/^model name/{print $2; exit}' /proc/cpuinfo | sed 's/^ *//')

  flags="host,kvm=on,l3-cache=on"
  enabled "${VM:-Y}" && flags+=",+hypervisor"
  # Host passthrough is intentionally non-migratable (full local feature set).
  flags+=",migratable=no"

  if [ "$vendor" = "GenuineIntel" ]; then
    flags+=",-vmx"                                   # nested virt off by default
    grep -qw tsc_scaling <<< "$vmx" && flags+=",+invtsc"
  else
    # AMD: invtsc only when the host advertises tsc_scale.
    grep -m1 '^flags' /proc/cpuinfo | grep -qw tsc_scale && flags+=",+invtsc"
  fi

  # Hyper-V enlightenments: passthrough, then drop what this CPU cannot
  # accelerate (an unsupported one makes Windows fail to boot).
  local hv="hv_passthrough"
  if [ "$vendor" = "GenuineIntel" ]; then
    grep -qw apicv <<< "$vmx" || hv+=",-hv-apicv,-hv-evmcs"
    case "$model" in
      "Intel Atom "*|"Intel Celeron "*|"Intel Pentium "*) hv+=",-hv-evmcs" ;;
    esac
  else
    grep -m1 '^flags' /proc/cpuinfo | grep -qw avic || hv+=",-hv-avic"
    hv+=",-hv-evmcs"
    # Windows guests on AMD KVM need arch_capabilities off.
    flags+=",arch_capabilities=off"
  fi
  printf '%s,%s' "$flags" "$hv"
}

# MTU: propagate the node's MTU (a smaller-than-standard one must reach the
# guest, or its TCP stalls). Jumbo frames are only used if the user asked.
detect_mtu() {
  local dev_mtu=""
  if [ -r "/sys/class/net/$UPLINK_DEV/mtu" ]; then dev_mtu=$(< "/sys/class/net/$UPLINK_DEV/mtu"); fi
  if [ -z "${MTU:-}" ]; then
    MTU="${dev_mtu:-0}"
  elif [ "$MTU" -gt 1500 ] 2>/dev/null; then
    MTU=1500
  fi
  if [ "$MTU" = "0" ]; then MTU=1500; fi
  GUEST_MTU="$MTU"
  return 0
}

# ── 3. audio: FIFO + relay (the guest captures via WASAPI loopback) ─────────
# QEMU writes the guest's audio to a FIFO; audio.py relays it to a socket that
# websocketd exposes (audio-ws.sock) — the same relay the upstream used.
AUDIO_OPTS=""
setup_audio() {
  enabled "$AUDIO" || return 0
  # Only q35 / pc / virt machines can host the sound device. MACHINE_TYPE is
  # parsed out of the -machine argument (defaults to q35).
  case "${MACHINE_TYPE:-q35}" in
    q35|pc|pc-i440fx-*|virt*) ;;
    *) warn "audio is not supported with machine type '${MACHINE_TYPE:-?}', ignoring AUDIO=Y."; AUDIO="N"; return 0;;
  esac
  local fifo="$QEMU_DIR/audio.fifo" sock="$QEMU_DIR/audio.sock"
  rm -f "$fifo" "$sock" /var/log/audio.log
  mkfifo -m 0600 "$fifo" || { warn "Failed to create audio FIFO"; AUDIO="N"; return 0; }
  python3 /run/audio.py "$fifo" "$sock" > /var/log/audio.log 2>&1 &
  echo $! > "$QEMU_DIR/audio.pid"
  # Wait for the relay to open the FIFO (it writes the WAV header once ready).
  local i; for i in $(seq 1 40); do [ -s /var/log/audio.log ] && break; sleep 0.25; done
  websocketd --unixsocket="$QEMU_DIR/audio-ws.sock" --binary=true \
    nc -U "$sock" > /dev/null 2>&1 &
  echo $! > "$QEMU_DIR/audio-ws.pid"
  AUDIO_OPTS=" -audiodev wav,id=snd,path=$fifo,out.frequency=48000,out.channels=2,out.format=s16"
  local model="${SOUND%%,*}"
  case "$model" in
    intel-hda|ich9-intel-hda)
      AUDIO_OPTS+=" -device $SOUND -device hda-output,audiodev=snd" ;;
    *)
      AUDIO_OPTS+=" -device $SOUND,audiodev=snd" ;;
  esac
}

# ── 4. firmware: OVMF code + vars ──────────────────────────────────────────
prepare_firmware() {
  local ovmf=/usr/share/OVMF
  local code="$ovmf/OVMF_CODE_4M.fd"
  local vars="$ovmf/OVMF_VARS_4M.fd"
  [ -s "$code" ] || { err "UEFI boot file ($code) not found"; exit 44; }
  [ -s "$vars" ] || { err "UEFI vars file ($vars) not found"; exit 45; }
  # Regenerate the ROM on every boot (it is cheap) so a stale PVC copy can never
  # win; the logo patch is best-effort.
  rm -f "$STORAGE/$PROCESS.rom.tmp"
  local logo="$QEMU_DIR/img/${PROCESS}.bmp"
  [ -s "$logo" ] || logo="$QEMU_DIR/img/qemu.bmp"
  if enabled "$LOGO" && [ -s "$logo" ] && [ -x /run/boot-logo ]; then
    /run/boot-logo "$logo" "$code" --output "$STORAGE/$PROCESS.rom.tmp" -q 2>/dev/null || rm -f "$STORAGE/$PROCESS.rom.tmp"
  fi
  [ -s "$STORAGE/$PROCESS.rom.tmp" ] || cp "$code" "$STORAGE/$PROCESS.rom.tmp"
  mv -f "$STORAGE/$PROCESS.rom.tmp" "$STORAGE/$PROCESS.rom"
  [ -s "$STORAGE/$PROCESS.vars" ] || cp "$vars" "$STORAGE/$PROCESS.vars"
}

# ── 5. nginx (:8090) + status websocket ────────────────────────────────────
start_servers() {
  nginx -e stderr || warn "nginx failed to start"
  websocketd --unixsocket="$QEMU_DIR/status-ws.sock" /run/socket.sh > /dev/null 2>&1 &
  echo $! > "$QEMU_DIR/status-ws.pid"
}

# ── 6. QEMU ────────────────────────────────────────────────────────────────
build_qemu_args() {
  local ram_mb="${RAM_SIZE%M}"; ram_mb="${ram_mb%G}"
  case "$RAM_SIZE" in *G) ram_mb=$(( ${RAM_SIZE%G} * 1024 ));; *M) ram_mb=${RAM_SIZE%M};; esac
  # Never ask for more than the POD's cgroup allows. /proc/meminfo reports the
  # NODE's memory (1 TiB here), so reading it made QEMU ask for 32 GiB inside a
  # 16 GiB pod and the container was OOM-killed. Read the cgroup limit instead
  # and leave ~1.5 GiB for the pod's own processes (nginx, dnsmasq, the relay).
  local limit_b limit_mb
  limit_b=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo 0)
  case "$limit_b" in ''|max|*[!0-9]*) limit_mb=0;; *) limit_mb=$(( limit_b / 1048576 ));; esac
  if [ "$limit_mb" -gt 0 ]; then
    local want=$(( limit_mb - 1536 ))
    [ "$want" -lt 1024 ] && want=1024
    if [ "$ram_mb" -gt "$want" ]; then
      warn "RAM_SIZE ${RAM_SIZE} exceeds the pod limit (${limit_mb}MB); using ${want}MB."
      ram_mb=$want
    fi
  fi

  ARGS="-nodefaults"
  ARGS+=" -machine type=q35,smm=off,graphics=off,vmport=off,dump-guest-core=off,hpet=off,accel=kvm"
  ARGS+=" -enable-kvm"
  ARGS+=" -global kvm-pit.lost_tick_policy=discard"
  # CPU is composed from the HOST's vendor/features (Intel/AMD, apicv, avic,
  # tsc_scaling) so the image runs on any node — see host_cpu_flags().
  ARGS+=" -cpu $(host_cpu_flags)"
  ARGS+=" -smp $CPU_CORES,sockets=1,dies=1,cores=$CPU_CORES,threads=1"
  ARGS+=" -m ${ram_mb}M"
  ARGS+=" -name $APP,process=$PROCESS"
  ARGS+=" -smbios type=1,serial=210235A4MM5237C00024"
  ARGS+=" -pidfile $QEMU_DIR/qemu.pid"
  # DISPLAY=none: the guest streams its own screen over est/H.264.
  ARGS+=" -display none -vga none"
  ARGS+=" -monitor unix:$QEMU_DIR/monitor.sock,server=on,wait=off,nodelay=on"
  ARGS+=" -serial mon:stdio"
  ARGS+=" -device qemu-xhci,id=xhci,p2=7,p3=7"
  ARGS+=" -device usb-tablet"
  ARGS+=" -netdev tap,id=hostnet0,ifname=$TAP,script=no,downscript=no"
  ARGS+=" -device virtio-net-pci,id=net0,netdev=hostnet0,romfile=,mac=$MAC,host_mtu=$MTU"
  # `nocow=on` (COW-filesystem hint) is a `qemu-img create/convert` option, NOT
  # a -drive one; golden-disk.sh owns disk creation, so nothing goes here.
  ARGS+=" -drive file=$DISK_FILE,id=data3,format=qcow2,cache=none,aio=native,discard=unmap,detect-zeroes=on,if=none"
  ARGS+=" -device virtio-scsi-pci,id=data3,bus=pcie.0,addr=0xa,iothread=io2,hotplug=off"
  ARGS+=" -device scsi-hd,drive=data3,bus=data3.0,channel=0,scsi-id=0,lun=0,rotation_rate=1,bootindex=3"
  ARGS+=" -object iothread,id=io2"
  ARGS+=" -rtc base=localtime"
  ARGS+=" -global ICH9-LPC.disable_s3=1 -global ICH9-LPC.disable_s4=1"
  ARGS+=" -drive file=$STORAGE/$PROCESS.rom,if=pflash,unit=0,format=raw,readonly=on"
  ARGS+=" -drive file=$STORAGE/$PROCESS.vars,if=pflash,unit=1,format=raw"
  ARGS+=" -object rng-random,id=objrng0,filename=/dev/urandom"
  ARGS+=" -device virtio-rng-pci,rng=objrng0,id=rng0,bus=pcie.0"
  ARGS+="$AUDIO_OPTS"
  ARGS+=" -fw_cfg name=opt/org.tianocore/UninstallMemAttrProtocol,string=y"
  # 1024x768 (matches the other sandboxes); the EDID is what Windows adopts.
  # NOTE: ARGUMENTS must NOT also carry a -device virtio-vga (the Containerfile
  # ENV used to) or QEMU gets the device twice and refuses to start.
  ARGS+=" -device virtio-vga,xres=1024,yres=768"
  # NB: must not end on a bare `[ ... ] &&` — when ARGUMENTS is empty that
  # returns 1 and `set -e` aborts the whole script.
  if [ -n "$ARGUMENTS" ]; then ARGS+=" $ARGUMENTS"; fi
  return 0
}

# ── run ────────────────────────────────────────────────────────────────────
# Clamp CPU_CORES to what the node actually has (a pod can be limited to fewer
# cores than the image asks for).
_ncores=$(grep -c '^processor' /proc/cpuinfo)
[ "$CPU_CORES" -gt "$_ncores" ] 2>/dev/null && { warn "CPU_CORES $CPU_CORES exceeds the $_ncores logical cores available; using $_ncores."; CPU_CORES="$_ncores"; }
detect_mtu
setup_network
setup_audio
prepare_firmware
start_servers
build_qemu_args

log "Starting $APP..."
log "Booting $APP using QEMU $(qemu-system-x86_64 --version | awk 'NR==1{print $4}')..."

# QEMU's serial console is teed to a pty so the container log shows the boot
# status (the sed strips the ANSI/EFI noise the upstream filtered too).
pipe="$QEMU_DIR/qemu.pipe"
rm -f "$pipe"; mkfifo "$pipe"
tee "$QEMU_DIR/qemu.pty" < "$pipe" &
output=$!

qemu-system-x86_64 $ARGS > "$pipe" 2>&1 &
pid=$!

cleanup() {
  kill "$pid" 2>/dev/null || true
  kill "$output" 2>/dev/null || true
  for f in "$QEMU_DIR"/audio.pid "$QEMU_DIR"/audio-ws.pid "$QEMU_DIR"/status-ws.pid; do
    [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null || true
  done
  [ -f /var/run/dnsmasq.pid ] && kill "$(cat /var/run/dnsmasq.pid)" 2>/dev/null || true
}
trap cleanup TERM INT

rc=0
wait "$pid" || rc=$?
cleanup
exit "$rc"
