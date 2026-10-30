#!/usr/bin/env python3
"""Install OpenSSH Server on the golden disk and prove it works. One entry point.

    openssh_setup.py <stage> [options]

    disk       convert the artifact disk to raw and verify the conversion
    boot       start the container and wait for the guest's desktop
    install    winget install OpenSSH.Preview, then configure sshd
    forward    expose the guest's sshd on the container's published port
    verify     connect, read a banner, log in - in that order, reporting each
    export     stop the guest and copy the disk out with its boot state
    selftest   run every parser against strings taken from real logs

WHY SUBCOMMANDS. The workflow used to be twenty shell steps, each with its own quoting to
get wrong. Six failures came from that and none from logic. Each subcommand here is plain
Python with argv-list calls into docker, so an argument is never reinterpreted, and each
one refuses to report success when its own check fails.
"""
import argparse
import os
import re
import sys
import time

import guest
import openssh_forward
import openssh_verify
import xsh


# ---------------------------------------------------------------- stages

def stage_place(args):
    """Fetch the golden disk from ghcr and convert it to the raw image QEMU opens.

    The counterpart to publish. ghcr_pull_disk.py rebuilds the qcow2 from the OCI layers and
    checks it against disk.sha256 from the manifest, so a transport fault shows up as a
    checksum mismatch rather than as a Windows that will not boot.

    Bootstate comes from the same run artifact as before - a few hundred KB, useless without
    the disk, and not worth a second registry round trip.
    """
    os.makedirs("storage", exist_ok=True)
    repo = args.pull_repo or "golden-disk-windows"
    tag = args.pull_tag or "base"
    print("--- pulling ghcr.io/easydev-org/%s:%s ---" % (repo, tag), flush=True)

    env = dict(os.environ)
    xsh.need(env.get("GHCR_TOKEN"), "GHCR_TOKEN is not set (needs read:packages)")
    local = "pulled.qcow2"
    r = xsh.run([sys.executable,
                 os.path.join(os.path.dirname(os.path.abspath(__file__)), "ghcr_pull_disk.py"),
                 repo, tag, local], echo=True)
    xsh.need(r.ok, "could not pull %s:%s" % (repo, tag))
    xsh.need(os.path.exists(local), "pull reported success but produced no file")
    print("  pulled: %.1f MiB" % (os.path.getsize(local) / 2 ** 20), flush=True)

    # From here it is identical to the artifact path: convert to raw and check it.
    # The virtual size is read from the SOURCE, before the convert and before unlink -
    # afterwards the qcow2 is gone and the only thing left to compare against is the raw
    # file itself, which would make the check compare a file with itself and pass for no
    # reason.
    expect = virtual_size(local)
    free_kb = int(xsh.run(["df", "--output=avail", "-k", "."], echo=False).out.split()[-1])
    xsh.need(free_kb > 64 * 1024 * 1024, "not enough free space for the raw image")
    xsh.run(["qemu-img", "convert", "-O", "raw", local, "storage/data.img"], check=True)
    os.unlink(local)
    size = os.path.getsize("storage/data.img")
    print("  converted: %d bytes (source virtual size %s)" % (size, expect), flush=True)
    if expect:
        xsh.need(size == expect,
                 "conversion incomplete: expected %d bytes, got %d" % (expect, size))
    nonzero = 0
    with open("storage/data.img", "rb") as f:
        for off in (0, 512, 1 << 20, size // 4, size // 2, size * 3 // 4):
            f.seek(off)
            if any(f.read(4096)):
                nonzero += 1
    print("  non-zero sample points: %d/6" % nonzero, flush=True)
    xsh.need(nonzero >= 2, "the converted image looks empty")

    state = xsh.run(["bash", "-c",
                     "find artifact -name '*.bootstate.tar.gz' | head -1"], echo=False).out.strip()
    if state:
        xsh.run(["tar", "xzf", state, "-C", "storage"], check=True)
        print("  restored bootstate: %s" % state, flush=True)
    else:
        print("  WARNING: no bootstate archive in the workspace", flush=True)

    open("storage/windows.boot", "w").close()
    print("  completion marker: storage/windows.boot", flush=True)
    return 0


def virtual_size(path):
    """The disk size QEMU will present, read from qemu-img rather than assumed.

    This was hard-coded to 64 GiB, which is the size bake-golden produces. Then a disk
    published from a different bake came back at 128 GiB and the check failed with
    "conversion incomplete: 137438953472 bytes" - a true measurement of the disk, compared
    against a number about a different disk. The check is worth keeping; the constant was not.
    """
    out = xsh.run(["qemu-img", "info", path], echo=False).out or ""
    return _read_virtual_size(out)


def stage_disk(args):
    """Make storage/data.img from the artifact, and prove it is complete.

    dockur opens /storage/data.img as raw. The artifact is qcow2, so it must be converted -
    and then CHECKED, because a conversion cut short produces a file of plausible size that
    QEMU happily boots and the guest then never paints. That cost two runs.
    """
    disk = xsh.run(["bash", "-c", "find artifact -type f -size +1G | head -1"], echo=False).out.strip()
    xsh.need(disk, "no disk in the artifact")
    print("  artifact: %s" % disk, flush=True)

    os.makedirs("storage", exist_ok=True)
    free_kb = int(xsh.run(["df", "--output=avail", "-k", "."], echo=False).out.split()[-1])
    need_kb = 64 * 1024 * 1024
    print("  free %dK, need %dK" % (free_kb, need_kb), flush=True)
    xsh.need(free_kb > need_kb, "not enough free space for a 64 GiB raw image")

    xsh.run(["qemu-img", "convert", "-O", "raw", disk, "storage/data.img"], check=True)

    size = os.path.getsize("storage/data.img")
    expect = virtual_size(disk)
    print("  converted: %d bytes (source virtual size %s)" % (size, expect), flush=True)
    if expect:
        xsh.need(size == expect,
                 "conversion incomplete: expected %d bytes, got %d" % (expect, size))

    # Right size but all zeroes is still possible; sample a few offsets.
    nonzero = 0
    with open("storage/data.img", "rb") as f:
        for off in (0, 512, 1 << 20, size // 4, size // 2, size * 3 // 4):
            f.seek(off)
            if any(f.read(4096)):
                nonzero += 1
    print("  non-zero sample points: %d/6" % nonzero, flush=True)
    xsh.need(nonzero >= 2, "the converted image looks empty")

    state = xsh.run(["bash", "-c",
                     "find artifact -name '*.bootstate.tar.gz' | head -1"], echo=False).out.strip()
    if state:
        xsh.run(["tar", "xzf", state, "-C", "storage"], check=True)
        print("  restored: %s" % state, flush=True)
    else:
        print("  WARNING: no bootstate archive; the disk may not boot", flush=True)

    # windows.boot, not boot: hasBootMarker() tests stateFile("boot"), which prefixes
    # 'windows.'. With the wrong name dockur takes its install path and wipes the disk.
    open("storage/windows.boot", "w").close()
    print("  completion marker: storage/windows.boot", flush=True)
    for name in sorted(os.listdir("storage")):
        print("    %s" % name, flush=True)
    return 0


def stage_boot(args):
    """Start the container on the prepared disk and wait for a desktop.

    DISK_SIZE MUST MATCH THE DISK. This was hard-coded to 64G, the size bake-golden
    produces, and a disk published from a 128 GiB bake then booted to a blank screen that
    never reached a desktop for over 460 seconds - dockur sizes the container view from
    DISK_SIZE, and telling it 64G while data.img holds 128 GiB is a mismatch it does not
    report, it just does not boot.

    So the size comes from the disk itself. --disk-size overrides when a caller knows
    better, and the value actually used is printed, because a wrong guess here costs the
    whole boot.
    """
    size = args.disk_size
    if not size:
        qcow = os.path.join("storage", "data.img")
        if os.path.exists(qcow):
            vs = virtual_size(qcow)
            if vs:
                # Whole GiB, rounded up: dockur accepts the size as a docker -e value.
                size = "%dG" % ((vs + (1 << 30) - 1) // (1 << 30))
        size = size or "64G"
    print("  DISK_SIZE=%s (from the disk)" % size, flush=True)

    xsh.run(["docker", "rm", "-f", args.container], echo=False)
    xsh.run([
        "docker", "run", "-d", "--name", args.container,
        "--device=/dev/kvm", "--device=/dev/net/tun", "--cap-add", "NET_ADMIN",
        "-e", "VERSION=11", "-e", "DISK_SIZE=%s" % size,
        "-e", "RAM_SIZE=8G", "-e", "CPU_CORES=4",
        "-p", "%d:%d" % (args.port, args.port),
        "-p", "8006:8006", "--stop-timeout", "180",
        "-v", "%s/storage:/storage" % os.getcwd(),
        "dockurr/windows",
    ], check=True)
    time.sleep(30)
    xsh.run(["docker", "ps", "-a"], echo=True)

    g = guest.Guest(args.container, args.shots)
    start = time.time()
    last = ""
    stable = 0
    while time.time() - start < args.wait:
        elapsed = int(time.time() - start)
        ppm = g.screenshot("boot")
        stage = "no-frame"
        if ppm:
            r = xsh.run([sys.executable, "scripts/screen-read.py", ppm], echo=False)
            stage = (r.out or "unknown").strip() or "unknown"
        print("  t=%ds stage=%s" % (elapsed, stage), flush=True)
        if stage == "desktop":
            stable += 1
            if stable >= 2:
                print("desktop after %ds" % elapsed, flush=True)
                return 0
        else:
            stable = 0
        last = stage
        time.sleep(15)
    xsh.need(False, "no desktop within %ds (last stage %r)" % (args.wait, last))


def stage_install(args):
    """winget install OpenSSH.Preview, then set up the service.

    The package id is Microsoft.OpenSSH.Preview - not .Beta (does not exist) and not
    .Server (also does not exist). Taken from microsoft/winget-pkgs, which is the index.
    """
    g = guest.Guest(args.container, args.shots)

    print("--- searching the real id in the guest ---", flush=True)
    g.powershell("winget search OpenSSH --source winget --accept-source-agreements", settle=25)
    g.screenshot("search")

    print("--- installing ---", flush=True)
    g.powershell(
        "winget install --id Microsoft.OpenSSH.Preview --exact --source winget "
        "--accept-source-agreements --accept-package-agreements --disable-interactivity",
        settle=0,
    )
    # Poll the screen instead of sleeping a fixed six minutes: winget has finished in under
    # a minute every time, and the old fixed wait was the largest avoidable cost in the job.
    deadline = time.time() + 420
    while time.time() < deadline:
        time.sleep(20)
        ppm = g.screenshot("winget")
        if not ppm:
            continue
        r = xsh.run([sys.executable, "scripts/screen-read.py", ppm], echo=False)
        if "installing" not in (r.out or ""):
            print("  winget appears finished", flush=True)
            break

    print("--- configuring sshd ---", flush=True)
    # The script is a file, not a string in this module: it is PowerShell, full of
    # backslashes and regexes, and putting it here meant writing them through two layers
    # of escaping (python string, then the guest keyboard).
    with open("scripts/sshd_setup.ps1.txt") as f:
        body = f.read().replace("__PORT__", str(args.port))
    statements = [l for l in body.splitlines() if l.strip()]
    g.run_script(statements, settle=20)
    g.screenshot("sshd")
    return 0


def stage_forward(args):
    return openssh_forward.main(
        ["--container", args.container, "--port", str(args.port)]
    )


def stage_verify(args):
    return openssh_verify.main(
        ["--port", str(args.port), "--user", args.user, "--password", args.password,
         "--attempts", str(args.attempts), "--wait", "30"]
    )


def stage_export(args):
    """Stop the guest and take the disk out, as qcow2, with the state files it needs.

    The output name is a parameter because three stages export: install-openssh makes the
    disk with sshd, install-sdk makes the one with the toolchain, and a name that says which
    is which is what keeps the artifacts from being confused later.
    """
    out_name = args.out_name or "windows.qcow2"
    xsh.run(["docker", "stop", "-t", "180", args.container], echo=True)
    os.makedirs("out", exist_ok=True)
    xsh.run(["docker", "cp", "%s:/storage/data.img" % args.container, "out/data.img"], check=True)
    xsh.run(["qemu-img", "convert", "-O", "qcow2", "out/data.img", "out/%s" % out_name],
            check=True)
    os.unlink("out/data.img")
    collected = []
    for name in ("windows.vars", "windows.ver", "windows.base", "windows.mac", "windows.rom"):
        r = xsh.run(["docker", "cp", "%s:/storage/%s" % (args.container, name),
                     "out/%s" % name], echo=False)
        if r.ok:
            collected.append(name)
        else:
            print("  missing %s" % name, flush=True)
    if collected:
        # Named after the disk so two exports in one workspace cannot overwrite each other.
        xsh.run(["tar", "czf", "out/%s.bootstate.tar.gz" % out_name, "-C", "out"] + collected,
                echo=False)
    for name in sorted(os.listdir("out")):
        print("  %s" % name, flush=True)
    return 0


def stage_publish(args):
    """Push the exported disk to ghcr, under a timestamped tag and a moving alias.

    WHY GHCR AND NOT AN ACTIONS ARTIFACT. Measured here: a 14 GiB disk between workflows as
    an artifact ran over 1000 seconds without finishing, the same range dockur-macos
    recorded. ghcr is a CDN, and it is where the sandbox images already look for a golden
    disk - so this is the production path, not extra machinery.

    TWO TAGS PER BUILD, because one name cannot do both jobs:

      base-20261030T081500   immutable. Names this exact disk forever, so a regression can
                             be traced to the build that introduced it, and a known-good
                             disk can still be pulled after newer ones exist.
      base-latest            moves with each build. What a consumer follows.

    Pushing only "base" would overwrite the previous disk on every build, and there would be
    no way to say "the disk from Tuesday" - which is the question asked when something
    starts failing.

    Both names point at one manifest: the layers upload once and the alias costs a few
    hundred bytes. ghcr_push_disk.py does the alias and reads each tag back, because a tag
    resolving to a different digest is worse than a failed push.
    """
    out_name = args.out_name or "windows.qcow2"
    path = os.path.join("out", out_name)
    xsh.need(os.path.exists(path), "no %s to publish - run export first" % path)
    print("  %s: %.1f MiB" % (path, os.path.getsize(path) / 2 ** 20), flush=True)

    target = args.publish_repo or "ghcr.io/easydev-org/golden-disk-windows"
    base_tag = args.publish_tag or "base"

    # SOURCE_DATE_EPOCH lets a caller pin the name; otherwise the clock decides. UTC with
    # second resolution, so two builds cannot collide by accident.
    stamp = args.stamp
    if not stamp:
        epoch = os.environ.get("SOURCE_DATE_EPOCH")
        stamp = time.strftime("%Y%m%dT%H%M%S", time.gmtime(int(epoch) if epoch else None))
    versioned = "%s-%s" % (base_tag, stamp)
    alias = "%s-latest" % base_tag
    print("  -> %s:%s  (alias %s)" % (target, versioned, alias), flush=True)

    env = dict(os.environ)
    xsh.need(env.get("GHCR_TOKEN"), "GHCR_TOKEN is not set (needs write:packages)")
    env.setdefault("GHCR_USER", os.environ.get("GITHUB_ACTOR", "easydev-org"))

    r = xsh.run([sys.executable,
                 os.path.join(os.path.dirname(os.path.abspath(__file__)), "ghcr_push_disk.py"),
                 path, target, versioned, alias],
                echo=True)
    xsh.need(r.ok, "push to %s:%s failed" % (target, versioned))

    print("published:", flush=True)
    print("  versioned  %s:%s" % (target, versioned), flush=True)
    print("  alias      %s:%s" % (target, alias), flush=True)
    if args.tag_file:
        with open(args.tag_file, "w") as f:
            f.write(versioned + chr(10) + alias + chr(10))
        print("  wrote %s" % args.tag_file, flush=True)
    return 0


def selftest_virtual_size():
    """The disk-size check, against the two formats qemu-img actually prints.

    Hard-coded to 64 GiB first, then matched with a pattern that assumed the bare-bytes form.
    qemu-img prints  'virtual size: 128 GiB (137438953472 bytes)'  when the size is a whole
    number of GiB and  'virtual size: 21474836480 bytes'  when it is not - so a reader that
    only knows one of them reports None on the other, and the check then falls back to
    comparing the file with itself and passing for the wrong reason.
    """
    cases = [
        ("with a GiB prefix", "virtual size: 128 GiB (137438953472 bytes)", 137438953472),
        ("64 GiB", "virtual size: 64 GiB (68719476736 bytes)", 68719476736),
        ("bare bytes", "virtual size: 21474836480 bytes", 21474836480),
        ("absent", "no size here", None),
    ]
    bad = 0
    for desc, text, want in cases:
        got = _read_virtual_size(text)
        bad += got != want
        print("  %s virtual-size %-18s -> %s" % ("ok " if got == want else "FAIL", desc, got))
    print("  %s" % ("virtual-size cases passed" if bad == 0 else "%d FAILED" % bad))
    return 0 if bad == 0 else 1


def _read_virtual_size(text):
    import re as _re
    m = _re.search(r"virtual size:[ ]*(?:[0-9.]+[ ]*[KMGT]iB[ ]*)?\(([0-9]+) bytes\)", text or "")
    if not m:
        m = _re.search(r"virtual size:[ ]*([0-9]+) bytes", text or "")
    return int(m.group(1)) if m else None


def main(argv=None):
    argv = argv if argv is not None else sys.argv[1:]
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("stage", choices=["disk", "place", "boot", "install", "forward",
                                      "verify", "export", "publish", "selftest"])
    ap.add_argument("--container", default="sshinst")
    ap.add_argument("--port", type=int, default=2222)
    ap.add_argument("--user", default="docker")
    ap.add_argument("--password", default="admin")
    ap.add_argument("--wait", type=int, default=1800, help="boot: seconds to wait for desktop")
    ap.add_argument("--attempts", type=int, default=6)
    ap.add_argument("--disk-size", default="",
                    help="boot: DISK_SIZE for docker; default read from the disk")
    ap.add_argument("--shots", default="shots")
    ap.add_argument("--out-name", default="windows.qcow2",
                    help="export/publish: filename of the qcow2 in out/")
    ap.add_argument("--publish-repo", default="ghcr.io/easydev-org/golden-disk-windows")
    ap.add_argument("--publish-tag", default="base")
    ap.add_argument("--pull-repo", default="golden-disk-windows")
    ap.add_argument("--pull-tag", default="base")
    ap.add_argument("--stamp", default="",
                    help="publish: version stamp; defaults to UTC now")
    ap.add_argument("--tag-file", default="",
                    help="publish: write the versioned and alias tags here")
    args = ap.parse_args(argv)

    if args.stage == "selftest":
        rc = openssh_verify.main(["--selftest"])
        rc |= openssh_forward.main(["--selftest"])
        rc |= selftest_virtual_size()
        return rc

    return {
        "disk": stage_disk,
        "place": stage_place,
        "boot": stage_boot,
        "install": stage_install,
        "forward": stage_forward,
        "verify": stage_verify,
        "export": stage_export,
        "publish": stage_publish,
    }[args.stage](args)


if __name__ == "__main__":
    sys.exit(main())
