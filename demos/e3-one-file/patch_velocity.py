#!/usr/bin/env python3
"""Stand in for a DAW: change one velocity byte in a .mid and write it out.

    python3 demos/e3-one-file/patch_velocity.py one-file.mid one-file-edited.mid

No DAW is installed on the authoring machine, so a foreign edit is
simulated at the byte level. This is a FAITHFUL stand-in for the only
thing the demo needs: a note-on whose velocity is no longer what tempura
rendered. A real DAW would also requantise, rewrite the track order and
drop what it does not understand, which is why the survival tables in
`demos/e0-carriers/README.md` stay UNMEASURED.

The patch targets the first note-on of the `snare` track: status 0x90
(channel 1 as tempura prints it), key 0x26 (38), velocity 0x64 (100).
It becomes 0x28 (40). Nothing else in the file changes, the residue
included, which is the point: the essence still says 100 and the lane
record's hash still hashes the events tempura rendered.
"""

import sys

NEEDLE = bytes([0x90, 0x26, 0x64])   # note-on, channel 1, key 38, velocity 100
NEW_VELOCITY = 0x28                  # 40


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    src, dst = argv[1], argv[2]
    with open(src, "rb") as f:
        data = bytearray(f.read())
    at = data.find(NEEDLE)
    if at < 0:
        print(f"patch_velocity: {src}: no {NEEDLE.hex()} note-on found", file=sys.stderr)
        return 1
    if data.find(NEEDLE, at + 1) >= 0:
        # Several matches would make the demo's offset ambiguous; the
        # first is still the one patched, and the run says so.
        print(f"patch_velocity: note: {NEEDLE.hex()} occurs more than once; patching the first")
    old = data[at + 2]
    data[at + 2] = NEW_VELOCITY
    with open(dst, "wb") as f:
        f.write(bytes(data))
    print(f"patch_velocity: {src} -> {dst}")
    print(f"  offset 0x{at + 2:08X}: velocity {old} -> {NEW_VELOCITY}")
    print(f"  {len(data)} bytes in, {len(data)} bytes out")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
