# The tracker piece

A `.it` a tracker opens, and the timeline that is inside it.

`piece.sjon` is a native timeline document. Every note, keyframe and
window lives in the document itself and no file is read to load it.
`piece.it` is that document rendered into an Impulse Tracker module with
both IT carriers attached. `piece.dump.sjon` is `piece.it` read back: the
same timeline tier, plus the module anchored inline as an `it/` tier.

## The commands that produced these files

Build the CLI once.

```
tools/zt cli
```

Then, from the repository root:

```
zig-out/bin/tempura build examples/tracker/piece.sjon --kind it -o examples/tracker/piece.it
zig-out/bin/tempura dump examples/tracker/piece.it -o examples/tracker/piece.dump.sjon
```

The build prints two warnings:

```
examples/tracker/piece.sjon:0x00000000: warning it_no_instrument: this
module carries no instrument or sample, so every rendered cell names
instrument 1: the file holds the timing and a tracker brings the sound
examples/tracker/piece.sjon:0x000008C8: warning residue_only: the query
lane 'hats' is computed, and a .it holds no query or formula: it rides in
the residue alone
```

Both are the design saying what it is. The module holds the arrangement
and a tracker brings the samples, and a `.it` has no place to keep a
pattern query.

There is no `--cc` here. An IT curve lane writes the volume column, so
there is no controller to name.

## The round trip that holds

`dump(build(doc))` is this document again, form for form at the timeline
tier. The corpus asserts it: `corpus/examples-tracker/` symlinks
`piece.sjon` as its `doc.sjon` and its golden carries `(rung3 :ok true)`
beside the built bytes' hash. `corpus/examples-tracker-it/` symlinks
`piece.it` and pins the committed bytes by hash, so the two goldens hold
the same sha256 and a stale artifact is a two-line diff.

What the round trip rests on is per-lane hashing, and `check-residue`
shows it over the file alone, with no document and no schema:

```
$ zig-out/bin/tempura check-residue examples/tracker/piece.it
chunk: present, read
tail: present
essence: 5406 bytes, envelope version 1
conductor: hash matches
lane bass: channel 1, hash matches
lane chord: channel 2, hash matches
lane chord: channel 3, hash matches
lane chord: channel 4, hash matches
lane sweep: channel 5 column vol, hash matches
```

Both carriers are there. The `TMPU` chunk holds the essence and the
records; the message tail holds a readable summary a tracker shows under
the song text. `chord` has three records because a cell holds one note,
so a three-note chord takes three channels, and each is hashed on its
own. `hats` has no record because a `.it` never held it: it comes back
from the essence whole.

A foreign tracker re-save is expected to keep the tail and drop the
chunk, which is why the tail alone rebuilds sections, cues and lane
bindings and reports `residue_partial` for the rest. That expectation is
UNMEASURED: the procedure is `conformance/CHECKLIST.md` section C.

## The meter is [4 4] on purpose

Speed 6 and 24 IT ticks to the quarter make a row a sixteenth, so a
64-row pattern is four bars of `[4 4]` and this piece is one pattern.
A meter whose bar does not divide 64 rows is a known gap in the
renderer's pattern sizing, recorded in the plan set's progress notes
rather than papered over in an example.
