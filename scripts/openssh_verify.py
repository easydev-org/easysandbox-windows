#!/usr/bin/env python3
"""Decide whether OpenSSH on the guest actually works, in Python.

WHY NOT SHELL. Every wrong answer this pipeline gave about SSH came from a shell test, and
every one of those tests was the same shape: match some text in some output.

  case "$out" in *SSH-OK*)      matched the command echoed back inside an ssh warning
  reject if output has ';'      rejected a real success, because cmd.exe does not treat
                                ';' as a separator and the command printed itself
  second line == "docker"       rejected a real success, because Windows' whoami returns
                                COMPUTERNAME\\user

Three verdicts, none of them about SSH. In Python the parsing is testable without a
container, a VM or twenty minutes: every function below takes text and returns a value,
and the module has a --selftest mode that runs them against the exact strings seen in the
logs. That is the point of the rewrite - not brevity, but being able to check the checker.

WHAT IS TESTED. Three things, in increasing strength:

  connect    a TCP connection can be opened to the port
  banner     the peer speaks first with "SSH-2.0-..."
  login      sshpass authenticates and a command's OUTPUT comes back

Login is the only one that proves the task; the other two are steps towards it and are
reported separately so a failure says which stage broke.
"""
import argparse
import re
import sys
import time

import xsh


def parse_login(stdout, stderr, user):
    """Read the output of `echo SSH-OK && whoami && hostname` and say whether it ran.

    Returns (ok, detail). The rules are here, in one place, because getting them wrong is
    what produced both the false green and the false red in earlier versions.
    """
    out = (stdout or "").replace("\r", "")
    lines = [l.strip() for l in out.splitlines() if l.strip()]

    if not lines:
        return False, "no output; stderr: %s" % (stderr or "").strip()[:200]

    # A single line containing every command is the failure mode where the remote shell
    # echoed the command instead of running it. With '&&' as the separator this should not
    # happen; if it does, say so rather than passing.
    if len(lines) == 1 and "&&" in lines[0]:
        return False, "the command was echoed, not executed: %r" % lines[0][:120]

    if lines[0] != "SSH-OK":
        return False, "first line is %r, expected 'SSH-OK'" % lines[0][:80]

    if len(lines) < 2:
        return False, "no whoami line after SSH-OK"

    # Windows' whoami prints COMPUTERNAME\user. Linux would print just the user. Accept
    # either, and require that the last path component is the account we asked for.
    who = lines[1]
    account = re.split(r"[\\/]", who)[-1].strip()
    if account.lower() != user.lower():
        return False, "logged in as %r, expected %r" % (who, user)

    host = lines[2] if len(lines) > 2 else ""
    return True, "logged in as %s on %s" % (who, host or "(hostname not printed)")


def parse_banner(text):
    """True if the text contains an SSH identification line."""
    return bool(re.search(r"SSH-\d\.\d-", text or ""))


def stage_connect(host, port, timeout):
    """Can a TCP connection be opened at all?"""
    import socket
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True, "connected"
    except Exception as exc:
        return False, "connect failed: %s" % exc


def stage_banner(host, port, timeout):
    """Does the peer speak SSH first? Read with a generous window - the banner here has
    taken ten seconds, and a six-second read was reported as 'nothing' for many rounds."""
    import socket
    try:
        s = socket.create_connection((host, port), timeout=timeout)
    except Exception as exc:
        return False, "connect failed: %s" % exc
    try:
        s.settimeout(timeout)
        data = s.recv(256)
    except Exception:
        data = b""
    finally:
        try:
            s.close()
        except Exception:
            pass
    text = data.decode("latin-1", "replace")
    if parse_banner(text):
        return True, text.strip()
    return False, "connected but silent (%d bytes)" % len(data)


def stage_login(host, port, user, password, timeout):
    """Authenticate and run a command; success means its output came back."""
    r = xsh.run(
        [
            "sshpass", "-p", password,
            "ssh",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=%d" % timeout,
            "-o", "PreferredAuthentications=password",
            "-o", "PubkeyAuthentication=no",
            "-p", str(port),
            "%s@%s" % (user, host),
            # '&&' is a separator in cmd.exe; ';' is not, and using it is what made the
            # command echo itself back for several rounds.
            "echo SSH-OK && whoami && hostname",
        ],
        echo=False,
        timeout=timeout + 30,
    )
    return parse_login(r.out, r.err, user)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=2222)
    ap.add_argument("--user", default="docker")
    ap.add_argument("--password", default="admin")
    ap.add_argument("--attempts", type=int, default=6)
    ap.add_argument("--wait", type=int, default=30, help="per-read timeout, seconds")
    ap.add_argument("--selftest", action="store_true",
                    help="check the parsers against strings seen in real logs")
    args = ap.parse_args(argv)

    if args.selftest:
        # Return rather than exit: openssh_setup.py calls this to chain several selftests,
        # and sys.exit here would end the process after the first one - silently skipping
        # the rest while still reporting success.
        return selftest()

    target = "%s:%d" % (args.host, args.port)
    for attempt in range(1, args.attempts + 1):
        print("\n=== attempt %d/%d against %s ===" % (attempt, args.attempts, target), flush=True)

        ok, detail = stage_connect(args.host, args.port, 10)
        print("  connect: %s (%s)" % ("ok" if ok else "FAILED", detail), flush=True)
        if not ok:
            time.sleep(15)
            continue

        ok, detail = stage_banner(args.host, args.port, args.wait)
        print("  banner:  %s (%s)" % ("ok" if ok else "FAILED", detail), flush=True)

        ok, detail = stage_login(args.host, args.port, args.user, args.password, args.wait)
        print("  login:   %s (%s)" % ("ok" if ok else "FAILED", detail), flush=True)
        if ok:
            print("\nVERIFIED: ssh login works on %s as %s" % (target, args.user), flush=True)
            return 0
        time.sleep(15)

    print("\nNOT VERIFIED: no working login on %s after %d attempts" % (target, args.attempts),
          flush=True)
    return 1


def selftest():
    """Run the parsers against the exact strings from the logs. No container needed."""
    cases = [
        # (description, stdout, stderr, user, expected_ok)
        ("real Windows success",
         "SSH-OK\nwin-uf78lq2l2e8\\docker\nWIN-UF78LQ2L2E8\n", "", "docker", True),
        ("real Linux success", "SSH-OK\ndocker\nmyhost\n", "", "docker", True),
        ("command echoed, not run",
         "SSH-OK; whoami; hostname\n",
         "Warning: Permanently added '[127.0.0.1]:2222' (ED25519) to the list of known hosts.",
         "docker", False),
        ("echoed with && (should not happen)",
         "SSH-OK && whoami && hostname\n", "", "docker", False),
        ("wrong account", "SSH-OK\nwin-x\\root\nHOST\n", "", "docker", False),
        ("permission denied", "", "Permission denied (publickey,password).", "docker", False),
        ("connection reset", "", "kex_exchange_identification: read: Connection reset by peer",
         "docker", False),
        ("only SSH-OK", "SSH-OK\n", "", "docker", False),
    ]
    bad = 0
    for desc, out, err, user, want in cases:
        got, detail = parse_login(out, err, user)
        mark = "ok " if got == want else "FAIL"
        if got != want:
            bad += 1
        print("  %s %-38s -> %-5s (wanted %-5s) %s" % (mark, desc, got, want, detail[:60]))

    for text, want in [("SSH-2.0-OpenSSH_for_Windows_10.0 Win32-OpenSSH-GitHub", True),
                       ("HTTP/1.1 200 OK", False),
                       ("", False)]:
        got = parse_banner(text)
        mark = "ok " if got == want else "FAIL"
        if got != want:
            bad += 1
        print("  %s banner %-32r -> %s" % (mark, text[:30], got))

    print("\n%s" % ("all parser cases passed" if bad == 0 else "%d CASE(S) FAILED" % bad))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
