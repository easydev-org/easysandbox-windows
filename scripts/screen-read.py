#!/usr/bin/env python3
"""Read a QEMU screendump and say what stage the Windows installer is at.

    screen-read.py <screen.ppm>

Prints one word describing the screen, so a shell can branch on it:

    desktop       the taskbar is up - installation is finished
    installing    Setup/Install is on screen with a percentage or a spinner
    oobe          the first-boot questions (region, account, privacy)
    language      Setup's first page, which a working answer file should skip
    unknown       anything else, including a black or blank framebuffer

WHY THIS EXISTS. The disk-size and boot-marker checks both said "finished" while
Windows was still installing, so every bake exported a half-installed disk. The only
signal that cannot lie is what the guest is drawing: a desktop has a taskbar, an
installer has progress text, and the two are trivially distinguishable by OCR.

tesseract reads P6 PPM directly, so there is no conversion step to fail. The text is
lower-cased and matched against the phrases Setup actually uses, in the languages
this project installs.
"""
import re
import subprocess
import sys


def ocr(ppm):
    try:
        out = subprocess.run(["tesseract", ppm, "stdout", "--psm", "3"],
                             capture_output=True, text=True, timeout=120)
        return (out.stdout or "").lower()
    except FileNotFoundError:
        return None
    except Exception:
        return ""


def classify(text):
    t = re.sub(r"\s+", " ", text)

    # Setup's own progress wording. Seen on this project's bakes:
    #   "Installing Windows 11 - 84% complete"
    #   "Installing 42% - Please keep your computer on."
    if re.search(r"installing\s+(windows|updates|\d+%)", t) or "% complete" in t:
        return "installing"
    if "please keep your computer on" in t or "your pc will restart" in t:
        return "installing"
    if "copying files" in t or "getting files ready" in t or "preparing" in t:
        return "installing"

    # First-boot questions.
    if ("let's connect" in t or "lets connect" in t or "sign in" in t
            or "create a user" in t or "region is correct" in t
            or "is the region correct" in t):
        return "oobe"

    # The page a working answer file must skip.
    if "select language" in t or "language to install" in t:
        return "language"

    # A desktop has a taskbar whose clock is drawn; the start menu text and the
    # desktop's own "Recycle Bin" label are the most reliable words on it.
    if "recycle bin" in t or "type here to search" in t:
        return "desktop"

    return "unknown"


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: screen-read.py <screen.ppm>")
    text = ocr(sys.argv[1])
    if text is None:
        print("unknown")
        sys.exit("tesseract is not installed")
    stage = classify(text)
    print(stage)
    # The raw text goes to stderr so the caller can log it without polluting the
    # single-word answer on stdout.
    sys.stderr.write("ocr: " + re.sub(r"\s+", " ", text).strip()[:400] + "\n")


main()
