#!/usr/bin/env python3
"""Turn a frame directory into a readable timeline plus an index page.

    frames-report.py <dir> [out.html]

The verdict per frame comes from frames.tsv, written by frames-loop.sh while the raw
framebuffer was still available - the taskbar test needs P6 pixels and cannot be re-run
from a PNG. Without the manifest the frames are still listed, just without a stage.

The HTML is a plain grid, so a whole boot can be scrolled through in a browser after
the run, which is the point of keeping fifty images.
"""
import os
import sys


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: frames-report.py <dir> [out.html]")
    directory = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(directory, "index.html")

    stages, elapsed = {}, {}
    manifest = os.path.join(directory, "frames.tsv")
    if os.path.exists(manifest):
        for line in open(manifest):
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 3:
                stages[parts[0]] = parts[2]
                elapsed[parts[0]] = parts[1]

    names = sorted(n for n in os.listdir(directory) if n.endswith(".png"))
    rows = [(n[:-4], n, os.path.getsize(os.path.join(directory, n))) for n in names]

    with open(out, "w") as f:
        f.write("<!doctype html><meta charset=utf-8><title>boot frames</title>\n")
        f.write("<style>body{font:13px system-ui;background:#111;color:#eee}"
                "figure{display:inline-block;margin:6px;vertical-align:top}"
                "img{width:320px;border:1px solid #444;display:block}"
                "figcaption{font:11px monospace;color:#9cf}</style>\n")
        f.write("<h1>boot frames (%d)</h1>\n" % len(rows))
        for stamp, name, size in rows:
            f.write("<figure><a href='%s'><img src='%s'></a>"
                    "<figcaption>%s &nbsp; t=%ss &nbsp; <b>%s</b></figcaption></figure>\n"
                    % (name, name, stamp, elapsed.get(stamp, "?"), stages.get(stamp, "")))

    print("%-18s %-7s %-9s %s" % ("frame", "t(s)", "KB", "stage"))
    for stamp, name, size in rows:
        print("%-18s %-7s %-9.0f %s" % (stamp, elapsed.get(stamp, "?"),
                                         size / 1024.0, stages.get(stamp, "")))
    print("\nwrote %s" % out)


main()
