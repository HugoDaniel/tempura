# examples

Three shipped pieces, one per way a timeline reaches the world. Every one
of them is a corpus case, so an example that stops compiling fails the
gate rather than rotting quietly (plan 09's corpus list ends with
`examples-*`; pacer 12 D1 is the precedent).

| Piece | Files | Corpus cases |
|---|---|---|
| native | `native.sjon` | `corpus/examples-native/` |
| DAW | `daw/piece.sjon`, `daw/piece.mid`, `daw/piece.dump.sjon` | `corpus/examples-daw/`, `corpus/examples-daw-mid/` |
| tracker | `tracker/piece.sjon`, `tracker/piece.it`, `tracker/piece.dump.sjon` | `corpus/examples-tracker/`, `corpus/examples-tracker-it/` |

`daw/README.md` and `tracker/README.md` name the commands that produced
their files and the round trip that holds.

## The native piece

`native.sjon` is plan 02's own example: the whole timeline vocabulary in
one document, arranged around an anchor that is **not shipped beside it**.

That absence is the point. `impulse-04.it` is a personal module and
foreign fixtures are never committed (plan 09, "Foreign fixtures are
personal"), so a host with a filesystem resolver reports
`anchor_unavailable` and the two lanes bound to that anchor resolve to
nothing:

```
$ zig-out/bin/tempura build examples/native.sjon --kind it -o /tmp/n.it
examples/native.sjon:32:1: error anchor_unavailable: no resolver could
read "impulse-04.it"; the anchor is recorded unresolved
```

That is the condition a browser host meets on every by-reference anchor,
because wasm has no filesystem, and it is the reason `tempura inline`
exists: inline the anchor's tiers into the document once and the document
carries its own bytes from then on.

What the example does assert, with no anchor at all, is the pacer door:

```
zig-out/bin/tempura export-score examples/native.sjon
```

The score is compose-clean. It declares one `(target …)` per target the
document drives, so it loads through `pacer.wasm` with no host registry,
and every lane kind reaches pacer's vocabulary — a notes lane as a
`(trigger …)`, a curve lane as keys, a query lane as a `(pattern …)`, a
formula lane as an `(expr …)`. `npm/tempura/test/landing.test.js` loads
that score through the real `pacer.wasm` and reads every position back.

`corpus/examples-native/` pins the score's text and both builds. Its
golden is the one place in the corpus where rung 3 is false, and its
`times.sjon` says exactly why: `Doc.eql` compares a pass-through pacer
form by its source text, and restoring `(control :id glow-amt …)` from
the essence re-prints it across seven lines. The document's meaning is
unchanged; its layout is not.
