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
    print("  converted: %d bytes" % size, flush=True)
    xsh.need(size == 68719476736,
             "conversion incomplete: expected 68719476736 bytes, got %d" % size)

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
    """Start the container and wait for a desktop, reporting what the screen shows."""
    xsh.run(["docker", "rm", "-f", args.container], echo=False)
    xsh.run([
        "docker", "run", "-d", "--name", args.container,
        "--device=/dev/kvm", "--device=/dev/net/tun", "--cap-add", "NET_ADMIN",
        "-e", "VERSION=11", "-e", "DISK_SIZE=64G", "-e", "RAM_SIZE=8G", "-e", "CPU_CORES=4",
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


SSHD_CONFIG = r"""
$ErrorActionPreference = 'Stop'
Set-Service sshd -StartupType Automatic
Stop-Service sshd -Force -ErrorAction SilentlyContinue
(Get-Content C:\ProgramData\ssh\sshd_config) `
  -replace '^#?\s*Port\s+.*', 'Port {port}' `
  -replace '^#?\s*PasswordAuthentication\s+.*', 'PasswordAuthentication yes' |
  Set-Content C:\ProgramData\ssh\sshd_config
Start-Service sshd
Start-Sleep 3
Set-NetFirewallProfile -All -Enabled False
New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True `
  -Direction Inbound -Protocol TCP -Action Allow -LocalPort {port} `
  -ErrorAction SilentlyContinue | Out-Null
Write-Output '--- service ---'
Get-Service sshd | Select-Object Status,StartType | Format-List
Write-Output '--- listening ---'
Get-NetTCPConnection -State Listen -LocalPort {port} -ErrorAction SilentlyContinue |
  Select-Object LocalAddress,LocalPort | Format-Table
Write-Output '--- config ---'
(Get-Content C:\ProgramData\ssh\sshd_config) -match '^(Port|PasswordAuthentication)'
"""


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
    g.powershell(SSHD_CONFIG.format(port=args.port), settle=15)
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
    """Stop the guest and copy the disk plus the state files it needs to boot."""
    xsh.run(["docker", "stop", "-t", "180", args.container], echo=True)
    os.makedirs("out", exist_ok=True)
    xsh.run(["docker", "cp", "%s:/storage/data.img" % args.container, "out/data.img"], check=True)
    xsh.run(["qemu-img", "convert", "-O", "qcow2", "out/data.img", "out/windows-openssh.qcow2"],
            check=True)
    os.unlink("out/data.img")
    for name in ("windows.vars", "windows.ver", "windows.base", "windows.mac", "windows.rom"):
        r = xsh.run(["docker", "cp", "%s:/storage/%s" % (args.container, name),
                     "out/%s" % name], echo=False)
        if not r.ok:
            print("  missing %s" % name, flush=True)
    xsh.run(["tar", "czf", "out/windows-openssh.qcow2.bootstate.tar.gz", "-C", "out",
             "windows.vars", "windows.ver", "windows.base", "windows.mac", "windows.rom"],
            echo=False)
    for name in sorted(os.listdir("out")):
        print("  %s" % name, flush=True)
    return 0


def main(argv=None):
    argv = argv if argv is not None else sys.argv[1:]
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("stage", choices=["disk", "boot", "install", "forward", "verify",
                                      "export", "selftest"])
    ap.add_argument("--container", default="sshinst")
    ap.add_argument("--port", type=int, default=2222)
    ap.add_argument("--user", default="docker")
    ap.add_argument("--password", default="admin")
    ap.add_argument("--wait", type=int, default=1800, help="boot: seconds to wait for desktop")
    ap.add_argument("--attempts", type=int, default=6)
    ap.add_argument("--shots", default="shots")
    args = ap.parse_args(argv)

    if args.stage == "selftest":
        rc = openssh_verify.main(["--selftest"])
        rc |= openssh_forward.main(["--selftest"])
        return rc

    return {
        "disk": stage_disk,
        "boot": stage_boot,
        "install": stage_install,
        "forward": stage_forward,
        "verify": stage_verify,
        "export": stage_export,
    }[args.stage](args)


if __name__ == "__main__":
    sys.exit(main())
