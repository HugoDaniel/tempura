# E1 — two files, one document

One hand-written timeline, rendered into a `.mid` and into a `.it`, and
both files read back. The three documents print the same tempo map.

Plan 11's E1 demo asks for the DAW export and the tracker module of the
same piece dumped, each a document with a derived skeleton, beside the
hand-written native timeline, and `tempura timeline` of all three
printing the same tempo map. That is what is here, with one substitution:
the piece is `examples/tracker/piece.sjon` rather than `impulse-04.it`
and a DAW export of it. `impulse-04.it` is a personal module and foreign
fixtures are never committed (plan 09, "Foreign fixtures are personal"),
and there is no DAW on this machine. A shipped example that renders to
both formats makes the same point and can be re-run by anyone.

## The commands

```
tools/zt cli

zig-out/bin/tempura build examples/tracker/piece.sjon --kind mid --cc 1 --no-residue -o demos/e1-two-files-one-document/piece-as-daw.mid
zig-out/bin/tempura build examples/tracker/piece.sjon --kind it --no-residue -o demos/e1-two-files-one-document/piece-as-tracker.it

zig-out/bin/tempura dump demos/e1-two-files-one-document/piece-as-daw.mid -o demos/e1-two-files-one-document/daw-skeleton.sjon
zig-out/bin/tempura dump demos/e1-two-files-one-document/piece-as-tracker.it -o demos/e1-two-files-one-document/tracker-skeleton.sjon

zig-out/bin/tempura timeline examples/tracker/piece.sjon -o demos/e1-two-files-one-document/timeline-native.sjon
zig-out/bin/tempura timeline demos/e1-two-files-one-document/daw-skeleton.sjon -o demos/e1-two-files-one-document/timeline-daw.sjon
zig-out/bin/tempura timeline demos/e1-two-files-one-document/tracker-skeleton.sjon -o demos/e1-two-files-one-document/timeline-tracker.sjon
```

`--no-residue` is deliberate. E1 is the milestone before the residue
exists, and a file with no residue is also what every foreign file is.
Both dumps therefore take reconciliation rule 1 and open with

```
; skeleton: derived, no residue found
```

so the timeline in each is what the bytes alone justify, not what the
document said.

All three documents validate clean:

```
$ zig-out/bin/tempura validate examples/tracker/piece.sjon
examples/tracker/piece.sjon: no diagnostics
$ zig-out/bin/tempura validate demos/e1-two-files-one-document/daw-skeleton.sjon
demos/e1-two-files-one-document/daw-skeleton.sjon: no diagnostics
$ zig-out/bin/tempura validate demos/e1-two-files-one-document/tracker-skeleton.sjon
demos/e1-two-files-one-document/tracker-skeleton.sjon: no diagnostics
```

Plan 11 asks for the native timeline validated in the LSP. No LSP session
is recorded here. `sjon-project.sjon` composes the four manifests and a
test in `src/Schema.zig` compares that project's vocabulary against the
preloaded one head for head, so the editor sees what the CLI sees; the
session itself is UNMEASURED.

## The same tempo map, three times

The document's own map:

```
(segment :tick 0 :us 480000 :tps "4196E93C00000000" :start-sec "0000000000000000")
(segment :tick 369008640 :us 428571.4285714286 :tps "4199A91000000000" :start-sec "400EB851EB851EB8")
```

Conducted by the `.mid`:

```
(segment :tick 0 :us 480000 :tps "4196E93C00000000" :start-sec "0000000000000000")
(segment :tick 369008640 :us 428571 :tps "4199A911AE82B0D1" :start-sec "400EB851EB851EB8")
```

Conducted by the `.it`:

```
(segment :tick 0 :us 480000 :tps "4196E93C00000000" :start-sec "0000000000000000")
(segment :tick 369008640 :us 428571.4285714286 :tps "4199A91000000000" :start-sec "400EB851EB851EB8")
```

Two segments each, at the same two TICKS, starting at the same two
seconds. That is the claim: a tempo step written at bar 2 of a document
is a tempo step at bar 2 of the file, whichever format the file is.

One number differs. A `.mid` stores a tempo as an integer number of
microseconds per quarter, so 140 qpm — 428571.4285714286 µs — is written
as 428571 and read back as 428571. The `.it` stores a tempo as a BPM
integer, `T8C` at row 32, and 140 converts back exactly, which is why its
second segment is the document's to the last digit.

The size of the `.mid`'s rounding shows in the four bars the document and
the `.mid` agree on: 7.268571428571429 s of wall clock from the document,
7.268568 s from the file. Three microseconds over four bars, in the one
documented seam, and never a tick out of place.

## What the skeleton cannot know

The rest of the three outputs differs, and every difference is something
the residue carries and `--no-residue` threw away.

| Line | native | `.mid` | `.it` |
|---|---|---|---|
| `:end` | `loop` | `hold` | `hold` |
| length | 4 bars | 4 bars | 11 bars |
| sections | `a`, `b` | none | none |
| cues | `fill` | `fill` | none |
| lane names | `bass`, `chord`, `sweep`, `hats` | `t2-ch1`, `t3-ch1`, `t4-ch1-cc1` | `ch1`, `ch1-vol`, `ch2`, `ch3`, `ch4`, `ch5-vol` |

* **`:end` and the sections are document facts.** Neither format has a
  field for them, so without the residue they are gone and the end
  behaviour falls back to `hold`.
* **The cue survives into the `.mid`** because a cue is an SMF marker,
  which is a first-class event. The `.it` has no per-row text field, so
  its cue is gone. (`--cues` on a dump makes one cue per played order,
  which is a different thing: an index, not the document's point.)
* **The lanes come back named by address**, because that is all the bytes
  say: track 2 channel 1, or IT channel 5's volume column. The document's
  names, targets and bindings are in the essence. The onset counts still
  agree lane for lane, which is the derivation working.
* **The `.it`'s length is 11 bars, not 4.** The document's `:length 4bar`
  is gone, so the length is derived from what the module plays, and a
  tracker module plays until its timing state repeats: the walk ends at
  the first `(order, row)` it revisits with an identical timing state
  (`src/itf/walk.zig`), which here is 161 rows rather than the 128 rows
  the two patterns hold, because the `T8C` at row 32 is what makes the
  state come round. The default length rounds that content end up to the
  next bar line, giving 11 bars and 19.268571428571427 s. Restore the
  residue and `:length 4bar` comes back with it, which is exactly what
  `examples/tracker/README.md` shows.

The two files here are 409 and 489 bytes. Drop `--no-residue` and the
`.it` is `examples/tracker/piece.it`, 6607 bytes, and it dumps back to
this document form for form — `examples/tracker/README.md` shows that
round trip and `corpus/examples-tracker/`'s golden asserts it.
