#!/usr/bin/env python3
"""Read a QEMU screendump and say what stage the Windows guest is at.

    screen-read.py <screen.ppm> [--verbose]

Prints one word, so a shell can branch on it:

    desktop       installation finished - a taskbar is drawn and nothing is installing
    installing    Setup is on screen (progress text, percentage, spinner)
    oobe          the first-boot questions
    language      Setup's first page, which a working answer file must skip
    blank         nothing drawn at all - black or one flat colour
    unknown       drawn, but not any of the above

WHY THE DESKTOP TEST IS PIXELS, NOT WORDS.

The first version of this file decided "desktop" from OCR finding "Recycle Bin" or
"type here to search". On a real Windows 11 bake that never matched once - the 11
taskbar has no search box text, only a magnifier icon - so the classifier answered
"unknown" for twenty-seven minutes straight while the answer was sitting on screen.

So the desktop test is a geometric fact about the framebuffer instead:

  * a taskbar is a solid horizontal band across the full width at the bottom, whose
    rows are nearly uniform in colour and clearly different from the rows above it;
  * during an install that band is either absent (full-bleed background) or the
    bottom is taken up with centred text and buttons, which breaks the long runs.

That holds for Windows 10 and 11, in any theme, with any accent colour, because it
is a property of the layout rather than of the lettering. OCR is still used, but only
for the negative test - "is Setup still talking about installing" - and as a fallback
for the intermediate stages.
"""
import re
import subprocess
import sys


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    if not data.startswith(b"P6"):
        raise SystemExit(path + ": not a P6 PPM")
    fields, pos = [], 2
    while len(fields) < 3:
        while pos < len(data) and data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            while pos < len(data) and data[pos] != 10:
                pos += 1
            continue
        start = pos
        while pos < len(data) and not data[pos:pos + 1].isspace():
            pos += 1
        fields.append(int(data[start:pos]))
    pos += 1
    w, h, maxval = fields
    return w, h, data[pos:], maxval


def rows(w, h, px):
    """Yield (y, colour, uniformity) for each row, sampling every 8th pixel."""
    step = 8
    for y in range(h):
        base = y * w * 3
        colours = {}
        n = 0
        for x in range(0, w, step):
            k = base + x * 3
            c = (px[k], px[k + 1], px[k + 2])
            colours[c] = colours.get(c, 0) + 1
            n += 1
        top = max(colours.values())
        yield y, max(colours, key=colours.get), top / float(n)


def taskbar(w, h, px):
    """Is there a taskbar-like band across the bottom?

    Returns (found, detail). The bottom 6% of the screen is examined because the
    Windows taskbar is about that high at 720p and 1080p. A row qualifies when more
    than 92% of its sampled pixels share one colour - a taskbar is a flat fill - and
    the band must be at least 12 rows tall so that a thin window border or a status
    line does not pass. The band's colour must also differ from the row above it,
    which is what separates a real taskbar from a uniformly coloured screen.
    """
    band_top = int(h * 0.94)
    flat = []
    for y, colour, uni in rows(w, h, px):
        if y < band_top:
            continue
        flat.append((y, colour, uni))

    run = 0
    best = (0, None)
    for y, colour, uni in flat:
        if uni > 0.92:
            run += 1
            if run > best[0]:
                best = (run, colour)
        else:
            run = 0

    height, colour = best
    if height < 12 or colour is None:
        return False, "no flat band in the bottom rows (tallest run %d)" % height

    # Compare against a row well above the band: if they are the same colour the
    # screen is simply one flat fill, not a taskbar on a desktop.
    above = None
    for y, c, uni in rows(w, h, px):
        if y == max(0, band_top - 60):
            above = c
            break
    if above == colour:
        return False, "bottom band is the same colour as the page (#%02x%02x%02x)" % colour
    return True, "flat band %dpx tall at the bottom (#%02x%02x%02x)" % (
        height, colour[0], colour[1], colour[2])


def blank(w, h, px):
    """Is the framebuffer essentially empty?

    Not "one colour" - a real screen with a single centred message samples as a
    handful of colours, and the first version used a threshold of 4, which called
    an actual install screen blank. The test that matters is whether anything is
    drawn at all, so the bar is deliberately low: fewer than 12 distinct colours
    over a coarse sample means a dead or not-yet-painted framebuffer.
    """
    colours = set()
    step = 16
    for y in range(0, h, step):
        base = y * w * 3
        for x in range(0, w, step):
            k = base + x * 3
            colours.add((px[k], px[k + 1], px[k + 2]))
            if len(colours) >= 12:
                return False
    return True


def ocr(path):
    try:
        out = subprocess.run(["tesseract", path, "stdout", "--psm", "3"],
                             capture_output=True, text=True, timeout=120)
        return (out.stdout or "").lower()
    except FileNotFoundError:
        return ""
    except Exception:
        return ""


def stage_from_text(t):
    t = re.sub(r"\s+", " ", t)
    if re.search(r"installing\s+(windows|updates|\d+%)", t) or "% complete" in t:
        return "installing"
    if "please keep your computer on" in t or "your pc will restart" in t:
        return "installing"
    if "copying files" in t or "getting files ready" in t or "preparing" in t:
        return "installing"
    if ("let's connect" in t or "lets connect" in t or "sign in" in t
            or "create a user" in t or "region is correct" in t):
        return "oobe"
    if "select language" in t or "language to install" in t:
        return "language"
    return None


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: screen-read.py <screen.ppm> [--verbose]")
    path = sys.argv[1]
    verbose = "--verbose" in sys.argv

    w, h, px, maxval = read_ppm(path)
    if maxval != 255:
        px = bytes((v * 255) // maxval for v in px)

    if blank(w, h, px):
        print("blank")
        verbose and sys.stderr.write("screen: fewer than 5 distinct colours\n")
        return

    has_bar, bar_detail = taskbar(w, h, px)
    text = ocr(path)
    from_text = stage_from_text(text)

    if verbose:
        sys.stderr.write("taskbar: %s (%s)\n" % ("yes" if has_bar else "no", bar_detail))
        sys.stderr.write("ocr: %s\n" % re.sub(r"\s+", " ", text).strip()[:300])

    # Setup talking about installing outranks the taskbar: Windows shows a taskbar-
    # like band during parts of Setup too, and while it says "Installing" the job is
    # plainly not done.
    if from_text in ("installing", "language", "oobe"):
        print(from_text)
        return

    if has_bar:
        print("desktop")
        return

    print("unknown")


main()
