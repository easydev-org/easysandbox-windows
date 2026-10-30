# lib/ - shared pieces, taken from easydev-org/easydiskbake

Nothing here knows what operating system is being installed. That is the point: every bake
ends the same way - a disk that boots - and the only part that differs is the installer
own configuration interface.

| file | what | where it came from |
|---|---|---|
| qmp.py | QMP client: absolute pointer, key events, screendump | easydiskbake/lib/qmp.py |
| keys.py | characters to QKeyCodes | easydiskbake/lib/keys.py |
| snapshots.py | one frame every N seconds, for a whole run | easydiskbake/lib/snapshots.py |

## Why QMP and not HMP

Both projects reached this separately, from the same failure. QEMU HMP mouse_move carries
RELATIVE deltas, while a guest with usb-tablet is an ABSOLUTE device - so the deltas go
nowhere. dockur-macos recorded the result: sixty-four clicks, the pointer still in the
top-left corner, sixty-four byte-identical frames.

QMP input-send-event takes abs axes plus explicit button state, which is what an absolute
pointer needs.

The Windows pipeline only ever typed, so this never bit it - but the moment anything here
needs to click, which an OCR-driven installer does, HMP would fail in exactly that way.

## Why keys.py reports an unmapped character

A character with no mapping has to raise, not be dropped. A silently missing letter produces
an account with the wrong name, and that surfaces much later as the password does not work.
guest.py own key map made the same choice, independently, and the two tables agree on all
96 printable characters - checked.

## A copy, not a shared package, and why that is a real risk

These are copied rather than installed from a package: three repositories, no shared build.
The risk is drift - a fix in one does not reach the others, and the next person cannot tell
which version they have. This file records the source so the copies can be compared; when
easydiskbake/lib changes, diff it against this directory.
