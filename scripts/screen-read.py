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
    """Is there a taskbar along the bottom edge?

    Returns (found, detail).

    The first version required rows that were >92% a single colour, on the reasoning
    that a taskbar is a flat fill. It failed on a real Windows 11 desktop - measured
    on a captured one: the taskbar occupies y=752..799 with dominant colour #eeeeee
    the whole way, but uniformity dips to 0.74 exactly where the icons sit. So the
    flatness threshold rejected the very thing it was looking for, twice, and the
    desktop was reported as 'no flat band (tallest run 8)' while it was on screen.

    What actually identifies a taskbar is narrower and more robust: the bottom strip
    is dominated by ONE colour, row after row, and that colour is different from the
    page above it. Icons puncturing the colour raise variety but do not change the
    dominant colour, so the test uses the dominant colour's identity rather than its
    share.
    """
    # SCAN UP FROM THE BOTTOM; do not start at a fixed fraction of the height.
    #
    # Two earlier versions anchored the strip at 94% and 90% of the height. Both were
    # defeated by what happened to be on screen: at 90% the anchor landed inside an
    # open Start menu (#eeeeee), 40 rows above the real taskbar, and the comparison
    # with "the page above" then matched - so a real taskbar was rejected. The
    # taskbar is, by definition, the thing at the very bottom, so it is found by
    # walking up from the last row for as long as the dominant colour stays the same.
    profile = [(y, c, u) for y, c, u in rows(w, h, px)]
    if not profile:
        return False, "empty framebuffer"

    bottom_colour = profile[-1][1]
    band = 0
    for y, colour, uni in reversed(profile):
        if colour != bottom_colour:
            break
        band += 1
    share = band / float(h)

    # A taskbar is a THIN band: >= 20 rows to be a real bar, but a small slice of the
    # height. The 30% ceiling let a false positive through: a Setup screen whose lower
    # half is flat black ran 234 rows (29% of 800) and was called a taskbar, while the
    # picture plainly showed 'Please keep your PC on' and no shell at all.
    #
    # 10% is the honest ceiling. At 1280x800 the taskbar measured 47 rows (6%); even
    # at a generous 96px taskbar on a 1080p screen it is under 9%. A band covering a
    # tenth of the display is background, not a bar.
    if band < 20:
        return False, ("bottom %d rows are uniform - too thin for a taskbar "
                       "(colour #%02x%02x%02x)"
                       % (band, bottom_colour[0], bottom_colour[1], bottom_colour[2]))
    if share > 0.10:
        return False, ("the bottom colour #%02x%02x%02x covers %.0f%% of the height - "
                       "that is background, not a taskbar"
                       % (bottom_colour[0], bottom_colour[1], bottom_colour[2], share * 100))

    return True, ("band #%02x%02x%02x occupies the bottom %d rows (%.0f%% of the height)"
                  % (bottom_colour[0], bottom_colour[1], bottom_colour[2],
                     band, share * 100))


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
    # The screens around a reboot. Seen on this project's bakes: the frame that got
    # misread as a desktop said exactly this, and a taskbar-shaped black region under
    # it was enough to convince the pixel test. Wording like this overrules pixels.
    if "please keep your pc on" in t or "keep your computer on" in t:
        return "installing"
    if "plugged in" in t or "don't turn off" in t or "do not turn off" in t:
        return "installing"
    if "just a moment" in t or "almost there" in t or "working on updates" in t:
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
