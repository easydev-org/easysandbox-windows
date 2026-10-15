#!/usr/bin/env bash
# Shrink the agent-worker Windows golden-disk OCI layer.
#
# Same idea as images/macos/repack-disk.sh. The Windows images are dominated by
# one layer: the pre-baked guest qcow2. Storing it defragmented to uncompressed
# 1 MiB clusters leaves the payload compressible, and a 128 MiB zstd window
# (--long=27) finds repetition an 8 MiB window misses.
#
# buildkit cannot set a long window, so this recompresses the disk layer and
# swaps it into the manifest (layers[i] + rootfs.diff_ids[i]). containerd
# accepts such layers (verified by running a pod from one).
#
# Usage:
#   defrag:  qemu-img convert -f qcow2 -O qcow2 -o cluster_size=1M,lazy_refcounts=on \
#              disk/data.qcow2  disk/defrag.qcow2
#   repack:  ./repack-disk.sh <defrag.qcow2> <srctag> <dsttag>
#     e.g.   ./repack-disk.sh /work/win-defrag.qcow2 v1.2.2 v1.5.0
#
# The replacement layer keeps the source layer's exact tar structure, i.e.
#   storage/data.qcow2  (+ storage/windows.vars when present).
#
# Env: REGISTRY, NAMESPACE (default sandbox), NAME, ZSTD_LEVEL (19),
#      ZSTD_WINDOW (27), ZSTD_THREADS (4), WORK.
set -Eeuo pipefail

DISK="${1:?defragged qcow2}"
SRCTAG="${2:?source tag}"
DSTTAG="${3:?destination tag}"

REGISTRY="${REGISTRY:-git.agent.svc.cluster.local}"
NAMESPACE="${NAMESPACE:-sandbox}"
NAME="${NAME:-sandbox-windows}"
REF="$REGISTRY/$NAMESPACE/$NAME"
LEVEL="${ZSTD_LEVEL:-19}"
WINDOW="${ZSTD_WINDOW:-27}"
THREADS="${ZSTD_THREADS:-4}"
W="${WORK:-./repack-win}"

for bin in qemu-img skopeo zstd tar python3; do
  command -v "$bin" >/dev/null || { echo "missing $bin" >&2; exit 1; }
done

rm -rf "$W"; mkdir -p "$W/stage/storage"
cd "$W"

echo "===== 1. pull $SRCTAG ====="
skopeo copy --src-tls-verify=false --src-creds "${FORGEJO_USER:-root}:${FORGEJO_PASS:-devpassword}" \
  "docker://$REF:$SRCTAG" "dir:$W/img"

echo
echo "===== 2. locate the disk layer (largest) ====="
python3 - "$W/img/manifest.json" > "$W/meta.txt" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
i = max(range(len(m["layers"])), key=lambda k: m["layers"][k]["size"])
l = m["layers"][i]
print(i)
print(l["size"])
print(l["digest"].split(":")[1])
print(m["config"]["digest"].split(":")[1])
PY
IDX=$(sed -n 1p "$W/meta.txt")
OLDSZ=$(sed -n 2p "$W/meta.txt")
OLDHEX=$(sed -n 3p "$W/meta.txt")
CFG=$(sed -n 4p "$W/meta.txt")
echo "disk layer[$IDX] $(numfmt --to=iec "$OLDSZ") $OLDHEX"

echo
echo "===== 3. tar the defragged disk (same structure as the old layer) ====="
cp --reflink=auto "$DISK" "$W/stage/storage/data.qcow2" 2>/dev/null || cp "$DISK" "$W/stage/storage/data.qcow2"
# carry over windows.vars if the old layer had it
if zstd -dc "$W/img/$OLDHEX" 2>/dev/null | tar -tf - 2>/dev/null | grep -q '^storage/windows.vars$'; then
  zstd -dc "$W/img/$OLDHEX" 2>/dev/null | tar -x -C "$W/stage" storage/windows.vars 2>/dev/null || true
fi
tar -C "$W/stage" -cf "$W/disk.tar" storage/data.qcow2 \
  $( [ -e "$W/stage/storage/windows.vars" ] && echo storage/windows.vars )
DIFF="sha256:$(sha256sum "$W/disk.tar" | awk '{print $1}')"
echo "tar=$(numfmt --to=iec "$(stat -c %s "$W/disk.tar")") diff_id=$DIFF"

echo
echo "===== 4. compress: zstd -$LEVEL --long=$WINDOW -T$THREADS ====="
time zstd "-$LEVEL" "--long=$WINDOW" -T"$THREADS" -q -f -o "$W/disk.tar.zst" "$W/disk.tar"
NEWHEX=$(sha256sum "$W/disk.tar.zst" | awk '{print $1}')
NEWSZ=$(stat -c %s "$W/disk.tar.zst")
echo "blob=$(numfmt --to=iec "$NEWSZ") $NEWHEX"
rm -f "$W/disk.tar" "$W/img/$OLDHEX"
cp "$W/disk.tar.zst" "$W/img/$NEWHEX"

echo
echo "===== 5. patch manifest + config ====="
python3 - "$W/img" "$IDX" "$NEWHEX" "$NEWSZ" "$CFG" "$DIFF" <<'PY'
import hashlib, json, os, sys
d, idx, newhex, newsz, cfghex, diff = sys.argv[1:7]
idx = int(idx)
mp = os.path.join(d, "manifest.json")
m = json.load(open(mp))
# A zstd layer only exists in the OCI media-type world; switch the manifest and
# config to OCI (skopeo refuses an OCI zstd layer inside a docker v2s2 manifest).
m["mediaType"] = "application/vnd.oci.image.manifest.v1+json"
m["config"]["mediaType"] = "application/vnd.oci.image.config.v1+json"
m["layers"][idx] = {"mediaType": "application/vnd.oci.image.layer.v1.tar+zstd",
                    "size": int(newsz), "digest": "sha256:" + newhex}
cfgp = os.path.join(d, cfghex)
c = json.load(open(cfgp))
c["rootfs"]["diff_ids"][idx] = diff
open(cfgp, "w").write(json.dumps(c, indent=2))
newcfg = hashlib.sha256(open(cfgp, "rb").read()).hexdigest()
os.rename(cfgp, os.path.join(d, newcfg))
m["config"] = {"mediaType": "application/vnd.oci.image.config.v1+json",
               "digest": "sha256:" + newcfg,
               "size": os.stat(os.path.join(d, newcfg)).st_size}
open(mp, "w").write(json.dumps(m, indent=2))
tot = sum(l["size"] for l in m["layers"])
print("config -> %s" % newcfg[:16])
print("total   = %d (%.2f GiB)" % (tot, tot / 2**30))
PY

echo
echo "===== 6. push $DSTTAG ====="
skopeo copy --format oci --dest-tls-verify=false --dest-creds "${FORGEJO_USER:-root}:${FORGEJO_PASS:-devpassword}" \
  "dir:$W/img" "docker://$REF:$DSTTAG"
skopeo inspect --creds "${FORGEJO_USER:-root}:${FORGEJO_PASS:-devpassword}" --tls-verify=false \
  "docker://$REF:$DSTTAG" | grep '"Digest"' | head -1
echo "REPACKED_WINDOWS"
