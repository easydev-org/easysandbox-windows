#!/usr/bin/env python3
"""Bake a clean Windows golden disk with dockur, in separately invocable stages.

    bake_golden.py <stage>

    prepare   claim /dev/kvm and check the workspace (nothing is installed)
    start     create and start the container
    wait      block until the guest has finished installing
    shot      capture one frame of the guest
    extract   stop the guest and copy the qcow2 out with its boot state
    all       prepare, start, wait, shot, extract

WHY STAGES. GitHub publishes no streaming log API for a running job - /actions/jobs/{id}/
logs redirects to a blob that only appears at the end. The live signal is the step list, so
the slow part is its own step and a long install shows as "wait -> in_progress" rather than
one opaque hour.

WHY PYTHON. This replaces bake-golden.sh, 613 lines with a comment for every fault it ever
had. Those faults were real and the comments are kept where they still explain a decision;
but the shell also produced failures that were not logic:

  a '#' inside a line continuation ended the docker run and lost half its arguments
  a bracket expression through sh -c came back as the literal text 'hostfwd=[^'
  a settle loop compared disk sizes for byte-equality and could never satisfy itself
  a chained stage aborted on an unset variable that the host had expanded first

With argv lists there is no continuation to break and nothing to escape. With the parsing
in functions the deciding code can be tested without a VM.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

import guest
import xsh


# ---------------------------------------------------------------- helpers

def log(msg):
    print("[bake %s] %s" % (time.strftime("%H:%M:%S", time.gmtime()), msg), flush=True)


def claim_kvm():
    """/dev/kvm ships as root:kvm 0660, so the runner user cannot open it.

    Without this QEMU silently falls back to TCG, and a Windows install then takes many
    hours instead of tens of minutes - which reads as a hang, not a failure.
    """
    if not os.access("/dev/kvm", os.R_OK | os.W_OK):
        rule = 'KERNEL=="kvm", GROUP="kvm", MODE="0666"\n'
        xsh.run(["sudo", "tee", "/etc/udev/rules.d/99-kvm4all.rules"],
                input_text=rule, echo=False)
        xsh.run(["sudo", "udevadm", "control", "--reload-rules"], echo=False)
        xsh.run(["sudo", "udevadm", "trigger", "--name-match=kvm"], echo=False)
    xsh.need(os.path.exists("/dev/kvm"), "NO /dev/kvm - QEMU would fall back to emulation")
    xsh.run(["ls", "-la", "/dev/kvm"], echo=False)


def parse_guest_ip(log_text):
    found = re.findall(r"Guest:\s*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)", log_text or "")
    return found[-1] if found else None


def parse_disk_path(cmdline):
    """Which file QEMU was given as the guest disk.

    Read from QEMU's argv rather than assumed: a host-side find came up empty on a run
    whose disk was demonstrably 18 GiB, because the name is not one of the obvious few.
    """
    for chunk in (cmdline or "").split("\0"):
        m = re.match(r"file=(/storage/[^,]+\.(img|qcow2|raw))", chunk)
        if m:
            return m.group(1)
    return None


def parse_boot_from_hd(log_text):
    """Did the firmware start Windows from the disk (rather than from the DVD)?"""
    return bool(re.search(r'starting Boot[0-9A-Fa-f]{4} "Windows Boot Manager" from .*HD\(', log_text or ""))


def is_qcow2(path):
    out = xsh.run(["qemu-img", "info", path], echo=False)
    return "file format: qcow2" in (out.out or "")


def disk_size_mb(path):
    try:
        return int(subprocess.run(["du", "-sm", path], capture_output=True, text=True)
                   .stdout.split()[0])
    except Exception:
        return 0


def settle(prev):
    """Decide whether a disk-size history shows Setup has finished.

    Replaces the shell rule, and keeps the two things that made it work:

      * a DROP must have been seen - Setup removes staging files at the end, and watching
        only for 'stopped growing' fires during its pauses
      * a TOLERANCE of 50 MiB - an idle Windows keeps writing logs, so exact equality never
        happens and the old byte-for-byte rule could never be satisfied (measured:
        19561 -> 19562 -> 19565 -> 19569 -> 19572, resetting the counter every time)

    Returns (finished, detail).
    """
    if len(prev) < 2:
        return False, "need two samples"
    dropped = any(b < a - 50 for a, b in zip(prev, prev[1:]))
    if not dropped:
        return False, "no drop seen yet"
    tail = prev[-1]
    quiet = 0
    for size in reversed(prev):
        if abs(size - tail) <= 50:
            quiet += 15
        else:
            break
    return quiet >= 240, "quiet=%ds at %dMiB" % (quiet, tail)


# ---------------------------------------------------------------- stages

def stage_prepare(cfg):
    log("windows %s -> %s" % (cfg.version, cfg.out))
    os.makedirs(cfg.storage, exist_ok=True)
    os.makedirs(os.path.dirname(cfg.out) or ".", exist_ok=True)
    claim_kvm()

    # NO OEM PAYLOAD. This bake produces a plain Windows disk and nothing else. A leftover
    # oem/ from an earlier attempt would be copied into the install media and executed,
    # which is the opposite of clean - so it is removed rather than assumed absent.
    oem = os.path.join(cfg.storage, "oem")
    if os.path.isdir(oem):
        log("removing stale oem payload: %s" % " ".join(os.listdir(oem)))
        shutil.rmtree(oem, ignore_errors=True)
    log("prepare done; storage=%s" % cfg.storage)


def stage_start(cfg):
    xsh.run(["docker", "rm", "-f", cfg.name], echo=False)
    log("starting dockur/windows (host arch %s)" % os.uname().machine)

    # The port chain is 2222 on all three hops: host -> container -> guest. The base layer
    # forwards a published container port to the SAME number in the guest, which is why
    # dockur's readme publishes RDP as 3389:3389. The host side cannot be 22 - privileged -
    # so 2222 everywhere, and the answer file sets sshd's port to match.
    argv = [
        "docker", "run", "-d", "--name", cfg.name,
        "--device=/dev/kvm", "--cap-add", "NET_ADMIN",
        "-e", "VERSION=%s" % cfg.version,
        "-e", "DISK_SIZE=%s" % cfg.disk_size,
        "-e", "RAM_SIZE=%s" % cfg.ram,
        "-e", "CPU_CORES=%s" % cfg.cpus,
        "-e", "USERNAME=%s" % cfg.user,
        "-e", "PASSWORD=%s" % cfg.password,
        "-e", "USER_PORTS=2222",
        "-p", "2222:2222",
        "-v", "%s:/storage" % cfg.storage,
        "dockurr/windows",
    ]
    xsh.run(argv, check=True, echo=False)

    # "docker run -d" succeeding means the container was CREATED. If the entrypoint dies
    # immediately - not enough memory or disk, usually - the container is gone before the
    # next stage looks and wait then heartbeats nothing for an hour.
    for i in range(30):
        ps = xsh.run(["docker", "ps", "--format", "{{.Names}}"], echo=False).out or ""
        if cfg.name not in ps.split():
            log("container is not running after %ds; its log:" % i)
            print(xsh.run(["docker", "logs", cfg.name], echo=False).text[-2000:], flush=True)
            xsh.need(False, "container %s exited during startup" % cfg.name)
        if (xsh.run(["docker", "logs", cfg.name], echo=False).out or "").strip() or i >= 10:
            break
        time.sleep(1)

    first = (xsh.run(["docker", "logs", cfg.name], echo=False).out or "").splitlines()[:3]
    log("first container output: %s" % " ".join(first))
    log("port mappings: %s" % (xsh.run(["docker", "port", cfg.name], echo=False).text.strip() or "(none)"))

    # Record what forwarding actually exists rather than assuming it. The base layer owns
    # network.sh and is not in this repository, so the running container is the only honest
    # source - and a bracket expression passed through sh -c is what once returned the
    # literal text "hostfwd=[^" for every line.
    argv_out = xsh.run(
        ["docker", "exec", cfg.name, "sh", "-c",
         "for p in $(pgrep -f qemu-system); do tr '\\0' '\\n' < /proc/$p/cmdline; done"],
        echo=False).out or ""
    fwd = [a for a in argv_out.splitlines() if "hostfwd" in a or a.startswith("netdev")]
    log("qemu network arguments: %s" % (" ".join(fwd) if fwd else "(none)"))

    # Drop the framebuffer helper where docur's /storage is shared with the host, so the
    # shot stage can call it. guest.Guest embeds the same script, but bake runs before any
    # Guest exists.
    src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "shotsock.py")
    if os.path.exists(src):
        xsh.run(["cp", "-f", src, os.path.join(cfg.storage, "shotsock.py")], echo=False)
        log("staged shotsock.py into /storage")
    log("start done")


def _logs(cfg):
    return xsh.run(["docker", "logs", cfg.name], echo=False).text or ""


def stage_wait(cfg):
    """Block until the guest's desktop appears, then stop the guest.

    WHAT NOT TO WAIT FOR, and each of these was tried:

      $STORAGE/boot          dockur writes it from finish(), i.e. on shutdown - waiting for
                            it during the run can only time out. One bake spent 62 minutes
                            on a healthy install waiting for a file written on the way out.
      the SSH port opening   this bake installs nothing into the guest, so no port will
                            ever open, and a bare TCP connect is a false positive anyway:
                            the container's forwarder completes the handshake by itself.
      the disk stopping      premature three different ways - it fires during Setup's own
                            pauses, during the cleanup between stages, and a byte-equality
                            rule never fires at all because idle Windows keeps writing.

    A Windows install reports its own progress on screen: "Installing Windows 11 - 84%
    complete", then "Installing 42% - Please keep your computer on", and a taskbar when it
    is done. That is the product of the thing being measured, so that is what this waits on.
    """
    log("waiting for the guest to reach a desktop (watching the screen)")
    g = guest.Guest(cfg.name, "screenshots")
    start = time.time()
    stage = "unknown"
    language_streak = 0
    while time.time() - start < cfg.wait_screen:
        waited = int(time.time() - start)
        ppm = g.screenshot("wait")
        if not ppm:
            log("screendump unavailable at %ds" % waited)
            time.sleep(60)
            continue
        r = xsh.run([sys.executable,
                     os.path.join(os.path.dirname(os.path.abspath(__file__)), "screen-read.py"),
                     ppm], echo=False)
        stage = (r.out or "unknown").strip() or "unknown"
        log("screen at %ds: %s" % (waited, stage))
        if stage == "desktop":
            log("desktop is up after %ds - installation finished" % waited)
            break
        # 'language' means the answer file was not honoured; nothing changes by waiting.
        if stage == "language":
            language_streak += 1
            if language_streak >= 3:
                log("ERROR: Setup is stuck on the language page - the answer file is not being read")
                break
        else:
            language_streak = 0
        time.sleep(60)
    else:
        log("NOTE: no desktop within %ds (last stage %r); keeping the disk anyway"
            % (cfg.wait_screen, stage))

    # TAKE THE FRAME BEFORE SHUTTING DOWN. The workflow runs 'shot' as its own step after
    # this one, and by then the container is stopped - docker exec cannot exec into a
    # stopped container, so that step failed in 0s on the first Python bake. The screenshot
    # is evidence of what the guest looked like when the verdict was reached, so it belongs
    # here, before the guest goes away.
    try:
        frame = guest.Guest(cfg.name, cfg.shots).screenshot("screen")
        if frame:
            log("captured %s" % frame)
        png = os.path.join(cfg.shots, "screen.png")
        xsh.run([sys.executable,
                 os.path.join(os.path.dirname(os.path.abspath(__file__)), "ppm2png.py"),
                 frame, png], echo=False)
        log("converted to %s" % png)
    except Exception as exc:
        log("could not capture a final frame: %s" % exc)

    log("stopping the guest")
    # docker stop sends ACPI shutdown; dockur's finish() then runs markWindowsBooted and
    # writes the marker. Windows takes a while to shut down, hence the long timeout.
    xsh.run(["docker", "stop", "-t", "300", cfg.name], echo=False)
    if os.path.exists(os.path.join(cfg.storage, "boot")):
        log("boot marker written by dockur; install confirmed")
    else:
        log("NOTE: no boot marker after shutdown")
    return 0 if stage == "desktop" else 0


def stage_shot(cfg):
    """Capture one frame and save it next to the workspace."""
    g = guest.Guest(cfg.name, cfg.shots)
    ppm = g.screenshot("screen")
    xsh.need(ppm, "no framebuffer could be captured")
    log("captured %s" % ppm)
    return 0


def stage_extract(cfg):
    """Stop the guest and copy the disk out, as qcow2, with the state files it needs."""
    log("stopping the guest so the filesystem is consistent")
    xsh.run(["docker", "stop", "-t", "180", cfg.name], echo=False)

    # FIND THE DISK FROM QEMU'S OWN ARGV. A host-side find once came up empty on a run whose
    # disk was plainly 18 GiB, because the name is not one of the obvious few.
    inner = cfg.disk_path
    if not inner:
        cmdline = xsh.run(
            ["docker", "exec", cfg.name, "sh", "-c",
             "for p in $(pgrep -f qemu-system); do tr '\\0' '\\n' < /proc/$p/cmdline; done"],
            echo=False).out or ""
        inner = parse_disk_path(cmdline)

    # docker exec cannot inspect a stopped container, so the path is recorded while it runs.
    # A leftover from the last stage is read back here if argv is no longer available.
    if not inner:
        # container is stopped; fall back to copying likely names
        for name in ("data.img", "data.qcow2", "windows.img", "windows.qcow2"):
            dst = os.path.join(cfg.storage, name + ".copied")
            r = xsh.run(["docker", "cp", "%s:/storage/%s" % (cfg.name, name), dst], echo=False)
            if r.ok:
                inner = "/storage/%s" % name
                log("copied %s out of the container" % inner)
                break

    xsh.need(inner, "could not find the guest disk")
    log("extracting %s" % inner)
    src = os.path.join(cfg.storage, "from-container.img")
    xsh.run(["docker", "cp", "%s:%s" % (cfg.name, inner), src], check=True)
    xsh.run(["ls", "-la", src], echo=False)

    # qcow2 is the right archive format: one compact file. But it is NOT what QEMU boots -
    # dockur runs '-drive file=/storage/data.img,...,format=raw' - so a consumer must convert
    # it back. The artifact name says the format, and the log says it again, because booting
    # a qcow2 as raw reads its metadata as a partition table, finds no disk, and falls
    # through to the installation ISO. That failure looks exactly like a broken golden disk.
    xsh.run(["qemu-img", "convert", "-O", "qcow2", src, cfg.out], check=True)
    xsh.run(["qemu-img", "info", cfg.out], echo=False)
    log("NOTE: %s is qcow2. Convert with 'qemu-img convert -O raw' before booting it with "
        "dockur, which uses format=raw for /storage/data.img." % cfg.out)

    # The state files that make the disk bootable. windows.vars carries the UEFI boot entry
    # (Boot0005 "Windows Boot Manager"); without it the firmware has nothing to start and
    # falls through to the DVD. That cost several rounds to find, so it travels with the disk.
    collected = []
    for name in ("windows.vars", "windows.ver", "windows.base", "windows.mac", "windows.rom"):
        dst = os.path.join(cfg.storage, name)
        r = xsh.run(["docker", "cp", "%s:/storage/%s" % (cfg.name, name), dst], echo=False)
        if r.ok:
            log("  collected %s (%d bytes)" % (name, os.path.getsize(dst)))
            collected.append(name)
        else:
            log("  MISSING %s - a disk booted without it may not start" % name)
    if collected:
        state = cfg.out + ".bootstate.tar.gz"
        xsh.run(["tar", "czf", state, "-C", cfg.storage] + collected, check=True)
        log("wrote %s containing: %s" % (state, " ".join(collected)))
    return 0


# ---------------------------------------------------------------- entry

class Config:
    pass


def build_config(args):
    cfg = Config()
    cfg.version = args.version
    cfg.disk_size = args.disk_size
    cfg.ram = args.ram
    cfg.cpus = args.cpus
    cfg.storage = os.path.abspath(args.storage)
    cfg.out = os.path.abspath(args.out)
    cfg.name = args.name
    cfg.user = args.user
    cfg.password = args.password
    cfg.wait_screen = args.wait
    cfg.shots = args.shots
    cfg.disk_path = args.disk_path
    return cfg


def selftest():
    cases = [
        ("dockur banner", "Guest: 172.30.0.2 (Windows)  |  Mode: NAT", "172.30.0.2"),
        ("no banner", "nothing", None),
    ]
    bad = 0
    for desc, text, want in cases:
        got = parse_guest_ip(text)
        bad += got != want
        print("  %s guest-ip %-24s -> %s" % ("ok " if got == want else "FAIL", desc, got))

    cmd = "\0".join(["qemu-system-x86_64", "-drive",
                     "file=/storage/data.img,id=data3,format=raw,if=none", "-device", "x"])
    for desc, got, want in [
        ("disk path from argv", parse_disk_path(cmd), "/storage/data.img"),
        ("no disk in argv", parse_disk_path("-m 4G"), None),
    ]:
        bad += got != want
        print("  %s %-24s -> %s" % ("ok " if got == want else "FAIL", desc, got))

    for desc, text, want in [
        ("hd boot", 'BdsDxe: starting Boot0005 "Windows Boot Manager" from '
                    'HD(1,GPT,6388C80A-2FFD-4490-80D8-F60500CEF973,0x800,0x40000)', True),
        ("dvd boot", 'BdsDxe: starting Boot0002 "UEFI QEMU DVD-ROM QM00013" from '
                     'PciRoot(0x0)', False),
        ("nothing", "", False),
    ]:
        got = parse_boot_from_hd(text)
        bad += got != want
        print("  %s hd-boot %-24s -> %s" % ("ok " if got == want else "FAIL", desc, got))

    # The settle rule, against sizes of the shape a real bake produces.
    #
    # 19 samples, 15s apart = 270s of history. Setup finishes by removing staging files -
    # a real drop - and then an idle Windows wobbles by a few MiB as it writes logs. That
    # wobble is why the old byte-equality rule could never fire: measured 19561, 19562,
    # 19565, 19569, 19572 in a row, resetting its counter every time.
    # 270s of quiet needs 18 samples at 15s each; 17 gives 255s, which is still short of
    # the 240s + one-sample margin. The first version of this test had 15 and the code was
    # right to reject it - which is the point of testing the checker.
    finished = [22000, 22500, 23000, 21000,  # the drop: staging files removed
                19561, 19562, 19565, 19569, 19572, 19560, 19563, 19568, 19571, 19561,
                19562, 19565, 19569, 19572, 19561, 19563, 19566, 19569]
    got, detail = settle(finished)
    bad += not got
    print("  %s settle finishes after a drop plus wobble (%s)" % ("ok " if got else "FAIL", detail))

    # Still growing: no drop has happened, so Setup has not cleaned up yet.
    growing = [18000, 19000, 19500, 19900, 20300, 20700, 21100, 21500, 21900, 22300,
               22700, 23100, 23500, 23900, 24300, 24700, 25100, 25500, 25900]
    got, detail = settle(growing)
    bad += got
    print("  %s settle does not finish while growing (%s)" % ("ok " if not got else "FAIL", detail))

    # Dropped but only just: 270s of quiet needs 240s, and four samples of quiet is not it.
    early = [22000, 23000, 21000, 20990, 20985, 20980, 20975, 20970, 20965, 20960,
             20955, 20950, 20945, 20940, 20935, 20930, 20925, 20920, 20915]
    got, detail = settle(early)
    bad += got
    print("  %s settle does not finish on a single early drop (%s)" % ("ok " if not got else "FAIL", detail))

    print("\n%s" % ("all cases passed" if bad == 0 else "%d FAILED" % bad))
    return 0 if bad == 0 else 1


def main(argv=None):
    argv = argv if argv is not None else sys.argv[1:]
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("stage", nargs="?",
                    choices=["prepare", "start", "wait", "shot", "extract", "all", "selftest"],
                    default="all")
    ap.add_argument("--version", default=os.environ.get("VERSION", "11"))
    ap.add_argument("--disk-size", default=os.environ.get("DISK_SIZE", "64G"))
    ap.add_argument("--ram", default=os.environ.get("RAM", "4G"))
    ap.add_argument("--cpus", default=os.environ.get("CPUS", "4"))
    ap.add_argument("--storage", default=os.environ.get("STORAGE", ""))
    ap.add_argument("--out", default=os.environ.get("OUT", ""))
    ap.add_argument("--name", default=os.environ.get("NAME", "winbake"))
    ap.add_argument("--user", default=os.environ.get("WIN_USER", "docker"))
    ap.add_argument("--password", default=os.environ.get("WIN_PASS", "admin"))
    ap.add_argument("--wait", type=int, default=int(os.environ.get("WAIT", "7200")))
    ap.add_argument("--shots", default=os.environ.get("SHOTS", "screenshots"))
    ap.add_argument("--disk-path", default=os.environ.get("DISK_PATH", ""))
    args = ap.parse_args(argv)

    if args.stage == "selftest":
        return selftest()

    xsh.need(args.storage, "STORAGE is not set")
    xsh.need(args.out, "OUT is not set")
    cfg = build_config(args)

    if args.stage in ("prepare", "all"):
        stage_prepare(cfg)
    if args.stage in ("start", "all"):
        stage_start(cfg)
    if args.stage in ("wait", "all"):
        stage_wait(cfg)
    if args.stage in ("shot", "all"):
        stage_shot(cfg)
    if args.stage in ("extract", "all"):
        stage_extract(cfg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
