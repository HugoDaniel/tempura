# E3 — one file

A native timeline, built into a `.mid` and into a `.it`, dumped back
essence-exact from either. Then the same `.mid` edited behind tempura's
back, and the reconciliation table doing its job.

## The document

`piece.sjon`: two sections, a cue, a notes lane, a curve lane whose
middle keyframe eases with a `(spring :damping 0.35)`, and a query lane.
Three of those are things neither format has a field for.

```
(section :name rise :at 0bar :dur 2bar)
(cue :name "turn" :at 2bar)
(keyframe :at 1bar :value 1 :ease (spring :damping 0.35))
(lane :name grit :kind query :target grit :query (euclid 7 16 2))
```

## The commands

```
tools/zt cli

zig-out/bin/tempura build demos/e3-one-file/piece.sjon --kind mid --cc 11 -o demos/e3-one-file/one-file.mid
zig-out/bin/tempura build demos/e3-one-file/piece.sjon --kind it -o demos/e3-one-file/one-file.it

zig-out/bin/tempura dump demos/e3-one-file/one-file.mid -o demos/e3-one-file/one-file.mid.sjon
zig-out/bin/tempura dump demos/e3-one-file/one-file.it -o demos/e3-one-file/one-file.it.sjon

python3 demos/e3-one-file/patch_velocity.py demos/e3-one-file/one-file.mid demos/e3-one-file/one-file-edited.mid
zig-out/bin/tempura dump demos/e3-one-file/one-file-edited.mid -o demos/e3-one-file/one-file-edited.sjon
```

Both builds warn `residue_only` for `grit`, and the `.it` build also
warns `it_no_instrument`. Both warnings are the design describing itself.

## Essence-exact, both kinds

4170 bytes of `.mid` and 4577 bytes of `.it`, each carrying the same
3583-byte essence. `check-residue` reads the file alone — no document, no
schema, no timeline restored:

```
$ zig-out/bin/tempura check-residue demos/e3-one-file/one-file.mid
essence: 3583 bytes, envelope version 1
conductor: hash matches
lane snare: track 2 ch 1, hash matches
lane bloom: track 3 ch 1 cc 11, hash matches
```

```
$ zig-out/bin/tempura check-residue demos/e3-one-file/one-file.it
chunk: present, read
tail: present
essence: 3583 bytes, envelope version 1
conductor: hash matches
lane snare: channel 1, hash matches
lane bloom: channel 2 column vol, hash matches
```

Two rendered lanes, two records, every hash over the events the file now
holds; `grit` has no record because neither format ever held it. The
`.it` reports both carriers: the `TMPU` trailing chunk and the message
tail.

Both dumps bring the document back form for form —
`one-file.mid.sjon` and `one-file.it.sjon` carry the same timeline tier,
the spring included:

```
(keyframe :at 1bar :value 1 :ease (spring :damping 0.35))
(lane :name grit :kind query :target grit :query (euclid 7 16 2))
```

A renderer samples `hold` and `linear` and nothing else (plan 08), so the
spring is written into the file as steps and is read back out of the
essence, exactly. The query lane never reached the file at all.

The `.it`'s message tail is what a tracker shows under the song text:

```
;; tempura
(timeline :title "one-file" :length 4bar :end loop)
(section :name rise :at 0bar :dur 2bar)
(section :name fall :at 2bar :dur 2bar)
(cue :name "turn" :at 2bar)
(lane :name snare :kind notes)
(lane :name bloom :kind curve :range [0 1])
(lane :name grit :kind query :query (euclid 7 16 2))
```

It reads as a table of contents on purpose. If a tracker re-save keeps
only the tail, that text alone rebuilds the sections, the cue and the
lane list, and the dump reports `residue_partial` for the rest.

## The foreign edit

No DAW is installed here, so the edit is simulated at the byte level by
`patch_velocity.py`: one velocity byte, 100 to 40, on the first note-on
of the `snare` track. Nothing else changes, the residue included.

```
$ python3 demos/e3-one-file/patch_velocity.py demos/e3-one-file/one-file.mid demos/e3-one-file/one-file-edited.mid
patch_velocity: note: 902664 occurs more than once; patching the first
patch_velocity: demos/e3-one-file/one-file.mid -> demos/e3-one-file/one-file-edited.mid
  offset 0x00000EBC: velocity 100 -> 40
  4170 bytes in, 4170 bytes out
```

The residue still says 100. The lane record's hash is over the events
tempura rendered, so it no longer matches what the file holds:

```
$ zig-out/bin/tempura check-residue demos/e3-one-file/one-file-edited.mid
essence: 3583 bytes, envelope version 1
conductor: hash matches
lane snare: track 2 ch 1, hash differs
lane bloom: track 3 ch 1 cc 11, hash matches
```

One lane differs and one does not. That is what per-lane records are for:
a foreign edit is detected per lane, not per file.

The dump then takes plan 04's rule 2 and says so:

```
$ zig-out/bin/tempura dump demos/e3-one-file/one-file-edited.mid -o demos/e3-one-file/one-file-edited.sjon
demos/e3-one-file/one-file-edited.mid:0x00000000: warning residue_stale:
lane snare at track 2 ch 1: the file's events are not the ones this
residue recorded, so the file wins and the lane is bound there;
dropped 8 notes
```

And the lane comes back BOUND rather than native:

```
(lane :name snare :kind notes :target snare :from song :track 2 :ch 1)
```

That one line is the whole rule. The file's native content is the truth
for what the file can say, so the eight `(note …)` forms are gone and the
lane reads its content from track 2 channel 1 — where the first velocity
is now 40, the DAW's value, not tempura's:

```
(note-on :at 960 :ch 1 :key 38 :vel 40)
```

Everything the file cannot say is still the residue's and comes back
untouched: `:length 4bar`, `:end loop`, both sections, the cue, the
spring-eased curve lane and the query lane. `tempura timeline` on the
edited document finds the same eight onsets at the same eight ticks — the
music is intact, one velocity is the DAW's, and the arrangement is still
the document's.

`one-file.mid.sjon` against `one-file-edited.sjon` is the diff worth
reading: one lane changed shape, one velocity changed value, nothing else
moved.

## The step that is UNMEASURED

Plan 11's E3 demo asks for one more thing: the `.it` reopened in OpenMPT
with the message tail visible, re-saved, and re-dumped with
`residue_partial` naming what the tail lacks.

**UNMEASURED.** OpenMPT is not installed on this machine and neither is
Schism or DOSBox (`conformance/PINS.md`). The procedure is
`conformance/CHECKLIST.md` sections A and C, and the expectation — the
tail kept, the chunk dropped — is stated and unverified in plan 04. The
`residue_partial` path itself is not untested: `corpus/residue-tail-only/`
pins it over a hand-built module with the chunk removed, which is the
same input a re-save would produce if the expectation holds.

The same applies to the DAW half. `patch_velocity.py` changes one byte;
a real DAW would also requantise, reorder tracks and drop what it does
not understand. What survives which DAW is `demos/e0-carriers/`'s second
table, and it is UNMEASURED too.
