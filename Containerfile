# agent-worker Windows sandbox — self-owned runtime, pre-baked disk, boot only.
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
ARG REGISTRY=git.agent.svc.cluster.local/root
FROM ${REGISTRY}/udfread:1.2.0 AS udfread
FROM ${REGISTRY}/qemu:750

# The build proxy must NOT be used for the in-cluster artifact mirror (it has no
# route to it -> 404). This mirrors the desktop images' NO_PROXY.
ENV NO_PROXY=localhost,127.0.0.1,.svc.cluster.local,.svc,artifact.worker.svc.cluster.local \
    no_proxy=localhost,127.0.0.1,.svc.cluster.local,.svc,artifact.worker.svc.cluster.local

# udfread: the Windows ISO reader used by the installer; kept because the boot
# path's disk detection references it. (Copied via a named stage because
# COPY --from does not expand ARGs.)
COPY --from=udfread /udfread /usr/bin/udfread

# --- pre-baked guest disk + boot state -------------------------------------
# The guest is already installed (data.qcow2 => DISK_FMT=qcow2), so no installer
# runs. The UEFI identity/ROM/vars and the version marker travel alongside it.
# EMBED_DISK=0 drops the (multi-GB) disk from the image; the disk is then
# fetched at run time from the artifact-published golden base and a per-sandbox
# overlay is created (see golden-disk.sh + GOLDEN_DISK_URL). Default 1 keeps the
# historical embedded-disk image.
ARG EMBED_DISK=1
COPY disk/data.qcow2  /storage/data.qcow2.embedded
RUN if [ "${EMBED_DISK}" = "1" ]; then mv /storage/data.qcow2.embedded /storage/data.qcow2; else rm -f /storage/data.qcow2.embedded; fi
# Guest identity + version marker (image-owned). The UEFI firmware itself is
# NOT shipped: boot.sh generates OVMF_CODE_4M.fd / OVMF_VARS_4M.fd from the
# base image's /usr/share/OVMF on first boot. A pre-seeded ROM was the wrong
# size (8.8 MB > the 8 MB pflash window) and QEMU refused to start
# ("combined size of system firmware exceeds 8388608 bytes").
COPY disk-support/windows.base /storage/windows.base
COPY disk-support/windows.boot /storage/windows.boot
COPY disk-support/windows.mac  /storage/windows.mac
COPY disk-support/windows.ver  /storage/windows.ver

# --- vendored Windows runtime ---------------------------------------------
# Boot scripts (vendor/run already includes the assets/ subdirectory).
COPY --chmod=755 vendor/run/ /run/

# --- agent-worker + easystream (both boot-fetched by the guest) ------------
# The guest launcher downloads both on every boot (nginx :8090 /worker and
# /easystream): an upgrade is an image change, never a golden rebake. There is
# NO disk fallback — the container always serves them.
#
# Both binaries come from their GitHub releases (the source repos are the source
# of truth; the sandbox image just ships what they published). No binaries are
# staged into the build context any more.
ARG WORKER_VERSION=v0.0.1
ARG EASYSTREAM_VERSION=v0.0.1
ARG RELEASE_PROXY
ARG RELEASE_CACHEBUST
RUN set -eux; echo "release cachebust ${RELEASE_CACHEBUST}"; \
    mkdir -p /opt/agent-worker; \
    for spec in \
      "agent-worker|https://github.com/easydev-org/easyworker/releases/download/${WORKER_VERSION}/agent-worker-windows-amd64.exe" \
      "easystream|https://github.com/easydev-org/easystream-windows/releases/download/${EASYSTREAM_VERSION}/easystream-windows-amd64.exe" ; do \
      name="${spec%%|*}"; url="${spec#*|}"; \
      curl -fsSL ${RELEASE_PROXY:+-x "${RELEASE_PROXY}"} -o "/opt/agent-worker/${name}" "${url}"; \
    done; \
    chmod 755 /opt/agent-worker/agent-worker /opt/agent-worker/easystream
# The real launch logic. The on-disk loader (bootstrap.vbs, the ONLY file on the
# golden disk) fetches this every boot, so ALL launch behaviour is an image
# change (no golden-disk rebake).
COPY --chmod=644 guest/oem.cmd           /opt/agent-worker/oem.cmd

# --- token/worker bridge (no sidecar) -------------------------------------
COPY --chmod=644 00-token.conf /etc/nginx/conf.d/00-token.conf
COPY --chmod=755 start.sh      /run/start.sh
# Runtime disk materializer (fetches the artifact golden base + overlay); a
# no-op unless GOLDEN_DISK_URL is set.
COPY --chmod=755 golden-disk.sh /run/golden-disk.sh

# Display mode: 1024x768, matching the macOS/Linux/Android sandboxes.
#
# The OLD `-global virtio-vga.xres/yres` was silently IGNORED (QEMU warned
# "invalid class name" and the guest came up at 640x480): xres/yres are DEVICE
# properties, not -global ones. Pass them on the device instead.
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
    ARGUMENTS="-device virtio-vga,xres=1024,yres=768"

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

VOLUME /storage
EXPOSE 3389 22 48080 8090
ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]
