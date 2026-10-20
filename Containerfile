# easyworker Windows sandbox — self-owned runtime, pre-baked disk, boot only.
#
# No upstream sandbox image is referenced. The runtime is the generic qemux/qemu
# Debian base plus a vendored copy of the Windows boot scripts (vendor/run,
# taken once from the upstream project and kept here), the virtio drivers, and
# the token bridge.
#
# Only the boot path runs (needsInstall -> hasData && hasBootMarker ->
# bootWindows). The upstream image also carries the whole Windows *installer*:
# samba (shared folders), wimtools/cabextract/gcab/mtools/xmlstarlet/dos2unix
# (unattended-answer editing + ISO/WIM extraction), python3-pip + blinter, and
# /var/drivers.txz. None of that is reachable on the boot path, so it is not
# installed here. Shared folders are off (SAMBA=N).
#
# ARG REGISTRY must be declared BEFORE the first FROM that uses it. buildx
# validates this (UndefinedArgInFrom / InvalidDefaultArgInFrom), and putting it
# after the golden stage made `FROM ${REGISTRY}/qemu:7.50` expand to "/qemu:7.50"
# and fail with "invalid reference format".
ARG REGISTRY=docker.io/qemux

# The golden disk is published as ONE image whose LAYERS are consecutive pieces
# of the qcow2 (15 layers, 14 GiB) because it is far above what a registry accepts
# in a single layer.
#
# Those layers are DATA ONLY — the image has no /bin/sh, so a `RUN cat /data.part*
# > /data.qcow2` inside it fails with
#   runc run failed: exec: "/bin/sh": stat /bin/sh: no such file or directory
# The pieces are therefore copied into a stage that DOES have a shell, and joined
# there. BuildKit still pulls and caches the 15 layers itself; only the result is
# carried forward, so no second 14 GiB copy is ever made.
ARG GOLDEN_DISK_IMAGE=ghcr.io/easydev-org/golden-disk-windows:base
FROM ${GOLDEN_DISK_IMAGE} AS golden

FROM ${REGISTRY}/udfread:1.2.0 AS udfread
FROM ${REGISTRY}/qemu:7.50

# No proxy settings: this file describes the image, not the build environment.
# Egress configuration belongs to whoever runs the build.

# udfread: the Windows ISO reader used by the installer; kept because the boot
# path's disk detection references it. (Copied via a named stage because
# COPY --from does not expand ARGs.)
COPY --from=udfread /udfread /usr/bin/udfread

# --- pre-baked guest disk + boot state -------------------------------------
# The guest is already installed (data.qcow2 => DISK_FMT=qcow2), so no installer
# runs. The UEFI identity/ROM/vars and the version marker travel alongside it.
#
# The disk is ALWAYS embedded. There used to be an EMBED_DISK=0 mode that fetched
# it at run time from an in-cluster artifact store; that tied the image to one
# environment and made every start pay a multi-GB download for immutable golden
# state. A large layer is the honest cost of carrying the disk.
#
# It lands in /opt/golden-disk, NOT /storage: /storage is where the writable
# volume is mounted, so a copy there would be hidden by the mount. golden-disk.sh
# uses this file as the qcow2 backing for the per-sandbox overlay.
#
# The disk itself is copied in at the VERY END of this file — see the note there.
# Keeping it last means any earlier failure (a missing release asset, a bad apt
# mirror, a wrong FROM tag) costs nothing, instead of pulling 14 GiB first and
# then discovering the problem.
# Guest identity + version marker (image-owned). The UEFI firmware itself is
# NOT shipped: boot.sh generates OVMF_CODE_4M.fd / OVMF_VARS_4M.fd from the
# base image's /usr/share/OVMF on first boot. A pre-seeded ROM was the wrong
# size (8.8 MB > the 8 MB pflash window) and QEMU refused to start
# ("combined size of system firmware exceeds 8388608 bytes").
COPY disk-support/windows.base /storage/windows.base
COPY disk-support/windows.boot /storage/windows.boot
COPY disk-support/windows.mac  /storage/windows.mac
COPY disk-support/windows.ver  /storage/windows.ver

# --- sandbox runtime -------------------------------------------------------
# The whole boot path is ONE script (sandbox.sh): network + audio + firmware +
# nginx + QEMU. vendor/run now holds only the two helpers it calls:
# audio.py (the FIFO->socket relay) and socket.sh (the status websocket).
COPY --chmod=755 vendor/run/ /run/
COPY --chmod=755 sandbox.sh    /run/entry.sh

# --- easyworker + easystream (both boot-fetched by the guest) ------------
# The guest launcher downloads both on every boot (nginx :8090 /worker and
# /easystream): an upgrade is an image change, never a golden rebake. There is
# NO disk fallback — the container always serves them.
#
# Both binaries come from their GitHub releases (the source repos are the source
# of truth; the sandbox image just ships what they published). No binaries are
# staged into the build context any more.
ARG WORKER_VERSION=v0.1.0
ARG EASYSTREAM_VERSION=v0.1.0
ARG RELEASE_PROXY
ARG RELEASE_CACHEBUST
RUN set -eux; echo "release cachebust ${RELEASE_CACHEBUST}"; \
    mkdir -p /opt/easyworker; \
    for spec in \
      "easyworker|https://github.com/easydev-org/easyworker/releases/download/${WORKER_VERSION}/easyworker-windows-amd64.exe" \
      "easystream|https://github.com/easydev-org/easystream-windows/releases/download/${EASYSTREAM_VERSION}/easystream-windows-amd64.exe" ; do \
      name="${spec%%|*}"; url="${spec#*|}"; \
      curl -fsSL ${RELEASE_PROXY:+-x "${RELEASE_PROXY}"} -o "/opt/easyworker/${name}" "${url}"; \
    done; \
    chmod 755 /opt/easyworker/easyworker /opt/easyworker/easystream
# The guest launch logic. The on-disk loader (bootstrap.vbs, the ONLY file on
# the golden disk) fetches this every boot, so ALL launch behaviour is an image
# change (no golden-disk rebake).
COPY --chmod=644 guest/oem.cmd           /opt/easyworker/oem.cmd

# --- token/worker bridge (no sidecar) -------------------------------------
COPY --chmod=644 00-token.conf /etc/nginx/conf.d/00-token.conf
# Runtime disk materializer (fetches the artifact golden base + overlay); a
# no-op unless GOLDEN_DISK_URL is set.
COPY --chmod=755 golden-disk.sh /run/golden-disk.sh

# Display + resources. sandbox.sh owns the FULL QEMU command line (including the
# 1024x768 virtio-vga device, matching the macOS/Linux/Android sandboxes), so
# ARGUMENTS is an empty EXTRA-args slot here — putting the VGA device in both
# places gave QEMU the device twice. RAM_SIZE is advisory: sandbox.sh clamps it
# to the pod's cgroup limit (this pod is 16 GiB, not the node's 1 TiB).
ENV VERSION=win11 \
    EDITION=pro \
    CPU_CORES=8 \
    DISK_SIZE=128G \
    RAM_SIZE=32768M \
    DISK_FMT=qcow2 \
    MANUAL=N \
    SAMBA=N \
    USER_PORTS=48080 \
    DISK_FILE=/storage/data.qcow2 \
    ARGUMENTS=""

# Default golden disk (disk-less images): baked into ENV so the VM boots even
# when no GOLDEN_DISK_URL is injected; a pod env still overrides it.
ARG GOLDEN_DISK_URL=""
ENV GOLDEN_DISK_URL=${GOLDEN_DISK_URL}

# The worker (in the guest) streams the screen itself as H.264 (/stream/ws), so
# the QEMU VNC display and the noVNC web client are dead weight: no VNC, no
# noVNC assets, no extra port. (DISPLAY=none keeps the qemu command free of any
# -display/-vnc flags.)
ENV DISPLAY=none

# noVNC is only used by the VNC display we just turned off. Drop its assets.
RUN rm -rf /usr/share/novnc /usr/share/novnc-* 2>/dev/null || true

# --- the golden disk, LAST ON PURPOSE ---------------------------------------
#
# Everything above is cheap and fails fast. This step pulls 14 GiB and produces
# the largest layer in the image, so it runs only after the build has proven it
# can succeed. Placed earlier, a missing release asset or a wrong base tag would
# still cost a full 14 GiB download first — which is exactly what happened while
# getting this workflow working.
#
# The pieces are copied here rather than joined in the `golden` stage because that
# stage is the disk image itself: pure data, with no /bin/sh to run `cat` with.
#
# One RUN keeps the finished disk in a single layer; copying the pieces and then
# copying the result separately would store 14 GiB twice.
COPY --from=golden /data.part* /tmp/golden/
RUN mkdir -p /opt/golden-disk \
    && cat /tmp/golden/data.part* > /opt/golden-disk/data.qcow2 \
    && rm -rf /tmp/golden \
    && ls -l /opt/golden-disk/data.qcow2

# The upstream dockur boot scripts (installer, samba, answer files, the version
# catalogue, the VNC web client, the multi-machine matrices) are NOT shipped:
# sandbox.sh only ever boots the pre-baked disk. /run/check.sh (the old
# healthcheck) is gone too — the deployment defines no probe.
RUN rm -rf /var/www /etc/samba /var/lib/samba 2>/dev/null || true

VOLUME /storage
EXPOSE 3389 22 48080 8090
ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]
