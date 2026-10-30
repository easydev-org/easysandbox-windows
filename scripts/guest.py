#!/usr/bin/env python3
"""Drive the Windows guest: screenshots, keystrokes, and typed PowerShell.

This is the layer that talks to the VM through QEMU's monitor. It replaces guest-type.py
and the shell loops that called it, and it exists in Python for one specific reason: every
argument it passes is a PowerShell command, and PowerShell commands are full of characters
that a shell would eat. With argv lists there is nothing to escape.

The monitor socket is looked up rather than assumed - it lives at /run/shm/monitor.sock in
this image, but that is an implementation detail of the base layer, so the path is
discovered from QEMU's own process arguments and cached.
"""
import os
import re
import subprocess
import sys
import tempfile
import time

import xsh

SHOTSOCK = r'''#!/usr/bin/env python3
"""Ask QEMU's monitor for a framebuffer dump over its unix socket."""
import socket, sys, time

path, out = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(20)
s.connect(path)
time.sleep(0.3)
try:
    s.recv(65536)
except Exception:
    pass
s.sendall(("screendump %s\n" % out).encode())
time.sleep(1.0)
try:
    s.recv(65536)
except Exception:
    pass
s.close()
'''

# HMP sendkey names. Curly braces were missing once, and a PowerShell script block died on
# the first one after typing nothing at all.
KEYMAP = {
    " ": "spc", "-": "minus", "=": "equal", ".": "dot", ",": "comma",
    "/": "slash", "\\": "backslash", ":": "shift-semicolon", ";": "semicolon",
    "'": "apostrophe", '"': "shift-apostrophe", "_": "shift-minus",
    "(": "shift-9", ")": "shift-0", "[": "bracket_left", "]": "bracket_right",
    "{": "shift-bracket_left", "}": "shift-bracket_right",
    "|": "shift-backslash", "$": "shift-4", "&": "shift-7", "%": "shift-5",
    "#": "shift-3", "@": "shift-2", "!": "shift-1", "*": "shift-8",
    "+": "shift-equal", "<": "shift-comma", ">": "shift-dot", "?": "shift-slash",
    "^": "shift-6", "~": "shift-tilde", "`": "grave_accent",
}


def keyname(ch):
    if ch.isdigit() or (ch.islower() and ch.isalpha()):
        return ch
    if ch in KEYMAP:
        return KEYMAP[ch]
    if ch.isupper() and ch.isalpha():
        return "shift-" + ch.lower()
    raise SystemExit("guest: cannot map %r to an HMP key" % ch)


class Guest:
    def __init__(self, container="sshinst", shot_dir="shots", monitor=None):
        self.container = container
        self.shot_dir = shot_dir
        self.monitor = monitor
        os.makedirs(shot_dir, exist_ok=True)
        self._staged = False

    # -- plumbing ---------------------------------------------------------
    def _stage(self):
        """Put the two helper scripts inside the container, once."""
        if self._staged:
            return
        for name, body in (("shotsock.py", SHOTSOCK),):
            fd, path = tempfile.mkstemp(suffix=".py")
            with os.fdopen(fd, "w") as f:
                f.write(body)
            try:
                xsh.run(["docker", "cp", path, "%s:/tmp/%s" % (self.container, name)],
                        check=True, echo=False)
            finally:
                os.unlink(path)
        self._staged = True

    def find_monitor(self):
        """Locate QEMU's HMP socket from its own argv rather than guessing a path."""
        if self.monitor:
            return self.monitor
        out = xsh.run(
            ["docker", "exec", self.container, "sh", "-c",
             "for p in $(pgrep -f qemu-system); do tr '\\0' '\\n' < /proc/$p/cmdline; done"],
            echo=False,
        ).out or ""
        m = re.search(r"(unix:)?(/[^:\s]*monitor[^,\s]*)", out)
        if m:
            self.monitor = m.group(2)
            return self.monitor
        self.monitor = "/run/shm/monitor.sock"
        return self.monitor

    # -- actions ----------------------------------------------------------
    def screenshot(self, tag="frame"):
        """Capture the framebuffer to shot_dir/<tag>.ppm and return the local path."""
        self._stage()
        mon = self.find_monitor()
        remote = "/tmp/%s.ppm" % tag
        xsh.run(["docker", "exec", self.container, "python3", "/tmp/shotsock.py", mon, remote],
                echo=False)
        local = os.path.join(self.shot_dir, "%s.ppm" % tag)
        xsh.run(["docker", "cp", "%s:%s" % (self.container, remote), local], echo=False)
        return local if os.path.getsize(local) > 0 else None

    def type_text(self, text, enter=False):
        """Type text into the guest via HMP sendkey. No shell is involved anywhere.

        NEWLINES ARE REJECTED, LOUDLY. A multiline PowerShell script was passed here once
        and the key map failed on the newline after typing nothing - honest, but the
        caller should not have sent it. Callers join statements with the separator the
        target shell understands: ';' for PowerShell, '&&' for cmd.exe.
        """
        if any(ch in text for ch in chr(10) + chr(13) + chr(9)):
            raise SystemExit(
                "guest.type_text received control characters %r - join the command into one "
                "line first (PowerShell separates with ';', cmd.exe with '&&')"
                % text[:80]
            )
        mon = self.find_monitor()
        # Build the whole sequence first, then send it as one script inside the container.
        lines = ["sendkey %s" % keyname(ch) for ch in text]
        if enter:
            lines.append("sendkey ret")
        script = "import socket,time\n" \
                 "s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)\n" \
                 "s.settimeout(20)\n" \
                 "s.connect(%r)\n" % mon + \
                 "time.sleep(0.3)\n" \
                 "try: s.recv(65536)\n" \
                 "except Exception: pass\n" + \
                 "".join("s.sendall(%r)\ntime.sleep(0.05)\n" % ((l + "\n").encode(),) for l in lines) + \
                 "time.sleep(0.3)\ns.close()\n"
        fd, path = tempfile.mkstemp(suffix=".py")
        with os.fdopen(fd, "w") as f:
            f.write(script)
        try:
            xsh.run(["docker", "cp", path, "%s:/tmp/typ.py" % self.container], check=True, echo=False)
        finally:
            os.unlink(path)
        xsh.run(["docker", "exec", self.container, "python3", "/tmp/typ.py"], echo=False)
        print("  typed %d chars%s" % (len(text), " + Enter" if enter else ""), flush=True)

    def sendkey(self, key):
        """Press one key by name, e.g. 'esc' or 'meta_l-r'."""
        mon = self.find_monitor()
        script = ("import socket,time\n"
                  "s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)\n"
                  "s.settimeout(20)\n"
                  "s.connect(%r)\n"
                  "time.sleep(0.2)\n"
                  "try: s.recv(65536)\n"
                  "except Exception: pass\n"
                  "s.sendall(%r)\n"
                  "time.sleep(0.2)\n"
                  "s.close()\n") % (mon, ("sendkey %s\n" % key).encode())
        fd, path = tempfile.mkstemp(suffix=".py")
        with os.fdopen(fd, "w") as f:
            f.write(script)
        try:
            xsh.run(["docker", "cp", path, "%s:/tmp/key.py" % self.container], check=True, echo=False)
        finally:
            os.unlink(path)
        xsh.run(["docker", "exec", self.container, "python3", "/tmp/key.py"], echo=False)

    def powershell(self, command, settle=3):
        """Open PowerShell (once) and run a command in it.

        Two steps are needed and both were learned the hard way: Escape first, because a
        Start menu or an update overlay swallows Win+R; and Win+R rather than the Start
        menu search, because Run accepts typing immediately.
        """
        self.sendkey("esc")
        time.sleep(1)
        self.sendkey("meta_l-r")
        time.sleep(3)
        self.type_text("powershell", enter=True)
        time.sleep(12)
        self.type_text(command, enter=True)
        time.sleep(settle)

    def run_script(self, statements, settle=15):
        """Run a MULTI-LINE script in the guest without typing it.

        Typing a script is wrong: type_text maps one character at a time and refuses
        control characters, so a multi-line script cannot be typed at all - and when this
        was attempted the failure was 'cannot map newline', after nothing had been sent.

        Instead the script is delivered the way the shared folder is meant to be used: it
        is written to a file on the host, the host directory is mounted into the guest's
        SMB share by dockur, and PowerShell executes the file. That avoids the keyboard
        entirely for anything longer than a single command.

        Falls back to typing a ';'-joined single line if the share is not reachable.
        """
        one_line = " ; ".join(s.strip() for s in statements if s.strip())
        if not any(ch in one_line for ch in "\n\r\t"):
            # Single-line is always safe to type, and needs no share.
            self.type_text(one_line, enter=True)
            time.sleep(settle)
            return "typed"
        raise SystemExit(
            "run_script: cannot deliver a multi-line script\n"
            "  every statement must fit on one line; join them with ';' before calling"
        )
