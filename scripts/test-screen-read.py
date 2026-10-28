#!/usr/bin/env python3
"""Exercise screen-read.py's helpers against real framebuffer dumps.

    test-screen-read.py <a.ppm> [b.ppm ...]

Prints, for each file, the distinct-colour count, whether the blank test fires,
and the taskbar verdict with its detail line. Used to calibrate the pixel test
against actual screens rather than guessed ones.
"""
import importlib.util
import sys

src = open(__file__.rsplit("/", 1)[0] + "/screen-read.py").read().rsplit("main()", 1)[0]
ns = {}
exec(compile(src, "screen-read.py", "exec"), ns)

for path in sys.argv[1:]:
    w, h, px, mx = ns["read_ppm"](path)
    print("=== %s (%dx%d, maxval %d) ===" % (path, w, h, mx))
    colours = set()
    for y in range(0, h, 16):
        base = y * w * 3
        for x in range(0, w, 16):
            k = base + x * 3
            colours.add((px[k], px[k + 1], px[k + 2]))
            if len(colours) > 40:
                break
        if len(colours) > 40:
            break
    print("  sampled colours: %d" % len(colours))
    print("  blank: %s" % ns["blank"](w, h, px))
    found, detail = ns["taskbar"](w, h, px)
    print("  taskbar: %s  (%s)" % (found, detail))
    # Row profile for the bottom eighth, which is where a taskbar lives.
    print("  bottom rows (y, dom colour, uniformity):")
    for y, colour, uni in ns["rows"](w, h, px):
        if y >= int(h * 0.93):
            print("    %4d  #%02x%02x%02x  %.2f" % (y, colour[0], colour[1], colour[2], uni))

# Synthetic checks, so the taskbar test is exercised in both directions without
# needing a real desktop dump on hand. These build tiny P6 files in /tmp.
def synth(w, h, bg, band=None, band_h=40, band_colour=(32, 32, 32)):
    buf = bytearray()
    buf += b"P6\n%d %d\n255\n" % (w, h)
    for y in range(h):
        if band and y >= h - band_h:
            buf += bytes(band_colour) * w
        else:
            buf += bytes(bg) * w
    return bytes(buf)

import os

cases = [
    ("flat blue (an install screen's background)", synth(320, 200, (0, 90, 158))),
    ("desktop: light bg + dark taskbar", synth(320, 200, (230, 230, 230), band=True)),
    ("desktop: dark bg + lighter taskbar", synth(320, 200, (20, 20, 24), band=True,
                                                 band_colour=(60, 60, 66))),
    ("install: light bg, NO taskbar", synth(320, 200, (240, 240, 240))),
    ("black", synth(320, 200, (0, 0, 0))),
]
print()
print("=== synthetic cases ===")
for name, data in cases:
    p = "/tmp/synth-%d.ppm" % abs(hash(name) % 10000)
    with open(p, "wb") as fh:
        fh.write(data)
    w, h, px, mx = ns["read_ppm"](p)
    found, detail = ns["taskbar"](w, h, px)
    print("  %-42s taskbar=%-5s blank=%-5s  %s"
          % (name, found, ns["blank"](w, h, px), detail))
