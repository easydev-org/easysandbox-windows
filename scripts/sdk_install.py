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
import sys
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
    # No --override. winget rejected the combination and printed help (exit 2). The
    # workload is passed the way winget documents for this package instead.
    ("Microsoft.VisualStudio.2022.BuildTools",
     ["--add", "Microsoft.VisualStudio.Workload.VCTools", "--includeRecommended"],
     "MSVC, the Windows SDK and CMake; a bare install has no cl.exe"),
    ("Microsoft.WindowsSDK.10.0.26100", None, "the SDK on its own"),
    ("Microsoft.DotNet.SDK.10", None, "the .NET SDK, which VCTools does not include"),
]


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
    r = ssh_run(port, user, password, 'curl -s -o NUL -w "%{http_code}" --max-time 20 https://cdn.winget.microsoft.com/cache', timeout=120)
    code = ((r.out or "") + (r.err or "")).strip().splitlines()
    print("  https://cdn.winget.microsoft.com  -> %s" % (code[-1][:60] if code else "(no output)"), flush=True)
    r = ssh_run(port, user, password, "nslookup cdn.winget.microsoft.com", timeout=120)
    for line in ((r.out or "") + (r.err or "")).strip().splitlines()[-4:]:
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
        parts = ["winget", "install", "--id", pid, "--exact", "--source", "winget",
                 "--accept-source-agreements", "--accept-package-agreements",
                 "--disable-interactivity"]
        if extra:
            parts += extra
        cmd = " ".join(parts)
        print("  running: %s" % cmd, flush=True)
        # BuildTools with a workload is slow; ten minutes is ordinary on a fresh machine.
        r = ssh_run(port, user, password, cmd, timeout=3600)
        print("  exit %d" % r.code, flush=True)
        for line in [l for l in (r.out or "").splitlines() if l.strip()][-5:]:
            print("    " + line[:150], flush=True)
        if r.code != 0:
            print("  NOTE: winget returned %d; the machine is asked directly below" % r.code,
                  flush=True)
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

    print("--- dotnet ---", flush=True)
    r = ssh_run(port, user, password, "dotnet --version", timeout=300)
    print("  %s" % ((r.out or r.err or "").strip()[:120] or "(no output)"), flush=True)
    if not r.ok:
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
