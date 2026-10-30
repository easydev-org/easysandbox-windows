"""Rebuild a golden qcow2 from its ghcr OCI image.

    ghcr_pull_disk.py <windows|macos> <out.qcow2>

The disk is published as ONE tag whose LAYERS are consecutive pieces of the
qcow2 (`golden-windows:base` has 8, `golden-macos:base` has 9). Concatenating the
layer payloads in manifest order reproduces the original file exactly, and the
result is verified against the sha256 recorded in the manifest annotation before
it is moved into place.

Why not skopeo: it is not installed in the sandbox images, and the whole point of
this script is that a plain machine with python3 can produce the embedded disk.

Auth: the packages are PRIVATE, and ghcr's /token endpoint echoes back
base64(PAT) rather than a registry JWT — that base64 string is what the /v2
endpoints accept as a Bearer token. (Sending the PAT as Basic, or decoding the
base64 first, both give 401.)

Environment: GHCR_TOKEN (a PAT with read:packages).
"""

import base64
import json
import os
import ssl
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request

# The packages now live in the organisation that owns this repository, so the
# workflow's own GITHUB_TOKEN can read them. That token is a GitHub App token,
# not a password: the /token endpoint expects it as x-access-token, and answers
# with a registry JWT that the /v2 endpoints accept as Bearer.
REG = "ghcr.io"
OWNER = "easydev-org"
USER = "x-access-token"

PLAN = {
    "windows": ("easysandbox-windows-golden", "base"),
    "macos": ("golden-disk-macos", "base"),
}

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE


def token(repo, pat):
    basic = base64.b64encode(f"{USER}:{pat}".encode()).decode()
    url = f"https://{REG}/token?scope=repository:{OWNER}/{repo}:pull&service={REG}"
    r = urllib.request.urlopen(
        urllib.request.Request(url, headers={"Authorization": "Basic " + basic}),
        timeout=30, context=ctx)
    return json.load(r)["token"]


def get(url, tok, accept=None):
    h = {"Authorization": "Bearer " + tok}
    if accept:
        h["Accept"] = accept
    return urllib.request.urlopen(urllib.request.Request(url, headers=h),
                                  timeout=120, context=ctx)


def main():
    # Two forms, because two callers exist:
    #   ghcr_pull_disk.py windows out.qcow2                  a name from PLAN
    #   ghcr_pull_disk.py easysandbox-windows-golden dev out.qcow2  an explicit repo and tag
    #
    # The second form is what the pipeline stages use: they publish under several tags of one
    # repository (base, openssh, dev), and a PLAN entry per tag would be a list to keep in step
    # with the workflows by hand.
    if len(sys.argv) >= 4:
        which, tag, out = sys.argv[1], sys.argv[2], sys.argv[3]
        repo = which
    elif len(sys.argv) == 3:
        which, out = sys.argv[1], sys.argv[2]
        if which not in PLAN:
            sys.exit("unknown disk %r; known: %s - or pass <repo> <tag> <out>" %
                     (which, ", ".join(sorted(PLAN))))
        repo, tag = PLAN[which]
    else:
        sys.exit("usage: ghcr_pull_disk.py <name|repo> [tag] <out.qcow2>")
    pat = os.environ.get("GHCR_TOKEN")
    if not pat:
        sys.exit("set GHCR_TOKEN (PAT with read:packages)")

    tok = token(repo, pat)
    man = json.load(get(f"https://{REG}/v2/{OWNER}/{repo}/manifests/{tag}", tok,
                        "application/vnd.oci.image.manifest.v1+json"))
    layers = man["layers"]
    want = (man.get("annotations") or {}).get("disk.sha256", "")
    print(f"{repo}:{tag}  layers={len(layers)}  expected sha256={want[:16] or '(none)'}")

    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    tmp = out + ".part"
    with open(tmp, "wb") as fh:
        for i, l in enumerate(layers):
            dg = l["digest"]
            sz = l["size"]
            print(f"  layer {i + 1}/{len(layers)}  {sz / 1024 ** 2:8.1f} MB  {dg[:22]}", flush=True)

            # RETRIED. A layer is up to 1 GiB and the connection can end part-way through:
            # one run failed with tarfile.ReadError: unexpected end of data after 400
            # seconds of downloading. That is a truncated blob, not a bad manifest. Runners
            # go through a proxy to a CDN and neither promises the whole body first time.
            data = None
            last = None
            for attempt in range(1, 5):
                fd, bpath = tempfile.mkstemp(suffix=".blob")
                os.close(fd)
                try:
                    url = "https://%s/v2/%s/%s/blobs/%s" % (REG, OWNER, repo, dg)
                    with get(url, tok) as r, open(bpath, "wb") as bf:
                        while True:
                            chunk = r.read(1 << 20)
                            if not chunk:
                                break
                            bf.write(chunk)
                    got = os.path.getsize(bpath)
                    if got != sz:
                        raise IOError("short layer: %d of %d bytes" % (got, sz))
                    with tarfile.open(bpath, "r:*") as tf:
                        parts = [m for m in tf.getmembers() if m.isfile()]
                        if not parts:
                            raise IOError("layer %d contains no file" % i)
                        data = tf.extractfile(parts[0]).read()
                    break
                except Exception as exc:
                    last = exc
                    print("        attempt %d failed: %s; retrying" % (attempt, str(exc)[:80]), flush=True)
                    if attempt >= 4:
                        sys.exit("layer %d could not be downloaded after 4 attempts: %s" % (i + 1, last))
                    time.sleep(5 * attempt)
                finally:
                    try:
                        os.unlink(bpath)
                    except OSError:
                        pass
            fh.write(data)
            print("        -> %.1f MB extracted" % (len(data) / 1024 ** 2), flush=True)

    if want:
        got = subprocess.run(["sha256sum", tmp], capture_output=True, text=True).stdout.split()[0]
        if got != want:
            os.unlink(tmp)
            sys.exit(f"sha256 MISMATCH\ngot  {got}\nwant {want}")
        print(f"sha256 ok: {got}")

    os.replace(tmp, out)
    print(f"wrote {out}: {os.path.getsize(out)} bytes")


if __name__ == "__main__":
    main()
