#!/usr/bin/env python3
"""One place to run external commands, so quoting is not something to get right each time.

WHY THIS EXISTS. Six separate failures in this pipeline came from shell quoting, none of
them from logic:

  hostfwd=[^                    a bracket class eaten by an outer shell
  awk: backslash not last ...   a backslash lost through docker exec -> sh -c
  chain: unbound variable       $chain expanded by the host instead of the container
  INPUT_INTERVAL: ''            a YAML value that vanished
  (pattern never matched)       a backslash-dollar written as a literal
  sshpass: 'SSH-OK' rejected    glob rules assumed to be python rules

Each cost a twenty-minute CI run to discover, and each was a syntax accident. The cure is
not to be more careful; it is to stop asking a shell to carry data. Every call here passes
an argv list with shell=False, so no metacharacter in an argument is ever interpreted.

For the cases that genuinely need a shell (a pipeline inside a container), the script is
written to a FILE and executed, never inlined into another quoted string - a file has no
layer above it to escape through.
"""
import shlex
import subprocess
import sys


class Result:
    """The outcome of one command, with everything a caller might want to inspect."""

    def __init__(self, argv, code, out, err):
        self.argv = argv
        self.code = code
        self.out = out
        self.err = err

    @property
    def ok(self):
        return self.code == 0

    @property
    def text(self):
        return (self.out or "") + (self.err or "")

    def __str__(self):
        return "%s -> %d\n  stdout: %s\n  stderr: %s" % (
            " ".join(shlex.quote(a) for a in self.argv),
            self.code,
            (self.out or "").strip()[:400],
            (self.err or "").strip()[:400],
        )


def run(argv, check=False, echo=True, input_text=None, timeout=None):
    """Run argv (a list) with no shell. Returns a Result; raises only if check and it fails."""
    if not isinstance(argv, (list, tuple)):
        raise TypeError("xsh.run takes a list of arguments, not a string: %r" % (argv,))
    argv = [str(a) for a in argv]
    if echo:
        print("$ " + " ".join(shlex.quote(a) for a in argv), flush=True)
    try:
        p = subprocess.run(
            argv,
            input=input_text,
            capture_output=True,
            text=True,
            timeout=timeout,
            shell=False,
        )
        r = Result(argv, p.returncode, p.stdout, p.stderr)
    except FileNotFoundError as exc:
        r = Result(argv, 127, "", str(exc))
    except subprocess.TimeoutExpired:
        r = Result(argv, 124, "", "timed out after %ss" % timeout)
    if echo and (r.out or r.err):
        for line in (r.out or "").rstrip().splitlines()[-6:]:
            print("  " + line, flush=True)
        for line in (r.err or "").rstrip().splitlines()[-3:]:
            print("  ! " + line, flush=True)
    if check and not r.ok:
        raise Fail(r)
    return r


class Fail(Exception):
    def __init__(self, result):
        self.result = result
        super().__init__(str(result))


def docker_exec(container, script, check=False, echo=True):
    """Run a shell script INSIDE a container, from a file, with no extra quoting layer.

    The script is written to the container and executed there. Passing a multi-line string
    through `docker exec ... sh -c "<script>"` is exactly the nesting that produced three
    of the six quoting faults - the host expands $vars meant for the container, and any
    backslash has to survive two levels. A file has none of that.
    """
    import os
    import tempfile

    fd, path = tempfile.mkstemp(suffix=".sh", prefix="xsh-")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(script)
        remote = "/tmp/%s.sh" % os.path.basename(path).replace(".sh", "")
        run(["docker", "cp", path, "%s:%s" % (container, remote)], check=True, echo=echo)
        return run(["docker", "exec", container, "sh", remote], check=check, echo=echo)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def need(condition, message):
    """Fail loudly. A step that cannot do its job must not report success."""
    if not condition:
        print("FAIL: " + message, file=sys.stderr, flush=True)
        raise SystemExit(1)
