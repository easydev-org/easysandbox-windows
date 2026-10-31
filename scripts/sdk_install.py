#!/usr/bin/env python3
"""Install the Windows SDK, MSVC build tools and the .NET SDK over SSH.

WHY THIS STAGE IS DIFFERENT. The first two stages typed into a guest, because a fresh
Windows has no service to reach it through. Once sshd runs, that apparatus is not needed:
every command here runs over a real SSH session, and the failures are the ones ssh reports
in words.

WHAT GETS INSTALLED, and why these ids:

  Microsoft.VisualStudio.2022.BuildTools   the compiler. --quiet alone installs an empty
      shell, so the workload has to be named:
          --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended
      VCTools is MSVC plus the Windows SDK plus CMake. Without it there is no cl.exe.

  Microsoft.WindowsSDK.10                  the SDK on its own
  Microsoft.DotNet.SDK.10                  the .NET SDK, which VCTools does not include

The ids come from microsoft/winget-pkgs, the index winget itself reads - the same place
Microsoft.OpenSSH.Preview came from after Microsoft.OpenSSH.Beta turned out not to exist.

WHY --disable-interactivity: winget asks for source and licence acceptance on first use and
will wait forever in a non-interactive session.
"""
import argparse
import os
import re
import sys
import time
import tempfile

import xsh

HERE = os.path.dirname(os.path.abspath(__file__))

# THE IDS ARE VERIFIED AGAINST microsoft/winget-pkgs, not guessed. The first attempt used
# Microsoft.WindowsSDK.10, which does not exist: the manifests live under
# manifests/m/Microsoft/WindowsSDK/10/0/<build>/, so the identifier is
# Microsoft.WindowsSDK.10.0.26100. winget answered exit 20 for the wrong one.
#
# BuildTools takes its workload through --override, and --override cannot be combined with
# --accept-package-agreements: winget printed its help and exited 2. The agreements are
# accepted by the switches passed TO the override string instead, which is what the installer
# itself understands.
PACKAGES = [
    # BuildTools is NOT here. winget pins 17.9.7, whose manifest caps the supported OS at
    # 10.0.22000; this guest is 10.0.26200, so the installer marks every component
    # "not applicable", installs nothing and exits 1. It is installed instead by the
    # evergreen bootstrapper in ps/vs-workload.ps1, which fetches a manifest that knows
    # about current builds. Adding both would give two installers of the same product.
    ("Microsoft.WindowsSDK.10.0.26100", None, "the SDK on its own"),
    ("Microsoft.DotNet.SDK.10", None, "the .NET SDK, which VCTools does not include"),
    ("Microsoft.PowerShell", None,
     "PowerShell 7; last because its MSI can drop the ssh session"),
]


def wait_for_ssh(port, user, password, seconds=300, why=""):
    """Wait until sshd answers again.

    A winget package can restart something inside the guest - PowerShell 7 is an MSI and
    touches the service host - and the session drops mid-install:
        kex_exchange_identification: read: Connection reset by peer
    Every later step then fails with 'Connection refused', which reads like the machine died.
    This waits for it to come back, and reports how long it took, so a real death and a
    transient restart look different.
    """
    start = time.time()
    while time.time() - start < seconds:
        r = ssh_run(port, user, password, "echo alive", timeout=30, echo=False)
        if r.ok and "alive" in (r.out or ""):
            waited = int(time.time() - start)
            if waited > 0:
                print("  sshd answered again after %ds%s" % (waited, (" (" + why + ")") if why else ""), flush=True)
            return True
        time.sleep(10)
    print("  sshd did not answer within %ds%s" % (seconds, (" (" + why + ")") if why else ""), flush=True)
    return False


def ssh_run(port, user, password, command, timeout=1800, echo=True):
    """Run one command over ssh. It goes as a single argv entry, so nothing inside it is
    parsed by an intermediate shell."""
    argv = [
        "sshpass", "-p", password,
        "ssh",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "ConnectTimeout=30",
        "-o", "PreferredAuthentications=password",
        "-o", "PubkeyAuthentication=no",
        "-o", "ServerAliveInterval=30",
        "-p", str(port),
        "%s@127.0.0.1" % user,
        command,
    ]
    return xsh.run(argv, echo=echo, timeout=timeout)


def parse_winget_list(text, package_id):
    """Is this id installed, per winget list?

    winget prints a column table whose widths shift with the longest name, so a substring
    match on the id is steadier than column positions - and an absent package simply does
    not appear.
    """
    for line in (text or "").splitlines():
        if package_id.lower() in line.lower():
            return True
    return False


def parse_cl(text):
    """Does this look like a working MSVC compiler?"""
    low = (text or "").lower()
    return "c/c++" in low and "compiler" in low


def stage_check_tools(port, user, password):
    # CAN THE GUEST REACH THE INTERNET AT ALL? winget installs by downloading from
    # Microsoft, and the guest sits behind QEMU user-mode NAT. ssh working proves the guest
    # is reachable from here; it says nothing about the guest reaching out. Without this the
    # failure surfaces three times as
    #     Failed in attempting to update the source: winget      exit 255
    # which reads like a winget problem rather than a network one.
    print("--- can the guest reach the internet ---", flush=True)
    # PowerShell own test, because curl through ssh gave 'Connection closed by remote
    # host' - the SSH session dropping, not curl answering, so it said nothing about the
    # network. Test-NetConnection reports whether a TCP handshake completed.
    r = ssh_run(port, user, password,
                "powershell -NoProfile -Command (Test-NetConnection cdn.winget.microsoft.com -Port 443).TcpTestSucceeded",
                timeout=180)
    out = ((r.out or "") + (r.err or "")).strip().splitlines()
    print("  TCP 443 to cdn.winget.microsoft.com -> %s" % (out[-1][:40] if out else "(no output)"), flush=True)
    r = ssh_run(port, user, password, "nslookup cdn.winget.microsoft.com", timeout=120)
    for line in ((r.out or "") + (r.err or "")).strip().splitlines()[-3:]:
        print("  dns: " + line[:90], flush=True)

    print("--- winget over ssh, and what is installed ---", flush=True)
    r = ssh_run(port, user, password, "winget --version")
    xsh.need(r.ok, "winget is not reachable over ssh: %s" % (r.err or r.out))
    print("  winget: %s" % (r.out or "").strip(), flush=True)
    r = ssh_run(port, user, password,
                "winget list --source winget --accept-source-agreements")
    already = [pid for pid, _, _ in PACKAGES if parse_winget_list(r.out, pid)]
    print("  already installed: %s" % (", ".join(already) if already else "(none)"),
          flush=True)
    return already


def stage_install(port, user, password):
    installed = stage_check_tools(port, user, password)
    for pid, extra, why in PACKAGES:
        if pid in installed:
            print("=== %s already installed ===" % pid, flush=True)
            continue
        print("=== %s ===" % pid, flush=True)
        print("  %s" % why, flush=True)
        if extra:
            # A BATCH FILE, not a command line. The switch string crosses ssh -> cmd.exe ->
            # winget -> vs_installer, and exit 87 (ERROR_INVALID_PARAMETER) is what the
            # installer returns when the quotes have been eaten by one of those layers. A
            # file has no layers above it.
            script = ("@echo off" + chr(13) + chr(10)
                      + "winget install --id " + pid + " --exact --source winget "
                      + "--accept-source-agreements --disable-interactivity "
                      + "--override " + chr(34) + extra + chr(34) + chr(13) + chr(10))
            remote = "C:/Users/%s/install-%s.bat" % (user, pid.replace(".", "-"))
            fd, local = tempfile.mkstemp(suffix=".bat")
            with os.fdopen(fd, "w", newline="") as f:
                f.write(script)
            try:
                xsh.run(["sshpass", "-p", password, "scp",
                         "-o", "StrictHostKeyChecking=no",
                         "-o", "UserKnownHostsFile=/dev/null",
                         "-P", str(port), local, "%s@127.0.0.1:%s" % (user, remote)],
                        echo=False, timeout=120)
            finally:
                os.unlink(local)
            cmd = 'cmd /c "%s"' % remote.replace("/", chr(92))
        else:
            cmd = " ".join([
                "winget", "install", "--id", pid, "--exact", "--source", "winget",
                "--accept-source-agreements", "--accept-package-agreements",
                "--disable-interactivity",
            ])
        print("  running: %s" % cmd, flush=True)
        # BuildTools with a workload is slow; ten minutes is ordinary on a fresh machine.
        r = ssh_run(port, user, password, cmd, timeout=3600)
        print("  exit %d" % r.code, flush=True)
        for line in [l for l in (r.out or "").splitlines() if l.strip()][-5:]:
            print("    " + line[:150], flush=True)
        if r.code != 0:
            print("  NOTE: winget returned %d; the machine is asked directly below" % r.code,
                  flush=True)
        # Some MSIs restart a service or the guest itself. PowerShell 7 did, and every
        # following step then failed with Connection refused - which reads as a dead machine.
        if not wait_for_ssh(port, user, password, seconds=300, why=pid):
            print("  WARNING: continuing, but sshd is not answering", flush=True)
    # ADD THE WORKLOAD, on the installed BuildTools.
    #
    # The script is a file staged with scp, for the same reason the sshd setup is: it
    # contains C:\Program Files (x86)\... with spaces and backslashes, and inline those
    # pass through ssh -> cmd.exe -> powershell, where characters get lost.
    print("=== adding the VCTools workload ===", flush=True)
    script = os.path.join(HERE, "ps", "vs-workload.ps1")
    remote = "C:/Users/%s/vs-workload.ps1" % user
    r = xsh.run(["sshpass", "-p", password, "scp",
                 "-o", "StrictHostKeyChecking=no",
                 "-o", "UserKnownHostsFile=/dev/null",
                 "-P", str(port), script, "%s@127.0.0.1:%s" % (user, remote)],
                echo=False, timeout=300)
    xsh.need(r.ok, "could not copy the workload script: %s" % (r.err or r.out))
    r = ssh_run(port, user, password,
                "powershell -NoProfile -ExecutionPolicy Bypass -File " + remote,
                timeout=3600)
    out = ((r.out or "") + (r.err or "")).strip()
    for line in out.splitlines()[-10:]:
        print("  " + line[:140], flush=True)

    # The script asks the product whether VCTools is there, because the exit code has been
    # misleading three times. Its answer, not the code, is what this step reports.
    if "VCTOOLS_PRESENT" in out:
        print("  VCTools is present", flush=True)
    else:
        print("  NOTE: VCTools not reported present; the compile check below decides", flush=True)

    return stage_verify(port, user, password)
    return stage_verify(port, user, password)


def stage_verify(port, user, password):
    """Prove the toolchain works, rather than trusting a winget exit code.

    An installer's exit code says a program ran, not that a compiler exists. So this asks
    the machine what it has, then compiles and runs something.

    The compile goes through a PowerShell FILE staged with scp, never inline: inline would
    mean escaping C:\\\\ paths and nested quotes once for python and again for powershell,
    which is the fault this project spent many rounds removing.
    """
    print("=== what the machine has ===", flush=True)
    failures = []

    r = ssh_run(port, user, password, "winget list --source winget", timeout=300)
    for pid, _, _ in PACKAGES:
        present = parse_winget_list(r.out, pid)
        print("  %-45s %s" % (pid, "installed" if present else "MISSING"), flush=True)
        if not present:
            failures.append(pid)

    # BuildTools is checked by asking vswhere, not winget: it is installed by the evergreen
    # bootstrapper, so winget may not list it at all, and what matters is whether the product
    # and its VCTools workload exist.
    print("  %-45s %s" % ("Visual Studio BuildTools + VCTools", "checking..."), flush=True)

    # pwsh is the PowerShell 7 binary; Windows PowerShell 5.1 is powershell.exe. Checking the
    # executable rather than only the winget entry, because 'installed' and 'runs' differ.
    # pwsh is the PowerShell 7 binary; Windows PowerShell 5.1 is powershell.exe. Checked by
    # running it, not by reading the winget entry - installed and runs are different claims.
    #   pwsh -v  prints just the version, and needs no quotes or dollar signs.
    print("--- pwsh ---", flush=True)
    r = ssh_run(port, user, password, "pwsh -v", timeout=300)
    pwsh_out = ((r.out or "") + (r.err or "")).strip()
    # Search the whole output for the same reason as dotnet: ssh host-key warnings arrive
    # after the real answer. pwsh -v prints "PowerShell 7.6.9", not a bare version number.
    found = None
    for line in pwsh_out.splitlines():
        if re.search(r"PowerShell [0-9]+[.][0-9]+", line):
            found = line.strip()
            break
    print("  %s" % (found or "(no version in output)"), flush=True)
    if not found:
        failures.append("pwsh")

    # FULL PATH, because winget does not refresh PATH for sessions that already exist. The
    # install succeeded - winget reported it and the SDK is on disk - but a new ssh session
    # still sees the old environment and answers 'sdk-not-found' for the bare name.
    print("--- dotnet ---", flush=True)
    dotnet = ("C:" + chr(92) + "Program Files" + chr(92) + "dotnet" + chr(92) + "dotnet.exe")
    r = ssh_run(port, user, password, '"' + dotnet + '" --version', timeout=300)
    # SEARCH THE WHOLE OUTPUT, not the last line. ssh writes its host-key warning to stderr,
    # r.err and r.out are concatenated, and the warning therefore arrives after the version -
    # so looking at the last line reported 10.0.403 as a failure on the run that proved it
    # worked.
    out = ((r.out or "") + (r.err or "")).strip()
    version = None
    for line in out.splitlines():
        t = line.strip()
        if re.match(r"^[0-9]+[.][0-9]+[.][0-9]+", t):
            version = t
            break
    print("  %s" % (version or "(no version in output)"), flush=True)
    if not version:
        failures.append("dotnet")

    print("--- compile and run a program with MSVC ---", flush=True)
    script = os.path.join(HERE, "ps", "msvc-check.ps1")
    xsh.need(os.path.exists(script), "missing %s" % script)
    remote = "C:/Users/%s/msvc-check.ps1" % user
    r = xsh.run(["sshpass", "-p", password, "scp",
                 "-o", "StrictHostKeyChecking=no",
                 "-o", "UserKnownHostsFile=/dev/null",
                 "-P", str(port), script, "%s@127.0.0.1:%s" % (user, remote)],
                echo=False, timeout=300)
    xsh.need(r.ok, "could not copy the build script to the guest: %s" % (r.err or r.out))
    r = ssh_run(port, user, password,
                "powershell -NoProfile -ExecutionPolicy Bypass -File " + remote,
                timeout=900)
    out = (r.out or "") + (r.err or "")
    if "hello-from-msvc" in out:
        print("  compiled and ran: hello-from-msvc", flush=True)
    else:
        for line in out.strip().splitlines()[-6:]:
            print("  " + line[:150], flush=True)
        failures.append("compile+run")

    if failures:
        print("FAIL: %s" % ", ".join(failures), flush=True)
        return 1
    print("VERIFIED: SDK, MSVC and .NET SDK all present and working", flush=True)
    return 0


def selftest():
    bad = 0
    listing = (
        "Name                             Id                                     Version\n"
        "-----------------------------------------------------------------------------\n"
        "Visual Studio Build Tools 2022   Microsoft.VisualStudio.2022.BuildTools  17.9.7\n"
        ".NET SDK 10.0.403                Microsoft.DotNet.SDK.10                10.0.403\n"
    )
    for desc, text, pid, want in [
        ("buildtools present", listing, "Microsoft.VisualStudio.2022.BuildTools", True),
        ("dotnet present", listing, "Microsoft.DotNet.SDK.10", True),
        ("windows sdk absent", listing, "Microsoft.WindowsSDK.10", False),
        ("powershell present", listing + "PowerShell 7.6.9  Microsoft.PowerShell  7.6.9" + chr(10),
         "Microsoft.PowerShell", True),
        ("empty listing", "", "Microsoft.DotNet.SDK.10", False),
    ]:
        got = parse_winget_list(text, pid)
        bad += got != want
        print("  %s %-22s -> %s" % ("ok " if got == want else "FAIL", desc, got))

    for desc, text, want in [
        ("cl banner", "Microsoft (R) C/C++ Optimizing Compiler Version 19.39.33523", True),
        ("no compiler", "NO_CL", False),
        ("empty", "", False),
    ]:
        got = parse_cl(text)
        bad += got != want
        print("  %s %-22s -> %s" % ("ok " if got == want else "FAIL", desc, got))

    # The PowerShell file must survive to disk with its Windows paths intact - a \\v or \\s
    # eaten as a python escape is exactly what broke the first attempt at building it.
    # Both PowerShell files must reach disk with their Windows paths intact. A backslash-v
    # or backslash-s eaten as a python escape is what broke the first attempt at writing
    # them - the file said Installerswhere.exe instead of Installer + backslash + vswhere.
    # The needle is built with chr(92) for the same reason: written as an escape in this
    # source it would be eaten on the way into the file too.
    bslash = chr(92)
    for name, needles in [
        ("msvc-check.ps1", ["Installer" + bslash + "vswhere.exe",
                            "Build" + bslash + "vcvars64.bat", "hello-from-msvc"]),
        ("vs-workload.ps1", ["Installer" + bslash + "vswhere.exe",
                             "setup.exe", "Start-Process", "Workload.VCTools",
                             "VCTOOLS_PRESENT"]),
    ]:
        path = os.path.join(HERE, "ps", name)
        if not os.path.exists(path):
            print("  FAIL %s missing" % name)
            bad += 1
            continue
        body = open(path).read()
        for needle in needles:
            got = needle in body
            bad += not got
            print("  %s %-18s %-26s -> %s" % ("ok " if got else "FAIL", name, needle[:26], got))

    script = os.path.join(HERE, "ps", "msvc-check.ps1")
    if os.path.exists(script):
        body = open(script).read()
        for needle, desc in [
            ("Installer\\vswhere.exe", "vswhere path intact"),
            ("Build\\vcvars64.bat", "vcvars path intact"),
            ("hello-from-msvc", "program text intact"),
        ]:
            got = needle in body
            bad += not got
            print("  %s %-22s -> %s" % ("ok " if got else "FAIL", desc, got))
    else:
        print("  FAIL ps/msvc-check.ps1 missing")
        bad += 1

    print("\n%s" % ("all cases passed" if bad == 0 else "%d FAILED" % bad))
    return 0 if bad == 0 else 1


def main(argv=None):
    argv = argv if argv is not None else sys.argv[1:]
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", type=int, default=2222)
    ap.add_argument("--user", default="docker")
    ap.add_argument("--password", default="admin")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--verify-only", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()
    if args.verify_only:
        return stage_verify(args.port, args.user, args.password)
    return stage_install(args.port, args.user, args.password)


if __name__ == "__main__":
    sys.exit(main())
