# The DAW piece

A `.mid` a DAW opens, and the timeline that is inside it.

`piece.sjon` is a native timeline document. Every note, keyframe and
window lives in the document itself and no file is read to load it.
`piece.mid` is that document rendered into a Standard MIDI File with the
residue attached. `piece.dump.sjon` is `piece.mid` read back: the same
timeline tier, plus the file anchored inline as a `midi/` tier.

## The commands that produced these files

Build the CLI once.

```
tools/zt cli
```

Then, from the repository root:

```
zig-out/bin/tempura build examples/daw/piece.sjon --kind mid --cc 1 -o examples/daw/piece.mid
zig-out/bin/tempura dump examples/daw/piece.mid -o examples/daw/piece.dump.sjon
```

The build prints one warning:

```
examples/daw/piece.sjon:0x0000081A: warning residue_only: the query lane
'spark' is computed, and a .mid holds no query or formula: it rides in the
residue alone
```

`--cc 1` is load-bearing. A native curve lane names a target, not a
controller, so without it `haze` would be `render_cc_missing` and would
ride in the residue alone like `spark`. With it, `haze` is sampled onto
controller 1 and a DAW shows it as a modulation-wheel envelope.

## The round trip that holds

`dump(build(doc))` is this document again, form for form at the timeline
tier. The corpus asserts it: `corpus/examples-daw/` symlinks
`piece.sjon` as its `doc.sjon` and its golden carries `(rung3 :ok true)`
beside the built bytes' hash. `corpus/examples-daw-mid/` symlinks
`piece.mid` and pins the committed bytes by hash, so the two goldens hold
the same sha256 and a stale artifact is a two-line diff.

What the round trip rests on is per-lane hashing, and `check-residue`
shows it over the file alone, with no document and no schema:

```
$ zig-out/bin/tempura check-residue examples/daw/piece.mid
essence: 5196 bytes, envelope version 1
conductor: hash matches
lane kick: track 2 ch 1, hash matches
lane lead: track 3 ch 1, hash matches
lane haze: track 4 ch 1 cc 1, hash matches
```

Three rendered lanes, three records, every hash over the events the file
now holds. `spark` has no record because a `.mid` never held it: it comes
back from the essence whole. Edit a velocity in a DAW and that lane's
hash stops matching, the dump takes the file's events as the truth for
what the file can say, and the diagnostics name what was dropped. That
is the same table `demos/e3-one-file/` walks with a byte patched by hand.

## One warning worth reading

`tempura export-score examples/daw/piece.sjon` warns:

```
examples/daw/piece.sjon:21:1: warning export_meter_unsupported: meter
changes to [3 4] at bar 6; pacer keeps [4 4]; positions stay exact,
bar/phase lanes drift from there
```

The meter change is in the `.mid` as a time-signature event and in the
document as a `(meter-point …)`. It is pacer's transport that holds one
meter, so the exported score keeps `[4 4]` and says so. Positions are
still exact ticks; only a pacer lane that asks for the bar phase drifts
after bar 6. The document is the authority, and the export is honest
about what it could not carry.
