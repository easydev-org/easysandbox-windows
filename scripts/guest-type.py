#!/usr/bin/env python3
"""Type text into a running QEMU guest through its HMP monitor.

    guest-type.py <monitor.sock> [--wait N] "<text>" [--enter]
    guest-type.py <monitor.sock> [--wait N] --key ctrl+esc
    guest-type.py <monitor.sock> [--wait N] --raw "sendkey ret"

WHY HMP sendkey. This makes no claims about what is running inside the guest: no
agent, no shared folder, no network service. It presses keys, which is what a person
at the console would do, so it works on a freshly booted Windows with no software
installed at all.

HMP's sendkey takes a key name, not a character: 'a', 'shift-a', 'spc', 'dot',
'minus', and modifier chords as 'ctrl-alt-delete'. So text is mapped to key names
here rather than passed through, and anything unmappable is refused loudly instead of
being silently dropped - a command that types out subtly wrong is far worse than one
that fails.

Windows-specific notes:
  * open PowerShell with win+r then typing 'powershell' - the Run box accepts text
    immediately, unlike the Start menu's search.
  * a space is 'spc'; HMP has no literal space key name.
"""
import socket
import sys
import time


# HMP key names for the printable ASCII this project needs. Letters are lower case and
# prefixed with shift- where upper case is required.
LETTERS = "abcdefghijklmnopqrstuvwxyz"
DIGITS = "0123456789"
PUNCT = {
    " ": "spc",
    "-": "minus",
    "=": "equal",
    ".": "dot",
    ",": "comma",
    "/": "slash",
    "\\": "backslash",
    ":": "shift-semicolon",
    ";": "semicolon",
    "'": "apostrophe",
    '"': "shift-apostrophe",
    "_": "shift-minus",
    "(": "shift-9",
    ")": "shift-0",
    "[": "bracket_left",
    "]": "bracket_right",
    "|": "shift-backslash",
    "$": "shift-4",
    "&": "shift-7",
    "%": "shift-5",
    "#": "shift-3",
    "@": "shift-2",
    "!": "shift-1",
    "*": "shift-8",
    "+": "shift-equal",
    "<": "shift-comma",
    ">": "shift-dot",
    "?": "shift-slash",
    "^": "shift-6",
    "~": "shift-apostrophe",
    "`": "grave_accent",
}


def keyname(ch):
    if ch in LETTERS:
        return ch
    if ch in DIGITS:
        return ch
    if ch in PUNCT:
        return PUNCT[ch]
    if ch.isupper() and ch.lower() in LETTERS:
        return "shift-" + ch.lower()
    raise SystemExit("guest-type: cannot map %r to a key name" % ch)


class Monitor:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(20)
        self.s.connect(path)
        time.sleep(0.4)
        try:
            self.s.recv(65536)
        except socket.timeout:
            pass

    def cmd(self, line):
        self.s.sendall((line + "\n").encode())
        time.sleep(0.05)

    def close(self):
        try:
            self.s.close()
        except Exception:
            pass


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    path = sys.argv[1]
    rest = sys.argv[2:]
    wait = 0.0
    enter = False
    mode = "text"
    payload = []

    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--wait":
            wait = float(rest[i + 1]); i += 2; continue
        if a == "--enter":
            enter = True; i += 1; continue
        if a == "--key":
            mode = "key"; payload.append(rest[i + 1]); i += 2; continue
        if a == "--raw":
            mode = "raw"; payload.append(rest[i + 1]); i += 2; continue
        payload.append(a); i += 1

    if wait:
        time.sleep(wait)

    mon = Monitor(path)
    try:
        if mode == "raw":
            for line in payload:
                mon.cmd(line)
            print("sent: %s" % " ; ".join(payload))
        elif mode == "key":
            for k in payload:
                mon.cmd("sendkey " + k)
            print("sent key: %s" % ", ".join(payload))
        else:
            text = " ".join(payload)
            for ch in text:
                mon.cmd("sendkey " + keyname(ch))
            if enter:
                mon.cmd("sendkey ret")
            print("typed %d characters%s" % (len(text), " and pressed Enter" if enter else ""))
        time.sleep(0.3)
    finally:
        mon.close()


main()
