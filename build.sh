#!/usr/bin/env bash
# Build and push the easyworker Windows (win11) VM image.
#
#   ./agent-toolchain/vm/windows/build.sh [base|devtools]
#
# The image is a self-owned runtime (the generic qemux/qemu base + the vendored
# boot scripts in vendor/) wrapped around a pre-baked guest disk. Supply a
# *defragged* disk (uncompressed 1 MiB clusters) or the OCI layer will not
# compress — see repack-disk.sh.
#
# The worker binary is boot-fetched by the guest from nginx :8090 /worker; the
# windows binary COPYed here is the disk fallback.
#
# Expected layout (git-ignored, staged outside the repo):
#   <variant>/disk/data.qcow2      the guest disk
#   <variant>/disk-support/        windows.{base,boot,mac,rom,vars,ver}
#
# Prerequisites: dist/easyworker-windows-amd64.exe (scripts/build-all.sh).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/../../.." && pwd)"

VARIANT="${1:-base}"
case "$VARIANT" in
  base|devtools) ;;
  *) echo "usage: build.sh [base|devtools]" >&2; exit 2 ;;
esac

# Base images (qemu, udfread) come from the official docker.io/qemux path; the
# cluster buildkitd's registry mirror serves them from the in-cluster artifact.
REGISTRY="${REGISTRY:-artifact.worker.svc.cluster.local}"
REGISTRY_NS="${REGISTRY_NS-qemux}"
# Where the built image is PUSHED (always the in-cluster artifact registry).
PUSH_REGISTRY="${PUSH_REGISTRY:-artifact.worker.svc.cluster.local}"
NAMESPACE="${NAMESPACE:-sandbox}"
NAME="${NAME:-sandbox-windows}"
TAG="${TAG:-${VARIANT}}"
# Default golden disk baked into the image ENV (disk-less images): the VM boots
# even when the caller/deployment did NOT inject GOLDEN_DISK_URL (a pod env
# still overrides it). Otherwise dockur would try to INSTALL Windows.
# devtools3 = the minimal on-disk LOADER (bootstrap.vbs), which just
# pulls host.lan:8090/oem.cmd and runs it. All launch logic now lives in
# the IMAGE (guest/oem.cmd), so launch changes never need a disk rebake.
GOLDEN_DISK_URL="${GOLDEN_DISK_URL:-http://artifact.worker.svc.cluster.local/artifacts/generic/golden-windows/11/data-devtools3.qcow2}"
DEST="${PUSH_REGISTRY}/${NAMESPACE}/${NAME}:${TAG}"
BUILDKIT="${BUILDKIT_ADDR:-tcp://buildkitd.agent.svc.cluster.local:1234}"
PROXY="${PROXY:-http://mihomo.develop.svc.cluster.local:7890}"
# NEVER proxy in-cluster traffic (buildkitd gRPC, artifact registry, DNS):
# a proxy here breaks `buildctl` and image pulls. Both spellings are needed —
# some tools read `no_proxy`, others `NO_PROXY`.
NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,.svc,.svc.cluster.local,.cluster.local,artifact.worker.svc.cluster.local,buildkitd.worker.svc.cluster.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16}"
no_proxy="${no_proxy:-$NO_PROXY}"
export NO_PROXY no_proxy
DISK="${DISK:-${DIR}/${VARIANT}/disk/data.qcow2}"
SUPPORT="${SUPPORT:-${DIR}/${VARIANT}/disk-support}"
# Both guest binaries come from GitHub releases (see the Containerfile), so the
# build only needs the versions, not staged files.
WORKER_VERSION="${WORKER_VERSION:-v0.1.0}"
EASYSTREAM_VERSION="${EASYSTREAM_VERSION:-v0.1.0}"
BUILDCTL="${BUILDCTL:-$(command -v buildctl || true)}"
# The guest disk is ALWAYS embedded in the image.
#
# There used to be a disk-less mode that fetched the disk at run time from an
# in-cluster artifact store. It worked, but it tied the image to that store, made
# every pod start pay for a 14 GiB download, and — the reason it is gone — meant
# the project could not be built or run anywhere the store was not reachable. The
# disk is immutable golden state, so a multi-GB image layer is the honest
# representation of it.

for f in "${DIR}/Containerfile" "${DIR}/00-token.conf" "${DIR}/sandbox.sh" "${DIR}/golden-disk.sh"; do
  [ -e "$f" ] || { echo "missing $f" >&2; exit 1; }
done
[ -e "${DISK}" ] || { echo "missing disk ${DISK}: run fetch-golden.sh first" >&2; exit 1; }
[ -d "${SUPPORT}" ] || { echo "missing support dir ${SUPPORT}" >&2; exit 1; }
[ -n "${BUILDCTL}" ] || { echo "buildctl not found (set BUILDCTL)" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/disk"
cp "${DIR}/Containerfile" "${WORK}/Dockerfile"
cp "${DIR}/00-token.conf" "${WORK}/"
# The single boot script (replaces the vendored vendor/run/*.sh boot chain).
cp "${DIR}/sandbox.sh" "${WORK}/"
# NOTE: neither the worker nor easystream is staged here — the Containerfile
# fetches both from their GitHub releases (WORKER_VERSION / EASYSTREAM_VERSION).
cp -r "${DIR}/vendor" "${WORK}/vendor"
cp -r "${DIR}/guest"  "${WORK}/guest"
cp "${DIR}/golden-disk.sh" "${WORK}/"
ln "${DISK}" "${WORK}/disk/data.qcow2" 2>/dev/null || cp "${DISK}" "${WORK}/disk/data.qcow2"
cp -r "${SUPPORT}" "${WORK}/disk-support"

echo "Building ${NAME}:${TAG} -> ${DEST} (buildkitd=${BUILDKIT})"
echo "  disk: $(du -h "${WORK}/disk/data.qcow2" | cut -f1) (embedded)"
"${BUILDCTL}" --addr "${BUILDKIT}" build \
  --frontend dockerfile.v0 \
  --local "context=${WORK}" \
  --local "dockerfile=${WORK}" \
  --opt "filename=Dockerfile" \
  --opt "build-arg:REGISTRY=${REGISTRY}${REGISTRY_NS:+/${REGISTRY_NS}}" \
  --opt "build-arg:HTTP_PROXY=${PROXY}" \
  --opt "build-arg:HTTPS_PROXY=${PROXY}" \
  --opt "build-arg:WORKER_VERSION=${WORKER_VERSION}" \
  --opt "build-arg:EASYSTREAM_VERSION=${EASYSTREAM_VERSION}" \
  --opt "build-arg:RELEASE_PROXY=${PROXY}" \
  --opt "build-arg:RELEASE_CACHEBUST=$(date +%s)" \
  --output "type=image,name=${DEST},push=true,registry.insecure=true,compression=zstd" \
  --progress plain

echo "Pushing to ${DEST}"
echo "pushed by buildctl: ${DEST}"
