# tempura — the timeline as a value

The family's timeline core: a versatile timeline with no UI. One SJON
document, `(timeline …)`, is the authoritative arrangement of a piece in
musical time — tempo and meter maps, sections and cues, lanes of notes
and keyframes, pattern queries and formulas, phrases placed as clips,
pacer's controls passed through.

One tick grid contains SJON's and pacer's grid, every DAW's SMF division
and Impulse Tracker's tick exactly. A `.mid` and a `.it` are read as
values, 1:1 with the bytes, and written back deterministically. What the
timeline says and the file cannot rides in that file's own metadata
slots, so the file alone reconstructs the document while a DAW or a
tracker still opens it as if nothing were there.

tempura never evaluates a value at time `t`. It exports the pacer score
that does.

Zig 0.16, CC0-1.0, no runtime dependency but SJON (a sibling path
checkout at `../SJON`). Same inputs give byte-identical outputs, native
and wasm32.

```
tools/zt cli
zig-out/bin/tempura build examples/tracker/piece.sjon --kind it -o piece.it
zig-out/bin/tempura dump piece.it            # the document comes back
zig-out/bin/tempura check-residue piece.it   # and here is why it could
```

## The verbs

`tempura <verb> FILE`. `-` reads stdin, artifacts go to stdout unless
`-o` names a file, diagnostics always go to stderr. `zig-out/bin/tempura
--help` is the full option list.

| Verb | What it answers |
|---|---|
| `dump FILE` | a `.mid` or `.it` as a timeline document |
| `build DOC` | a document as a `.mid` or `.it`, residue attached |
| `export DOC --kind K` | the same file with no residue, for playing |
| `validate DOC` | the schema and host checks, with spans |
| `inspect FILE` | the annotated byte map of a `.mid` or `.it` |
| `timeline DOC` | the derived `TimeMap` as data (`--json` too) |
| `export-score DOC` | the pacer score |
| `inline DOC` | an anchor's tiers, dumped into the document |
| `edit DOC --op JSON` | plan and apply one structural edit |
| `at DOC --seconds S` | one playhead answer, decoded |
| `check-residue FILE` | what a file carries, and whether it still agrees |

Exit codes are a verdict on the input, not on the tool: `0` no errors,
`1` the document or file has errors, `2` a usage error, `3` out of
memory or a dead output stream.

## The build verbs

**Every build goes through `tools/zt`**, never `zig build` directly. It
is a `mkdir` lock that serialises compilation machine-wide and caps the
job count, because several parallel Debug test builds will exhaust this
machine's memory. If it prints `waiting`, wait.

| Command | Purpose |
|---|---|
| `tools/zt test` | every inline test; `-Dtest-root=<path-relative-to-src>` runs one subtree |
| `tools/zt verify` | the gate: test + CLI goldens + native corpus + `node --test` + the wasm size budget + the pacer-schema drift check + the generated-docs drift check |
| `tools/zt corpus` | the native golden gate; `-- --update` regenerates and the diff is reviewed |
| `tools/zt fixtures` | re-derive the corpus's committed binary fixtures from the cores' builders |
| `tools/zt landing` | regenerate `npm/tempura/test/fixtures` for the pacer landing proof |
| `tools/zt cli` | the native `tempura` binary; `tools/zt run -- <args>` runs it without installing |
| `tools/zt wasm` | `tempura.wasm`, wasm32-freestanding, ReleaseSmall, and a copy into `npm/tempura/` |
| `tools/zt wasm-budget` | the wasm against its frozen size ceiling |
| `tools/zt fuzz` | the never-panic harnesses, separate from `verify` so the gate stays fast |
| `tools/zt conform` | the oracle matrix (libopenmpt, midicsv, the OpenMPT wiki cases); skips with a reason and exits 0 when a tool is absent, and is a nightly job rather than part of `verify` |
| `tools/zt audit-diagnostics` | every raised `Diag.Code` variant is referenced by name in some test |
| `tools/zt docs` | regenerate `docs/timeline-language.md` from `schema/tempura.sjon`'s own descriptions |
| `tools/zt cli-golden` | regenerate the CLI goldens |

## The fidelity ladder, as shipped

| Rung | Claim | Where it is asserted |
|---|---|---|
| 1 | `write(read(bytes)) == bytes` for every file the canonical writers produced | the corpus's `(roundtrip)` and `(build)` directives, both formats |
| 2 | `read(write(read(f))) ≡ read(f)` for a foreign layout — event by event for a `.mid`, field by field with every pass-through region byte-equal for a `.it` | the corpus's `(roundtrip)`, over fixtures the canonical writer would never have produced |
| 3 | `dump(build(doc, kind))` is the document again at the timeline tier | the corpus's `(build)` directive, `(rung3 :ok …)` per case |
| — | music-exact under a foreign edit: a changed lane's hash stops matching, the file's events become the truth for what the file can say, and the diagnostics list the loss | the seven `residue-*` corpus cases and `demos/e3-one-file/` |
| — | never-panic over arbitrary bytes: both readers, the VLQ decoder, the pattern unpacker, the residue unpackers, the pattern queries and `dump` | `tools/zt fuzz` (`src/fuzz.zig`) |
| — | one answer, two hosts: the golden corpus re-derived from `tempura.wasm` in `node` | `npm/tempura/test/corpus.test.js`, inside `verify` |
| — | every printed position lands on the tick tempura claims, read back by the real `pacer.wasm` | `npm/tempura/test/landing.test.js`, with a mutation test that fails on a one-tick error |

78 corpus cases, and every shipped example is one of them.

## What is unmeasured

Three claims are stated and NOT verified, and none of them is assumed
green anywhere in this repo.

1. **Residue survival per tool.** Whether OpenMPT, Schism, IT 2.14 or any
   DAW keeps the payloads through a re-save or a re-export. The procedure
   and the empty tables are `conformance/CHECKLIST.md` section C, with
   the summary in `demos/e0-carriers/README.md`. The design is total
   either way: a file whose residue is gone dumps as a derived skeleton.
2. **Invisibility to foreign readers.** That a file with residue and the
   same file without it report the same duration, tempo and names.
   Automatable in part — `tools/zt conform` runs the libopenmpt half —
   and unrun because the oracles are not installed
   (`conformance/PINS.md`).
3. **The impulsos measure.** E0's census of a real piece's beat-level
   facts. The piece is not on this machine, so no count was estimated and
   no conclusion drawn from it.

`docs/plans/04-residue.md`'s progress log carries the same list with its
date.

## Where things are

| Path | What |
|---|---|
| `docs/plans/` | the spec, `00`–`11`; read `README.md` there first and `11-demos-and-milestones.md` when picking up work |
| `docs/plans/11-demos-and-milestones.md` | the status board and the **ledger of decisions** — every ruling, dated, with what it would cost if wrong |
| `docs/timeline-language.md` | the timeline vocabulary, generated from the manifest and drift-gated |
| `docs/residue.md` | the payload formats, restated so another reader could implement them |
| `docs/grid.md` | the tick grid and its tables, restated for consumers |
| `CLAUDE.md` | the conventions: layering, aggregators, the frozen surfaces, the gates |
| `schema/` | four manifests plus the harness one; `pacer.sjon` is a verbatim copy and drift-gated |
| `examples/` | a native piece, a DAW piece, a tracker piece, each a corpus case |
| `demos/` | one directory per milestone, with the commands that produced it |
| `conformance/` | the oracle matrix, the manual checklist, the version pins |
| `npm/tempura/` | the ESM glue around `tempura.wasm`, and the parity and landing tests |

The 0.1.0 tag is not cut. The code reaches E3 with its freezes
documented, and the tag is the user's signal to give.
